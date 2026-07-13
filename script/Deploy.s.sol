// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Escrow} from "../src/contracts/Escrow.sol";
import {Script, console} from "forge-std/Script.sol";

contract Deploy is Script {
    function run() public {
        address escrowOwner = vm.envAddress("ESCROW_OWNER");
        address escrowOperator = vm.envAddress("ESCROW_OPERATOR");
        uint256 cooldownPeriod = vm.envOr("COOLDOWN_PERIOD", uint256(1 days));

        vm.startBroadcast();

        Escrow escrow = new Escrow(escrowOwner, escrowOperator, cooldownPeriod);
        console.log("Escrow deployed at:", address(escrow));

        vm.stopBroadcast();
    }
}
