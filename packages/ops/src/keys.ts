// Server and demo keys (spec section 3.1), kept in a gitignored env file at the repo root.
import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import { privateKeyToAccount } from 'viem/accounts'
import type { Hex, PrivateKeyAccount } from 'viem'
import { repoRoot } from './deploy.ts'

/** Every key the testnet setup uses. The owner key is a deployer only: hand ownership to the MD's
 *  MetaMask (or a Safe) with transferOwnership + acceptOwnership before the pilot. */
export const KEY_NAMES = [
  'OWNER_PK',
  'ATTESTER_PK',
  'REFUNDER_PK',
  'RELAYER_PK',
  'SUBMITTER_PK',
  'DEMO_DEVICE_PK',
  'DEMO_STUDENT_PK',
  'DEMO_SESSION_PK',
] as const
export type KeyName = (typeof KEY_NAMES)[number]

export const envFile = (name = process.env.CANTEEN_ENV ?? 'testnet') => resolve(repoRoot, `.env.${name}`)

export function loadKeys(name?: string): Record<KeyName, PrivateKeyAccount> {
  const file = envFile(name)
  if (!existsSync(file)) throw new Error(`${file} not found. Run: npm run gen-keys -w @canteenpos/ops`)
  process.loadEnvFile(file)
  const out = {} as Record<KeyName, PrivateKeyAccount>
  for (const k of KEY_NAMES) {
    const v = process.env[k]
    if (!v) throw new Error(`${k} missing from ${file}`)
    out[k] = privateKeyToAccount(v as Hex)
  }
  return out
}
