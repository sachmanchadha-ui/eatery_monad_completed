// Deploys CanteenOrders with config/canteen.json, authorizes the demo tablet, and writes
// deployments/<chainId>.json for the indexer and apps.
//   npm run deploy -w @canteenpos/ops            (Monad testnet)
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { formatEther } from 'viem'
import { canteenConfig } from '@canteenpos/sdk'
import { deployCanteen, repoRoot } from '../deploy.ts'
import { loadKeys } from '../keys.ts'
import { clientsFor, explorerAddress, explorerTx, targetChain } from '../network.ts'

const keys = loadKeys()
const chain = targetChain()
const c = clientsFor(keys.OWNER_PK, chain)
const out = resolve(repoRoot, 'deployments', `${chain.id}.json`)

if (existsSync(out) && !process.argv.includes('--force')) {
  console.error(`${out} exists. A second deploy would orphan the first; pass --force if you mean it.`)
  process.exit(1)
}

const balance = await c.pub.getBalance({ address: keys.OWNER_PK.address })
console.log(`Deploying to ${chain.name} from ${keys.OWNER_PK.address} (balance ${formatEther(balance)} MON)`)

const d = await deployCanteen(c, {
  openSec: canteenConfig.orderWindow.openSec,
  cutoffSec: canteenConfig.orderWindow.cutoffSec,
  roles: { attester: keys.ATTESTER_PK.address, refunder: keys.REFUNDER_PK.address, relayer: keys.RELAYER_PK.address },
  slotCapacity: canteenConfig.slotCapacity,
  slots: canteenConfig.slots,
  items: canteenConfig.items,
  devices: [keys.DEMO_DEVICE_PK.address],
  onStep: (s) => console.log('  ' + s),
})

mkdirSync(resolve(repoRoot, 'deployments'), { recursive: true })
writeFileSync(out, JSON.stringify(d, null, 2) + '\n')
const spent = balance - (await c.pub.getBalance({ address: keys.OWNER_PK.address }))
console.log(`\nWrote ${out}`)
console.log(`Contract: ${explorerAddress(chain, d.address)}`)
console.log(`Deploy tx: ${explorerTx(chain, d.txHash)}`)
console.log(`Spent ${formatEther(spent)} MON`)
