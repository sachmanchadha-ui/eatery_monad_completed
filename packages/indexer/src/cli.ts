// npm run indexer -w @canteenpos/indexer -- <command>
//   migrate   create or update the schema
//   sync      index continuously (Ctrl+C to stop)
//   once      index until caught up, then exit
//   rebuild   clear chain-derived tables and replay from the deploy block
//   status    print the cursor and today's orders
//
// Env: DATABASE_URL (default: the docker compose Postgres; pglite:<dir> runs without Docker), RPC_URL, CHAIN=anvil for local,
//      DEPLOYMENT=<file> to index a deployment other than deployments/<chainId>.json.
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { createPublicClient, http } from 'viem'
import { foundry } from 'viem/chains'
import { dayId, monadTestnet } from '@canteenpos/sdk'
import { migrate, openDb } from './db.ts'
import { Indexer } from './indexer.ts'

const repoRoot = resolve(import.meta.dirname, '../../..')
const chain = process.env.CHAIN === 'anvil' ? foundry : monadTestnet
const deployment = JSON.parse(
  readFileSync(process.env.DEPLOYMENT ?? resolve(repoRoot, 'deployments', `${chain.id}.json`), 'utf8'),
)
const db = await openDb(process.env.DATABASE_URL ?? 'postgres://canteen:canteen@127.0.0.1:5433/canteen')
const client = createPublicClient({ chain, transport: http(process.env.RPC_URL || chain.rpcUrls.default.http[0]) })
const indexer = new Indexer(db, client, {
  chainId: chain.id,
  address: deployment.address,
  deployBlock: deployment.deployBlock,
  confirmations: chain.id === foundry.id ? 0 : Number(process.env.CONFIRMATIONS ?? 2),
  log: (m) => console.log(new Date().toISOString(), m),
})

const cmd = process.argv[2] ?? 'sync'
await migrate(db)
await indexer.init()

if (cmd === 'migrate') {
  console.log('schema up to date')
} else if (cmd === 'once') {
  console.log(`applied ${await indexer.catchUp()} events, cursor at block ${await indexer.cursor()}`)
} else if (cmd === 'rebuild') {
  console.log(`replayed ${await indexer.rebuild()} events, cursor at block ${await indexer.cursor()}`)
} else if (cmd === 'status') {
  const today = dayId(Math.floor(Date.now() / 1000))
  const { rows } = await db.query(
    `select order_id, slot_id, token_no, status, total_paise from orders where day_id >= $1 order by order_id`,
    [today - 1],
  )
  console.log(`cursor at block ${await indexer.cursor()}, ${rows.length} orders since yesterday`)
  console.table(rows)
} else if (cmd === 'sync') {
  const stop = new AbortController()
  process.on('SIGINT', () => stop.abort())
  console.log(`indexing ${deployment.address} on ${chain.name}`)
  await indexer.run(1000, stop.signal)
} else {
  console.error(`unknown command ${cmd}`)
  process.exitCode = 1
}
await db.close()
