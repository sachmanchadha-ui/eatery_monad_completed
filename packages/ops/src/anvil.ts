// Local anvil for tests. Uses ~/.foundry/bin when it is not on PATH.
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { createPublicClient, http } from 'viem'
import { foundry } from 'viem/chains'

/** anvil's well-known first dev account. Only ever funded on a local chain. */
export const ANVIL_PK = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'

export function anvilBin(): string {
  const exe = process.platform === 'win32' ? 'anvil.exe' : 'anvil'
  const local = join(homedir(), '.foundry', 'bin', exe)
  return existsSync(local) ? local : 'anvil'
}

export async function startAnvil(port: number): Promise<{ rpc: string; stop: () => void }> {
  const proc: ChildProcess = spawn(anvilBin(), ['--port', String(port), '--silent'], { stdio: 'ignore' })
  const rpc = `http://127.0.0.1:${port}`
  const pub = createPublicClient({ chain: foundry, transport: http(rpc) })
  for (let i = 0; i < 100; i++) {
    try {
      await pub.getChainId()
      return { rpc, stop: () => proc.kill() }
    } catch {
      await new Promise((r) => setTimeout(r, 100))
    }
  }
  proc.kill()
  throw new Error('anvil did not start')
}
