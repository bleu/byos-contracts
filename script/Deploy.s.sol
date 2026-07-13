// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Escrow} from "../src/contracts/Escrow.sol";
import {Script, console} from "forge-std/Script.sol";

contract Deploy is Script {
    function run() public {
        uint48 adminTransferDelay = uint48(vm.envOr("ADMIN_TRANSFER_DELAY", uint256(2 days)));
        address admin = vm.envAddress("ESCROW_ADMIN");
        address operator = vm.envAddress("ESCROW_OPERATOR");
        uint256 cooldownPeriod = vm.envOr("COOLDOWN_PERIOD", uint256(1 days));

        vm.startBroadcast();

        Escrow escrow = new Escrow(adminTransferDelay, admin, operator, cooldownPeriod);
        console.log("Escrow deployed at:", address(escrow));

        vm.stopBroadcast();
    }
}
