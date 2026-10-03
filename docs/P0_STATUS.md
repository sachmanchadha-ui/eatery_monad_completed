# P0 status: verify-before-building items (spec section 14)

| # | Item | Status | Answer / next step |
| :--- | :--- | :--- | :--- |
| V1 | Student login method | **Done** | Google Workspace accounts on `kccemsr.edu.in`. The backend accepts only Google ID tokens whose `hd` claim equals that domain (server-side, P3). No phone OTP fallback needed. Stored in `config/canteen.json`. |
| V2 | Offline session-key signing | **In progress** | Test page published (see below). Run it on 3 real phones, including one iPhone, before the live demo. |
| V3 | Razorpay refund funding after settlement | Open | Needed by P8. |
| V4 | Contractor agrees to automatic refunds and a float | Open | Needed by P8. Ask early. |
| V5 | Slots, capacity, items, prices | **Done (buildathon placeholders)** | Order window 07:00 to 09:00. Slots 12:30 and 13:15 (30 min claim windows, no overlap). Capacity 100 per slot, so pre-orders cap at 30. Vada Pav Rs 15, Dosa Rs 40, Idli Rs 30. In `config/canteen.json`; `contracts/test/RealConfig.t.sol` proves the contract accepts it. Replace with walked-canteen numbers before the pilot. |
| V6 | Monad testnet details | **Done** | See `docs/P1_NOTES.md`. |
| V7 | QR scan reliability | Open | V2 test measured the response QR payload at **494 bytes** (with the device signature included for phone self-submit), above the spec's 300 to 400 estimate. Test printed QRs of that size on cheap cameras; consider a compact binary encoding if scans are slow. |
| V8 | MD sign-off on ads and pilot scope | Open | |
| V9 | Whole-order refund if any item sells out (R4) | **Done** | Confirmed: the refund must be given. Already how the contract behaves. |

## V2 test procedure

Page: https://claude.ai/artifact/4nyxmz4PqWSMUy3yLUCWPn (private to the owner; source in `tools/v2-offline-signing/`, known answers from `packages/sdk/scripts/v2-kat.ts`).

On each phone, signed in to claude.ai:
1. Open the page and tap **Create session key** (network on).
2. Turn on airplane mode. The network pill reads Offline.
3. Tap **Run signing test**. Every row should pass and network requests should read 0.
4. Turn the network back on, enter the phone model, tap **Save result**.
5. On the iPhone, reopen the page after a few days: step 1 shows whether the stored key survived.

What it proves: the phone generates the same EIP-712 hashes and RFC 6979 signature bytes as the contract-verified SDK, verifies a tablet signature locally, decrypts its key from IndexedDB with a non-extractable WebCrypto key, and makes no network request while doing it.

What it does not prove: opening the app itself while offline (that needs the installed PWA with a service worker, P4), and iOS storage eviction for an installed PWA. The page runs inside the claude.ai viewer, not as a home-screen app.

Desktop Chromium baseline: all checks pass, key decrypt 57 ms, sign 0.2 ms.
