// Generates every server and demo key into .env.<CANTEEN_ENV> (default .env.testnet). Prints addresses only.
// Refuses to overwrite an existing file, so keys holding testnet funds are never lost by accident.
import { existsSync, writeFileSync } from 'node:fs'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { KEY_NAMES, envFile } from '../keys.ts'

const file = envFile()
if (existsSync(file)) {
  console.error(`${file} already exists. Delete it yourself first if you really want new keys.`)
  process.exit(1)
}

const lines = ['# CanteenPOS keys. Never commit this file. Testnet only.']
console.log(`Writing ${file}\n`)
for (const name of KEY_NAMES) {
  const pk = generatePrivateKey()
  lines.push(`${name}=${pk}`)
  console.log(`${name.replace(/_PK$/, '').padEnd(14)} ${privateKeyToAccount(pk).address}`)
}
writeFileSync(file, lines.join('\n') + '\n', { mode: 0o600 })
