// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IEscrow} from 'interfaces/IEscrow.sol';

import {EscrowTestBase} from './EscrowTestBase.sol';

contract DepositTest is EscrowTestBase {
  function test_deposit_credits_sub_solver() public {
    escrow.deposit{value: 5 ether}(subSolver);
    assertEq(escrow.balance(subSolver), 5 ether);
    assertEq(escrow.effectiveBalance(subSolver), 5 ether);
  }

  function test_deposit_multiple_accumulates() public {
    escrow.deposit{value: 3 ether}(subSolver);
    escrow.deposit{value: 2 ether}(subSolver);
    assertEq(escrow.balance(subSolver), 5 ether);
  }

  function test_deposit_anyone_can_deposit_for_sub_solver() public {
    vm.deal(subSolver2, 10 ether);
    vm.prank(subSolver2);
    escrow.deposit{value: 1 ether}(subSolver);
    assertEq(escrow.balance(subSolver), 1 ether);
  }

  function test_deposit_zero_value() public {
    escrow.deposit{value: 0}(subSolver);
    assertEq(escrow.balance(subSolver), 0);
  }

  function test_deposit_deploys_trampoline_on_first_deposit() public {
    address predicted = factory.addressOf(subSolver);
    assertEq(predicted.code.length, 0);

    escrow.deposit{value: 1 ether}(subSolver);

    assertGt(predicted.code.length, 0);
  }

  // --- Events ---

  function test_deposit_emits_event() public {
    vm.expectEmit(true, false, false, true);
    emit IEscrow.Deposited(subSolver, 5 ether);
    escrow.deposit{value: 5 ether}(subSolver);
  }
}
