// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CanteenOrders} from "../src/CanteenOrders.sol";

/// @dev Drives random sequences of every state-changing call and records ghost state
///      for the invariants in spec section 5.6.
contract Handler is Test {
    CanteenOrders internal c;
    uint256 internal constant IST = 19800;

    address internal owner;
    uint256 internal attesterPk;
    address internal refunder;
    address internal relayer;

    uint256[3] internal walletPks = [uint256(0x5701), 0x5702, 0x5703];
    uint256[3] internal sessionPks = [uint256(0x5E01), 0x5E02, 0x5E03];
    uint256[] public devicePks;

    uint8[4] internal slotIds = [0, 1, 2, 3];
    uint16[3] internal itemIds = [1, 2, 3];
    uint32[3] internal prices = [2000, 4000, 1000];

    // ghost state
    uint256[] public dayList;
    mapping(uint256 => bool) internal dayKnown;
    mapping(uint256 => mapping(uint8 => uint256)) public ghostPortions;
    mapping(uint256 => mapping(uint8 => mapping(uint16 => uint256))) public ghostDemand;
    bytes32[] public paymentRefs;
    bytes32[] public challengeHashes;
    mapping(uint256 => CanteenOrders.Status) internal lastStatus;
    uint256 internal nonceSeq;
    uint256 internal paySeq;

    struct Pending {
        uint256 orderId;
        CanteenOrders.DeviceChallenge ch;
        bytes dsig;
        bytes ssig;
    }

    Pending[] internal pending;
    CanteenOrders.DeviceChallenge internal lastChallenge;
    bytes internal lastChallengeSig;
    uint256 internal lastChallengeDevicePk;

    // violation flags
    bool public placedOutsideWindow;
    bool public refReuseSucceeded;
    bool public nonceReuseSucceeded;
    bool public illegalTransition;
    bool public forfeitedWhileRefundable;
    bool public honestCheckInRejected;

    mapping(bytes32 => uint256) public calls;
    mapping(bytes32 => uint256) public wins;

    constructor(
        CanteenOrders c_,
        address owner_,
        uint256 attesterPk_,
        address refunder_,
        address relayer_,
        uint256 devPk
    ) {
        c = c_;
        owner = owner_;
        attesterPk = attesterPk_;
        refunder = refunder_;
        relayer = relayer_;
        devicePks.push(devPk);
        renewSessions();
    }

    // ------------------------------------------------------------------ helpers

    function _day() internal view returns (uint256) {
        return (vm.getBlockTimestamp() + IST) / 1 days;
    }

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", c.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function renewSessions() public {
        for (uint256 k; k < 3; ++k) {
            address w = vm.addr(walletPks[k]);
            uint48 exp = uint48(vm.getBlockTimestamp() + 30 days);
            uint256 n = c.sessionNonce(w);
            bytes32 h = keccak256(abi.encode(c.SESSION_TYPEHASH(), w, vm.addr(sessionPks[k]), exp, n));
            c.registerSessionKey(w, vm.addr(sessionPks[k]), exp, n, _sign(walletPks[k], h));
        }
    }

    function _orderCount() internal view returns (uint256) {
        return c.orderCount();
    }

    function _pickOrder(uint256 seed) internal view returns (uint256) {
        uint256 n = _orderCount();
        return n == 0 ? 0 : 1 + seed % n;
    }

    function _findOrder(uint256 seed, CanteenOrders.Status want) internal view returns (uint256) {
        uint256 n = _orderCount();
        for (uint256 k; k < n; ++k) {
            uint256 id = 1 + (seed % n + k) % n;
            if (c.getOrder(id).status == want) return id;
        }
        return 0;
    }

    /// A Placed order whose claim window has not ended yet.
    function _findLivePlaced(uint256 seed) internal view returns (uint256) {
        uint256 n = _orderCount();
        for (uint256 k; k < n; ++k) {
            uint256 id = 1 + (seed % n + k) % n;
            (, uint256 ce) = c.claimWindow(id);
            if (c.getOrder(id).status == CanteenOrders.Status.Placed && vm.getBlockTimestamp() <= ce) return id;
        }
        return 0;
    }

    function _studentIdx(address s) internal view returns (uint256) {
        for (uint256 k; k < 3; ++k) {
            if (vm.addr(walletPks[k]) == s) return k;
        }
        revert("unknown student");
    }

    function _allowed(CanteenOrders.Status a, CanteenOrders.Status b) internal pure returns (bool) {
        if (a == b) return true;
        if (a == CanteenOrders.Status.None) return b == CanteenOrders.Status.Placed;
        if (a == CanteenOrders.Status.Placed) {
            return b == CanteenOrders.Status.CheckedIn || b == CanteenOrders.Status.Forfeited
                || b == CanteenOrders.Status.RefundOwed;
        }
        if (a == CanteenOrders.Status.CheckedIn) {
            return b == CanteenOrders.Status.Served || b == CanteenOrders.Status.RefundOwed;
        }
        if (a == CanteenOrders.Status.RefundOwed) return b == CanteenOrders.Status.RefundPaid;
        return false; // terminal: Served, Forfeited, RefundPaid
    }

    modifier synced(bytes32 name) {
        calls[name]++;
        _;
        uint256 n = _orderCount();
        for (uint256 id = 1; id <= n; ++id) {
            CanteenOrders.Status s = c.getOrder(id).status;
            if (!_allowed(lastStatus[id], s)) illegalTransition = true;
            lastStatus[id] = s;
        }
    }

    // ------------------------------------------------------------------ time

    function warp(uint256 secs) external synced("warp") {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 3 hours));
    }

    function warpToNextWindow(uint256 sodOff) external synced("warpToNextWindow") {
        uint256 dayStart = _day() * 1 days - IST;
        uint256 target = dayStart + 1 days + 25200 + bound(sodOff, 0, 7200);
        vm.warp(target);
        renewSessions();
    }

    // ------------------------------------------------------------------ orders

    function place(uint256 seed) external synced("place") {
        // Half the time jump forward into the next order window; the other half tries at the current time.
        uint256 nowSod = (vm.getBlockTimestamp() + IST) % 1 days;
        if (seed & 1 == 0 && (nowSod < 25200 || nowSod >= 32400)) {
            uint256 dayStart = _day() * 1 days - IST;
            if (nowSod >= 32400) dayStart += 1 days;
            vm.warp(dayStart + 25200 + (seed >> 24) % 7200);
            renewSessions();
        }
        uint256 sIdx = seed % 3;
        uint8 slotId = (seed >> 8) % 4 == 0 ? slotIds[(seed >> 10) % 4] : 1; // crowd slot 1 to share challenges
        uint256 n = 1 + (seed >> 16) % 4;
        CanteenOrders.Line[] memory ls = new CanteenOrders.Line[](n);
        uint32 total;
        for (uint256 k; k < n; ++k) {
            uint256 it = uint256(keccak256(abi.encode(seed, k))) % 3;
            uint16 qty = uint16(1 + uint256(keccak256(abi.encode(seed, k, "q"))) % 5);
            ls[k] = CanteenOrders.Line(itemIds[it], qty, prices[it]);
            total += prices[it] * qty;
        }
        CanteenOrders.OrderIntent memory i = CanteenOrders.OrderIntent(
            vm.addr(walletPks[sIdx]),
            slotId,
            keccak256(abi.encode(ls)),
            total,
            ++nonceSeq,
            uint48(vm.getBlockTimestamp() + 10 minutes)
        );
        bytes32 ih = c.intentStructHash(i);
        bytes32 ref = keccak256(abi.encode("ref", ++paySeq));
        bytes memory ssig = _sign(sessionPks[sIdx], ih);
        bytes memory asig = _sign(attesterPk, keccak256(abi.encode(c.PAYMENT_TYPEHASH(), ih, ref)));

        uint256 sod = (vm.getBlockTimestamp() + IST) % 1 days;
        try c.placeOrder(i, ls, ssig, ref, asig) {
            if (sod < 25200 || sod >= 32400) placedOutsideWindow = true;
            uint256 d = _day();
            if (!dayKnown[d]) {
                dayKnown[d] = true;
                dayList.push(d);
            }
            for (uint256 k; k < n; ++k) {
                ghostPortions[d][slotId] += ls[k].qty;
                ghostDemand[d][slotId][ls[k].itemId] += ls[k].qty;
            }
            paymentRefs.push(ref);
            wins["place"]++;
            // replay the same intent and same ref: both must fail
            try c.placeOrder(i, ls, ssig, ref, asig) {
                nonceReuseSucceeded = true;
            } catch {}
        } catch {}
    }

    function placeReusingRef(uint256 seed) external synced("placeReusingRef") {
        if (paymentRefs.length == 0) return;
        bytes32 ref = paymentRefs[seed % paymentRefs.length];
        CanteenOrders.Line[] memory ls = new CanteenOrders.Line[](1);
        ls[0] = CanteenOrders.Line(3, 1, 1000);
        CanteenOrders.OrderIntent memory i = CanteenOrders.OrderIntent(
            vm.addr(walletPks[0]), 0, keccak256(abi.encode(ls)), 1000, ++nonceSeq, uint48(vm.getBlockTimestamp() + 600)
        );
        bytes32 ih = c.intentStructHash(i);
        try c.placeOrder(
            i,
            ls,
            _sign(sessionPks[0], ih),
            ref,
            _sign(attesterPk, keccak256(abi.encode(c.PAYMENT_TYPEHASH(), ih, ref)))
        ) {
            refReuseSucceeded = true;
        } catch {}
    }

    // ------------------------------------------------------------------ check in

    function _challenge(uint256 devIdx, uint8 slotId, bytes32 nonce)
        internal
        view
        returns (CanteenOrders.DeviceChallenge memory ch, bytes memory sig)
    {
        uint256 pk = devicePks[devIdx % devicePks.length];
        ch = CanteenOrders.DeviceChallenge(vm.addr(pk), slotId, nonce, uint48(vm.getBlockTimestamp()));
        sig = _sign(pk, c.challengeStructHash(ch));
    }

    function _studentSig(uint256 orderId, CanteenOrders.DeviceChallenge memory ch)
        internal
        view
        returns (bytes memory)
    {
        address s = c.getOrder(orderId).student;
        bytes32 h = keccak256(abi.encode(c.CHECKIN_TYPEHASH(), orderId, c.challengeStructHash(ch)));
        return _sign(sessionPks[_studentIdx(s)], h);
    }

    function _recordChallenge(CanteenOrders.DeviceChallenge memory ch) internal {
        challengeHashes.push(c.challengeStructHash(ch));
    }

    /// Jump into the order's claim window (if it is still ahead) and check in with a fresh challenge.
    function checkIn(uint256 seed, uint256 offset) external synced("checkIn") {
        uint256 id = seed % 4 == 0 ? _pickOrder(seed) : _findLivePlaced(seed);
        if (id == 0) return;
        (uint256 cs, uint256 ce) = c.claimWindow(id);
        if (vm.getBlockTimestamp() < cs) vm.warp(cs + bound(offset, 0, ce - cs));
        CanteenOrders.Order memory o = c.getOrder(id);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) =
            _challenge(seed >> 8, o.slotId, keccak256(abi.encode(seed, vm.getBlockTimestamp())));
        try c.checkIn(id, ch, dsig, _studentSig(id, ch)) {
            _recordChallenge(ch);
            lastChallenge = ch;
            wins["checkIn"]++;
            lastChallengeSig = dsig;
            if (seed & 2 == 0) _shareChallenge(seed);
        } catch {}
    }

    /// The same QR scanned by several students in a row (up to the per-challenge cap).
    function _shareChallenge(uint256 seed) internal {
        uint256 n = _orderCount();
        for (uint256 k; k < n; ++k) {
            uint256 id = 1 + (seed % n + k) % n;
            CanteenOrders.Order memory o = c.getOrder(id);
            (uint256 cs, uint256 ce) = c.claimWindow(id);
            if (
                o.status != CanteenOrders.Status.Placed || o.slotId != lastChallenge.slotId
                    || lastChallenge.timestamp < cs || lastChallenge.timestamp > ce
            ) continue;
            try c.checkIn(id, lastChallenge, lastChallengeSig, _studentSig(id, lastChallenge)) {
                wins["checkInShared"]++;
            } catch {}
        }
    }

    /// Reuse the last challenge for another order, exercising the per-challenge cap.
    function checkInSharedChallenge(uint256 seed) external synced("checkInShared") {
        if (lastChallenge.device == address(0)) return;
        uint256 n = _orderCount();
        for (uint256 k; k < n; ++k) {
            uint256 id = 1 + (seed % n + k) % n;
            CanteenOrders.Order memory o = c.getOrder(id);
            (uint256 cs, uint256 ce) = c.claimWindow(id);
            if (
                o.status == CanteenOrders.Status.Placed && o.slotId == lastChallenge.slotId
                    && lastChallenge.timestamp >= cs && lastChallenge.timestamp <= ce
            ) {
                try c.checkIn(id, lastChallenge, lastChallengeSig, _studentSig(id, lastChallenge)) {
                    wins["checkInShared"]++;
                } catch {}
                return;
            }
        }
    }

    /// Phone signs a check-in now but the tablet drops it; it is submitted later.
    function signCheckInLater(uint256 seed) external synced("signLater") {
        uint256 id = _findLivePlaced(seed);
        if (id == 0) return;
        (uint256 cs, uint256 ce) = c.claimWindow(id);
        if (vm.getBlockTimestamp() < cs) vm.warp(cs + (seed >> 16) % (ce - cs));
        if (vm.getBlockTimestamp() > ce) return;
        CanteenOrders.Order memory o = c.getOrder(id);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) =
            _challenge(seed >> 8, o.slotId, keccak256(abi.encode("later", seed, vm.getBlockTimestamp())));
        if (!c.deviceValidAt(ch.device, ch.timestamp)) return;
        pending.push(Pending(id, ch, dsig, _studentSig(id, ch)));
    }

    /// Invariant 5: a payload signed while the device was valid must land, even after revocation,
    /// as long as the order is still Placed, the grace has not passed and the challenge has uses left.
    function submitPending(uint256 seed) external synced("submitPending") {
        if (pending.length == 0) return;
        uint256 k = seed % pending.length;
        Pending memory p = pending[k];
        pending[k] = pending[pending.length - 1];
        pending.pop();
        CanteenOrders.Order memory o = c.getOrder(p.orderId);
        (, uint256 ce) = c.claimWindow(p.orderId);
        bytes32 h = c.challengeStructHash(p.ch);
        // A revoke in the very same second as the challenge is not "later"; everything after is.
        (, uint48 revokedAt) = c.devices(p.ch.device);
        bool shouldLand = o.status == CanteenOrders.Status.Placed && vm.getBlockTimestamp() <= ce + 30 minutes
            && c.challengeUses(h) < 8 && (revokedAt == 0 || revokedAt > p.ch.timestamp);
        try c.checkIn(p.orderId, p.ch, p.dsig, p.ssig) {
            _recordChallenge(p.ch);
            wins["submitPending"]++;
        } catch {
            if (shouldLand) honestCheckInRejected = true;
        }
    }

    // ------------------------------------------------------------------ settle

    function serve(uint256 seed) external synced("serve") {
        uint256 id = seed % 4 == 0 ? _pickOrder(seed) : _findOrder(seed, CanteenOrders.Status.CheckedIn);
        if (id == 0) return;
        address dev = vm.addr(devicePks[(seed >> 8) % devicePks.length]);
        vm.prank(dev);
        try c.markServed(id) {
            wins["serve"]++;
        } catch {}
    }

    function flagUnserved(uint256 seed) external synced("flagUnserved") {
        uint256 id = _findOrder(seed, CanteenOrders.Status.CheckedIn);
        if (id == 0) return;
        uint256 due = uint256(c.getOrder(id).presentAt) + 20 minutes + 1;
        if (seed % 4 == 0 && vm.getBlockTimestamp() < due) vm.warp(due);
        try c.flagUnserved(id) {
            wins["flagUnserved"]++;
        } catch {}
    }

    function forfeit(uint256 seed) external synced("forfeit") {
        uint256 id = _findOrder(seed, CanteenOrders.Status.Placed);
        if (id == 0) return;
        (, uint256 ce) = c.claimWindow(id);
        if (seed % 4 == 0 && vm.getBlockTimestamp() <= ce + 30 minutes) vm.warp(ce + 30 minutes + 1);
        try c.markForfeit(id) {
            wins["forfeit"]++;
            if (c.isRefundableForUnavailability(id)) forfeitedWhileRefundable = true;
        } catch {}
    }

    function toggle(uint256 seed, bool available) external synced("toggle") {
        vm.prank(seed % 2 == 0 ? relayer : owner);
        c.setItemAvailable(itemIds[(seed >> 8) % 3], available);
    }

    function claimRefund(uint256 seed) external synced("claimRefund") {
        uint256 id = seed % 2 == 0
            ? _findOrder(seed, CanteenOrders.Status.Placed)
            : _findOrder(seed, CanteenOrders.Status.CheckedIn);
        if (id == 0) return;
        try c.claimUnavailableRefund(id) {
            wins["claimRefund"]++;
        } catch {}
    }

    function refundPaid(uint256 seed) external synced("refundPaid") {
        uint256 id = seed % 4 == 0 ? _pickOrder(seed) : _findOrder(seed, CanteenOrders.Status.RefundOwed);
        if (id == 0) return;
        vm.prank(refunder);
        try c.recordRefundPaid(id, keccak256(abi.encode(seed))) {
            wins["refundPaid"]++;
        } catch {}
    }

    // ------------------------------------------------------------------ scenario

    /// A coherent day: a burst of orders, then check-ins (some sharing a QR), dropped payloads,
    /// serves, a sold-out toggle, late submissions and settlement. Each step is one of the
    /// handler's own actions, so ghost tracking and transition checks apply to every step.
    function dayCycle(uint256 seed) external {
        this.warpToNextWindow(seed);
        uint256 n = 3 + seed % 12;
        for (uint256 k; k < n; ++k) {
            this.place(uint256(keccak256(abi.encode(seed, "p", k))) & ~uint256(1));
        }
        for (uint256 k; k < n; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, "c", k)));
            if (r % 3 == 0) this.signCheckInLater(r);
            else this.checkIn(r, r >> 32);
            if (r % 5 == 0) this.serve(r >> 64);
        }
        if (seed % 3 == 0) this.toggle(seed >> 8, false);
        this.warp(seed >> 16);
        for (uint256 k; k < 4; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, "s", k)));
            this.submitPending(r);
            this.serve(r >> 8);
            this.claimRefund(r >> 16);
            this.flagUnserved(r >> 24);
            this.forfeit(r >> 32);
            this.refundPaid(r >> 40);
        }
    }

    // ------------------------------------------------------------------ devices

    function revokeDevice(uint256 seed) external synced("revoke") {
        vm.prank(owner);
        try c.revokeDevice(vm.addr(devicePks[seed % devicePks.length])) {} catch {}
    }

    function authorizeNewDevice() external synced("authorize") {
        if (devicePks.length >= 6) return;
        uint256 pk = 0xD000 + devicePks.length;
        vm.prank(owner);
        c.authorizeDevice(vm.addr(pk));
        devicePks.push(pk);
    }

    // ------------------------------------------------------------------ getters for invariants

    function daysLength() external view returns (uint256) {
        return dayList.length;
    }

    function paymentRefsLength() external view returns (uint256) {
        return paymentRefs.length;
    }

    function challengeHashesLength() external view returns (uint256) {
        return challengeHashes.length;
    }
}

contract InvariantTest is Test {
    CanteenOrders internal c;
    Handler internal h;

    uint256 internal constant IST = 19800;
    uint256 internal constant DAY = 20_400;

    function setUp() public {
        address owner = vm.addr(0xA11CE);
        uint256 attesterPk = 0xA77E57;
        address refunder = vm.addr(0x2EF0);
        address relayer = vm.addr(0x2E1A);
        uint256 devPk = 0xDE71CE;

        vm.warp(DAY * 1 days - IST - 4 hours);
        vm.startPrank(owner);
        c = new CanteenOrders(25200, 32400, vm.addr(attesterPk), refunder, relayer);
        c.setSlot(0, 43200, 100, true);
        c.setSlot(1, 45000, 100, true);
        c.setSlot(2, 46800, 40, true); // small slot: cap 12
        c.setSlot(3, 48600, 100, true);
        c.setItem(1, 2000, true);
        c.setItem(2, 4000, true);
        c.setItem(3, 1000, true);
        c.authorizeDevice(vm.addr(devPk));
        vm.stopPrank();

        h = new Handler(c, owner, attesterPk, refunder, relayer, devPk);
        vm.warp(DAY * 1 days - IST + 7 hours + 30 minutes);
        targetContract(address(h));

        bytes4[] memory sel = new bytes4[](20);
        sel[0] = Handler.warp.selector;
        sel[1] = Handler.warpToNextWindow.selector;
        sel[2] = Handler.place.selector;
        sel[3] = Handler.placeReusingRef.selector;
        sel[4] = Handler.checkIn.selector;
        sel[5] = Handler.checkInSharedChallenge.selector;
        sel[6] = Handler.signCheckInLater.selector;
        sel[7] = Handler.submitPending.selector;
        sel[8] = Handler.serve.selector;
        sel[9] = Handler.flagUnserved.selector;
        sel[10] = Handler.forfeit.selector;
        sel[11] = Handler.toggle.selector;
        sel[12] = Handler.claimRefund.selector;
        sel[13] = Handler.refundPaid.selector;
        sel[14] = Handler.revokeDevice.selector;
        sel[15] = Handler.authorizeNewDevice.selector;
        sel[16] = Handler.place.selector; // listed twice to weight the core flows
        sel[17] = Handler.checkIn.selector;
        sel[18] = Handler.dayCycle.selector;
        sel[19] = Handler.dayCycle.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    /// 1 and 3: only legal transitions ever happen, so terminal states are final,
    /// Served is reached only from CheckedIn and CheckedIn only from Placed.
    function invariant_legalTransitionsOnly() public view {
        assertFalse(h.illegalTransition());
    }

    /// 2: pre-orders never exceed 30% of slot capacity.
    function invariant_slotCap() public view {
        uint8[4] memory caps = [uint8(30), 30, 12, 30];
        for (uint256 k; k < h.daysLength(); ++k) {
            uint256 d = h.dayList(k);
            for (uint8 s; s < 4; ++s) {
                assertLe(c.slotUsed(d, s), caps[s]);
            }
        }
    }

    /// 4: no order is forfeited while refundable for unavailability.
    function invariant_noForfeitWhileRefundable() public view {
        assertFalse(h.forfeitedWhileRefundable());
    }

    /// 5: check-ins signed while a device was valid stay valid after revocation.
    function invariant_honestCheckInsLand() public view {
        assertFalse(h.honestCheckInRejected());
    }

    /// 6: a challenge hash backs at most 8 check-ins.
    function invariant_challengeCap() public view {
        for (uint256 k; k < h.challengeHashesLength(); ++k) {
            assertLe(c.challengeUses(h.challengeHashes(k)), 8);
        }
    }

    /// 7: payment refs and intent nonces are consumed once.
    function invariant_singleUse() public view {
        assertFalse(h.refReuseSucceeded());
        assertFalse(h.nonceReuseSucceeded());
        assertEq(h.paymentRefsLength(), c.orderCount());
    }

    /// 8: placeOrder never succeeds outside 07:00 to 09:00 IST.
    function invariant_orderWindow() public view {
        assertFalse(h.placedOutsideWindow());
    }

    /// 9: per day and slot, demand equals the sum of placed order lines and matches slotUsed.
    function invariant_demandMatchesLines() public view {
        for (uint256 k; k < h.daysLength(); ++k) {
            uint256 d = h.dayList(k);
            for (uint8 s; s < 4; ++s) {
                uint256 sum;
                for (uint16 it = 1; it <= 3; ++it) {
                    assertEq(c.getSlotDemand(d, s, it), h.ghostDemand(d, s, it));
                    sum += c.getSlotDemand(d, s, it);
                }
                assertEq(sum, c.slotUsed(d, s));
                assertEq(sum, h.ghostPortions(d, s));
            }
        }
    }

    function afterInvariant() external view {
        // Set INV_METRICS=true with -vv to print how many calls of each kind succeeded in a run.
        if (vm.envOr("INV_METRICS", false)) {
            bytes32[9] memory k = [
                bytes32("place"),
                "checkIn",
                "checkInShared",
                "submitPending",
                "serve",
                "flagUnserved",
                "forfeit",
                "claimRefund",
                "refundPaid"
            ];
            for (uint256 j; j < k.length; ++j) {
                console.log(string(abi.encodePacked(k[j])), h.wins(k[j]));
            }
        }
    }
}
