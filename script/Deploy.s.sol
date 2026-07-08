// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {BYOSEscrow} from "../src/contracts/BYOSEscrow.sol";
import {BYOSTrampoline} from "../src/contracts/BYOSTrampoline.sol";
import {Script, console} from "forge-std/Script.sol";

contract Deploy is Script {
    function run() public {
        address escrowOwner = vm.envAddress("ESCROW_OWNER");
        address escrowOperator = vm.envAddress("ESCROW_OPERATOR");
        uint256 cooldownPeriod = vm.envOr("COOLDOWN_PERIOD", uint256(1 days));

        vm.startBroadcast();

        BYOSEscrow escrow = new BYOSEscrow(escrowOwner, escrowOperator, cooldownPeriod);
        console.log("BYOSEscrow deployed at:", address(escrow));

        BYOSTrampoline trampoline = new BYOSTrampoline();
        console.log("BYOSTrampoline deployed at:", address(trampoline));

        vm.stopBroadcast();
    }
}
