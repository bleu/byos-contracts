// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Script, console} from 'forge-std/Script.sol';

import {Escrow} from 'contracts/Escrow.sol';
import {TrampolineFactory} from 'contracts/TrampolineFactory.sol';

contract Deploy is Script {
  /// @dev GPv2Settlement lives at the same address on all supported chains.
  address internal constant DEFAULT_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

  function run() public {
    address _escrowOwner = vm.envAddress('ESCROW_OWNER');
    address _escrowOperator = vm.envAddress('ESCROW_OPERATOR');
    uint256 _cooldownPeriod = vm.envOr('COOLDOWN_PERIOD', uint256(1 days));
    address _settlement = vm.envOr('SETTLEMENT', DEFAULT_SETTLEMENT);

    vm.startBroadcast();

    TrampolineFactory _factory = new TrampolineFactory(_settlement);
    console.log('TrampolineFactory deployed at:', address(_factory));

    Escrow _escrow = new Escrow(_escrowOwner, _escrowOperator, _cooldownPeriod, _factory);
    console.log('Escrow deployed at:', address(_escrow));

    vm.stopBroadcast();
  }
}
