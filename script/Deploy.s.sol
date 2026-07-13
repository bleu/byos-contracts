// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Script, console} from 'forge-std/Script.sol';

import {Escrow} from 'contracts/Escrow.sol';

contract Deploy is Script {
  function run() public {
    address _escrowOwner = vm.envAddress('ESCROW_OWNER');
    address _escrowOperator = vm.envAddress('ESCROW_OPERATOR');
    uint256 _cooldownPeriod = vm.envOr('COOLDOWN_PERIOD', uint256(1 days));

    vm.startBroadcast();

    Escrow _escrow = new Escrow(_escrowOwner, _escrowOperator, _cooldownPeriod);
    console.log('Escrow deployed at:', address(_escrow));

    vm.stopBroadcast();
  }
}
