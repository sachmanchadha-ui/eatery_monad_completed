// Differential test (spec 5.7): signatures produced by the TypeScript helpers are accepted by the
// real contract, and every hash the helpers compute equals the contract's own view of it.
// Boots a local anvil, deploys the Foundry build, and runs the full order lifecycle.
import { after, before, describe, test } from 'node:test'
import assert from 'node:assert/strict'
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  http,
  keccak256,
  parseEther,
  stringToHex,
  type Address,
  type Hex,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { foundry } from 'viem/chains'
import {
  buildIntent,
  canteenDomain,
  canteenOrdersAbi,
  challengeStructHash,
  dayId,
  dayStart,
  hashLines,
  intentStructHash,
  OrderStatus,
  signChallenge,
  signCheckIn,
  signIntent,
  signPaymentAttestation,
  signSessionKeyAuth,
  type DeviceChallenge,
  type Line,
} from '../src/index.ts'

const here = dirname(fileURLToPath(import.meta.url))
const artifact = JSON.parse(
  readFileSync(resolve(here, '../../../contracts/out/CanteenOrders.sol/CanteenOrders.json'), 'utf8'),
)
const bytecode = artifact.bytecode.object as Hex

const PORT = 18545
const RPC = `http://127.0.0.1:${PORT}`
// anvil's well-known first dev account; only ever funded on a local chain
const DEPLOYER_PK = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'

function anvilBin(): string {
  const exe = process.platform === 'win32' ? 'anvil.exe' : 'anvil'
  const local = join(homedir(), '.foundry', 'bin', exe)
  return existsSync(local) ? local : 'anvil'
}

const owner = privateKeyToAccount(DEPLOYER_PK)
const attester = privateKeyToAccount(generatePrivateKey())
const refunder = privateKeyToAccount(generatePrivateKey())
const relayer = privateKeyToAccount(generatePrivateKey())
const device = privateKeyToAccount(generatePrivateKey())
const studentWallet = privateKeyToAccount(generatePrivateKey())
const sessionKey = privateKeyToAccount(generatePrivateKey())

const VADA: Line = { itemId: 1, qty: 2, unitPricePaise: 2000 }
const CHAI: Line = { itemId: 3, qty: 1, unitPricePaise: 1000 }
const SLOT_1230 = 45000

let anvil: ChildProcess
const pub = createPublicClient({ chain: foundry, transport: http(RPC) })
const testClient = createTestClient({ chain: foundry, mode: 'anvil', transport: http(RPC) })
const wallet = (account: ReturnType<typeof privateKeyToAccount>) =>
  createWalletClient({ account, chain: foundry, transport: http(RPC) })

let address: Address
let domain: ReturnType<typeof canteenDomain>
let day: number

async function at(ts: number) {
  await testClient.setNextBlockTimestamp({ timestamp: BigInt(ts) })
}

async function send(account: ReturnType<typeof privateKeyToAccount>, functionName: string, args: unknown[]) {
  const hash = await wallet(account).writeContract({
    address,
    abi: canteenOrdersAbi,
    functionName: functionName as never,
    args: args as never,
  })
  const receipt = await pub.waitForTransactionReceipt({ hash })
  assert.equal(receipt.status, 'success', `${functionName} reverted`)
  return receipt
}

const read = (functionName: string, args: unknown[] = []) =>
  pub.readContract({ address, abi: canteenOrdersAbi, functionName: functionName as never, args: args as never }) as Promise<any>

async function placeOrder(lines: Line[], nonce: bigint, ref: string, ts: number) {
  const intent = buildIntent({ student: studentWallet.address, slotId: 1, lines, nonce, deadline: ts + 600 })
  const studentSig = await signIntent(sessionKey, domain, intent)
  const paymentRef = keccak256(stringToHex(ref))
  const attesterSig = await signPaymentAttestation(attester, domain, intent, paymentRef)
  await at(ts)
  // relayed by the backend submitter (here: the owner account), never by the student
  await send(owner, 'placeOrder', [intent, lines, studentSig, paymentRef, attesterSig])
  return { intent, paymentRef }
}

describe('TypeScript signing helpers vs CanteenOrders', () => {
  before(async () => {
    anvil = spawn(anvilBin(), ['--port', String(PORT), '--silent'], { stdio: 'ignore' })
    for (let i = 0; i < 100; i++) {
      try {
        await pub.getChainId()
        break
      } catch {
        await new Promise((r) => setTimeout(r, 100))
      }
    }

    const now = Number((await pub.getBlock()).timestamp)
    day = dayId(now) + 1
    await at(dayStart(day) + 6 * 3600) // 06:00 IST tomorrow

    const hash = await wallet(owner).deployContract({
      abi: canteenOrdersAbi,
      bytecode,
      args: [25200n, 32400n, attester.address, refunder.address, relayer.address],
    })
    address = (await pub.waitForTransactionReceipt({ hash })).contractAddress!
    domain = canteenDomain(foundry.id, address)

    await send(owner, 'setSlot', [1, SLOT_1230, 100, true])
    await send(owner, 'setItem', [1, 2000, true])
    await send(owner, 'setItem', [3, 1000, true])
    await send(owner, 'authorizeDevice', [device.address])
    for (const a of [device, refunder, relayer]) {
      await testClient.setBalance({ address: a.address, value: parseEther('1') })
    }
  })

  after(() => {
    anvil?.kill()
  })

  test('domain separator matches', async () => {
    const onchain = await read('DOMAIN_SEPARATOR')
    const { hashDomain } = await import('viem')
    const local = hashDomain({
      domain: { name: 'CanteenOrders', version: '1', chainId: BigInt(foundry.id), verifyingContract: address },
      types: {
        EIP712Domain: [
          { name: 'name', type: 'string' },
          { name: 'version', type: 'string' },
          { name: 'chainId', type: 'uint256' },
          { name: 'verifyingContract', type: 'address' },
        ],
      },
    })
    assert.equal(local, onchain)
  })

  test('lines, intent and challenge hashes match the contract', async () => {
    const lines = [VADA, CHAI, { itemId: 65535, qty: 1, unitPricePaise: 4_000_000_000 }]
    assert.equal(hashLines(lines), await read('hashLines', [lines]))

    const intent = buildIntent({ student: studentWallet.address, slotId: 3, lines, nonce: 2n ** 200n, deadline: 2 ** 47 })
    assert.equal(intentStructHash(intent), await read('intentStructHash', [intent]))

    const ch: DeviceChallenge = { device: device.address, slotId: 255, nonce: keccak256('0x01'), timestamp: 2 ** 48 - 1 }
    assert.equal(challengeStructHash(ch), await read('challengeStructHash', [ch]))
  })

  test('session key registration with a wallet signature', async () => {
    const now = Number((await pub.getBlock()).timestamp)
    const auth = { student: studentWallet.address, key: sessionKey.address, expiry: now + 29 * 86400, nonce: 0n }
    const sig = await signSessionKeyAuth(studentWallet, domain, auth)
    await send(owner, 'registerSessionKey', [auth.student, auth.key, auth.expiry, auth.nonce, sig])
    const [key] = await read('sessionKeys', [studentWallet.address])
    assert.equal(key, sessionKey.address)
  })

  test('full lifecycle: place, check in, serve', async () => {
    await placeOrder([VADA, CHAI], 1n, 'pay_1', dayStart(day) + 8 * 3600)
    const order = await read('getOrder', [1n])
    assert.equal(OrderStatus[order.status], 'Placed')
    assert.equal(order.tokenNo, 1)
    assert.equal(order.totalPaise, 5000)
    assert.equal(await read('getSlotDemand', [BigInt(day), 1, 1]), 2n)

    const ts = dayStart(day) + SLOT_1230 + 60
    const ch: DeviceChallenge = { device: device.address, slotId: 1, nonce: keccak256(stringToHex('qr-1')), timestamp: ts }
    const deviceSig = await signChallenge(device, domain, ch)
    const studentSig = await signCheckIn(sessionKey, domain, 1n, ch)
    await at(ts + 2)
    await send(device, 'checkIn', [1n, ch, deviceSig, studentSig])
    assert.equal(OrderStatus[(await read('getOrder', [1n])).status], 'CheckedIn')

    await send(device, 'markServed', [1n])
    assert.equal(OrderStatus[(await read('getOrder', [1n])).status], 'Served')
  })

  test('phone self-submits a dropped check-in after the tablet is revoked', async () => {
    const nextDay = day + 1
    await placeOrder([CHAI], 2n, 'pay_2', dayStart(nextDay) + 8 * 3600)
    const id = 2n
    const ts = dayStart(nextDay) + SLOT_1230 + 120
    const ch: DeviceChallenge = { device: device.address, slotId: 1, nonce: keccak256(stringToHex('qr-2')), timestamp: ts }
    const deviceSig = await signChallenge(device, domain, ch)
    const studentSig = await signCheckIn(sessionKey, domain, id, ch)

    await at(ts + 60)
    await send(owner, 'revokeDevice', [device.address])
    await at(ts + 45 * 60) // after the claim window, inside the submit grace
    await send(owner, 'checkIn', [id, ch, deviceSig, studentSig])
    assert.equal(OrderStatus[(await read('getOrder', [id])).status], 'CheckedIn')
  })

  test('sold-out toggle makes the order refundable and the refund is recorded', async () => {
    const d = day + 2
    await placeOrder([VADA], 3n, 'pay_3', dayStart(d) + 8 * 3600)
    await at(dayStart(d) + 10 * 3600)
    await send(relayer, 'setItemAvailable', [1, false])
    await send(owner, 'claimUnavailableRefund', [3n])
    let order = await read('getOrder', [3n])
    assert.equal(OrderStatus[order.status], 'RefundOwed')
    await send(refunder, 'recordRefundPaid', [3n, keccak256(stringToHex('rfnd_3'))])
    order = await read('getOrder', [3n])
    assert.equal(OrderStatus[order.status], 'RefundPaid')
  })
})
