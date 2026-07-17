// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Script, console} from 'forge-std/Script.sol';

import {Escrow} from 'contracts/Escrow.sol';
import {TrampolineFactory} from 'contracts/TrampolineFactory.sol';

contract Deploy is Script {
  /// @dev GPv2Settlement lives at the same address on all supported chains.
  address internal constant DEFAULT_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

  function run() public {
    uint48 _adminTransferDelay = uint48(vm.envOr('ADMIN_TRANSFER_DELAY', uint256(2 days)));
    address _admin = vm.envAddress('ESCROW_ADMIN');
    address _operator = vm.envAddress('ESCROW_OPERATOR');
    address _submitter = vm.envAddress('BYOS_SUBMITTER');
    uint256 _cooldownPeriod = vm.envOr('COOLDOWN_PERIOD', uint256(1 days));
    address _settlement = vm.envOr('SETTLEMENT', DEFAULT_SETTLEMENT);
    string memory _name = vm.envOr('ESCROW_TOKEN_NAME', string('BYOS Escrow'));
    string memory _symbol = vm.envOr('ESCROW_TOKEN_SYMBOL', string('BYOS'));

    vm.startBroadcast();

    Escrow _escrow =
      new Escrow(_adminTransferDelay, _admin, _operator, _submitter, _cooldownPeriod, _settlement, _name, _symbol);
    console.log('Escrow deployed at:', address(_escrow));
    console.log('TrampolineFactory deployed at:', address(_escrow.TRAMPOLINE_FACTORY()));

    vm.stopBroadcast();
  }
}
