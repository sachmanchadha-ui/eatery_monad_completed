// Transaction helpers. Monad charges the gas LIMIT, not gas used, so every write estimates first
// and sends with a small buffer instead of a wallet default.
import { encodeDeployData } from 'viem'
import type { Abi, Account, Address, Chain, Hex, PublicClient, TransactionReceipt, Transport, WalletClient } from 'viem'

export type Clients = {
  pub: PublicClient
  wallet: WalletClient<Transport, Chain, Account>
}

/** Gas limit = estimate x 1.10. */
export const withBuffer = (gas: bigint) => (gas * 11_000n) / 10_000n

export async function write(
  c: Clients,
  call: { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] },
): Promise<TransactionReceipt> {
  const req = { ...call, account: c.wallet.account } as never
  const gas = await c.pub.estimateContractGas(req)
  const hash = await c.wallet.writeContract({ ...(req as object), gas: withBuffer(gas) } as never)
  const receipt = await c.pub.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`${call.functionName} reverted (tx ${hash})`)
  return receipt
}

export async function deploy(
  c: Clients,
  args: { abi: Abi; bytecode: Hex; args: readonly unknown[] },
): Promise<TransactionReceipt & { contractAddress: Address }> {
  const data = encodeDeployData(args as never)
  const gas = await c.pub.estimateGas({ account: c.wallet.account, data })
  const hash = await c.wallet.sendTransaction({ data, gas: withBuffer(gas) } as never)
  const receipt = await c.pub.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error(`deploy failed (tx ${hash})`)
  return receipt as TransactionReceipt & { contractAddress: Address }
}

/** Plain value transfer with the exact 21,000 gas limit. */
export async function transfer(c: Clients, to: Address, value: bigint): Promise<TransactionReceipt> {
  const hash = await c.wallet.sendTransaction({ to, value, gas: 21_000n } as never)
  const receipt = await c.pub.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`transfer to ${to} failed (tx ${hash})`)
  return receipt
}
