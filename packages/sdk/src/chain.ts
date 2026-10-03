import { defineChain } from 'viem'

// Checked 2026-10-02 against docs.monad.xyz and the RPC itself (eth_chainId = 0x279f).
// Note: Monad charges the transaction's gas LIMIT, not gas used, so set tight limits.
export const monadTestnet = defineChain({
  id: 10143,
  name: 'Monad Testnet',
  nativeCurrency: { name: 'Monad', symbol: 'MON', decimals: 18 },
  rpcUrls: { default: { http: ['https://testnet-rpc.monad.xyz'] } },
  blockExplorers: { default: { name: 'MonadVision', url: 'https://testnet.monadvision.com' } },
  testnet: true,
})
