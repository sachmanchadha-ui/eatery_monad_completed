# CanteenPOS v2: System Specification and Implementation Plan

**Status:** design locked after a decision-by-decision review of v1. Items marked **UNVERIFIED** must be checked before the dependent phase starts (section 14).
**Replaces:** v1 sections 1, 3, 5.2, 6, 7 and the pitch in section 8. Sections 2 (design system) and 4 (client config) are carried over with fixes.
**One-line summary:** a fund-free order state machine on Monad that gives a campus canteen a paid pre-order baseline and gives students a signed, censorship-resistant proof that they showed up.

---

## 1. Executive Summary and Problem Framing

### 1.1 The operational problem

A campus canteen cooks on intuition. Two losses repeat daily: under-preparation (stockouts in the lunch rush) and over-preparation (unsold food). Informal WhatsApp pre-orders fail because a promise carries no cost, so no-shows land entirely on the canteen.

### 1.2 What v2 actually does

- Students pre-order and **pay by UPI** between 07:00 and 09:00 for a chosen pickup slot.
- Pre-orders are capped at **30% of each slot's physical capacity**. Walk-ups are 80 to 90% of real volume, so pre-orders are a **paid baseline** for morning prep. They are not a demand forecast.
- A no-show **forfeits** to the canteen. That is the loss the system removes.
- At the counter the student's phone and the canteen tablet perform a signed handshake (**check-in**). A student who checked in and was not served becomes **refund owed**, enforced by public contract state.
- Rupees never touch the contract. The contract is the public rulebook and ledger. The contractor's Razorpay account holds and returns the money.

### 1.3 What the system claims, and what it does not

| Claim we make | Why it holds |
| :--- | :--- |
| Pre-orders give the kitchen a paid baseline. | UPI payment is captured before the order is written onchain. |
| A student who checks in cannot be denied and charged. | After check-in, the order becomes refund-owed unless a canteen device marks it served. |
| The canteen cannot keep a checked-in student's money without a signed service record. | `markServed` is the only path from CheckedIn to Served, and it needs an authorized device key. |
| Check-in evidence cannot be deleted or backdated by the operator. | It is a contract event signed by the student's own key. |

| Claim we do NOT make | Reason |
| :--- | :--- |
| "Zero food waste" or "predictive demand." | Pre-orders are 10 to 20% of volume. It is a baseline. |
| "Mathematically impossible for the canteen to keep money." | A no-show forfeits by design, and refunds are paid off-chain by our backend. |
| "Funds locked in escrow." | The contract holds no funds. |
| "Anonymous." | Addresses are pseudonymous. Privy links each wallet to a Google account off-chain. |
| "10,000 TPS" or "Secure Enclave." | Use "sub-second blocks, near-free gas" and "origin-bound key in IndexedDB." |

### 1.4 Why Monad, in one honest paragraph

The chain is not a payment rail here. It is used for two properties a database cannot offer: (1) evidence the operator cannot erase or backdate, and (2) a path the student can use directly when the canteen's tablet drops a message. Monad is chosen because sub-second blocks and near-zero gas make per-order transactions viable at a 20 rupee ticket size. Any EVM chain with similar cost would work.

---

## 2. Locked Decisions Register

| ID | Decision |
| :--- | :--- |
| D1 | Real canteen pilot. The buildathon demo runs the same contract and the same flows. |
| D2 | Seller of record is the **canteen contractor** (Razorpay account, VPA, bank, refund liability). |
| D3 | Contract holds **no funds**. Demo payments use the cINR faucet token. Pilot payments use UPI via Razorpay. |
| D4 | Unclaimed orders **forfeit**. Self-serve refund exists only for merchant failure (see D9, D10). |
| D5 | Student-picked **slots** (3 to 4 per day), 30 minute claim window per slot, per-slot capacity. |
| D6 | **Hard 09:00 cutoff** enforced by the contract. Window opens 07:00. Standing schedule, no daily publishing. |
| D7 | Pre-orders capped at **30%** of each slot's physical capacity. |
| D8 | Check-in is a **student-signed, tablet-challenged handshake**. Dead phone = no check-in = forfeit. |
| D9 | Checked in but not served within the serve grace: **RefundOwed**. |
| D10 | Item toggled unavailable: every unserved order containing it becomes refundable immediately. |
| D11 | Owner manages **devices**, not people. Device keys can only check in and serve. |
| D12 | Backend hot key limited to `setItemAvailable`. |
| D13 | Embedded wallets (Privy or Web3Auth) with Google `.edu.in` login. Backend checks the `hd` claim. |
| D14 | Phone-local **session key** signs check-ins so signing works offline. |
| D15 | Student-signed **order intent** before payment. Backend publishes `RefundPaid(orderId, refundId)` after each refund. |
| D16 | Public pseudonymous addresses and item ids. PII stays off-chain. |
| D17 | Ad: one static "Sponsored" card on the confirmation screen only. |

### 2.1 Refinements made while writing this spec

These were not in the review log. Each fixes a hole found during spec writing. Confirm or reverse them.

| ID | Refinement | Why |
| :--- | :--- | :--- |
| R1 | **Payment attestation.** `placeOrder` needs a backend-signed `PaymentAttestation(intentHash, paymentRef)`. Anyone may submit it, including the student. | Without it, the contract cannot tell a paid order from spam, and a student-submitted intent would create unpaid orders. |
| R2 | **Bounded-use challenges.** A tablet challenge may serve at most 8 check-ins, not exactly one. | Single-use nonces would serialize the counter line. Unbounded reuse lets one screenshot check in unlimited remote students. |
| R3 | **Session key curve is secp256k1**, wrapped by a non-extractable WebCrypto key. | WebCrypto cannot produce secp256k1 keys, and `ecrecover` needs secp256k1. A truly non-extractable WebCrypto key would be P-256, which the EVM cannot verify cheaply. |
| R4 | **Cart of up to 4 lines per order.** Whole-order refund if any line becomes unavailable. | Single-item orders force one payment per item. |
| R5 | **Two timers:** a claim window (when the student must be present) and a submission grace (when the check-in transaction may still land). | The LTE fallback needs the transaction to land after the student leaves the basement. |
| R6 | **Separate attester and refunder keys.** | Smaller blast radius per key. |
| R7 | **Device validity is time-scoped.** Check-ins signed before a device was revoked stay valid. | A stolen tablet must not invalidate honest check-ins made earlier. |

---

## 3. System Architecture

```
 STUDENT PHONE (PWA)                CANTEEN TABLET (PWA)             OWNER LAPTOP
 - Privy login (Google)             - device key (IndexedDB)         - MetaMask (owner key)
 - session key (offline signing)    - rotating challenge QR          - /setup: authorize device,
 - signs intent, check-in           - scans student QR                 fund gas, revoke, schedule
 - self-submits fallback            - checkIn / markServed (tx)
        |                                   |                               |
        | HTTPS                             | tx                            | tx
        v                                   v                               v
 +---------------------------+      +------------------------------------------------+
 | BACKEND (Next.js + worker)|----->| MONAD: CanteenOrders contract (fund-free)      |
 | - intent validation       | tx   | orders, slots, demand, check-in, forfeit,      |
 | - Razorpay order/webhook  |      | refund-owed, refund-paid, device registry      |
 | - payment attestation     |<-----| events                                         |
 | - submitter, keeper       | logs +------------------------------------------------+
 | - refund executor         |
 | - indexer + Postgres      |      RAZORPAY (contractor account): UPI collect, refunds
 +---------------------------+
```

### 3.1 Key inventory

| Key | Held by | On-chain power | If compromised |
| :--- | :--- | :--- | :--- |
| **Owner** | MD's MetaMask | authorize and revoke devices, schedule, rotate attester, refunder, relayer | Rogue devices could mark orders served. Monitor `DeviceAuthorized` events. Use a multisig later. |
| **Attester** | Backend | sign payment attestations | Can mint orders until slot caps fill. Owner rotates it. No funds at risk. |
| **Refunder** | Backend | call `recordRefundPaid` | Can log fake refund ids. Reconciliation catches it. |
| **Relayer** | Backend | `setItemAvailable` only | Can toggle items off. Students get refunds. |
| **Submitter** | Backend | none (all signed calls are permissionless) | Can burn gas budget. Rate limits apply. |
| **Device** | One per tablet | sign challenges, `markServed` | Revoke it. Earlier check-ins stay valid. |
| **Session key** | Student phone | sign intents and check-ins for that student | Student re-registers a new key. |
| **Student wallet** | Privy embedded | authorize session keys | Standard embedded wallet risk. |

---

## 4. Time Model and Parameters

All times IST (UTC+05:30). `dayId = (timestamp + 19800) / 86400`.

| Parameter | Value | Notes |
| :--- | :--- | :--- |
| `OPEN_SEC` | 25200 (07:00) | Immutable at deploy. |
| `CUTOFF_SEC` | 32400 (09:00) | Immutable at deploy. |
| Slot starts (placeholder) | 12:00, 12:30, 13:00, 13:30 | **Replace with real rush times.** |
| `CLAIM_WINDOW` | 30 min | Challenge timestamp must fall inside it. |
| `SUBMIT_GRACE` | 30 min | `checkIn` may land up to this long after the claim window closes. |
| `SERVE_GRACE` | 20 min | From `presentAt` (the challenge timestamp). |
| `PREORDER_CAP_BPS` | 3000 | 30% of slot capacity, in portions. |
| `MAX_LINES` | 4 | Items per order. |
| `MAX_QTY_PER_LINE` | 10 | Placeholder. |
| `MAX_USES_PER_CHALLENGE` | 8 | Placeholder. Tune on a real counter. |
| `SESSION_KEY_TTL` | 30 days | Hard cap in the contract. |
| Challenge rotation | 30 s | Tablet side. |
| Tablet stale-QR rule | 60 s | Tablet side only, never in the contract. |
| Backend intent stop | 08:58 | Leaves room for UPI latency before the 09:00 cutoff. |

Schedule and price changes made by the owner take effect on the **next dayId**. Orders never reprice.

---

## 5. Smart Contract Specification: `CanteenOrders.sol`

### 5.1 Order state machine

```
                    placeOrder (attested, before 09:00)
                              |
                              v
                          [Placed]
                 |            |               |
   checkIn       |            | markForfeit   | claimUnavailableRefund
   (student +    |            | (anyone, after| (anyone, if any line's item
    device sigs) |            |  claim window | went unavailable after
                 v            |  + submit     | the order was placed)
          [CheckedIn]         |  grace, and   |
           |        |         v  not refundable)
 markServed|        |    [Forfeited]          |
 (device)  |        | flagUnserved            |
           v        | (anyone, after          v
       [Served]     |  presentAt+SERVE_GRACE) [RefundOwed] <----+
                    +-----------------------> [RefundOwed]     |
                                                  |             |
                                   recordRefundPaid (refunder)  |
                                                  v             |
                                            [RefundPaid]        |
        CheckedIn orders also move to RefundOwed via claimUnavailableRefund
```

Terminal states: Served, Forfeited, RefundPaid.

### 5.2 EIP-712 domain and types

Domain: `name="CanteenOrders"`, `version="1"`, `chainId`, `verifyingContract`. This blocks cross-chain and cross-deployment replay.

```
OrderIntent(address student,uint8 slotId,bytes32 linesHash,uint32 totalPaise,uint256 nonce,uint48 deadline)
PaymentAttestation(bytes32 intentHash,bytes32 paymentRef)
DeviceChallenge(address device,uint8 slotId,bytes32 nonce,uint48 timestamp)
CheckIn(uint256 orderId,bytes32 challengeHash)
SessionKeyAuth(address student,address key,uint48 expiry)
```

- `linesHash = keccak256(abi.encode(Line[] lines))` where `Line = (uint16 itemId, uint16 qty, uint32 unitPricePaise)`.
- `intentHash` in `PaymentAttestation` is the EIP-712 **struct hash** of the intent. Backend and contract must compute it identically.
- `challengeHash` in `CheckIn` is the struct hash of the `DeviceChallenge`.

### 5.3 Function table

| Function | Caller | Effect and checks |
| :--- | :--- | :--- |
| `registerSessionKey(student, key, expiry, sig)` | anyone | `sig` is the student wallet's `SessionKeyAuth`. `expiry <= now + 30 days`. Overwrites the previous key. |
| `placeOrder(intent, lines, studentSig, paymentRef, attesterSig)` | anyone | Inside 07:00 to 09:00. Intent not expired, nonce unused. Student sig recovers to the registered session key. Attestation recovers to `attester`. `paymentRef` unused. Lines hash matches. Each line: item active, price equals effective price, not toggled off today, qty in range. `totalPaise` matches. Slot active, starts after cutoff. Portions fit under the 30% cap. Updates demand, token, order. |
| `checkIn(orderId, challenge, deviceSig, studentSig)` | anyone | Status Placed. Now <= claimEnd + SUBMIT_GRACE. Challenge slot matches. Challenge timestamp inside the claim window and not in the future. Device was valid at that timestamp. Device sig recovers to `challenge.device`. Challenge use count under the cap. Student sig over `CheckIn(orderId, challengeHash)` recovers to the student's registered key. Sets `presentAt = challenge.timestamp`. |
| `markServed(orderId)` | authorized device | Status CheckedIn. Moves to Served. |
| `flagUnserved(orderId)` | anyone | Status CheckedIn and now > presentAt + SERVE_GRACE. Moves to RefundOwed (reason Unserved). |
| `markForfeit(orderId)` | anyone | Status Placed and now > claimEnd + SUBMIT_GRACE and not refundable for unavailability. Moves to Forfeited. |
| `claimUnavailableRefund(orderId)` | anyone | Status Placed or CheckedIn, and some line's item has `firstOffAt` set with `placedAt <= firstOffAt`. Moves to RefundOwed (reason ItemUnavailable). |
| `recordRefundPaid(orderId, refundRef)` | refunder | Status RefundOwed. Moves to RefundPaid. |
| `setItemAvailable(itemId, bool)` | relayer or owner | Sets today's flag. First time off today records `firstOffAt`. Toggling back on does not clear `firstOffAt`. |
| `authorizeDevice(addr)` / `revokeDevice(addr)` | owner | A revoked address cannot be re-authorized. A new tablet gets a new key. |
| `setSlot`, `setItem` | owner | Effective next dayId. |
| `setAttester`, `setRefunder`, `setRelayer` | owner | Rotation. |
| `transferOwnership` / `acceptOwnership` | owner / pending | Two-step. |

Views: `getOrder`, `getOrderLines`, `getSlotDemand(dayId, slotId, itemId)`, `slotUsed`, `tokenCounter`, `sessionKeys`, `deviceValidAt`, `isItemAvailable(dayId, itemId)`.

### 5.4 Events

```
SessionKeyRegistered(student, key, expiry)
OrderPlaced(orderId, student, dayId, slotId, tokenNo, paymentRef, totalPaise)
CheckedIn(orderId, device, presentAt)
Served(orderId, device)
Forfeited(orderId)
RefundOwed(orderId, reason)            // reason: 1 Unserved, 2 ItemUnavailable
RefundPaid(orderId, refundRef)
ItemAvailability(dayId, itemId, available)
DeviceAuthorized(device) / DeviceRevoked(device)
ConfigScheduled(kind, id, effectiveDay)
```

### 5.5 Reference skeleton (not audited)

Treat this as a starting point for Foundry, not final code. Config setters and some views are summarized as comments.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract CanteenOrders is EIP712 {
    enum Status { None, Placed, CheckedIn, Served, Forfeited, RefundOwed, RefundPaid }
    enum Reason { None, Unserved, ItemUnavailable }

    struct Line { uint16 itemId; uint16 qty; uint32 unitPricePaise; }
    struct OrderIntent {
        address student; uint8 slotId; bytes32 linesHash;
        uint32 totalPaise; uint256 nonce; uint48 deadline;
    }
    struct DeviceChallenge { address device; uint8 slotId; bytes32 nonce; uint48 timestamp; }
    struct SessionKey { address key; uint48 expiry; }
    struct Order {
        address student; uint32 dayId; uint8 slotId; uint32 tokenNo;
        uint48 placedAt; uint48 presentAt; Status status; Reason reason; bytes32 paymentRef;
    }

    uint256 internal constant IST = 19800;
    uint256 public immutable OPEN_SEC;
    uint256 public immutable CUTOFF_SEC;
    uint256 public constant CLAIM_WINDOW = 30 minutes;
    uint256 public constant SUBMIT_GRACE = 30 minutes;
    uint256 public constant SERVE_GRACE = 20 minutes;
    uint256 public constant SESSION_TTL = 30 days;
    uint256 public constant PREORDER_CAP_BPS = 3000;
    uint256 public constant MAX_LINES = 4;
    uint256 public constant MAX_USES_PER_CHALLENGE = 8;

    bytes32 private constant INTENT_T = keccak256("OrderIntent(address student,uint8 slotId,bytes32 linesHash,uint32 totalPaise,uint256 nonce,uint48 deadline)");
    bytes32 private constant PAY_T = keccak256("PaymentAttestation(bytes32 intentHash,bytes32 paymentRef)");
    bytes32 private constant CHAL_T = keccak256("DeviceChallenge(address device,uint8 slotId,bytes32 nonce,uint48 timestamp)");
    bytes32 private constant CHECKIN_T = keccak256("CheckIn(uint256 orderId,bytes32 challengeHash)");
    bytes32 private constant SESSION_T = keccak256("SessionKeyAuth(address student,address key,uint48 expiry)");

    address public owner; address public pendingOwner;
    address public attester; address public refunder; address public relayer;

    struct DeviceInfo { uint48 authorizedAt; uint48 revokedAt; }
    mapping(address => DeviceInfo) public devices;
    mapping(address => SessionKey) public sessionKeys;

    uint256 public orderCount;
    mapping(uint256 => Order) public orders;
    mapping(uint256 => Line[]) internal orderLines;
    mapping(address => mapping(uint256 => bool)) public intentNonceUsed;
    mapping(bytes32 => bool) public paymentRefUsed;

    mapping(uint256 => mapping(uint8 => uint256)) public slotUsed;             // day => slot => portions
    mapping(uint256 => mapping(uint8 => uint32)) public tokenCounter;          // day => slot => last token
    mapping(uint256 => mapping(uint8 => mapping(uint16 => uint256))) public demand; // day => slot => item => qty
    mapping(uint256 => mapping(uint16 => bool)) public offToday;               // day => item => currently off
    mapping(uint256 => mapping(uint16 => uint48)) public firstOffAt;           // day => item => first off time
    mapping(bytes32 => uint8) public challengeUses;

    error OutsideWindow(); error IntentExpired(); error NonceUsed(); error NoSessionKey();
    error BadStudentSig(); error BadAttestation(); error PaymentReused(); error BadLines();
    error LinesMismatch(); error BadLine(); error BadSlot(); error SlotFull(); error BadTotal();
    error BadStatus(); error TooLate(); error WrongSlot(); error ChallengeOutOfWindow();
    error DeviceNotAuthorized(); error BadDeviceSig(); error ChallengeExhausted();
    error NotDevice(); error NotYet(); error NotAllowed(); error Refundable();

    constructor(uint256 openSec, uint256 cutoffSec, address attester_, address refunder_, address relayer_)
        EIP712("CanteenOrders", "1")
    {
        OPEN_SEC = openSec; CUTOFF_SEC = cutoffSec;
        owner = msg.sender; attester = attester_; refunder = refunder_; relayer = relayer_;
    }

    // ---------- session keys ----------
    function registerSessionKey(address student, address key, uint48 expiry, bytes calldata sig) external {
        if (expiry > block.timestamp + SESSION_TTL) revert NotAllowed();
        bytes32 h = _hashTypedDataV4(keccak256(abi.encode(SESSION_T, student, key, expiry)));
        if (ECDSA.recover(h, sig) != student) revert BadStudentSig();
        sessionKeys[student] = SessionKey(key, expiry);
        emit SessionKeyRegistered(student, key, expiry);
    }

    // ---------- place ----------
    function placeOrder(
        OrderIntent calldata i, Line[] calldata lines, bytes calldata studentSig,
        bytes32 paymentRef, bytes calldata attesterSig
    ) external returns (uint256 orderId) {
        uint256 d = _dayId(block.timestamp);
        uint256 sod = (block.timestamp + IST) % 1 days;
        if (sod < OPEN_SEC || sod >= CUTOFF_SEC) revert OutsideWindow();
        if (block.timestamp > i.deadline) revert IntentExpired();
        if (intentNonceUsed[i.student][i.nonce]) revert NonceUsed();
        if (paymentRefUsed[paymentRef]) revert PaymentReused();

        bytes32 intentHash = keccak256(abi.encode(
            INTENT_T, i.student, i.slotId, i.linesHash, i.totalPaise, i.nonce, i.deadline));
        SessionKey memory sk = sessionKeys[i.student];
        if (sk.key == address(0) || block.timestamp > sk.expiry) revert NoSessionKey();
        if (ECDSA.recover(_hashTypedDataV4(intentHash), studentSig) != sk.key) revert BadStudentSig();
        bytes32 payHash = keccak256(abi.encode(PAY_T, intentHash, paymentRef));
        if (ECDSA.recover(_hashTypedDataV4(payHash), attesterSig) != attester) revert BadAttestation();

        if (lines.length == 0 || lines.length > MAX_LINES) revert BadLines();
        if (keccak256(abi.encode(lines)) != i.linesHash) revert LinesMismatch();

        (uint32 startSec, uint16 cap, bool slotOn) = _slot(d, i.slotId);
        if (!slotOn || startSec <= CUTOFF_SEC) revert BadSlot();

        orderId = ++orderCount;
        uint256 total; uint256 portions;
        for (uint256 k; k < lines.length; ++k) {
            Line calldata l = lines[k];
            (uint32 price, bool itemOn) = _item(d, l.itemId);
            if (!itemOn || offToday[d][l.itemId] || price != l.unitPricePaise || l.qty == 0 || l.qty > 10) revert BadLine();
            total += uint256(price) * l.qty;
            portions += l.qty;
            demand[d][i.slotId][l.itemId] += l.qty;
            orderLines[orderId].push(l);
        }
        if (total != i.totalPaise) revert BadTotal();
        if (slotUsed[d][i.slotId] + portions > (uint256(cap) * PREORDER_CAP_BPS) / 10_000) revert SlotFull();
        slotUsed[d][i.slotId] += portions;

        intentNonceUsed[i.student][i.nonce] = true;
        paymentRefUsed[paymentRef] = true;
        uint32 tokenNo = ++tokenCounter[d][i.slotId];
        orders[orderId] = Order(i.student, uint32(d), i.slotId, tokenNo,
            uint48(block.timestamp), 0, Status.Placed, Reason.None, paymentRef);
        emit OrderPlaced(orderId, i.student, d, i.slotId, tokenNo, paymentRef, i.totalPaise);
    }

    // ---------- check in ----------
    function checkIn(uint256 orderId, DeviceChallenge calldata c, bytes calldata deviceSig, bytes calldata studentSig) external {
        Order storage o = orders[orderId];
        if (o.status != Status.Placed) revert BadStatus();
        (uint256 cStart, uint256 cEnd) = _claimWindow(o.dayId, o.slotId);
        if (block.timestamp > cEnd + SUBMIT_GRACE) revert TooLate();
        if (c.slotId != o.slotId) revert WrongSlot();
        if (c.timestamp < cStart || c.timestamp > cEnd || c.timestamp > block.timestamp) revert ChallengeOutOfWindow();
        if (!deviceValidAt(c.device, c.timestamp)) revert DeviceNotAuthorized();

        bytes32 cHash = keccak256(abi.encode(CHAL_T, c.device, c.slotId, c.nonce, c.timestamp));
        if (ECDSA.recover(_hashTypedDataV4(cHash), deviceSig) != c.device) revert BadDeviceSig();
        if (challengeUses[cHash] >= MAX_USES_PER_CHALLENGE) revert ChallengeExhausted();

        address key = sessionKeys[o.student].key;
        bytes32 ciHash = keccak256(abi.encode(CHECKIN_T, orderId, cHash));
        if (key == address(0) || ECDSA.recover(_hashTypedDataV4(ciHash), studentSig) != key) revert BadStudentSig();

        challengeUses[cHash]++;
        o.presentAt = c.timestamp;
        o.status = Status.CheckedIn;
        emit CheckedIn(orderId, c.device, c.timestamp);
    }

    // ---------- settle ----------
    function markServed(uint256 orderId) external {
        DeviceInfo memory dv = devices[msg.sender];
        if (dv.authorizedAt == 0 || dv.revokedAt != 0) revert NotDevice();
        Order storage o = orders[orderId];
        if (o.status != Status.CheckedIn) revert BadStatus();
        o.status = Status.Served;
        emit Served(orderId, msg.sender);
    }

    function flagUnserved(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (o.status != Status.CheckedIn) revert BadStatus();
        if (block.timestamp <= uint256(o.presentAt) + SERVE_GRACE) revert NotYet();
        o.status = Status.RefundOwed; o.reason = Reason.Unserved;
        emit RefundOwed(orderId, uint8(Reason.Unserved));
    }

    function markForfeit(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (o.status != Status.Placed) revert BadStatus();
        (, uint256 cEnd) = _claimWindow(o.dayId, o.slotId);
        if (block.timestamp <= cEnd + SUBMIT_GRACE) revert NotYet();
        if (_unavailableRefundable(orderId)) revert Refundable();
        o.status = Status.Forfeited;
        emit Forfeited(orderId);
    }

    function claimUnavailableRefund(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (o.status != Status.Placed && o.status != Status.CheckedIn) revert BadStatus();
        if (!_unavailableRefundable(orderId)) revert NotAllowed();
        o.status = Status.RefundOwed; o.reason = Reason.ItemUnavailable;
        emit RefundOwed(orderId, uint8(Reason.ItemUnavailable));
    }

    function recordRefundPaid(uint256 orderId, bytes32 refundRef) external {
        if (msg.sender != refunder) revert NotAllowed();
        Order storage o = orders[orderId];
        if (o.status != Status.RefundOwed) revert BadStatus();
        o.status = Status.RefundPaid;
        emit RefundPaid(orderId, refundRef);
    }

    // ---------- availability and devices ----------
    function setItemAvailable(uint16 itemId, bool available) external {
        if (msg.sender != relayer && msg.sender != owner) revert NotAllowed();
        uint256 d = _dayId(block.timestamp);
        offToday[d][itemId] = !available;
        if (!available && firstOffAt[d][itemId] == 0) firstOffAt[d][itemId] = uint48(block.timestamp);
        emit ItemAvailability(d, itemId, available);
    }

    function authorizeDevice(address a) external {
        if (msg.sender != owner) revert NotAllowed();
        if (devices[a].authorizedAt != 0) revert NotAllowed();     // no reuse after revoke
        devices[a].authorizedAt = uint48(block.timestamp);
        emit DeviceAuthorized(a);
    }

    function revokeDevice(address a) external {
        if (msg.sender != owner) revert NotAllowed();
        devices[a].revokedAt = uint48(block.timestamp);
        emit DeviceRevoked(a);
    }

    function deviceValidAt(address a, uint256 ts) public view returns (bool) {
        DeviceInfo memory dv = devices[a];
        return dv.authorizedAt != 0 && ts >= dv.authorizedAt && (dv.revokedAt == 0 || ts < dv.revokedAt);
    }

    // ---------- internals ----------
    function _dayId(uint256 ts) internal pure returns (uint256) { return (ts + IST) / 1 days; }
    function _dayStart(uint256 d) internal pure returns (uint256) { return d * 1 days - IST; }
    function _claimWindow(uint256 d, uint8 slot) internal view returns (uint256 s, uint256 e) {
        (uint32 startSec,,) = _slot(d, slot);
        s = _dayStart(d) + startSec; e = s + CLAIM_WINDOW;
    }
    function _unavailableRefundable(uint256 id) internal view returns (bool) {
        Order storage o = orders[id]; Line[] storage ls = orderLines[id];
        for (uint256 k; k < ls.length; ++k) {
            uint48 t = firstOffAt[o.dayId][ls[k].itemId];
            if (t != 0 && o.placedAt <= t) return true;
        }
        return false;
    }
    // _slot(d, id) -> (startSec, capacity, active) and _item(d, id) -> (pricePaise, active):
    // return the config effective on day d, applying any pending change whose effectiveDay <= d.
    // setSlot / setItem write a pending change with effectiveDay = today + 1.
    // setAttester / setRefunder / setRelayer / transferOwnership / acceptOwnership: owner-only, omitted here.
    // Events as listed in section 5.4.
}
```

**Known gaps in the skeleton:** `_slot` and `_item` bodies, the config setters, and ownership functions are left out. `checkIn` does not re-check session key expiry, because the contract cannot know when the phone signed. The slot start time must be validated at config time to sit after `CUTOFF_SEC` and before 24:00.

### 5.6 Invariants to test

1. No state transition leaves a terminal state.
2. `slotUsed[d][s] <= capacity * 0.30` always.
3. An order reaches Served only through CheckedIn, and CheckedIn only through a valid check-in.
4. An order cannot be Forfeited while refundable for unavailability.
5. Check-ins signed while a device was valid remain valid after it is revoked.
6. A challenge hash is used by at most 8 check-ins.
7. A payment ref and an intent nonce are each consumed once.
8. `placeOrder` is impossible outside 07:00 to 09:00 IST, including at the exact boundaries.
9. Total demand for a day equals the sum of order lines placed that day.

### 5.7 Test plan (Foundry)

- Unit tests per function, including each revert path.
- Fuzz: random lines, quantities, times around the cutoff and claim boundaries, signature mutations.
- Invariant tests for items 1 to 9 above.
- Differential test: a TypeScript signing helper (viem) produces signatures that the contract accepts, which proves hash parity between client and contract.
- Gas snapshot for `placeOrder` with 1 and 4 lines.

---

## 6. Backend Specification

**Stack:** Next.js route handlers, a Node worker process, Postgres, viem for chain access. Hosting can be Vercel for the API and a small always-on host for the worker. The worker holds keys and runs the keeper, indexer, and refund executor.

### 6.1 Core flows

**Order flow**
1. `POST /api/intents`: student sends `{intent, lines, studentSig}`. Backend checks: Privy session valid, Google `hd` claim equals the college domain, current time before 08:58, signature recovers to the registered session key, prices match the chain, capacity available. It reserves capacity in Postgres for 5 minutes and creates a Razorpay order whose notes carry `intentHash`.
2. Student pays through Razorpay Checkout (UPI intent).
3. `POST /api/razorpay/webhook` on `payment.captured`: verify the webhook signature, dedupe on event id, look up the intent, sign a `PaymentAttestation(intentHash, paymentRef)` with the attester key.
4. Submitter calls `placeOrder`. The attestation and intent are also returned to the student app, which may submit them itself.
5. Indexer sees `OrderPlaced` and marks the order live.

**Failure handling for step 4:** if `placeOrder` reverts (cutoff passed during UPI latency, slot full, item turned off), the backend automatically refunds through Razorpay and logs the reason. A revert leaves no onchain record, so this refund is off-chain only. Say so in the pitch Q&A if asked.

**Refund flow**
1. Indexer sees `RefundOwed(orderId, reason)`.
2. Executor checks the Razorpay balance, issues the refund against the original payment, stores the refund id.
3. Submitter calls `recordRefundPaid(orderId, refundId)` from the refunder key.
4. Reconciliation flags any `RefundOwed` older than 15 minutes without `RefundPaid`.

**Keeper (every 60 s):** calls `markForfeit` for orders past claim window plus submit grace, and `flagUnserved` for CheckedIn orders past the serve grace. Both are permissionless, so a student or anyone else can also call them.

**Availability:** `POST /api/admin/availability` (owner or staff session) calls `setItemAvailable` from the relayer key. After the transaction confirms, the keeper calls `claimUnavailableRefund` for each affected order.

### 6.2 Data model (Postgres)

| Table | Key columns |
| :--- | :--- |
| `students` | privy_user_id, wallet_address, email_domain_ok, created_at |
| `session_keys` | student_id, key_address, expiry, registered_tx |
| `intents` | intent_hash, student_id, slot_id, lines_json, total_paise, razorpay_order_id, status, reserved_until |
| `payments` | payment_ref, intent_hash, razorpay_payment_id, amount, captured_at |
| `orders` | order_id, intent_hash, day_id, slot_id, token_no, status, last_event_block |
| `refunds` | order_id, reason, razorpay_refund_id, amount, status, recorded_tx |
| `chain_cursor` | last_processed_block |
| `jobs` | kind, payload, run_at, attempts, last_error |
| `audit_log` | actor, action, tx_hash, at |

### 6.3 Indexer

Poll `getLogs` every second from `chain_cursor`. Store block number and log index for every event. Handlers are idempotent on `(tx_hash, log_index)`. The database is a **cache of chain state**. If it disagrees with the chain, the chain wins and a rebuild command replays from the deploy block.

### 6.4 Float and exposure

- Refund balance must cover every open pre-order payment that could still be refunded.
- **Per-intent check:** reject a new intent if `available_balance - open_refund_exposure < intent_amount`.
- **Sizing:** `max_exposure = sum over slots of floor(capacity * 0.30) * max_item_price`. Illustration only, with 4 slots of 100 portions and a 25 rupee item, that is about 3,000 rupees. Use real capacities.
- **UNVERIFIED:** how Razorpay funds refunds after settlement has swept money to the contractor's bank (section 14).

### 6.5 Gas budget

Submitter and device wallets need MON. Per-student daily limit on sponsored transactions. A balance alarm at 20% of the daily budget. Testnet MON comes from the faucet. Mainnet cost per order is expected to be negligible, but measure it.

### 6.6 Payment adapter interface

```ts
interface PaymentAdapter {
  createCharge(intent: Intent): Promise<ChargeRef>
  onPaid(handler: (ref: ChargeRef, amountPaise: number) => void): void
  refund(ref: ChargeRef, amountPaise: number, note: string): Promise<RefundRef>
  availableBalance(): Promise<number>
}
```

- **DemoAdapter:** cINR ERC-20 with a faucet button (500 cINR). The student's embedded wallet transfers cINR to a demo vault, the backend watches `Transfer`, refunds transfer back.
- **RazorpayAdapter:** pilot mode as described above.

The contract, indexer, and both apps are identical in both modes. Only the adapter changes.

---

## 7. Student App (PWA): replaces v1 section 5.2 and section 6

### 7.1 Screens

| Screen | Purpose | Notes |
| :--- | :--- | :--- |
| Login | "Continue with Google" | Privy. Phone OTP fallback if the college has no Workspace accounts. OTP gives no whitelist. |
| Menu and slots | Cart (up to 4 lines), slot picker | Slot cards show remaining pre-order portions from chain state. Sold-out items greyed. |
| Review | Total, slot, token preview | Student signs the intent here. |
| Pay | Razorpay UPI intent, or demo cINR | Shows a pending state until `OrderPlaced` arrives. |
| Confirmation | Token as `12:30 · #14`, slot, claim window | Static "Sponsored" card below the token, labeled, no autoplay, no overlay. Never on the pay step. |
| My Order | Live status | Placed, Show at counter, Checked in, Served, Forfeited, Refund owed, Refund paid. Links each state to its onchain event. |
| Counter check-in | Camera scan, then response QR | Works with no network. |
| Settings | Re-authorize session key | After browser data loss. |

The v1 pass `#108` and the hardcoded modal token are removed. Tokens come from `OrderPlaced`.

### 7.2 Session key

- Generate a secp256k1 key with `@noble/curves` on first login.
- Encrypt it at rest with AES-GCM using a **non-extractable WebCrypto wrapping key**, both stored in IndexedDB.
- Student wallet signs `SessionKeyAuth(student, key, expiry)`. Any submitter relays it.
- Describe it honestly: "an origin-bound key in IndexedDB, encrypted with a non-extractable WebCrypto key." Do not call it secure-enclave or non-extractable.
- Re-registration overwrites the old key. Old signatures stop verifying.
- **UNVERIFIED on iOS Safari:** stored site data can be evicted after about a week without use unless the PWA is installed to the home screen. Test and prompt installation.

### 7.3 Offline check-in protocol

1. Tablet shows a **challenge QR**: `{v:1, device, slotId, nonce, timestamp, deviceSig}`, rotating every 30 s.
2. Student opens Counter check-in, scans it.
3. Phone verifies the device signature locally, signs `CheckIn(orderId, challengeHash)` with the session key.
4. Phone shows a **response QR**: `{v:1, orderId, challenge, studentSig}`.
5. Tablet scans it, checks the challenge is under 60 s old, submits `checkIn`.
6. The phone **keeps the signed payload** until the chain confirms `CheckedIn`. If the tablet drops it, the app resubmits itself when the network returns, up to claim end plus submit grace.

Expect a QR of roughly 300 to 400 bytes. Use error-correction level L or M and test on cheap phone cameras in canteen lighting.

### 7.4 Dead phone

No signature, no check-in, no serve, forfeit. Staff do not hand over food on a manual override. The 30 minute claim window plus 30 minute submit grace is the mitigation: a student with a dead phone charges it and returns.

---

## 8. Tablet and Kitchen Display System: replaces v1 section 7

Route `/tablet`. Runs on one or more canteen tablets, each with its own device key.

### 8.1 Screens

- **Counter mode (default):** large rotating challenge QR, camera scanner for response QRs, big result card after a scan ("Token #14, 2 Vada Pav, 1 Chai", green or red).
- **Queue:** three columns, **Placed**, **Checked in**, **Served**, filtered by the current slot. Search by token.
- **Prep summary:** per-slot totals from `getSlotDemand`, frozen after 09:00. Example row: `12:30 baseline: 40 Vada Pav, 12 Dosa, 30 Chai`.
- **Sold out toggle:** per item, calls the backend availability endpoint. Staff never see a wallet.
- **Status strip:** device authorized yes or no, gas balance, last chain sync, pending queue length.

### 8.2 Behavior

- After a scan, the tablet submits `checkIn`. On confirmation the order card appears, staff hand over food and press **Serve**, which sends `markServed`.
- Pending transactions persist in IndexedDB and retry. Duplicate submission is harmless because contract status checks reject it.
- The tablet pays its own gas from the device wallet. Low-gas warning at 0.05 MON.
- If the tablet loses the network, it keeps issuing challenges. Students can still sign, and their phones submit later.

### 8.3 Caveat for staff training

If staff hand over food but forget to press Serve, the student's order becomes refund-owed and they get food plus a refund. This is the canteen's process loss. The queue view highlights CheckedIn orders older than 10 minutes in the terracotta accent so staff catch them.

---

## 9. Owner Admin: `/setup`

- Connect MetaMask (injected connector, used only here).
- **Authorize new tablet:** tablet shows a setup QR with its device address, owner's laptop webcam scans it, one click calls `authorizeDevice`, a second click sends 0.2 MON for gas.
- **Revoke:** list of devices with last-seen time, one click `revokeDevice`.
- **Schedule:** view slots, capacities, prices. Edits show "effective tomorrow."
- **Keys:** rotate attester, refunder, relayer.
- **Event feed:** live `DeviceAuthorized`, `ConfigScheduled`, `RefundOwed`, `RefundPaid` for monitoring.

The owner key loss case: nobody can authorize devices or change schedule, but no funds are at risk. Plan a Safe multisig for the owner role after the pilot.

---

## 10. Design System and Client Configuration

### 10.1 Design system

Carried over from v1 section 2 unchanged: Bento-box layout, warm charcoal canvas, cream serif headings, terracotta accents. Reuse the v1 `tailwind.config.ts` as-is.

| Token | Hex | Use |
| :--- | :--- | :--- |
| `canvas` | `#141211` | Body |
| `surface` / `surface-elevated` | `#1E1A18` / `#282320` | Cards, controls |
| `border-subtle` / `border-focus` | `#3A322D` / `#C15F3C` | Outlines, active |
| `cream` / `cream-muted` / `cream-dim` | `#F5E6D3` / `#C4A584` / `#7E7063` | Text tiers |
| `accent-crail` | `#C15F3C` | Primary actions |
| `accent-orange` | `#E67D22` | Live timers, badges |
| `accent-peach` | `#FFB38A` | Tokens, values |
| `accent-success` | `#5E9E74` | Served, confirmed |

Fonts: Newsreader (serif), Inter (sans), JetBrains Mono (mono).

### 10.2 Chain and wallet config (replaces v1 section 4)

- Students: Privy embedded wallets, viem clients. No MetaMask for students.
- Owner: injected MetaMask on `/setup` only.
- Tablets: device key in IndexedDB, viem wallet client from a local account.

```ts
import { defineChain } from 'viem'

export const monadTestnet = defineChain({
  id: 10143, // UNVERIFIED: confirm against current Monad docs before deploying
  name: 'Monad Testnet',
  nativeCurrency: { name: 'Monad', symbol: 'MON', decimals: 18 },
  rpcUrls: { default: { http: ['https://testnet-rpc.monad.xyz'] } },
  blockExplorers: { default: { name: 'MonadExplorer', url: 'https://testnet.monadexplorer.com' } },
})
```

v1 had markdown link syntax inside the URL strings, which would break the RPC call. Fixed above. Confirm the chain id, RPC URL, and explorer URL against current docs before use.

---

## 11. Threat Model

| # | Attack | Defense | Residual risk |
| :--- | :--- | :--- | :--- |
| 1 | Remote check-in using a challenge relayed from the counter | Device-signed challenge, per-challenge use cap of 8, tablet-side 60 s staleness rule | A friend physically at the counter can relay challenges. Cap limits each relay to 8 check-ins. Detect by comparing footfall to check-ins. |
| 2 | Canteen denies food after check-in | RefundOwed after serve grace | A device can falsely mark served. This is the canteen's own attestation. |
| 3 | Stolen or broken tablet | `revokeDevice`, time-scoped validity | Short window before revocation. |
| 4 | Relayer key compromised | Can only toggle items off, which refunds students | Temporary denial of service. |
| 5 | Attester key compromised | Capacity cap bounds orders, owner rotates | Capacity exhausted until rotation. |
| 6 | Owner key compromised | Event monitoring, two-step ownership | Rogue device authorization. Move to multisig. |
| 7 | Backend refuses to attest a real payment | Student holds Razorpay receipt and signed intent | Evidence is off-chain only. |
| 8 | Backend does not pay a refund | Public `RefundOwed` with no `RefundPaid` | Visible, not preventable. |
| 9 | Payment captured but `placeOrder` reverts | Automatic refund, daily reconciliation | Off-chain only record. |
| 10 | Student clears browser data | Re-register key, fallback payload display | Pending unsent check-in payloads are lost. |
| 11 | Outsider or sybil orders | Backend attests only verified `hd` accounts | Domain check must be server-side. |
| 12 | Gas sponsor drained | Per-student limits, budget alarms | Bounded loss. |
| 13 | Cutoff race at 08:59 | Backend stops intents at 08:58, auto-refund on revert | Rare unlucky student gets a refund. |
| 14 | Cross-chain or cross-contract signature replay | EIP-712 domain with chainId and verifyingContract | None expected. |
| 15 | Nonce exhaustion griefing | Student retries on next 30 s rotation | Mild nuisance. |

---

## 12. Pitch (replaces v1 section 8)

### 12.1 Two-minute structure

- **0:00 to 0:25, problem:** canteens cook on guesses, WhatsApp pre-orders cost nothing to break, the canteen eats no-shows.
- **0:25 to 1:00, mechanism:** pay by UPI before 09:00, capped at 30% of a slot, the kitchen gets a paid baseline, a no-show forfeits.
- **1:00 to 1:40, the part only a chain does:** live demo of the two-way scan, then show the tablet dropping a message and the student's phone submitting it directly.
- **1:40 to 2:00, close:** *"Pre-orders give the kitchen a paid baseline. A student who checks in can't be denied and charged. The canteen can't keep their money without a signed service record."*

### 12.2 Q&A answers

**Why not Postgres?**
*"You could store these check-ins in a database. The difference is who holds the pen. In a database, the canteen or we can edit, delete, or backdate a row. Here the student's own key signs the check-in, and the contract timestamps it. If the tablet drops it, the student's phone submits it directly. Nobody running the system can erase it. Refunds are paid through Razorpay by our backend, so we publish the refund id onchain. If a refund is owed and no id appears, everyone can see we didn't pay. The chain doesn't move the money. It makes it impossible to hide whether we owed it."*

**Where is the value transfer?** None, by design. Rupees stay in UPI and Razorpay.

**So you still trust the backend for payment?** Yes. The chain makes non-payment visible, not impossible.

**Privacy?** Addresses are pseudonymous, item ids are public because the kitchen's demand counts need them, and all personal data stays off-chain.

**Can someone fake presence?** A person at the counter can relay challenges to a few friends. We cap that per challenge and it needs a collaborator physically present. Not cryptographically solvable. Operationally detectable.

**Is the key secure?** It is an origin-bound key in IndexedDB, encrypted with a non-extractable WebCrypto key. Not hardware-backed.

### 12.3 Demo script

Use DemoAdapter. Faucet, order, scan, serve. Then simulate a tablet drop, show the phone's direct submission. Then toggle an item off and show the immediate refund state. Label simulated numbers as simulated.

---

## 13. v1 Defects Retired by This Spec

- Contract held ETH with an immutable merchant and no deadlines.
- Demand and token counters never reset by day.
- Cutoff set manually by the merchant, so nothing was actually locked.
- `fulfillOrder` and `refundOrder` both merchant-only.
- Token `#108` hardcoded in two places.
- `CheckoutWithAdModal` JSX props passed as quoted strings in `page.tsx`, and the modal block was malformed.
- RPC and explorer URLs written as markdown links inside code strings.
- Admin page never called the contract.
- Ad shown during a sub-second transaction wait.
- Barometer showed fixed numbers presented as live.
- "Zero food waste" claim.

---

## 14. Verify Before Building (UNVERIFIED items)

| # | Item | How to verify | Blocks |
| :--- | :--- | :--- | :--- |
| V1 | K.C. College issues Google Workspace accounts to students, and the domain | Ask the MD or college IT, or check a student's phone | Login design |
| V2 | Session-key signing works fully offline in the PWA, including on iOS Safari | Airplane-mode test on 3 real phones, one iPhone | Phase 4 |
| V3 | Razorpay refund funding after settlement, and refund API behavior in the contractor's account | Razorpay support or docs, test mode | Phase 8 |
| V4 | Contractor agrees to automatic refunds from their balance and a minimum float | Written confirmation | Phase 8 |
| V5 | Real slot times, per-slot physical capacity, real item list and prices | Walk the canteen | Phase 1 params |
| V6 | Monad testnet chain id, RPC, explorer, current gas behavior | Current Monad docs | Phase 2 |
| V7 | QR size and scan reliability on cheap cameras in canteen lighting | Printed test cards | Phase 4 and 5 |
| V8 | MD sign-off on ad placement and the pilot scope | Meeting | Phase 7 |
| V9 | Cart whole-order refund rule (R4) acceptable to the canteen | Ask the contractor | Phase 1 |

---

## 15. Implementation Plan

Effort figures are rough focused days for one developer and assume no surprises. Cut or reorder to fit your buildathon date.

### 15.1 Sequence

```
P0 Verify -> P1 Contract + tests -> P2 Deploy + indexer -> P3 Backend core
                                          |                      |
                                          +-> P5 Tablet <--------+
                                          +-> P4 Student PWA <---+
P4 + P5 -> P6 Owner admin -> P7 Demo build + pitch -> P8 Pilot hardening
```

P4 and P5 can run in parallel once P2 is done. P6 can start after P5's device logic exists.

### 15.2 Phases

**P0. Verify the blockers (1 day)**
- Run V1, V2, V5, V6 first. V3 and V4 can wait for P8, but start the conversation now because contractor answers are slow.
- Done when: login method chosen, offline signing confirmed or the fallback decided, real slot and item data in hand.

**P1. Contract and tests (4 days)**
1. Foundry project, OpenZeppelin dependencies.
2. Implement slots, items, config with next-day effect.
3. Implement `registerSessionKey`, `placeOrder` (cart), demand and token counters.
4. Implement `checkIn`, devices, challenge cap.
5. Implement settle functions, availability, refunds.
6. TypeScript signing helper with viem and differential tests.
7. Invariant and fuzz suite from 5.6 and 5.7.
- Done when: all invariants pass, gas snapshot recorded, hash parity test green.

**P2. Deploy and indexer (2 days)**
1. Deploy to Monad testnet, verify on the explorer.
2. Generate the five server keys and the owner key, fund them.
3. Indexer with cursor, idempotent handlers, rebuild command.
4. Postgres schema.
- Done when: a scripted order, check-in, and serve show correctly in the database from chain events alone.

**P3. Backend core (4 days)**
1. Privy session verification and the `hd` check.
2. `/api/intents` with capacity reservation.
3. DemoAdapter with the cINR contract and faucet.
4. Attestation signing, submitter, `placeOrder` path.
5. Keeper for forfeit and unserved flags.
6. Refund executor with `recordRefundPaid`.
7. Availability endpoint.
- Done when: a full demo order and a forced refund run end to end with curl and scripts.

**P4. Student PWA (5 days)**
1. Privy login, session key generation and registration.
2. Menu, cart, slot picker from chain reads.
3. Intent signing, pay, pending state.
4. Confirmation with token and sponsored card.
5. My Order live status from the indexer.
6. Counter check-in scanner and response QR, offline path.
7. Payload retention and self-submit fallback.
8. PWA install prompt, theme.
- Done when: V2 and V7 pass on real devices.

**P5. Tablet (4 days)**
1. Device key, setup QR, authorization status.
2. Rotating challenge QR.
3. Scanner, local validation, `checkIn` submission, retry queue.
4. Queue board, serve action, stale-order highlight.
5. Prep summary from `getSlotDemand`.
6. Sold-out toggle.
- Done when: a tablet and a phone complete check-in and serve, including a forced tablet drop followed by phone self-submission.

**P6. Owner admin (2 days)**
- `/setup` authorize, fund, revoke, schedule view, key rotation, event feed.
- Done when: a new tablet goes from blank to authorized in under two minutes, and a revoked tablet's earlier check-ins stay valid.

**P7. Demo build and pitch (3 days)**
1. Demo data seeding, labeled simulated numbers.
2. Scripted failure demos: tablet drop, item toggle refund.
3. Rehearse the 2 minute pitch and the Q&A in section 12.
4. Record a backup video of the full flow.
- Done when: three clean consecutive dry runs.

**P8. Pilot hardening (5 days plus calendar time)**
1. RazorpayAdapter, webhook verification, idempotency.
2. Float check, exposure calculation, alarms.
3. Daily reconciliation job and alerts to the canteen manager.
4. Monitoring: gas balances, keeper lag, `RefundOwed` without `RefundPaid`.
5. Written contractor agreement (V4), staff one-page guide.
6. Dry run with 20 students at one slot before opening to everyone.
- Done when: the dry run settles correctly and a forced refund pays within 15 minutes.

### 15.3 Minimum cut if time is short

Keep: P0 (V2, V5), P1 (all core, trim config setters to constants), P2, P3 (Demo only), P4, P5, one failure demo. Drop: Razorpay, availability relayer, owner admin UI (authorize devices with a script), sponsored card, keeper automation (call `markForfeit` by hand). This still demonstrates the full check-in protocol, which is the strongest part of the design.

### 15.4 Open parameters to settle during build

Real slot times and capacities, `MAX_QTY_PER_LINE`, `SERVE_GRACE`, `MAX_USES_PER_CHALLENGE`, which curve to use for session keys if V2 forces a change (P-256 needs a verifier or precompile check, **UNVERIFIED** on Monad), whether whole-order refund (R4) stays, sponsor name for the demo card.
