// Known-answer vectors for the V2 phone signing test (tools/v2-offline-signing).
// The phone must reproduce these bytes exactly. Keys here are public test keys, never used on chain.
import { getAddress, hashTypedData, keccak256, stringToHex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { canteenDomain, canteenTypes, challengeStructHash, signChallenge, signCheckIn } from '../src/index.ts'

const domain = canteenDomain(10143, getAddress('0x000000000000000000000000000000000000c0de'))
const deviceKey = keccak256(stringToHex('canteenpos-v2-test-device'))
const sessionKey = keccak256(stringToHex('canteenpos-v2-test-session'))
const device = privateKeyToAccount(deviceKey)
const session = privateKeyToAccount(sessionKey)
const challenge = {
  device: device.address,
  slotId: 0,
  nonce: keccak256(stringToHex('qr-0001')),
  timestamp: 1790000000,
}
const orderId = 14n

const deviceSig = await signChallenge(device, domain, challenge)
const checkInSig = await signCheckIn(session, domain, orderId, challenge)
const checkInDigest = hashTypedData({
  domain,
  types: canteenTypes,
  primaryType: 'CheckIn',
  message: { orderId, challengeHash: challengeStructHash(challenge) },
})

console.log(
  JSON.stringify(
    {
      domain: { chainId: 10143, verifyingContract: domain.verifyingContract },
      sessionKey,
      sessionAddress: session.address,
      challenge,
      deviceSig,
      orderId: 14,
      challengeHash: challengeStructHash(challenge),
      checkInDigest,
      checkInSig,
    },
    null,
    2,
  ),
)
