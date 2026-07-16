// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IEscrow} from 'interfaces/IEscrow.sol';

import {EscrowTestBase, ReentrantWithdrawer, RejectETH} from './EscrowTestBase.sol';

contract SubSolverActionsTest is EscrowTestBase {
  // --- Withdrawal lifecycle ---

  function test_full_withdrawal_lifecycle() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(subSolver);
    escrow.requestWithdrawal();
    assertEq(escrow.effectiveBalance(subSolver), 0);
    assertEq(escrow.balanceOf(subSolver), 10 ether);

    vm.warp(block.timestamp + COOLDOWN);

    vm.prank(subSolver);
    escrow.executeWithdrawal();
    assertEq(escrow.balanceOf(subSolver), 0);
    assertEq(subSolver.balance, 10 ether);

    // Verify no leftover state — re-deposit and check clean accounting
    escrow.deposit{value: 4 ether}(subSolver);
    assertEq(escrow.balanceOf(subSolver), 4 ether);
    assertEq(escrow.effectiveBalance(subSolver), 4 ether);

    // Second withdrawal cycle
    vm.prank(subSolver);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);
    vm.prank(subSolver);
    escrow.executeWithdrawal();

    assertEq(escrow.balanceOf(subSolver), 0);
    assertEq(escrow.withdrawalRequestedAt(subSolver), 0);
    assertInvariant();
  }

  function test_withdrawal_reverts_before_cooldown() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.warp(block.timestamp + COOLDOWN - 1);
    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_CooldownNotElapsed.selector);
    escrow.executeWithdrawal();
  }

  function test_withdrawal_request_reverts_if_no_balance() public {
    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_InsufficientBalance.selector);
    escrow.requestWithdrawal();
  }

  function test_withdrawal_request_reverts_if_already_requested() public {
    escrow.deposit{value: 1 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_WithdrawalAlreadyRequested.selector);
    escrow.requestWithdrawal();
  }

  function test_cancel_withdrawal_restores_effective_balance() public {
    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();
    assertEq(escrow.effectiveBalance(subSolver), 0);

    vm.prank(subSolver);
    escrow.cancelWithdrawal();
    assertEq(escrow.effectiveBalance(subSolver), 5 ether);
  }

  function test_cancel_withdrawal_reverts_if_none_pending() public {
    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_NoWithdrawalRequested.selector);
    escrow.cancelWithdrawal();
  }

  function test_execute_withdrawal_reverts_after_full_debit_during_cooldown() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.prank(op);
    escrow.debit(subSolver, 10 ether, keccak256('full-debit'));

    vm.warp(block.timestamp + COOLDOWN);
    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_NothingToWithdraw.selector);
    escrow.executeWithdrawal();
  }

  function test_withdrawal_at_exact_cooldown_boundary() public {
    escrow.deposit{value: 5 ether}(subSolver);
    uint256 requestTime = block.timestamp;
    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.warp(requestTime + COOLDOWN);
    vm.prank(subSolver);
    escrow.executeWithdrawal();
    assertEq(subSolver.balance, 5 ether);
  }

  function test_re_deposit_and_withdraw_after_completed_cycle() public {
    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);
    vm.prank(subSolver);
    escrow.executeWithdrawal();
    assertEq(subSolver.balance, 5 ether);

    escrow.deposit{value: 3 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);
    vm.prank(subSolver);
    escrow.executeWithdrawal();
    assertEq(subSolver.balance, 8 ether);
    assertEq(escrow.balanceOf(subSolver), 0);
  }

  function test_execute_withdrawal_reverts_if_transfer_fails() public {
    RejectETH rejector = new RejectETH();
    address rejectorAddr = address(rejector);
    escrow.deposit{value: 5 ether}(rejectorAddr);

    vm.prank(rejectorAddr);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);

    vm.prank(rejectorAddr);
    vm.expectRevert(IEscrow.Escrow_TransferFailed.selector);
    escrow.executeWithdrawal();
  }

  function test_set_cooldown_period_zero_allows_instant_withdrawal() public {
    vm.prank(admin);
    escrow.setCooldownPeriod(0);

    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.prank(subSolver);
    escrow.executeWithdrawal();
    assertEq(subSolver.balance, 5 ether);
  }

  function test_cooldown_reduction_makes_pending_withdrawal_executable() public {
    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.warp(block.timestamp + 1 hours);
    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_CooldownNotElapsed.selector);
    escrow.executeWithdrawal();

    vm.prank(admin);
    escrow.setCooldownPeriod(30 minutes);

    vm.prank(subSolver);
    escrow.executeWithdrawal();
    assertEq(subSolver.balance, 5 ether);
  }

  // --- Reentrancy ---

  function test_execute_withdrawal_is_reentrancy_safe() public {
    ReentrantWithdrawer attacker = new ReentrantWithdrawer(escrow);
    address attackerAddr = address(attacker);

    escrow.deposit{value: 20 ether}(subSolver);
    escrow.deposit{value: 10 ether}(attackerAddr);

    vm.prank(attackerAddr);
    attacker.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);

    vm.prank(attackerAddr);
    attacker.executeWithdrawal();

    assertEq(attackerAddr.balance, 10 ether);
    assertEq(escrow.balanceOf(attackerAddr), 0);
    assertEq(escrow.balanceOf(subSolver), 20 ether);
  }

  // --- Events ---

  function test_withdrawal_lifecycle_emits_events() public {
    escrow.deposit{value: 5 ether}(subSolver);

    vm.prank(subSolver);
    vm.expectEmit(true, false, false, false);
    emit IEscrow.WithdrawalRequested(subSolver);
    escrow.requestWithdrawal();

    vm.prank(subSolver);
    vm.expectEmit(true, false, false, false);
    emit IEscrow.WithdrawalCancelled(subSolver);
    escrow.cancelWithdrawal();

    vm.prank(subSolver);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);

    vm.prank(subSolver);
    vm.expectEmit(true, false, false, true);
    emit IEscrow.Withdrawn(subSolver, 5 ether);
    escrow.executeWithdrawal();
  }
}
