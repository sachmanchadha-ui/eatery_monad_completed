// Deploys CanteenOrders from the Foundry build and applies the canteen config (spec P2.1).
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { canteenOrdersAbi } from '@canteenpos/sdk'
import type { ItemConfig, SlotConfig } from '@canteenpos/sdk'
import type { Address, Hex } from 'viem'
import { deploy, write, type Clients } from './tx.ts'

const here = dirname(fileURLToPath(import.meta.url))
export const repoRoot = resolve(here, '../../..')

export function loadBytecode(): Hex {
  const path = resolve(repoRoot, 'contracts/out/CanteenOrders.sol/CanteenOrders.json')
  return JSON.parse(readFileSync(path, 'utf8')).bytecode.object as Hex
}

export type Roles = { attester: Address; refunder: Address; relayer: Address }

export type DeployOptions = {
  openSec: number
  cutoffSec: number
  roles: Roles
  slotCapacity: number
  slots: SlotConfig[]
  items: ItemConfig[]
  devices?: Address[]
  /** Called after each step, for progress output. */
  onStep?: (step: string) => void
}

export type Deployment = {
  chainId: number
  address: Address
  deployBlock: number
  txHash: Hex
  deployer: Address
  openSec: number
  cutoffSec: number
  roles: Roles
  deployedAt: string
}

export async function deployCanteen(c: Clients, o: DeployOptions): Promise<Deployment> {
  const step = o.onStep ?? (() => {})
  const receipt = await deploy(c, {
    abi: canteenOrdersAbi,
    bytecode: loadBytecode(),
    args: [BigInt(o.openSec), BigInt(o.cutoffSec), o.roles.attester, o.roles.refunder, o.roles.relayer],
  })
  const address = receipt.contractAddress
  step(`deployed ${address} in block ${receipt.blockNumber}`)

  const call = (functionName: string, args: readonly unknown[]) =>
    write(c, { address, abi: canteenOrdersAbi, functionName, args })
  for (const s of o.slots) {
    await call('setSlot', [s.id, s.startSec, o.slotCapacity, true])
    step(`slot ${s.id} at ${s.label}, capacity ${o.slotCapacity}`)
  }
  for (const it of o.items) {
    await call('setItem', [it.id, it.pricePaise, true])
    step(`item ${it.id} ${it.name} at ${it.pricePaise} paise`)
  }
  for (const d of o.devices ?? []) {
    await call('authorizeDevice', [d])
    step(`device ${d} authorized`)
  }

  return {
    chainId: await c.pub.getChainId(),
    address,
    deployBlock: Number(receipt.blockNumber),
    txHash: receipt.transactionHash,
    deployer: c.wallet.account.address,
    openSec: o.openSec,
    cutoffSec: o.cutoffSec,
    roles: o.roles,
    deployedAt: new Date().toISOString(),
  }
}
