// EIP-712 types and signing helpers for CanteenOrders (spec section 5.2).
// Every struct hash here must match the contract byte for byte; test/parity.test.ts proves it.
import { encodeAbiParameters, hashStruct, keccak256 } from 'viem'
import type { Address, Hex, TypedData, TypedDataDefinition, TypedDataDomain } from 'viem'

export const DOMAIN_NAME = 'CanteenOrders'
export const DOMAIN_VERSION = '1'

export type Line = { itemId: number; qty: number; unitPricePaise: number }

export type OrderIntent = {
  student: Address
  slotId: number
  linesHash: Hex
  totalPaise: number
  nonce: bigint
  deadline: number
}

export type DeviceChallenge = { device: Address; slotId: number; nonce: Hex; timestamp: number }

export type SessionKeyAuth = { student: Address; key: Address; expiry: number; nonce: bigint }

export const canteenTypes = {
  OrderIntent: [
    { name: 'student', type: 'address' },
    { name: 'slotId', type: 'uint8' },
    { name: 'linesHash', type: 'bytes32' },
    { name: 'totalPaise', type: 'uint32' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint48' },
  ],
  PaymentAttestation: [
    { name: 'intentHash', type: 'bytes32' },
    { name: 'paymentRef', type: 'bytes32' },
  ],
  DeviceChallenge: [
    { name: 'device', type: 'address' },
    { name: 'slotId', type: 'uint8' },
    { name: 'nonce', type: 'bytes32' },
    { name: 'timestamp', type: 'uint48' },
  ],
  CheckIn: [
    { name: 'orderId', type: 'uint256' },
    { name: 'challengeHash', type: 'bytes32' },
  ],
  SessionKeyAuth: [
    { name: 'student', type: 'address' },
    { name: 'key', type: 'address' },
    { name: 'expiry', type: 'uint48' },
    { name: 'nonce', type: 'uint256' },
  ],
} as const

export function canteenDomain(chainId: number, verifyingContract: Address): TypedDataDomain {
  return { name: DOMAIN_NAME, version: DOMAIN_VERSION, chainId, verifyingContract }
}

/** Anything that can sign EIP-712 data: a viem LocalAccount, a wallet client account, a Privy wallet. */
export type TypedDataSigner = {
  signTypedData: <
    const typedData extends TypedData | Record<string, unknown>,
    primaryType extends keyof typedData | 'EIP712Domain' = keyof typedData,
  >(
    args: TypedDataDefinition<typedData, primaryType>,
  ) => Promise<Hex>
}

const lineTupleArray = [
  {
    type: 'tuple[]',
    components: [
      { name: 'itemId', type: 'uint16' },
      { name: 'qty', type: 'uint16' },
      { name: 'unitPricePaise', type: 'uint32' },
    ],
  },
] as const

/** keccak256(abi.encode(Line[] lines)), as computed in placeOrder. */
export function hashLines(lines: readonly Line[]): Hex {
  return keccak256(encodeAbiParameters(lineTupleArray, [lines]))
}

export function totalPaise(lines: readonly Line[]): number {
  return lines.reduce((t, l) => t + l.unitPricePaise * l.qty, 0)
}

/** EIP-712 struct hash of an intent. This is the `intentHash` inside a PaymentAttestation. */
export function intentStructHash(intent: OrderIntent): Hex {
  return hashStruct({ data: intent, primaryType: 'OrderIntent', types: canteenTypes })
}

/** EIP-712 struct hash of a challenge. This is the `challengeHash` inside a CheckIn. */
export function challengeStructHash(challenge: DeviceChallenge): Hex {
  return hashStruct({ data: challenge, primaryType: 'DeviceChallenge', types: canteenTypes })
}

export function buildIntent(args: {
  student: Address
  slotId: number
  lines: readonly Line[]
  nonce: bigint
  deadline: number
}): OrderIntent {
  return {
    student: args.student,
    slotId: args.slotId,
    linesHash: hashLines(args.lines),
    totalPaise: totalPaise(args.lines),
    nonce: args.nonce,
    deadline: args.deadline,
  }
}

/** Student wallet authorizes a session key. */
export function signSessionKeyAuth(wallet: TypedDataSigner, domain: TypedDataDomain, auth: SessionKeyAuth) {
  return wallet.signTypedData({ domain, types: canteenTypes, primaryType: 'SessionKeyAuth', message: auth })
}

/** Session key signs the order intent before payment. */
export function signIntent(sessionKey: TypedDataSigner, domain: TypedDataDomain, intent: OrderIntent) {
  return sessionKey.signTypedData({ domain, types: canteenTypes, primaryType: 'OrderIntent', message: intent })
}

/** Backend attester signs once the payment is captured. */
export function signPaymentAttestation(
  attester: TypedDataSigner,
  domain: TypedDataDomain,
  intent: OrderIntent,
  paymentRef: Hex,
) {
  return attester.signTypedData({
    domain,
    types: canteenTypes,
    primaryType: 'PaymentAttestation',
    message: { intentHash: intentStructHash(intent), paymentRef },
  })
}

/** Tablet device key signs a rotating challenge. */
export function signChallenge(device: TypedDataSigner, domain: TypedDataDomain, challenge: DeviceChallenge) {
  return device.signTypedData({ domain, types: canteenTypes, primaryType: 'DeviceChallenge', message: challenge })
}

/** Student session key answers a challenge for one order. */
export function signCheckIn(
  sessionKey: TypedDataSigner,
  domain: TypedDataDomain,
  orderId: bigint,
  challenge: DeviceChallenge,
) {
  return sessionKey.signTypedData({
    domain,
    types: canteenTypes,
    primaryType: 'CheckIn',
    message: { orderId, challengeHash: challengeStructHash(challenge) },
  })
}
