// Testnet smoke run (P2 done-criterion on the real chain). The main deployment only takes orders 07:00-09:00
// IST and serves from 12:30, so this deploys a separate short-window copy: ordering closes a few minutes from
// now, the slot opens one minute later. It then places, checks in and serves one order, indexes the copy, and
// prints the order as the database sees it. Takes about 5 minutes and roughly 0.6 MON from the owner key.
//   npm run smoke -w @canteenpos/indexer
// Env: SMOKE_DATABASE_URL (default in-memory), SMOKE_LEAD seconds before cutoff (default 180).
import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { formatEther, keccak256, stringToHex } from 'viem'
import {
  buildIntent,
  canteenConfig,
  canteenDomain,
  canteenOrdersAbi,
  dayId,
  dayStart,
  secondOfDay,
  signChallenge,
  signCheckIn,
  signIntent,
  signPaymentAttestation,
  signSessionKeyAuth,
} from '@canteenpos/sdk'
import { clientsFor, deployCanteen, explorerAddress, explorerTx, loadKeys, repoRoot, targetChain, write } from '@canteenpos/ops'
import { Indexer, migrate, openDb } from '../src/index.ts'

const keys = loadKeys()
const chain = targetChain()
const owner = clientsFor(keys.OWNER_PK, chain)
const submitter = clientsFor(keys.SUBMITTER_PK, chain)
const device = clientsFor(keys.DEMO_DEVICE_PK, chain)
const say = (m: string) => console.log(`[${new Date().toLocaleTimeString()}] ${m}`)
const blockTime = async () => Number((await owner.pub.getBlock()).timestamp)

const ownerStart = await owner.pub.getBalance({ address: keys.OWNER_PK.address })
for (const [name, c] of [['SUBMITTER', submitter], ['DEMO_DEVICE', device]] as const) {
  const bal = await c.pub.getBalance({ address: c.wallet.account.address })
  if (bal < 10n ** 16n) throw new Error(`${name} has ${formatEther(bal)} MON. Run: npm run fund -w @canteenpos/ops`)
}

const now = await blockTime()
const sod = secondOfDay(now)
const lead = Number(process.env.SMOKE_LEAD ?? 180)
const cutoffSec = sod + lead
const startSec = cutoffSec + 60
if (startSec + 30 * 60 > 86400) throw new Error('Too close to midnight IST for a same-day slot. Run it after 00:00 IST.')
const vada = canteenConfig.items[0]

say(`deploying a smoke copy: orders until +${lead}s, slot opens at +${lead + 60}s`)
const dep = await deployCanteen(owner, {
  openSec: Math.max(0, sod - 600),
  cutoffSec,
  roles: { attester: keys.ATTESTER_PK.address, refunder: keys.REFUNDER_PK.address, relayer: keys.RELAYER_PK.address },
  slotCapacity: canteenConfig.slotCapacity,
  slots: [{ id: 0, startSec, label: 'smoke' }],
  items: [vada],
  devices: [keys.DEMO_DEVICE_PK.address],
  onStep: (s) => say('  ' + s),
})
mkdirSync(resolve(repoRoot, 'deployments'), { recursive: true })
writeFileSync(resolve(repoRoot, 'deployments', `${chain.id}-smoke.json`), JSON.stringify(dep, null, 2) + '\n')
const domain = canteenDomain(chain.id, dep.address)
const call = (c: typeof owner, functionName: string, args: readonly unknown[]) =>
  write(c, { address: dep.address, abi: canteenOrdersAbi, functionName, args })

// Student authorizes a session key; the backend submitter relays it.
const student = keys.DEMO_STUDENT_PK
const session = keys.DEMO_SESSION_PK
const auth = { student: student.address, key: session.address, expiry: (await blockTime()) + 29 * 86400, nonce: 0n }
await call(submitter, 'registerSessionKey', [auth.student, auth.key, auth.expiry, auth.nonce, await signSessionKeyAuth(student, domain, auth)])
say('session key registered')

// Paid intent: session key signs, attester attests, submitter places.
if (secondOfDay(await blockTime()) >= cutoffSec - 5) {
  throw new Error(`Setup took longer than the ${lead}s ordering lead, so the cutoff passed. Re-run with a larger SMOKE_LEAD.`)
}
const lines = [{ itemId: vada.id, qty: 2, unitPricePaise: vada.pricePaise }]
const intent = buildIntent({ student: student.address, slotId: 0, lines, nonce: 1n, deadline: (await blockTime()) + 600 })
const paymentRef = keccak256(stringToHex(`smoke-${Date.now()}`))
const placed = await call(submitter, 'placeOrder', [
  intent,
  lines,
  await signIntent(session, domain, intent),
  paymentRef,
  await signPaymentAttestation(keys.ATTESTER_PK, domain, intent, paymentRef),
])
say(`order placed  ${explorerTx(chain, placed.transactionHash)}`)

// Wait for the slot's claim window, then the counter handshake.
const slotOpens = dayStart(dayId(now)) + startSec
while ((await blockTime()) < slotOpens) {
  await new Promise((r) => setTimeout(r, 3000))
}
const ts = await blockTime()
const challenge = { device: keys.DEMO_DEVICE_PK.address, slotId: 0, nonce: keccak256(stringToHex(`qr-${ts}`)), timestamp: ts }
const checkedIn = await call(submitter, 'checkIn', [
  1n,
  challenge,
  await signChallenge(keys.DEMO_DEVICE_PK, domain, challenge),
  await signCheckIn(session, domain, 1n, challenge),
])
say(`checked in    ${explorerTx(chain, checkedIn.transactionHash)}`)
const served = await call(device, 'markServed', [1n])
say(`served        ${explorerTx(chain, served.transactionHash)}`)

// Index the smoke copy from its deploy block and read the order back from Postgres.
const db = await openDb(process.env.SMOKE_DATABASE_URL ?? 'pglite:')
await migrate(db)
const indexer = new Indexer(db, owner.pub, {
  chainId: chain.id,
  address: dep.address,
  deployBlock: dep.deployBlock,
  confirmations: 2,
  log: (m) => say('  indexer: ' + m),
})
await indexer.init()
let row: Record<string, any> | undefined
for (let i = 0; i < 30 && row?.status !== 'Served'; i++) {
  await indexer.catchUp()
  row = (await db.query('select * from orders where order_id = 1')).rows[0]
  if (row?.status !== 'Served') await new Promise((r) => setTimeout(r, 2000))
}
const lineRows = (await db.query('select item_id, qty, unit_price_paise from order_lines where order_id = 1')).rows
await db.close()

console.log('\nOrder 1 as indexed from chain events:')
console.table([{ status: row?.status, token: row?.token_no, total_paise: row?.total_paise, device: row?.served_by }])
console.table(lineRows)
const spent = ownerStart - (await owner.pub.getBalance({ address: keys.OWNER_PK.address }))
console.log(`Smoke contract: ${explorerAddress(chain, dep.address)}`)
console.log(`Owner spent ${formatEther(spent)} MON on the smoke deploy`)
if (row?.status !== 'Served') {
  console.error('FAILED: the indexer did not show the order as Served')
  process.exitCode = 1
} else {
  console.log('PASSED: order, check-in and serve are in the database from chain events alone')
}
