import { createPublicClient, createWalletClient, http } from 'viem'
import type { Chain, PrivateKeyAccount } from 'viem'
import { foundry } from 'viem/chains'
import { monadTestnet } from '@canteenpos/sdk'
import type { Clients } from './tx.ts'

/** Target chain: Monad testnet by default, or a local anvil when CHAIN=anvil. RPC_URL overrides the endpoint. */
export function targetChain(): Chain {
  return process.env.CHAIN === 'anvil' ? foundry : monadTestnet
}

export function clientsFor(account: PrivateKeyAccount, chain: Chain = targetChain()): Clients {
  const transport = http(process.env.RPC_URL || chain.rpcUrls.default.http[0])
  return {
    pub: createPublicClient({ chain, transport }) as Clients['pub'],
    wallet: createWalletClient({ account, chain, transport }),
  }
}

export function explorerTx(chain: Chain, hash: string) {
  const url = chain.blockExplorers?.default.url
  return url ? `${url}/tx/${hash}` : hash
}

export function explorerAddress(chain: Chain, address: string) {
  const url = chain.blockExplorers?.default.url
  return url ? `${url}/address/${address}` : address
}
