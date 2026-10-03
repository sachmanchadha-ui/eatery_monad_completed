// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {CanteenOrders} from "../src/CanteenOrders.sol";

contract ConstructorTest is Base {
    function test_rejectsBadWindow() public {
        vm.expectRevert(CanteenOrders.BadConfig.selector);
        new CanteenOrders(CUTOFF, OPEN, attester, refunder, relayer);
        vm.expectRevert(CanteenOrders.BadConfig.selector);
        new CanteenOrders(OPEN, 1 days + 1, attester, refunder, relayer);
    }

    function test_rejectsZeroRoles() public {
        vm.expectRevert(CanteenOrders.ZeroAddress.selector);
        new CanteenOrders(OPEN, CUTOFF, address(0), refunder, relayer);
    }

    function test_initialState() public view {
        assertEq(c.owner(), owner);
        assertEq(c.attester(), attester);
        assertEq(c.OPEN_SEC(), OPEN);
        assertEq(c.CUTOFF_SEC(), CUTOFF);
        assertEq(c.getSlotIds().length, 4);
        assertEq(c.getItemIds().length, 3);
        assertEq(c.currentDayId(), DAY);
    }
}

contract SessionKeyTest is Base {
    function test_register() public view {
        (address k, uint48 exp) = c.sessionKeys(student);
        assertEq(k, session);
        assertGt(exp, vm.getBlockTimestamp());
        assertEq(c.sessionNonce(student), 1);
    }

    function test_rejectsTooLongExpiry() public {
        uint48 exp = uint48(vm.getBlockTimestamp() + 30 days + 1);
        bytes32 h = keccak256(abi.encode(c.SESSION_TYPEHASH(), student, session, exp, uint256(1)));
        bytes memory sig = sign(studentPk, h);
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.registerSessionKey(student, session, exp, 1, sig);
    }

    function test_rejectsPastExpiry() public {
        uint48 exp = uint48(vm.getBlockTimestamp());
        bytes32 h = keccak256(abi.encode(c.SESSION_TYPEHASH(), student, session, exp, uint256(1)));
        bytes memory sig = sign(studentPk, h);
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.registerSessionKey(student, session, exp, 1, sig);
    }

    function test_rejectsWrongSigner() public {
        uint48 exp = uint48(vm.getBlockTimestamp() + 1 days);
        bytes32 h = keccak256(abi.encode(c.SESSION_TYPEHASH(), student, session, exp, uint256(1)));
        bytes memory sig = sign(sessionPk, h);
        vm.expectRevert(CanteenOrders.BadStudentSig.selector);
        c.registerSessionKey(student, session, exp, 1, sig);
    }

    /// An old authorization cannot be replayed to restore a key the student replaced.
    function test_oldAuthCannotBeReplayed() public {
        uint48 exp = uint48(vm.getBlockTimestamp() + 1 days);
        address oldKey = vm.addr(0x01D);
        bytes32 h0 = keccak256(abi.encode(c.SESSION_TYPEHASH(), student, oldKey, exp, uint256(1)));
        bytes memory oldSig = sign(studentPk, h0);
        c.registerSessionKey(student, oldKey, exp, 1, oldSig);
        registerSession(studentPk, sessionPk); // nonce 2, back to the real key
        vm.expectRevert(CanteenOrders.NonceUsed.selector);
        c.registerSessionKey(student, oldKey, exp, 1, oldSig);
        (address k,) = c.sessionKeys(student);
        assertEq(k, session);
    }

    function test_reRegistrationInvalidatesOldKeySignatures() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        registerSession(studentPk, 0xBEEF);
        vm.expectRevert(CanteenOrders.BadStudentSig.selector);
        submit(o);
    }
}

contract PlaceOrderTest is Base {
    function test_placesOrder() public {
        CanteenOrders.Line[] memory ls = new CanteenOrders.Line[](2);
        ls[0] = line(VADA, 2);
        ls[1] = line(CHAI, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        vm.expectEmit(true, true, false, true);
        emit CanteenOrders.OrderPlaced(1, student, DAY, 1, 1, o.paymentRef, 5000);
        uint256 id = submit(o);

        CanteenOrders.Order memory ord = c.getOrder(id);
        assertEq(ord.student, student);
        assertEq(ord.dayId, DAY);
        assertEq(ord.slotId, 1);
        assertEq(ord.tokenNo, 1);
        assertEq(uint8(ord.status), uint8(CanteenOrders.Status.Placed));
        assertEq(ord.claimStart, dayStart(DAY) + S1230);
        assertEq(ord.totalPaise, 5000);
        assertEq(c.getOrderLines(id).length, 2);
        assertEq(c.slotUsed(DAY, 1), 3);
        assertEq(c.getSlotDemand(DAY, 1, VADA), 2);
        assertEq(c.getSlotDemand(DAY, 1, CHAI), 1);
        assertEq(c.slotRemaining(DAY, 1), 27);
    }

    function test_tokensIncrementPerSlotAndResetPerDay() public {
        assertEq(c.getOrder(placeDefault()).tokenNo, 1);
        assertEq(c.getOrder(placeDefault()).tokenNo, 2);
        assertEq(c.getOrder(place(2, one(CHAI, 1))).tokenNo, 1);
        warpTo(DAY + 1, 8 * 3600);
        assertEq(c.getOrder(placeDefault()).tokenNo, 1);
        assertEq(c.slotUsed(DAY + 1, 1), 2);
    }

    function test_relayedBySomeoneElse() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        vm.prank(address(0xCAFE));
        submit(o);
    }

    function test_windowBoundaries() public {
        warpTo(DAY, OPEN - 1);
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        vm.expectRevert(CanteenOrders.OutsideWindow.selector);
        submit(o);

        warpTo(DAY, OPEN);
        submit(signOrder(sessionPk, makeIntent(student, 1, ls), ls));

        warpTo(DAY, CUTOFF - 1);
        submit(signOrder(sessionPk, makeIntent(student, 1, ls), ls));

        warpTo(DAY, CUTOFF);
        o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        vm.expectRevert(CanteenOrders.OutsideWindow.selector);
        submit(o);
    }

    function test_expiredIntent() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        vm.warp(vm.getBlockTimestamp() + 10 minutes + 1);
        vm.expectRevert(CanteenOrders.IntentExpired.selector);
        submit(o);
    }

    function test_nonceReuse() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        CanteenOrders.OrderIntent memory i = makeIntent(student, 1, ls);
        submit(signOrder(sessionPk, i, ls)); // same intent, new payment ref
        Signed memory o = signOrder(sessionPk, i, ls);
        vm.expectRevert(CanteenOrders.NonceUsed.selector);
        submit(o);
    }

    function test_paymentRefReuse() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory a = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        submit(a);
        Signed memory b = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        b.paymentRef = a.paymentRef;
        vm.expectRevert(CanteenOrders.PaymentReused.selector);
        submit(b);
    }

    function test_noSessionKey() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(address(0xD00D), 1, ls), ls);
        vm.expectRevert(CanteenOrders.NoSessionKey.selector);
        submit(o);
    }

    function test_expiredSessionKey() public {
        warpTo(DAY + 31, 8 * 3600);
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        vm.expectRevert(CanteenOrders.NoSessionKey.selector);
        submit(o);
    }

    function test_studentSigFromWalletNotSessionKey() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(studentPk, makeIntent(student, 1, ls), ls);
        vm.expectRevert(CanteenOrders.BadStudentSig.selector);
        submit(o);
    }

    function test_badAttestation() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        o.paymentRef = keccak256("other"); // attestation was over a different ref
        vm.expectRevert(CanteenOrders.BadAttestation.selector);
        submit(o);
    }

    function test_attestationFromWrongKey() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        o.attesterSig =
            sign(relayerPk, keccak256(abi.encode(c.PAYMENT_TYPEHASH(), c.intentStructHash(o.intent), o.paymentRef)));
        vm.expectRevert(CanteenOrders.BadAttestation.selector);
        submit(o);
    }

    function test_attesterRotation() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        vm.prank(owner);
        c.setAttester(address(0x1234));
        vm.expectRevert(CanteenOrders.BadAttestation.selector);
        submit(o);
    }

    function test_emptyAndTooManyLines() public {
        CanteenOrders.Line[] memory ls = new CanteenOrders.Line[](0);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        vm.expectRevert(CanteenOrders.BadLines.selector);
        submit(o);

        ls = new CanteenOrders.Line[](5);
        for (uint256 k; k < 5; ++k) {
            ls[k] = line(CHAI, 1);
        }
        o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        vm.expectRevert(CanteenOrders.BadLines.selector);
        submit(o);
    }

    function test_fourLinesAccepted() public {
        CanteenOrders.Line[] memory ls = new CanteenOrders.Line[](4);
        ls[0] = line(VADA, 1);
        ls[1] = line(DOSA, 1);
        ls[2] = line(CHAI, 1);
        ls[3] = line(CHAI, 2);
        uint256 id = place(0, ls);
        assertEq(c.getSlotDemand(DAY, 0, CHAI), 3);
        assertEq(c.getOrder(id).totalPaise, VADA_P + DOSA_P + 3 * CHAI_P);
    }

    function test_linesMismatch() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        o.lines = one(VADA, 2);
        vm.expectRevert(CanteenOrders.LinesMismatch.selector);
        submit(o);
    }

    function _expectBadLine(CanteenOrders.Line[] memory ls, bytes4 err) internal {
        CanteenOrders.OrderIntent memory i = makeIntent(student, 1, ls);
        Signed memory o = signOrder(sessionPk, i, ls);
        vm.expectRevert(err);
        submit(o);
    }

    function test_badLines() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        ls[0].unitPricePaise = VADA_P - 1; // wrong price
        _expectBadLine(ls, CanteenOrders.BadLine.selector);

        _expectBadLine(one(VADA, 0), CanteenOrders.BadLine.selector); // zero qty
        _expectBadLine(one(VADA, 11), CanteenOrders.BadLine.selector); // over max qty

        ls = one(99, 1); // unknown item
        _expectBadLine(ls, CanteenOrders.BadLine.selector);

        vm.prank(relayer);
        c.setItemAvailable(DOSA, false); // toggled off today
        _expectBadLine(one(DOSA, 1), CanteenOrders.BadLine.selector);
    }

    function test_maxQtyAccepted() public {
        place(1, one(CHAI, 10));
    }

    function test_badTotal() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        CanteenOrders.OrderIntent memory i = makeIntent(student, 1, ls);
        i.totalPaise = VADA_P + 1;
        Signed memory o = signOrder(sessionPk, i, ls);
        vm.expectRevert(CanteenOrders.BadTotal.selector);
        submit(o);
    }

    function test_badSlot() public {
        CanteenOrders.Line[] memory ls = one(VADA, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 9, ls), ls); // unknown slot
        vm.expectRevert(CanteenOrders.BadSlot.selector);
        submit(o);
    }

    function test_slotCapIsThirtyPercent() public {
        for (uint256 k; k < 3; ++k) {
            place(1, one(CHAI, 10));
        }
        assertEq(c.slotUsed(DAY, 1), 30);
        assertEq(c.slotRemaining(DAY, 1), 0);
        CanteenOrders.Line[] memory ls = one(CHAI, 1);
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        vm.expectRevert(CanteenOrders.SlotFull.selector);
        submit(o);
    }
}

contract ConfigTest is Base {
    function test_changesTakeEffectNextDay() public {
        vm.startPrank(owner);
        c.setItem(VADA, 2500, true);
        c.setSlot(1, S1230, 200, true);
        vm.stopPrank();

        assertEq(c.getItem(DAY, VADA).pricePaise, VADA_P);
        assertEq(c.getItem(DAY + 1, VADA).pricePaise, 2500);
        assertEq(c.slotRemaining(DAY, 1), 30);
        assertEq(c.slotRemaining(DAY + 1, 1), 60);

        place(1, one(VADA, 1)); // old price still valid today

        warpTo(DAY + 1, 8 * 3600);
        CanteenOrders.Line[] memory ls = one(VADA, 1); // carries the old price
        Signed memory o = signOrder(sessionPk, makeIntent(student, 1, ls), ls);
        vm.expectRevert(CanteenOrders.BadLine.selector);
        submit(o);
        ls[0].unitPricePaise = 2500;
        place(1, ls);
    }

    function test_pendingPromotesOnLaterEdit() public {
        vm.prank(owner);
        c.setItem(VADA, 2500, true); // effective DAY+1
        warpTo(DAY + 3, 8 * 3600);
        vm.prank(owner);
        c.setItem(VADA, 3000, true); // promotes 2500 to current, 3000 effective DAY+4
        assertEq(c.getItem(DAY + 3, VADA).pricePaise, 2500);
        assertEq(c.getItem(DAY + 4, VADA).pricePaise, 3000);
    }

    function test_newIdIsLiveToday() public {
        vm.prank(owner);
        c.setItem(7, 1500, true);
        assertTrue(c.isItemAvailable(DAY, 7));
        CanteenOrders.Line[] memory ls = one(7, 1);
        ls[0].unitPricePaise = 1500;
        place(1, ls);
    }

    function test_editingExistingSlotDoesNotMoveOrderWindow() public {
        uint256 id = placeDefault();
        vm.prank(owner);
        c.setSlot(1, S1330, CAP, true);
        (uint256 cs,) = c.claimWindow(id);
        assertEq(cs, dayStart(DAY) + S1230);
    }

    function test_slotValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(CanteenOrders.BadConfig.selector);
        c.setSlot(5, uint32(CUTOFF), CAP, true);
        vm.expectRevert(CanteenOrders.BadConfig.selector);
        c.setSlot(5, uint32(1 days - 29 minutes), CAP, true);
        c.setSlot(5, uint32(1 days - 30 minutes), CAP, true);
        vm.expectRevert(CanteenOrders.BadConfig.selector);
        c.setItem(8, 0, true);
        vm.stopPrank();
    }

    function test_onlyOwner() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.setSlot(0, S1200, CAP, true);
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.setItem(VADA, 1, true);
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.setAttester(address(1));
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.setRefunder(address(1));
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.setRelayer(address(1));
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.authorizeDevice(address(1));
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.revokeDevice(device);
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.transferOwnership(address(1));
        vm.stopPrank();
    }

    function test_twoStepOwnership() public {
        address next = address(0x0E2);
        vm.prank(owner);
        c.transferOwnership(next);
        assertEq(c.owner(), owner);
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.acceptOwnership();
        vm.prank(next);
        c.acceptOwnership();
        assertEq(c.owner(), next);
        assertEq(c.pendingOwner(), address(0));
    }

    function test_roleSettersRejectZero() public {
        vm.startPrank(owner);
        vm.expectRevert(CanteenOrders.ZeroAddress.selector);
        c.setAttester(address(0));
        vm.expectRevert(CanteenOrders.ZeroAddress.selector);
        c.setRefunder(address(0));
        vm.expectRevert(CanteenOrders.ZeroAddress.selector);
        c.setRelayer(address(0));
        vm.stopPrank();
    }
}

contract CheckInTest is Base {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = placeDefault(); // slot 1, 12:30
    }

    function test_checkIn() public {
        (uint256 cs,) = c.claimWindow(id);
        vm.expectEmit(true, true, false, true);
        emit CanteenOrders.CheckedIn(id, device, uint48(cs + 60));
        doCheckIn(id, 60);
        CanteenOrders.Order memory o = c.getOrder(id);
        assertEq(uint8(o.status), uint8(CanteenOrders.Status.CheckedIn));
        assertEq(o.presentAt, cs + 60);
    }

    function test_lateSubmissionInsideGrace() public {
        (uint256 cs, uint256 ce) = c.claimWindow(id);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs + 100), "n");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        vm.warp(ce + 30 minutes); // last second of submit grace
        c.checkIn(id, ch, dsig, ssig);
    }

    function test_tooLate() public {
        (uint256 cs, uint256 ce) = c.claimWindow(id);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs + 100), "n");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        vm.warp(ce + 30 minutes + 1);
        vm.expectRevert(CanteenOrders.TooLate.selector);
        c.checkIn(id, ch, dsig, ssig);
    }

    function test_wrongSlot() public {
        (uint256 cs,) = c.claimWindow(id);
        vm.warp(cs + 10);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 2, uint48(cs + 10), "n");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        vm.expectRevert(CanteenOrders.WrongSlot.selector);
        c.checkIn(id, ch, dsig, ssig);
    }

    function test_challengeOutsideWindow() public {
        (uint256 cs, uint256 ce) = c.claimWindow(id);
        vm.warp(ce + 5);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs - 1), "n");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        vm.expectRevert(CanteenOrders.ChallengeOutOfWindow.selector);
        c.checkIn(id, ch, dsig, ssig);

        (ch, dsig) = challenge(devicePk, 1, uint48(ce + 1), "n");
        ssig = checkInSig(sessionPk, id, ch);
        vm.expectRevert(CanteenOrders.ChallengeOutOfWindow.selector);
        c.checkIn(id, ch, dsig, ssig);
    }

    function test_challengeFromTheFuture() public {
        (uint256 cs,) = c.claimWindow(id);
        vm.warp(cs + 10);
        // within clock skew tolerance: accepted
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs + 40), "a");
        c.checkIn(id, ch, dsig, checkInSig(sessionPk, id, ch));

        uint256 id2 = _placeForSlot1();
        vm.warp(cs + 10);
        (ch, dsig) = challenge(devicePk, 1, uint48(cs + 41), "b");
        bytes memory ssig = checkInSig(sessionPk, id2, ch);
        vm.expectRevert(CanteenOrders.ChallengeOutOfWindow.selector);
        c.checkIn(id2, ch, dsig, ssig);
    }

    function _placeForSlot1() internal returns (uint256 newId) {
        uint256 t = vm.getBlockTimestamp();
        warpTo(DAY, 8 * 3600);
        newId = placeDefault();
        vm.warp(t);
    }

    function test_unauthorizedDevice() public {
        (uint256 cs,) = c.claimWindow(id);
        vm.warp(cs + 10);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(0xBAD, 1, uint48(cs + 10), "n");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        vm.expectRevert(CanteenOrders.DeviceNotAuthorized.selector);
        c.checkIn(id, ch, dsig, ssig);
    }

    function test_forgedDeviceSig() public {
        (uint256 cs,) = c.claimWindow(id);
        vm.warp(cs + 10);
        (CanteenOrders.DeviceChallenge memory ch,) = challenge(devicePk, 1, uint48(cs + 10), "n");
        bytes memory forged = sign(0xBAD, c.challengeStructHash(ch));
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        vm.expectRevert(CanteenOrders.BadDeviceSig.selector);
        c.checkIn(id, ch, forged, ssig);
    }

    function test_badStudentSig() public {
        (uint256 cs,) = c.claimWindow(id);
        vm.warp(cs + 10);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs + 10), "n");
        bytes memory ssig = checkInSig(studentPk, id, ch); // wallet, not session key
        vm.expectRevert(CanteenOrders.BadStudentSig.selector);
        c.checkIn(id, ch, dsig, ssig);

        ssig = checkInSig(sessionPk, id + 1, ch); // signed for another order
        vm.expectRevert(CanteenOrders.BadStudentSig.selector);
        c.checkIn(id, ch, dsig, ssig);
    }

    function test_cannotCheckInTwice() public {
        doCheckIn(id, 60);
        (uint256 cs,) = c.claimWindow(id);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs + 60), "z");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        vm.expectRevert(CanteenOrders.BadStatus.selector);
        c.checkIn(id, ch, dsig, ssig);
    }

    function test_challengeUseCapIsEight() public {
        uint256[] memory ids = new uint256[](9);
        ids[0] = id;
        for (uint256 k = 1; k < 9; ++k) {
            ids[k] = placeDefault();
        }
        (uint256 cs,) = c.claimWindow(id);
        vm.warp(cs + 10);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs + 10), "shared");
        for (uint256 k; k < 8; ++k) {
            c.checkIn(ids[k], ch, dsig, checkInSig(sessionPk, ids[k], ch));
        }
        assertEq(c.challengeUses(c.challengeStructHash(ch)), 8);
        bytes memory ssig = checkInSig(sessionPk, ids[8], ch);
        vm.expectRevert(CanteenOrders.ChallengeExhausted.selector);
        c.checkIn(ids[8], ch, dsig, ssig);
    }

    /// R7: a check-in signed while the device was valid still lands after revocation.
    function test_revokedDeviceEarlierChallengeStillValid() public {
        (uint256 cs,) = c.claimWindow(id);
        vm.warp(cs + 10);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs + 10), "n");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        vm.warp(cs + 20);
        vm.prank(owner);
        c.revokeDevice(device);
        vm.warp(cs + 40 minutes); // phone self-submits later
        c.checkIn(id, ch, dsig, ssig);
        assertEq(uint8(status(id)), uint8(CanteenOrders.Status.CheckedIn));
    }

    function test_revokedDeviceLaterChallengeRejected() public {
        (uint256 cs,) = c.claimWindow(id);
        vm.warp(cs + 10);
        vm.prank(owner);
        c.revokeDevice(device);
        (CanteenOrders.DeviceChallenge memory ch, bytes memory dsig) = challenge(devicePk, 1, uint48(cs + 10), "n");
        bytes memory ssig = checkInSig(sessionPk, id, ch);
        vm.expectRevert(CanteenOrders.DeviceNotAuthorized.selector);
        c.checkIn(id, ch, dsig, ssig);
    }
}

contract SettleTest is Base {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = placeDefault();
    }

    function test_serve() public {
        doCheckIn(id, 60);
        vm.prank(device);
        c.markServed(id);
        assertEq(uint8(status(id)), uint8(CanteenOrders.Status.Served));
    }

    function test_serveRequiresDevice() public {
        doCheckIn(id, 60);
        vm.expectRevert(CanteenOrders.NotDevice.selector);
        c.markServed(id);
        vm.prank(owner);
        c.revokeDevice(device);
        vm.prank(device);
        vm.expectRevert(CanteenOrders.NotDevice.selector);
        c.markServed(id);
    }

    function test_serveRequiresCheckIn() public {
        vm.prank(device);
        vm.expectRevert(CanteenOrders.BadStatus.selector);
        c.markServed(id);
    }

    function test_flagUnserved() public {
        doCheckIn(id, 60);
        CanteenOrders.Order memory o = c.getOrder(id);
        vm.warp(o.presentAt + 20 minutes);
        vm.expectRevert(CanteenOrders.NotYet.selector);
        c.flagUnserved(id);
        vm.warp(o.presentAt + 20 minutes + 1);
        vm.expectEmit(true, false, false, true);
        emit CanteenOrders.RefundOwed(id, 1);
        c.flagUnserved(id);
        o = c.getOrder(id);
        assertEq(uint8(o.status), uint8(CanteenOrders.Status.RefundOwed));
        assertEq(uint8(o.reason), uint8(CanteenOrders.Reason.Unserved));
        vm.prank(device);
        vm.expectRevert(CanteenOrders.BadStatus.selector);
        c.markServed(id);
    }

    function test_flagUnservedRequiresCheckIn() public {
        vm.expectRevert(CanteenOrders.BadStatus.selector);
        c.flagUnserved(id);
    }

    function test_forfeit() public {
        (, uint256 ce) = c.claimWindow(id);
        vm.warp(ce + 30 minutes);
        vm.expectRevert(CanteenOrders.NotYet.selector);
        c.markForfeit(id);
        vm.warp(ce + 30 minutes + 1);
        c.markForfeit(id);
        assertEq(uint8(status(id)), uint8(CanteenOrders.Status.Forfeited));
    }

    function test_forfeitOnlyFromPlaced() public {
        doCheckIn(id, 60);
        (, uint256 ce) = c.claimWindow(id);
        vm.warp(ce + 31 minutes);
        vm.expectRevert(CanteenOrders.BadStatus.selector);
        c.markForfeit(id);
    }

    function test_unavailableRefundFromPlaced() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(relayer);
        c.setItemAvailable(VADA, false);
        assertTrue(c.isRefundableForUnavailability(id));
        vm.expectEmit(true, false, false, true);
        emit CanteenOrders.RefundOwed(id, 2);
        c.claimUnavailableRefund(id);
        assertEq(uint8(c.getOrder(id).reason), uint8(CanteenOrders.Reason.ItemUnavailable));
    }

    function test_unavailableRefundFromCheckedIn() public {
        doCheckIn(id, 60);
        vm.prank(owner);
        c.setItemAvailable(VADA, false);
        c.claimUnavailableRefund(id);
        assertEq(uint8(status(id)), uint8(CanteenOrders.Status.RefundOwed));
    }

    function test_unavailableRefundRequiresToggle() public {
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.claimUnavailableRefund(id);
        vm.prank(relayer);
        c.setItemAvailable(CHAI, false); // not in the order
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.claimUnavailableRefund(id);
    }

    function test_toggleOnDoesNotUndoRefundability() public {
        vm.startPrank(relayer);
        c.setItemAvailable(VADA, false);
        c.setItemAvailable(VADA, true);
        vm.stopPrank();
        assertTrue(c.isRefundableForUnavailability(id));
    }

    function test_orderAfterToggleOffAndOnIsNotRefundable() public {
        vm.startPrank(relayer);
        c.setItemAvailable(VADA, false);
        vm.warp(vm.getBlockTimestamp() + 60);
        c.setItemAvailable(VADA, true);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 60);
        uint256 later = placeDefault();
        assertFalse(c.isRefundableForUnavailability(later));
    }

    /// Fix over the v2 skeleton: a second switch-off later in the day must still cover orders
    /// placed between the first off/on cycle and the second switch-off.
    function test_secondSwitchOffCoversLaterOrders() public {
        vm.startPrank(relayer);
        c.setItemAvailable(VADA, false);
        vm.warp(vm.getBlockTimestamp() + 60);
        c.setItemAvailable(VADA, true);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 60);
        uint256 later = placeDefault();
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        vm.prank(relayer);
        c.setItemAvailable(VADA, false);
        assertTrue(c.isRefundableForUnavailability(later));
        c.claimUnavailableRefund(later);
    }

    /// Fix over the v2 skeleton: a switch-off after the forfeit point does not turn a no-show into a refund.
    function test_lateSwitchOffDoesNotRescueNoShow() public {
        (, uint256 ce) = c.claimWindow(id);
        vm.warp(ce + 30 minutes + 1);
        vm.prank(relayer);
        c.setItemAvailable(VADA, false); // e.g. sold out at 14:01, keeper has not run yet
        assertFalse(c.isRefundableForUnavailability(id));
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.claimUnavailableRefund(id);
        c.markForfeit(id);
        assertEq(uint8(status(id)), uint8(CanteenOrders.Status.Forfeited));
    }

    function test_switchOffAtForfeitPointStillCounts() public {
        (, uint256 ce) = c.claimWindow(id);
        vm.warp(ce + 30 minutes);
        vm.prank(relayer);
        c.setItemAvailable(VADA, false);
        vm.warp(ce + 31 minutes);
        vm.expectRevert(CanteenOrders.Refundable.selector);
        c.markForfeit(id);
        c.claimUnavailableRefund(id);
    }

    function test_repeatedOffCallsRecordOnce() public {
        vm.startPrank(relayer);
        c.setItemAvailable(VADA, false);
        vm.warp(vm.getBlockTimestamp() + 10);
        c.setItemAvailable(VADA, false);
        vm.stopPrank();
        assertEq(c.getOffTimes(DAY, VADA).length, 1);
    }

    function test_cannotForfeitWhileRefundable() public {
        vm.prank(relayer);
        c.setItemAvailable(VADA, false);
        (, uint256 ce) = c.claimWindow(id);
        vm.warp(ce + 31 minutes);
        vm.expectRevert(CanteenOrders.Refundable.selector);
        c.markForfeit(id);
    }

    function test_setItemAvailableAuth() public {
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.setItemAvailable(VADA, false);
    }

    function test_refundPaid() public {
        doCheckIn(id, 60);
        vm.warp(vm.getBlockTimestamp() + 21 minutes);
        c.flagUnserved(id);
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.recordRefundPaid(id, "rfnd_1");
        vm.prank(refunder);
        vm.expectEmit(true, false, false, true);
        emit CanteenOrders.RefundPaid(id, "rfnd_1");
        c.recordRefundPaid(id, "rfnd_1");
        assertEq(uint8(status(id)), uint8(CanteenOrders.Status.RefundPaid));
        vm.prank(refunder);
        vm.expectRevert(CanteenOrders.BadStatus.selector);
        c.recordRefundPaid(id, "rfnd_2");
    }

    function test_refundPaidRequiresOwed() public {
        vm.prank(refunder);
        vm.expectRevert(CanteenOrders.BadStatus.selector);
        c.recordRefundPaid(id, "x");
    }
}

contract DeviceTest is Base {
    function test_cannotReauthorizeRevoked() public {
        vm.startPrank(owner);
        c.revokeDevice(device);
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.authorizeDevice(device);
        vm.stopPrank();
    }

    /// Fix over the v2 skeleton: a repeated revoke must not push revokedAt later.
    function test_cannotRevokeTwice() public {
        vm.startPrank(owner);
        c.revokeDevice(device);
        (, uint48 r) = c.devices(device);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.revokeDevice(device);
        (, uint48 r2) = c.devices(device);
        assertEq(r, r2);
        vm.stopPrank();
    }

    function test_cannotRevokeUnknown() public {
        vm.prank(owner);
        vm.expectRevert(CanteenOrders.NotAllowed.selector);
        c.revokeDevice(address(0x9));
    }

    function test_validityWindow() public {
        (uint48 a,) = c.devices(device);
        assertFalse(c.deviceValidAt(device, a - 1));
        assertTrue(c.deviceValidAt(device, a));
        vm.prank(owner);
        c.revokeDevice(device);
        assertTrue(c.deviceValidAt(device, vm.getBlockTimestamp() - 1));
        assertFalse(c.deviceValidAt(device, vm.getBlockTimestamp()));
    }
}
