// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CanteenOrders} from "../src/CanteenOrders.sol";

/// @dev Shared fixture: deployed contract, four slots, three items, signing helpers and IST time helpers.
abstract contract Base is Test {
    CanteenOrders internal c;

    uint256 internal constant IST = 19800;
    uint256 internal constant OPEN = 25200; // 07:00
    uint256 internal constant CUTOFF = 32400; // 09:00
    uint256 internal constant DAY = 20_400; // an arbitrary dayId (~2025-11)

    uint32 internal constant S1200 = 43200;
    uint32 internal constant S1230 = 45000;
    uint32 internal constant S1300 = 46800;
    uint32 internal constant S1330 = 48600;
    uint16 internal constant CAP = 100; // physical portions -> 30 pre-order portions

    uint16 internal constant VADA = 1;
    uint16 internal constant DOSA = 2;
    uint16 internal constant CHAI = 3;
    uint32 internal constant VADA_P = 2000;
    uint32 internal constant DOSA_P = 4000;
    uint32 internal constant CHAI_P = 1000;

    uint256 internal ownerPk = 0xA11CE;
    uint256 internal attesterPk = 0xA77E57;
    uint256 internal refunderPk = 0x2EF0;
    uint256 internal relayerPk = 0x2E1A;
    uint256 internal devicePk = 0xDE71CE;
    uint256 internal studentPk = 0x57D;
    uint256 internal sessionPk = 0x5E55;

    address internal owner;
    address internal attester;
    address internal refunder;
    address internal relayer;
    address internal device;
    address internal student;
    address internal session;

    uint256 internal paymentSeq;
    uint256 internal intentNonceSeq;

    function setUp() public virtual {
        owner = vm.addr(ownerPk);
        attester = vm.addr(attesterPk);
        refunder = vm.addr(refunderPk);
        relayer = vm.addr(relayerPk);
        device = vm.addr(devicePk);
        student = vm.addr(studentPk);
        session = vm.addr(sessionPk);

        // Deploy the day before so config is live and the device predates every challenge.
        warpTo(DAY - 1, 20 * 3600);
        vm.startPrank(owner);
        c = new CanteenOrders(OPEN, CUTOFF, attester, refunder, relayer);
        c.setSlot(0, S1200, CAP, true);
        c.setSlot(1, S1230, CAP, true);
        c.setSlot(2, S1300, CAP, true);
        c.setSlot(3, S1330, CAP, true);
        c.setItem(VADA, VADA_P, true);
        c.setItem(DOSA, DOSA_P, true);
        c.setItem(CHAI, CHAI_P, true);
        c.authorizeDevice(device);
        vm.stopPrank();

        registerSession(studentPk, sessionPk);
        warpTo(DAY, 8 * 3600); // 08:00 on DAY: order window open
    }

    // ------------------------------------------------------------------ time

    function dayStart(uint256 d) internal pure returns (uint256) {
        return d * 1 days - IST;
    }

    function warpTo(uint256 d, uint256 secOfDay) internal {
        vm.warp(dayStart(d) + secOfDay);
    }

    // ------------------------------------------------------------------ signing

    function digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", c.DOMAIN_SEPARATOR(), structHash));
    }

    function sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest(structHash));
        return abi.encodePacked(r, s, v);
    }

    function registerSession(uint256 walletPk, uint256 keyPk) internal {
        address w = vm.addr(walletPk);
        address k = vm.addr(keyPk);
        uint48 expiry = uint48(vm.getBlockTimestamp() + 30 days);
        uint256 n = c.sessionNonce(w);
        bytes32 h = keccak256(abi.encode(c.SESSION_TYPEHASH(), w, k, expiry, n));
        c.registerSessionKey(w, k, expiry, n, sign(walletPk, h));
    }

    function line(uint16 itemId, uint16 qty) internal pure returns (CanteenOrders.Line memory l) {
        l.itemId = itemId;
        l.qty = qty;
        l.unitPricePaise = itemId == VADA ? VADA_P : itemId == DOSA ? DOSA_P : itemId == CHAI ? CHAI_P : 0;
    }

    function one(uint16 itemId, uint16 qty) internal pure returns (CanteenOrders.Line[] memory ls) {
        ls = new CanteenOrders.Line[](1);
        ls[0] = line(itemId, qty);
    }

    function totalOf(CanteenOrders.Line[] memory ls) internal pure returns (uint32 t) {
        for (uint256 k; k < ls.length; ++k) {
            t += ls[k].unitPricePaise * ls[k].qty;
        }
    }

    function makeIntent(address s, uint8 slotId, CanteenOrders.Line[] memory ls)
        internal
        returns (CanteenOrders.OrderIntent memory i)
    {
        i.student = s;
        i.slotId = slotId;
        i.linesHash = keccak256(abi.encode(ls));
        i.totalPaise = totalOf(ls);
        i.nonce = ++intentNonceSeq;
        i.deadline = uint48(vm.getBlockTimestamp() + 10 minutes);
    }

    struct Signed {
        CanteenOrders.OrderIntent intent;
        CanteenOrders.Line[] lines;
        bytes studentSig;
        bytes32 paymentRef;
        bytes attesterSig;
    }

    function signOrder(uint256 keyPk, CanteenOrders.OrderIntent memory i, CanteenOrders.Line[] memory ls)
        internal
        returns (Signed memory o)
    {
        bytes32 ih = c.intentStructHash(i);
        o.intent = i;
        o.lines = ls;
        o.studentSig = sign(keyPk, ih);
        o.paymentRef = keccak256(abi.encode("pay", ++paymentSeq));
        o.attesterSig = sign(attesterPk, keccak256(abi.encode(c.PAYMENT_TYPEHASH(), ih, o.paymentRef)));
    }

    function submit(Signed memory o) internal returns (uint256) {
        return c.placeOrder(o.intent, o.lines, o.studentSig, o.paymentRef, o.attesterSig);
    }

    function place(uint8 slotId, CanteenOrders.Line[] memory ls) internal returns (uint256) {
        return submit(signOrder(sessionPk, makeIntent(student, slotId, ls), ls));
    }

    function placeDefault() internal returns (uint256) {
        return place(1, one(VADA, 2));
    }

    function challenge(uint256 dPk, uint8 slotId, uint48 ts, bytes32 nonce)
        internal
        view
        returns (CanteenOrders.DeviceChallenge memory ch, bytes memory sig)
    {
        ch = CanteenOrders.DeviceChallenge(vm.addr(dPk), slotId, nonce, ts);
        sig = sign(dPk, c.challengeStructHash(ch));
    }

    function checkInSig(uint256 keyPk, uint256 orderId, CanteenOrders.DeviceChallenge memory ch)
        internal
        view
        returns (bytes memory)
    {
        return sign(keyPk, keccak256(abi.encode(c.CHECKIN_TYPEHASH(), orderId, c.challengeStructHash(ch))));
    }

    /// @dev Warps to `offset` seconds into the order's claim window and checks in with a fresh challenge.
    function doCheckIn(uint256 orderId, uint256 offset) internal {
        (uint256 cs,) = c.claimWindow(orderId);
        vm.warp(cs + offset);
        CanteenOrders.Order memory o = c.getOrder(orderId);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) =
            challenge(devicePk, o.slotId, uint48(vm.getBlockTimestamp()), keccak256(abi.encode(orderId, offset)));
        c.checkIn(orderId, ch, dsig, checkInSig(sessionPk, orderId, ch));
    }

    function status(uint256 orderId) internal view returns (CanteenOrders.Status) {
        return c.getOrder(orderId).status;
    }
}
