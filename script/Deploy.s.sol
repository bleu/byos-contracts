// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Script, console} from 'forge-std/Script.sol';

import {Escrow} from 'contracts/Escrow.sol';

contract Deploy is Script {
  function run() public {
    uint48 _adminTransferDelay = uint48(vm.envOr('ADMIN_TRANSFER_DELAY', uint256(2 days)));
    address _admin = vm.envAddress('ESCROW_ADMIN');
    address _operator = vm.envAddress('ESCROW_OPERATOR');
    uint256 _cooldownPeriod = vm.envOr('COOLDOWN_PERIOD', uint256(1 days));
    string memory _name = vm.envOr('ESCROW_TOKEN_NAME', string('BYOS Escrow'));
    string memory _symbol = vm.envOr('ESCROW_TOKEN_SYMBOL', string('BYOS'));

    vm.startBroadcast();

    Escrow _escrow = new Escrow(_adminTransferDelay, _admin, _operator, _cooldownPeriod, _name, _symbol);
    console.log('Escrow deployed at:', address(_escrow));

    vm.stopBroadcast();
  }
}
