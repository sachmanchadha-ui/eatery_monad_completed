// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {CanteenOrders} from "../src/CanteenOrders.sol";

contract FuzzTest is Base {
    /// placeOrder succeeds exactly inside [07:00, 09:00) IST.
    function testFuzz_orderWindow(uint256 sod) public {
        sod = bound(sod, 0, 1 days - 1);
        warpTo(DAY, sod);
        CanteenOrders.Line[] memory ls = one(CHAI, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        bool inWindow = sod >= OPEN && sod < CUTOFF;
        if (!inWindow) vm.expectRevert(CanteenOrders.OutsideWindow.selector);
        submit(o);
    }

    /// Random carts succeed exactly when every line is valid and the slot cap holds.
    function testFuzz_cart(uint8 n, uint256 seed, uint8 prefill) public {
        n = uint8(bound(n, 1, 4));
        prefill = uint8(bound(prefill, 0, 30));
        if (prefill > 0) place(1, prefillLines(prefill));

        CanteenOrders.Line[] memory ls = new CanteenOrders.Line[](n);
        bool valid = true;
        uint256 portions;
        for (uint256 k; k < n; ++k) {
            uint16 item = uint16(1 + uint256(keccak256(abi.encode(seed, k, "i"))) % 4); // 4 is unknown
            uint16 qty = uint16(uint256(keccak256(abi.encode(seed, k, "q"))) % 13); // 0..12
            ls[k] = line(item, qty);
            if (item == 4 || qty == 0 || qty > 10) valid = false;
            portions += qty;
        }
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        if (!valid) {
            vm.expectRevert(CanteenOrders.BadLine.selector);
        } else if (prefill + portions > 30) {
            vm.expectRevert(CanteenOrders.SlotFull.selector);
        }
        submit(o);
        if (valid && prefill + portions <= 30) assertEq(c.slotUsed(DAY, 1), prefill + portions);
    }

    function prefillLines(uint8 q) internal pure returns (CanteenOrders.Line[] memory ls) {
        uint256 n = (uint256(q) + 9) / 10;
        ls = new CanteenOrders.Line[](n);
        uint256 left = q;
        for (uint256 k; k < n; ++k) {
            uint16 take = uint16(left > 10 ? 10 : left);
            ls[k] = line(CHAI, take);
            left -= take;
        }
    }

    /// checkIn accepts a challenge exactly inside the claim window and a submission inside the grace.
    function testFuzz_checkInTiming(uint256 tsOff, uint256 delay) public {
        uint256 id = placeDefault();
        (uint256 cs, uint256 ce) = c.claimWindow(id);
        uint256 ts = cs - 1 hours + bound(tsOff, 0, 3 hours);
        delay = bound(delay, 0, 2 hours);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(ts), "n");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        vm.warp(ts + delay);

        if (ts + delay > ce + 30 minutes) vm.expectRevert(CanteenOrders.TooLate.selector);
        else if (ts < cs || ts > ce) vm.expectRevert(CanteenOrders.ChallengeOutOfWindow.selector);
        c.checkIn(id, ch, dsig, ssig);
    }

    function _mutate(bytes memory sig, uint256 pos, uint8 x) internal pure returns (bytes memory m) {
        m = bytes.concat(sig);
        pos = pos % m.length;
        m[pos] = bytes1(uint8(m[pos]) ^ (x == 0 ? 1 : x));
    }

    /// Any single-byte change to a student or attester signature is rejected.
    function testFuzz_orderSigMutation(bool attesterSide, uint256 pos, uint8 x) public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        if (attesterSide) o.attesterSig = _mutate(o.attesterSig, pos, x);
        else o.studentSig = _mutate(o.studentSig, pos, x);
        vm.expectRevert();
        submit(o);
    }

    /// Any single-byte change to a device or check-in signature is rejected.
    function testFuzz_checkInSigMutation(bool deviceSide, uint256 pos, uint8 x) public {
        uint256 id = placeDefault();
        (uint256 cs,) = c.claimWindow(id);
        vm.warp(cs + 10);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs + 10), "n");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        if (deviceSide) dsig = _mutate(dsig, pos, x);
        else ssig = _mutate(ssig, pos, x);
        vm.expectRevert();
        c.checkIn(id, ch, dsig, ssig);
    }

    /// Tampering with any challenge field invalidates the device signature or the student signature.
    function testFuzz_challengeTamper(uint8 field, bytes32 nonce2, uint48 tsShift) public {
        uint256 id = placeDefault();
        (uint256 cs,) = c.claimWindow(id);
        vm.warp(cs + 100);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs + 50), "n");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        field = field % 2;
        if (field == 0) {
            vm.assume(nonce2 != ch.nonce);
            ch.nonce = nonce2;
        } else {
            tsShift = uint48(bound(tsShift, 1, 40));
            ch.timestamp = ch.timestamp + tsShift;
        }
        vm.expectRevert(CanteenOrders.BadDeviceSig.selector);
        c.checkIn(id, ch, dsig, ssig);
    }
}
