// Tops up the keys that send transactions, from the owner key (which you fund from the faucet).
// Only sends what is missing below each target, so it is safe to re-run.
//   npm run fund -w @canteenpos/ops
import { formatEther, parseEther } from 'viem'
import { loadKeys } from '../keys.ts'
import { clientsFor, explorerTx, targetChain } from '../network.ts'
import { transfer } from '../tx.ts'

const keys = loadKeys()
const chain = targetChain()
const c = clientsFor(keys.OWNER_PK, chain)

// Rough per-call costs at the 100 gwei floor: placeOrder ~0.03 MON, checkIn ~0.01, markServed ~0.004.
const targets = {
  SUBMITTER_PK: parseEther(process.env.FUND_SUBMITTER ?? '0.3'),
  DEMO_DEVICE_PK: parseEther(process.env.FUND_DEVICE ?? '0.2'),
  REFUNDER_PK: parseEther(process.env.FUND_REFUNDER ?? '0.05'),
  RELAYER_PK: parseEther(process.env.FUND_RELAYER ?? '0.05'),
} as const

for (const [name, target] of Object.entries(targets)) {
  const addr = keys[name as keyof typeof targets].address
  const have = await c.pub.getBalance({ address: addr })
  const label = name.replace(/_PK$/, '').padEnd(12)
  if (have >= target) {
    console.log(`${label} ${addr} has ${formatEther(have)} MON, skipped`)
    continue
  }
  const r = await transfer(c, addr, target - have)
  console.log(`${label} ${addr} topped up to ${formatEther(target)} MON  ${explorerTx(chain, r.transactionHash)}`)
}
console.log(`Owner left with ${formatEther(await c.pub.getBalance({ address: keys.OWNER_PK.address }))} MON`)
