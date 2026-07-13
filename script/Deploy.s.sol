// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Escrow} from "../src/contracts/Escrow.sol";
import {TrampolineFactory} from "../src/contracts/TrampolineFactory.sol";
import {Script, console} from "forge-std/Script.sol";

contract Deploy is Script {
    /// @dev GPv2Settlement lives at the same address on all supported chains.
    address constant DEFAULT_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    function run() public {
        address escrowOwner = vm.envAddress("ESCROW_OWNER");
        address escrowOperator = vm.envAddress("ESCROW_OPERATOR");
        uint256 cooldownPeriod = vm.envOr("COOLDOWN_PERIOD", uint256(1 days));
        address settlement = vm.envOr("SETTLEMENT", DEFAULT_SETTLEMENT);

        vm.startBroadcast();

        TrampolineFactory factory = new TrampolineFactory(settlement);
        console.log("TrampolineFactory deployed at:", address(factory));

        Escrow escrow = new Escrow(escrowOwner, escrowOperator, cooldownPeriod, factory);
        console.log("Escrow deployed at:", address(escrow));

        vm.stopBroadcast();
    }
}
