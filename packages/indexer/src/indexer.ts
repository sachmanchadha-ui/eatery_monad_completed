// Chain indexer (spec 6.3). Polls logs from a cursor, applies them in (block, logIndex) order inside one
// database transaction per batch, and records every log in chain_events keyed on (tx_hash, log_index), so a
// replayed log is a no-op. The database is a cache of chain state: `rebuild` replays from the deploy block.
import { canteenOrdersAbi, RefundReason } from '@canteenpos/sdk'
import type { Address, PublicClient } from 'viem'
import type { Db, Queryable } from './db.ts'

export type IndexerConfig = {
  chainId: number
  address: Address
  deployBlock: number
  /** Blocks per getLogs request. Public RPCs cap the range; halved automatically on error. */
  batchSize?: number
  /** Only index blocks this far behind head. Monad finalizes in about two blocks. */
  confirmations?: number
  log?: (msg: string) => void
}

/** A decoded contract log, with the block number as a plain number. */
type DecodedLog = {
  eventName: string
  args: Record<string, any>
  blockNumber: number
  logIndex: number
  transactionHash: string
}

/** Chain-derived tables, in dependency order for truncation. */
const DERIVED = ['refunds', 'order_lines', 'orders', 'session_keys', 'devices', 'item_availability', 'chain_events']

const json = (v: unknown) => JSON.stringify(v, (_k, x) => (typeof x === 'bigint' ? x.toString() : x))
const lc = (a: string) => a.toLowerCase()

export class Indexer {
  private readonly db: Db
  private readonly client: PublicClient
  private readonly cfg: IndexerConfig
  private batch: number
  private readonly confirmations: number
  private readonly log: (msg: string) => void

  constructor(db: Db, client: PublicClient, cfg: IndexerConfig) {
    this.db = db
    this.client = client
    this.cfg = cfg
    this.batch = cfg.batchSize ?? 100
    this.confirmations = cfg.confirmations ?? 2
    this.log = cfg.log ?? (() => {})
  }

  /** Creates the cursor for this deployment, or checks the stored one matches it. */
  async init(): Promise<void> {
    const { rows } = await this.db.query('select chain_id, contract from chain_cursor where id = 1')
    if (rows.length === 0) {
      await this.db.query(
        'insert into chain_cursor (chain_id, contract, deploy_block, last_processed_block) values ($1, $2, $3, $4)',
        [this.cfg.chainId, lc(this.cfg.address), this.cfg.deployBlock, this.cfg.deployBlock - 1],
      )
      return
    }
    const r = rows[0]
    if (Number(r.chain_id) !== this.cfg.chainId || r.contract !== lc(this.cfg.address)) {
      throw new Error(
        `This database indexes ${r.contract} on chain ${r.chain_id}, not ${lc(this.cfg.address)} on ${this.cfg.chainId}. Use a separate database.`,
      )
    }
  }

  async cursor(): Promise<number> {
    const { rows } = await this.db.query('select last_processed_block from chain_cursor where id = 1')
    return Number(rows[0].last_processed_block)
  }

  /** Indexes one batch. Returns the number of logs applied, or null when already caught up. */
  async syncOnce(): Promise<{ from: number; to: number; logs: number } | null> {
    const head = Number(await this.client.getBlockNumber())
    const target = head - this.confirmations
    const cursor = await this.cursor()
    if (cursor >= target) return null

    const from = cursor + 1
    let to = Math.min(cursor + this.batch, target)
    let logs: DecodedLog[]
    for (;;) {
      try {
        const raw = await this.client.getContractEvents({
          address: this.cfg.address,
          abi: canteenOrdersAbi,
          fromBlock: BigInt(from),
          toBlock: BigInt(to),
        })
        logs = raw.map((r) => ({
          eventName: r.eventName as string,
          args: r.args as Record<string, any>,
          blockNumber: Number(r.blockNumber),
          logIndex: r.logIndex,
          transactionHash: r.transactionHash,
        }))
        break
      } catch (e) {
        if (to === from) throw e
        this.batch = Math.max(1, Math.floor((to - from + 1) / 2))
        to = from + this.batch - 1
        this.log(`getLogs failed, retrying with ${this.batch} blocks`)
      }
    }
    logs.sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex)

    // Network reads happen before the transaction so it stays short.
    const times = new Map<number, number>()
    for (const bn of new Set(logs.map((l) => l.blockNumber))) {
      times.set(bn, Number((await this.client.getBlock({ blockNumber: BigInt(bn) })).timestamp))
    }
    const lines = new Map<string, readonly { itemId: number; qty: number; unitPricePaise: number }[]>()
    for (const l of logs) {
      if (l.eventName !== 'OrderPlaced') continue
      const id = l.args.orderId as bigint
      // Lines never change after placement, so the latest state is exact (no archive node needed).
      lines.set(String(id), (await this.client.readContract({
        address: this.cfg.address,
        abi: canteenOrdersAbi,
        functionName: 'getOrderLines',
        args: [id],
      })) as never)
    }

    await this.db.transaction(async (tx) => {
      for (const l of logs) await this.apply(tx, l, times.get(l.blockNumber)!, lines)
      await tx.query('update chain_cursor set last_processed_block = $1, updated_at = now() where id = 1', [to])
    })
    if (logs.length) this.log(`blocks ${from}-${to}: ${logs.length} events`)
    return { from, to, logs: logs.length }
  }

  /** Syncs until caught up with head minus confirmations. */
  async catchUp(): Promise<number> {
    let applied = 0
    for (;;) {
      const r = await this.syncOnce()
      if (!r) return applied
      applied += r.logs
    }
  }

  /** Runs forever, polling every `intervalMs` once caught up. */
  async run(intervalMs = 1000, signal?: AbortSignal): Promise<void> {
    while (!signal?.aborted) {
      try {
        const r = await this.syncOnce()
        if (r) continue
      } catch (e) {
        this.log(`sync error: ${(e as Error).message}`)
      }
      await new Promise((res) => setTimeout(res, intervalMs))
    }
  }

  /** Drops chain-derived rows and replays from the deploy block. The chain wins. */
  async rebuild(): Promise<number> {
    await this.db.transaction(async (tx) => {
      await tx.query(`truncate ${DERIVED.join(', ')}`)
      await tx.query(`delete from audit_log where actor = 'chain'`)
      await tx.query('update chain_cursor set last_processed_block = deploy_block - 1, updated_at = now() where id = 1')
    })
    this.log('derived tables cleared, replaying from the deploy block')
    return this.catchUp()
  }

  private async apply(
    tx: Queryable,
    l: DecodedLog,
    blockTime: number,
    lines: Map<string, readonly { itemId: number; qty: number; unitPricePaise: number }[]>,
  ): Promise<void> {
    const fresh = await tx.query(
      `insert into chain_events (tx_hash, log_index, block_number, block_time, event, args)
       values ($1, $2, $3, to_timestamp($4), $5, $6::jsonb)
       on conflict (tx_hash, log_index) do nothing returning 1`,
      [l.transactionHash, l.logIndex, l.blockNumber, blockTime, l.eventName, json(l.args)],
    )
    if (fresh.rows.length === 0) return // already applied

    const a = l.args
    const at = [l.blockNumber, l.logIndex]
    const setStatus = (orderId: bigint, status: string, extra = '', params: unknown[] = []) =>
      tx.query(
        `update orders set status = $2, last_event_block = $3, last_event_log = $4, updated_at = now()${extra}
         where order_id = $1`,
        [orderId, status, ...at, ...params],
      )

    switch (l.eventName) {
      case 'OrderPlaced': {
        await tx.query(
          `insert into orders (order_id, student, day_id, slot_id, token_no, payment_ref, intent_hash, total_paise,
                               status, placed_at, placed_tx, last_event_block, last_event_log)
           values ($1, $2, $3, $4, $5, $6, (select intent_hash from payments where payment_ref = $6), $7,
                   'Placed', to_timestamp($8), $9, $10, $11)
           on conflict (order_id) do nothing`,
          [a.orderId, lc(a.student), a.dayId, a.slotId, a.tokenNo, a.paymentRef, a.totalPaise, blockTime, l.transactionHash, ...at],
        )
        const ls = lines.get(String(a.orderId)) ?? []
        for (const [i, line] of ls.entries()) {
          await tx.query(
            `insert into order_lines (order_id, line_no, item_id, qty, unit_price_paise) values ($1, $2, $3, $4, $5)
             on conflict do nothing`,
            [a.orderId, i, line.itemId, line.qty, line.unitPricePaise],
          )
        }
        break
      }
      case 'CheckedIn':
        await setStatus(a.orderId, 'CheckedIn', ', present_at = to_timestamp($5), checkin_device = $6', [
          Number(a.presentAt),
          lc(a.device),
        ])
        break
      case 'Served':
        await setStatus(a.orderId, 'Served', ', served_by = $5', [lc(a.device)])
        break
      case 'Forfeited':
        await setStatus(a.orderId, 'Forfeited')
        break
      case 'RefundOwed': {
        const reason = RefundReason[Number(a.reason)] ?? String(a.reason)
        await setStatus(a.orderId, 'RefundOwed', ', refund_reason = $5', [reason])
        await tx.query(
          `insert into refunds (order_id, reason, amount_paise, status, owed_tx, owed_at)
           select $1, $2, total_paise, 'owed', $3, to_timestamp($4) from orders where order_id = $1
           on conflict (order_id) do nothing`,
          [a.orderId, reason, l.transactionHash, blockTime],
        )
        break
      }
      case 'RefundPaid':
        await setStatus(a.orderId, 'RefundPaid')
        await tx.query(
          `update refunds set status = 'paid', refund_ref = $2, recorded_tx = $3, paid_at = to_timestamp($4)
           where order_id = $1`,
          [a.orderId, a.refundRef, l.transactionHash, blockTime],
        )
        break
      case 'SessionKeyRegistered':
        await tx.query(
          `insert into session_keys (student, key_address, expiry, registered_tx, registered_block)
           values ($1, $2, to_timestamp($3), $4, $5)
           on conflict (student) do update set key_address = excluded.key_address, expiry = excluded.expiry,
             registered_tx = excluded.registered_tx, registered_block = excluded.registered_block`,
          [lc(a.student), lc(a.key), Number(a.expiry), l.transactionHash, l.blockNumber],
        )
        break
      case 'ItemAvailability':
        await tx.query(
          `insert into item_availability (day_id, item_id, available, changed_at, tx_hash)
           values ($1, $2, $3, to_timestamp($4), $5)
           on conflict (day_id, item_id) do update set available = excluded.available,
             changed_at = excluded.changed_at, tx_hash = excluded.tx_hash`,
          [a.dayId, a.itemId, a.available, blockTime, l.transactionHash],
        )
        break
      case 'DeviceAuthorized':
        await tx.query(
          `insert into devices (address, authorized_at, authorized_tx) values ($1, to_timestamp($2), $3)
           on conflict (address) do update set authorized_at = excluded.authorized_at, authorized_tx = excluded.authorized_tx`,
          [lc(a.device), blockTime, l.transactionHash],
        )
        break
      case 'DeviceRevoked':
        await tx.query(
          `insert into devices (address, revoked_at, revoked_tx) values ($1, to_timestamp($2), $3)
           on conflict (address) do update set revoked_at = excluded.revoked_at, revoked_tx = excluded.revoked_tx`,
          [lc(a.device), blockTime, l.transactionHash],
        )
        break
      default:
        // ConfigScheduled, RoleUpdated, ownership events: kept for the owner's event feed (spec 9).
        await tx.query(`insert into audit_log (actor, action, tx_hash, detail) values ('chain', $1, $2, $3::jsonb)`, [
          l.eventName,
          l.transactionHash,
          json(a),
        ])
    }
  }
}
