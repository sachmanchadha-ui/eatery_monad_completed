# P1 notes: contract and tests

Status: P1 done criteria met. All 9 invariants pass, the gas snapshot is recorded, and the hash parity test is green.

## Refinements made during P1 (confirm or reverse, like R1 to R7)

| ID | Change from the spec skeleton | Why |
| :--- | :--- | :--- |
| R8 | `SessionKeyAuth` gains a `uint256 nonce`. The contract tracks `sessionNonce[student]` and accepts only the current value. | Without it, anyone can replay an old authorization to restore a key the student replaced, for example a key from a lost phone, until that authorization expires. |
| R9 | An item switch-off counts toward refundability only if it falls between `placedAt` and the order's forfeit point (claim end + submit grace). Every switch-off time is stored (`getOffTimes`). This replaces `firstOffAt`. | With `firstOffAt`: (a) a toggle off, then on, then off again left orders placed between the two toggles non-refundable; (b) a sold-out toggle at 15:00 turned every 12:30 no-show the keeper had not forfeited yet into a refund. With the bound, refundability is final once forfeit becomes possible, so forfeit and refund can never race. |
| R10 | Each order stores its `claimStart` at placement. | The skeleton recomputed the window from the slot config, so a later schedule edit could move an existing order's window. |
| R11 | `revokeDevice` reverts for unknown or already revoked devices. | A second revoke moved `revokedAt` later and so widened the device's valid period. |
| R12 | `CLOCK_SKEW = 30 s`. A challenge timestamp may be up to 30 s ahead of block time. | The spec said "not in the future". A tablet clock a few seconds fast would then make every check-in revert. |
| R13 | The first configuration of a new slot or item id is live the same day. Edits to existing ids still apply the next day. | No order can reference a brand-new id, so nothing reprices. It also lets a fresh deploy take orders on the same day (demo). |

Smaller additions: `Order` also stores `totalPaise` (the refund executor needs the amount). There are zero-address checks on role setters, `RoleUpdated` and ownership events, and client views: `getSlot`, `getItem`, `slotRemaining`, `getSlotIds`, `getItemIds`, `claimWindow`, `hashLines`, `intentStructHash`, `challengeStructHash`, `DOMAIN_SEPARATOR`.

## V6 (Monad testnet), checked 2026-10-02

- Chain id 10143 (confirmed via `eth_chainId`). RPC `https://testnet-rpc.monad.xyz`. Faucet `https://faucet.monad.xyz`.
- Explorer has moved: `https://testnet.monadvision.com` (also `testnet.monadscan.com`). The spec's `testnet.monadexplorer.com` is out of date.
- **Gas is charged on the gas limit, not gas used.** Minimum base fee is 100 MON-gwei. Clients must set tight limits instead of wallet defaults.

## Gas (from `contracts/snapshots/GasTest.json`)

| Call | Gas |
| :--- | ---: |
| placeOrder, 1 line | 237,370 |
| placeOrder, 4 lines | 372,093 |
| checkIn | 75,564 |
| markServed | 30,780 |
| markForfeit | 37,833 |
| claimUnavailableRefund | 40,269 |
| recordRefundPaid | 31,033 |
| setItemAvailable (off) | 94,345 |

At the 100 gwei floor, a 1-line order costs about 0.024 MON on testnet. Still to verify on chain.

## Build notes

- `via_ir = true` is required: `placeOrder` exceeds the legacy pipeline's stack limit.
- In tests, use `vm.getBlockTimestamp()` instead of `block.timestamp`. With via-ir the optimizer caches `block.timestamp` across `vm.warp` within a function.
