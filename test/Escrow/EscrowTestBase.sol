// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {Escrow} from 'contracts/Escrow.sol';
import {TrampolineFactory} from 'contracts/TrampolineFactory.sol';

abstract contract EscrowTestBase is Test {
  Escrow escrow;
  TrampolineFactory factory;
  address admin;
  address op;
  address submitter;
  address subSolver;
  address subSolver2;

  uint256 constant COOLDOWN = 1 days;
  uint48 constant ADMIN_TRANSFER_DELAY = 2 days;
  bytes32 constant ADMIN_ROLE = 0x00;
  bytes32 constant OPERATOR_ROLE = keccak256('OPERATOR_ROLE');
  bytes32 constant SUBMITTER_ROLE = keccak256('SUBMITTER_ROLE');

  function setUp() public {
    admin = makeAddr('admin');
    op = makeAddr('operator');
    submitter = makeAddr('submitter');
    subSolver = makeAddr('subSolver');
    subSolver2 = makeAddr('subSolver2');
    escrow = new Escrow(ADMIN_TRANSFER_DELAY, admin, op, submitter, COOLDOWN, makeAddr('settlement'));
    factory = TrampolineFactory(address(escrow.TRAMPOLINE_FACTORY()));
  }
}

/// @dev Contract that rejects ETH transfers.
contract RejectETH {
  receive() external payable {
    revert('rejected');
  }
}

/// @dev Contract that attempts reentrancy on executeWithdrawal.
contract ReentrantWithdrawer {
  Escrow public target;
  uint256 public reentrancyCount;

  constructor(
    Escrow _target
  ) {
    target = _target;
  }

  function requestWithdrawal() external {
    target.requestWithdrawal();
  }

  function executeWithdrawal() external {
    target.executeWithdrawal();
  }

  receive() external payable {
    if (reentrancyCount == 0) {
      reentrancyCount++;
      try target.executeWithdrawal() {} catch {}
    }
  }
}
