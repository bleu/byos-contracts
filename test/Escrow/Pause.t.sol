// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {IEscrow} from 'interfaces/IEscrow.sol';

import {EscrowTestBase} from './EscrowTestBase.sol';

contract PauseTest is EscrowTestBase {
  function test_pause_sets_flag() public {
    vm.prank(op);
    escrow.pause();
    assertTrue(escrow.paused());
  }

  function test_unpause_clears_flag() public {
    vm.prank(op);
    escrow.pause();
    vm.prank(op);
    escrow.unpause();
    assertFalse(escrow.paused());
  }

  function test_pause_requires_operator_role() public {
    vm.prank(subSolver);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, subSolver, OPERATOR_ROLE)
    );
    escrow.pause();
  }

  function test_unpause_requires_operator_role() public {
    vm.prank(op);
    escrow.pause();

    vm.prank(subSolver);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, subSolver, OPERATOR_ROLE)
    );
    escrow.unpause();
  }

  function test_double_pause_reverts() public {
    vm.startPrank(op);
    escrow.pause();
    vm.expectRevert(IEscrow.Escrow_EnforcedPause.selector);
    escrow.pause();
    vm.stopPrank();
  }

  function test_double_unpause_reverts() public {
    vm.prank(op);
    vm.expectRevert(IEscrow.Escrow_ExpectedPause.selector);
    escrow.unpause();
  }

  // --- Pause interaction with each operation ---

  function test_deposit_allowed_when_paused() public {
    vm.prank(op);
    escrow.pause();

    escrow.deposit{value: 5 ether}(subSolver);
    assertEq(escrow.balanceOf(subSolver), 5 ether);
  }

  function test_debit_allowed_when_paused() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(op);
    escrow.pause();

    vm.prank(op);
    escrow.debit(subSolver, 3 ether, keccak256('reason'));
    assertEq(escrow.balanceOf(subSolver), 7 ether);
  }

  function test_execute_withdrawal_blocked_when_paused() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);

    vm.prank(op);
    escrow.pause();

    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_EnforcedPause.selector);
    escrow.executeWithdrawal();
  }

  function test_request_withdrawal_allowed_when_paused() public {
    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(op);
    escrow.pause();

    vm.prank(subSolver);
    escrow.requestWithdrawal();
    assertEq(escrow.effectiveBalance(subSolver), 0);
  }

  function test_cancel_withdrawal_allowed_when_paused() public {
    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.prank(op);
    escrow.pause();

    vm.prank(subSolver);
    escrow.cancelWithdrawal();
    assertEq(escrow.effectiveBalance(subSolver), 5 ether);
  }

  function test_withdraw_debits_allowed_when_paused() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(op);
    escrow.debit(subSolver, 3 ether, keccak256('reason'));

    vm.prank(op);
    escrow.pause();

    escrow.withdrawDebits();
    assertEq(admin.balance, 3 ether);
  }

  function test_transfer_blocked_when_paused() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(op);
    escrow.pause();

    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_EnforcedPause.selector);
    escrow.transfer(subSolver2, 1 ether);
  }

  // --- Events ---

  function test_pause_emits_event() public {
    vm.prank(op);
    vm.expectEmit(true, false, false, false);
    emit IEscrow.Paused(op);
    escrow.pause();
  }

  function test_unpause_emits_event() public {
    vm.prank(op);
    escrow.pause();

    vm.prank(op);
    vm.expectEmit(true, false, false, false);
    emit IEscrow.Unpaused(op);
    escrow.unpause();
  }
}
