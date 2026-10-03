// P2 done-criterion: a scripted order, check-in and serve show correctly in the database from chain
// events alone. Also covers a no-show forfeit, a sold-out refund that gets paid, replay idempotency,
// and a full rebuild. Runs on a local anvil with in-memory Postgres (PGlite).
import { after, before, describe, test } from 'node:test'
import assert from 'node:assert/strict'
import { createPublicClient, createTestClient, createWalletClient, http, keccak256, parseEther, stringToHex } from 'viem'
import type { Address, Hex, PrivateKeyAccount } from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { foundry } from 'viem/chains'
import {
  buildIntent,
  canteenConfig,
  canteenDomain,
  canteenOrdersAbi,
  dayId,
  dayStart,
  intentStructHash,
  signChallenge,
  signCheckIn,
  signIntent,
  signPaymentAttestation,
  signSessionKeyAuth,
  type Line,
} from '@canteenpos/sdk'
import { ANVIL_PK, deployCanteen, startAnvil, write, type Clients, type Deployment } from '@canteenpos/ops'
import { Indexer, migrate, openDb, type Db } from '../src/index.ts'

const PORT = 18547
const [SLOT_1230, SLOT_1315] = canteenConfig.slots
const price = (id: number) => canteenConfig.items.find((i) => i.id === id)!.pricePaise
const VADA = 1
const DOSA = 2
const IDLI = 3
const line = (itemId: number, qty: number): Line => ({ itemId, qty, unitPricePaise: price(itemId) })

const owner = privateKeyToAccount(ANVIL_PK) // also acts as the backend submitter here
const attester = privateKeyToAccount(generatePrivateKey())
const refunder = privateKeyToAccount(generatePrivateKey())
const relayer = privateKeyToAccount(generatePrivateKey())
const device = privateKeyToAccount(generatePrivateKey())
const student = privateKeyToAccount(generatePrivateKey())
const session = privateKeyToAccount(generatePrivateKey())

let stopAnvil: () => void
let rpc: string
let db: Db
let indexer: Indexer
let dep: Deployment
let day: number
const ids = { served: 0n, forfeited: 0n, refunded: 0n }
let servedIntentHash: Hex

const pub = () => createPublicClient({ chain: foundry, transport: http(rpc) })
const as = (account: PrivateKeyAccount): Clients => ({
  pub: pub() as Clients['pub'],
  wallet: createWalletClient({ account, chain: foundry, transport: http(rpc) }),
})
const call = (account: PrivateKeyAccount, functionName: string, args: readonly unknown[]) =>
  write(as(account), { address: dep.address, abi: canteenOrdersAbi, functionName, args })

/** Moves chain time to `ts` (IST seconds since epoch) by mining a block there. */
async function at(ts: number) {
  const tc = createTestClient({ chain: foundry, mode: 'anvil', transport: http(rpc) })
  await tc.setNextBlockTimestamp({ timestamp: BigInt(ts) })
  await tc.mine({ blocks: 1 })
}

let nonce = 0n
async function placeOrder(slotId: number, lines: Line[], ref: string): Promise<{ id: bigint; intentHash: Hex }> {
  const now = Number((await pub().getBlock()).timestamp)
  const domain = canteenDomain(foundry.id, dep.address)
  const intent = buildIntent({ student: student.address, slotId, lines, nonce: ++nonce, deadline: now + 600 })
  const paymentRef = keccak256(stringToHex(ref))
  const studentSig = await signIntent(session, domain, intent)
  const attesterSig = await signPaymentAttestation(attester, domain, intent, paymentRef)
  // The backend's off-chain record of the paid intent (P3 writes these); the indexer links it by payment ref.
  await db.query(
    `insert into intents (intent_hash, student, slot_id, lines_json, total_paise, status) values ($1, $2, $3, $4, $5, 'paid')`,
    [intentStructHash(intent), student.address.toLowerCase(), slotId, JSON.stringify(lines), intent.totalPaise],
  )
  await db.query(`insert into payments (payment_ref, intent_hash, amount_paise) values ($1, $2, $3)`, [
    paymentRef,
    intentStructHash(intent),
    intent.totalPaise,
  ])
  await call(owner, 'placeOrder', [intent, lines, studentSig, paymentRef, attesterSig])
  const id = (await pub().readContract({ address: dep.address, abi: canteenOrdersAbi, functionName: 'orderCount' })) as bigint
  return { id, intentHash: intentStructHash(intent) }
}

async function snapshot() {
  const orders = await db.query(
    `select order_id, student, day_id, slot_id, token_no, payment_ref, intent_hash, total_paise, status, refund_reason,
            placed_at, present_at, checkin_device, served_by, placed_tx, last_event_block, last_event_log
     from orders order by order_id`,
  )
  const lines = await db.query('select * from order_lines order by order_id, line_no')
  const refunds = await db.query('select * from refunds order by order_id')
  const counts = await db.query(
    `select (select count(*) from chain_events)::int as events,
            (select count(*) from audit_log where actor = 'chain')::int as audit,
            (select count(*) from session_keys)::int as session_keys,
            (select count(*) from devices)::int as devices,
            (select count(*) from item_availability)::int as availability`,
  )
  return { orders: orders.rows, lines: lines.rows, refunds: refunds.rows, counts: counts.rows[0] }
}

describe('indexer end to end', () => {
  before(async () => {
    ;({ rpc, stop: stopAnvil } = await startAnvil(PORT))
    const tc = createTestClient({ chain: foundry, mode: 'anvil', transport: http(rpc) })
    for (const a of [refunder, relayer, device]) await tc.setBalance({ address: a.address, value: parseEther('1') })

    day = dayId(Number((await pub().getBlock()).timestamp)) + 1
    await at(dayStart(day) + 6 * 3600) // 06:00 IST tomorrow
    dep = await deployCanteen(as(owner), {
      openSec: canteenConfig.orderWindow.openSec,
      cutoffSec: canteenConfig.orderWindow.cutoffSec,
      roles: { attester: attester.address, refunder: refunder.address, relayer: relayer.address },
      slotCapacity: canteenConfig.slotCapacity,
      slots: canteenConfig.slots,
      items: canteenConfig.items,
      devices: [device.address],
    })

    // TEST_DATABASE_URL runs the same test on a real Postgres (pg driver). Its schema is wiped first,
    // so point it only at a throwaway test database.
    const testUrl = process.env.TEST_DATABASE_URL
    db = await openDb(testUrl ?? 'pglite:')
    if (testUrl) await db.exec('drop schema public cascade; create schema public')
    await migrate(db)
    indexer = new Indexer(db, pub() as never, {
      chainId: foundry.id,
      address: dep.address,
      deployBlock: dep.deployBlock,
      confirmations: 0,
      batchSize: 3, // small, so the run crosses many batches
    })
    await indexer.init()

    // Student registers a session key (relayed by the backend).
    const expiry = Number((await pub().getBlock()).timestamp) + 29 * 86400
    const auth = { student: student.address, key: session.address, expiry, nonce: 0n }
    const sig = await signSessionKeyAuth(student, canteenDomain(foundry.id, dep.address), auth)
    await call(owner, 'registerSessionKey', [auth.student, auth.key, auth.expiry, auth.nonce, sig])

    // 08:00: three paid pre-orders.
    await at(dayStart(day) + 8 * 3600)
    const served = await placeOrder(SLOT_1230.id, [line(VADA, 2), line(IDLI, 1)], 'pay_served')
    ids.served = served.id
    servedIntentHash = served.intentHash
    ids.forfeited = (await placeOrder(SLOT_1230.id, [line(DOSA, 1)], 'pay_noshow')).id
    ids.refunded = (await placeOrder(SLOT_1315.id, [line(IDLI, 2)], 'pay_soldout')).id

    // 12:00: Idli sells out. The 13:15 order becomes refundable and the refund is paid.
    await at(dayStart(day) + 12 * 3600)
    await call(relayer, 'setItemAvailable', [IDLI, false])
    await call(owner, 'claimUnavailableRefund', [ids.refunded])
    await call(refunder, 'recordRefundPaid', [ids.refunded, keccak256(stringToHex('rfnd_soldout'))])

    // 12:31: the first student checks in at the counter and is served.
    // (Idli went off before this check-in, so that order is also refundable; staff serve it anyway.)
    const ts = dayStart(day) + SLOT_1230.startSec + 60
    await at(ts)
    const domain = canteenDomain(foundry.id, dep.address)
    const challenge = { device: device.address, slotId: SLOT_1230.id, nonce: keccak256(stringToHex('qr-1')), timestamp: ts }
    await call(owner, 'checkIn', [
      ids.served,
      challenge,
      await signChallenge(device, domain, challenge),
      await signCheckIn(session, domain, ids.served, challenge),
    ])
    await call(device, 'markServed', [ids.served])

    // 13:31: the no-show's claim window plus submit grace is over.
    await at(dayStart(day) + SLOT_1230.startSec + 61 * 60)
    await call(owner, 'markForfeit', [ids.forfeited])

    await indexer.catchUp()
  })

  after(async () => {
    await db?.close()
    stopAnvil?.()
  })

  test('orders reach the right final state from chain events alone', async () => {
    const { rows } = await db.query('select * from orders order by order_id')
    assert.equal(rows.length, 3)
    const [served, forfeited, refunded] = rows

    assert.equal(served.status, 'Served')
    assert.equal(served.day_id, day)
    assert.equal(served.slot_id, SLOT_1230.id)
    assert.equal(served.token_no, 1)
    assert.equal(served.total_paise, 2 * price(VADA) + price(IDLI))
    assert.equal(served.student, student.address.toLowerCase())
    assert.equal(served.checkin_device, device.address.toLowerCase())
    assert.equal(served.served_by, device.address.toLowerCase())
    assert.equal(new Date(served.present_at).getTime() / 1000, dayStart(day) + SLOT_1230.startSec + 60)
    assert.equal(served.intent_hash, servedIntentHash, 'linked to the off-chain intent by payment ref')

    assert.equal(forfeited.status, 'Forfeited')
    assert.equal(forfeited.token_no, 2)

    assert.equal(refunded.status, 'RefundPaid')
    assert.equal(refunded.refund_reason, 'ItemUnavailable')
    assert.equal(refunded.slot_id, SLOT_1315.id)
    assert.equal(refunded.token_no, 1, 'tokens count per slot')
  })

  test('order lines, refunds and side tables', async () => {
    const lines = await db.query('select order_id, item_id, qty, unit_price_paise from order_lines order by order_id, line_no')
    assert.deepEqual(
      lines.rows.map((r) => [Number(r.order_id), r.item_id, r.qty, r.unit_price_paise]),
      [
        [Number(ids.served), VADA, 2, price(VADA)],
        [Number(ids.served), IDLI, 1, price(IDLI)],
        [Number(ids.forfeited), DOSA, 1, price(DOSA)],
        [Number(ids.refunded), IDLI, 2, price(IDLI)],
      ],
    )

    const refunds = await db.query('select * from refunds')
    assert.equal(refunds.rows.length, 1)
    const r = refunds.rows[0]
    assert.equal(Number(r.order_id), Number(ids.refunded))
    assert.equal(r.status, 'paid')
    assert.equal(r.reason, 'ItemUnavailable')
    assert.equal(r.amount_paise, 2 * price(IDLI))
    assert.equal(r.refund_ref, keccak256(stringToHex('rfnd_soldout')))
    assert.ok(r.paid_at >= r.owed_at)

    const sk = await db.query('select key_address from session_keys where student = $1', [student.address.toLowerCase()])
    assert.equal(sk.rows[0].key_address, session.address.toLowerCase())
    const dv = await db.query('select * from devices')
    assert.equal(dv.rows[0].address, device.address.toLowerCase())
    assert.equal(dv.rows[0].revoked_at, null)
    const av = await db.query('select available from item_availability where day_id = $1 and item_id = $2', [day, IDLI])
    assert.equal(av.rows[0].available, false)
    const cfg = await db.query(`select count(*)::int as n from audit_log where action = 'ConfigScheduled'`)
    assert.equal(cfg.rows[0].n, canteenConfig.slots.length + canteenConfig.items.length)
  })

  test('the cursor reached the chain head', async () => {
    assert.equal(await indexer.cursor(), Number(await pub().getBlockNumber()))
    assert.equal(await indexer.syncOnce(), null)
  })

  test('replaying already-indexed blocks changes nothing', async () => {
    const before = await snapshot()
    // Simulates a crash after applying logs but before the cursor moved.
    await db.query('update chain_cursor set last_processed_block = deploy_block - 1')
    await indexer.catchUp()
    assert.deepEqual(await snapshot(), before)
  })

  test('rebuild from the deploy block reproduces the same state', async () => {
    const before = await snapshot()
    await indexer.rebuild()
    assert.deepEqual(await snapshot(), before)
    const intents = await db.query('select count(*)::int as n from intents')
    assert.equal(intents.rows[0].n, 3, 'off-chain tables survive a rebuild')
  })

  test('a database cannot be pointed at a different deployment', async () => {
    const other = new Indexer(db, pub() as never, {
      chainId: foundry.id,
      address: '0x000000000000000000000000000000000000dEaD' as Address,
      deployBlock: 1,
    })
    await assert.rejects(other.init(), /Use a separate database/)
  })
})
