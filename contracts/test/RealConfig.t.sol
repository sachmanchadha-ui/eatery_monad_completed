// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {CanteenOrders} from "../src/CanteenOrders.sol";

/// @dev Loads config/canteen.json (V5) into a fresh contract and checks it is accepted as-is.
contract RealConfigTest is Test {
    using stdJson for string;

    function test_realConfigLoads() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../config/canteen.json"));
        uint256 open = json.readUint(".orderWindow.openSec");
        uint256 cutoff = json.readUint(".orderWindow.cutoffSec");
        uint256 capacity = json.readUint(".slotCapacity");

        vm.warp(20_400 days - 19800 + 6 hours);
        CanteenOrders c = new CanteenOrders(open, cutoff, address(1), address(2), address(3));

        for (uint256 k; json.keyExists(string.concat(".slots[", vm.toString(k), "]")); ++k) {
            string memory p = string.concat(".slots[", vm.toString(k), "]");
            c.setSlot(
                uint8(json.readUint(string.concat(p, ".id"))),
                uint32(json.readUint(string.concat(p, ".startSec"))),
                uint16(capacity),
                true
            );
        }
        for (uint256 k; json.keyExists(string.concat(".items[", vm.toString(k), "]")); ++k) {
            string memory p = string.concat(".items[", vm.toString(k), "]");
            c.setItem(
                uint16(json.readUint(string.concat(p, ".id"))),
                uint32(json.readUint(string.concat(p, ".pricePaise"))),
                true
            );
        }

        uint256 today = c.currentDayId();
        assertEq(c.getSlotIds().length, 2);
        assertEq(c.getItemIds().length, 3);
        assertEq(c.slotRemaining(today, 0), 30);
        assertEq(c.slotRemaining(today, 1), 30);
        assertEq(c.getSlot(today, 1).startSec, 47700); // 13:15
        assertEq(c.getItem(today, 1).pricePaise, 1500); // Vada Pav, Rs 15
        assertTrue(c.isItemAvailable(today, 3));
    }
}
