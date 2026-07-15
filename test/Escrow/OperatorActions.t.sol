// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {VmSafe} from 'forge-std/Vm.sol';

import {IEscrow} from 'interfaces/IEscrow.sol';

import {EscrowTestBase} from './EscrowTestBase.sol';

contract OperatorActionsTest is EscrowTestBase {
  // --- Debit ---

  function test_debit_reduces_balance() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(op);
    escrow.debit(subSolver, 3 ether, keccak256('revert-tx-hash'));
    assertEq(escrow.balanceOf(subSolver), 7 ether);
    assertEq(escrow.withdrawableBalance(), 3 ether);
  }

  function test_debit_reverts_non_operator() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(subSolver);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, subSolver, OPERATOR_ROLE)
    );
    escrow.debit(subSolver, 1 ether, keccak256('reason'));
  }

  function test_debit_reverts_exceeding_balance() public {
    escrow.deposit{value: 1 ether}(subSolver);
    vm.prank(op);
    vm.expectRevert(IEscrow.Escrow_InsufficientBalance.selector);
    escrow.debit(subSolver, 2 ether, keccak256('reason'));
  }

  function test_debit_exact_full_balance() public {
    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(op);
    escrow.debit(subSolver, 5 ether, keccak256('full'));
    assertEq(escrow.balanceOf(subSolver), 0);
    assertEq(escrow.withdrawableBalance(), 5 ether);
  }

  function test_debit_zero_amount() public {
    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(op);
    escrow.debit(subSolver, 0, keccak256('zero'));
    assertEq(escrow.balanceOf(subSolver), 5 ether);
  }

  function test_debit_multiple_incremental() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.startPrank(op);
    escrow.debit(subSolver, 3 ether, keccak256('first'));
    escrow.debit(subSolver, 3 ether, keccak256('second'));
    escrow.debit(subSolver, 4 ether, keccak256('third'));
    vm.stopPrank();
    assertEq(escrow.balanceOf(subSolver), 0);
    assertEq(escrow.withdrawableBalance(), 10 ether);
  }

  function test_debit_during_cooldown_reduces_withdrawal_amount() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.prank(op);
    escrow.debit(subSolver, 3 ether, keccak256('revert'));

    vm.warp(block.timestamp + COOLDOWN);
    vm.prank(subSolver);
    escrow.executeWithdrawal();

    assertEq(subSolver.balance, 7 ether);
    assertEq(escrow.withdrawableBalance(), 3 ether);
  }

  function test_debit_after_withdrawal_reverts() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.warp(block.timestamp + COOLDOWN);
    vm.prank(subSolver);
    escrow.executeWithdrawal();

    vm.prank(op);
    vm.expectRevert(IEscrow.Escrow_InsufficientBalance.selector);
    escrow.debit(subSolver, 1 ether, keccak256('late-debit'));
  }

  // --- Freeze ---

  function test_freeze_blocks_execute_withdrawal() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);

    vm.prank(op);
    escrow.freeze(subSolver);

    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_AccountFrozen.selector);
    escrow.executeWithdrawal();
  }

  function test_unfreeze_allows_withdrawal_without_re_requesting() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);

    vm.prank(op);
    escrow.freeze(subSolver);

    vm.prank(op);
    escrow.unfreeze(subSolver);

    vm.prank(subSolver);
    escrow.executeWithdrawal();
    assertEq(subSolver.balance, 10 ether);
  }

  function test_cancel_withdrawal_allowed_while_frozen() public {
    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.prank(op);
    escrow.freeze(subSolver);

    vm.prank(subSolver);
    escrow.cancelWithdrawal();
    assertEq(escrow.effectiveBalance(subSolver), 5 ether);
  }

  function test_freeze_reverts_non_operator() public {
    vm.prank(subSolver);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, subSolver, OPERATOR_ROLE)
    );
    escrow.freeze(subSolver);
  }

  function test_double_freeze_is_idempotent_no_event() public {
    vm.startPrank(op);
    escrow.freeze(subSolver);
    assertTrue(escrow.frozen(subSolver));

    vm.recordLogs();
    escrow.freeze(subSolver);
    VmSafe.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 0);

    assertTrue(escrow.frozen(subSolver));
    vm.stopPrank();
  }

  function test_double_unfreeze_is_idempotent_no_event() public {
    vm.startPrank(op);
    escrow.freeze(subSolver);
    escrow.unfreeze(subSolver);
    assertFalse(escrow.frozen(subSolver));

    vm.recordLogs();
    escrow.unfreeze(subSolver);
    VmSafe.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 0);

    assertFalse(escrow.frozen(subSolver));
    vm.stopPrank();
  }

  function test_unfreeze_reverts_non_operator() public {
    vm.prank(op);
    escrow.freeze(subSolver);

    vm.prank(subSolver);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, subSolver, OPERATOR_ROLE)
    );
    escrow.unfreeze(subSolver);
  }

  // --- Expanded freeze semantics (transfers) ---

  function test_deposit_to_frozen_address_allowed() public {
    vm.prank(op);
    escrow.freeze(subSolver);

    escrow.deposit{value: 5 ether}(subSolver);
    assertEq(escrow.balanceOf(subSolver), 5 ether);
  }

  function test_debit_frozen_address_allowed() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(op);
    escrow.freeze(subSolver);

    vm.prank(op);
    escrow.debit(subSolver, 3 ether, keccak256('reason'));
    assertEq(escrow.balanceOf(subSolver), 7 ether);
  }

  // --- Events ---

  function test_debit_emits_event() public {
    escrow.deposit{value: 10 ether}(subSolver);
    bytes32 reason = keccak256('revert-tx');

    vm.prank(op);
    vm.expectEmit(true, false, false, true);
    emit IEscrow.Debited(subSolver, 3 ether, reason);
    escrow.debit(subSolver, 3 ether, reason);
  }

  function test_freeze_unfreeze_emits_events() public {
    vm.prank(op);
    vm.expectEmit(true, false, false, false);
    emit IEscrow.Frozen(subSolver);
    escrow.freeze(subSolver);

    vm.prank(op);
    vm.expectEmit(true, false, false, false);
    emit IEscrow.Unfrozen(subSolver);
    escrow.unfreeze(subSolver);
  }
}
