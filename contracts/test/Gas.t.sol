// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {CanteenOrders} from "../src/CanteenOrders.sol";

/// @dev Gas snapshots (written to snapshots/GasTest.json). Monad charges the gas LIMIT, not gas used,
///      so clients should set limits close to these numbers plus a small buffer.
contract GasTest is Base {
    function test_gas_placeOrder_1line() public {
        placeDefault(); // warm the slot and demand slots so this measures a typical order
        CanteenOrders.Line[] memory ls = one(VADA, 2);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        c.placeOrder(o.intent, o.lines, o.studentSig, o.paymentRef, o.attesterSig);
        vm.snapshotGasLastCall("placeOrder_1line");
    }

    function test_gas_placeOrder_4lines() public {
        placeDefault();
        CanteenOrders.Line[] memory ls = new CanteenOrders.Line[](4);
        ls[0] = line(VADA, 1);
        ls[1] = line(DOSA, 1);
        ls[2] = line(CHAI, 1);
        ls[3] = line(CHAI, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        c.placeOrder(o.intent, o.lines, o.studentSig, o.paymentRef, o.attesterSig);
        vm.snapshotGasLastCall("placeOrder_4lines");
    }

    function test_gas_checkIn_markServed() public {
        uint256 id = placeDefault();
        (uint256 cs,) = c.claimWindow(id);
        vm.warp(cs + 60);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs + 60), "n");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        c.checkIn(id, ch, dsig, ssig);
        vm.snapshotGasLastCall("checkIn");
        vm.prank(device);
        c.markServed(id);
        vm.snapshotGasLastCall("markServed");
    }

    function test_gas_settlement() public {
        uint256 a = placeDefault();
        uint256 b = placeDefault();
        (, uint256 ce) = c.claimWindow(a);
        vm.warp(ce + 31 minutes);
        c.markForfeit(a);
        vm.snapshotGasLastCall("markForfeit");
        vm.prank(relayer);
        c.setItemAvailable(CHAI, false);
        vm.snapshotGasLastCall("setItemAvailable_off");
        b;
    }

    function test_gas_refund() public {
        uint256 id = placeDefault();
        vm.prank(relayer);
        c.setItemAvailable(VADA, false);
        c.claimUnavailableRefund(id);
        vm.snapshotGasLastCall("claimUnavailableRefund");
        vm.prank(refunder);
        c.recordRefundPaid(id, "rfnd");
        vm.snapshotGasLastCall("recordRefundPaid");
    }

    function test_gas_registerSessionKey() public {
        uint48 exp = uint48(vm.getBlockTimestamp() + 30 days);
        uint256 n = c.sessionNonce(student);
        bytes32 h = keccak256(abi.encode(c.SESSION_TYPEHASH(), student, session, exp, n));
        bytes memory sig = sign(studentPk, h);
        c.registerSessionKey(student, session, exp, n, sig);
        vm.snapshotGasLastCall("registerSessionKey_rotate");
    }
}
