// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IEscrow} from 'interfaces/IEscrow.sol';

import {EscrowTestBase} from './EscrowTestBase.sol';

contract TransferTest is EscrowTestBase {
  function test_transfer_moves_tokens() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(subSolver);
    escrow.transfer(subSolver2, 4 ether);

    assertEq(escrow.balanceOf(subSolver), 6 ether);
    assertEq(escrow.balanceOf(subSolver2), 4 ether);
    assertInvariant();
  }

  function test_transfer_reverts_when_paused() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(op);
    escrow.pause();

    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_EnforcedPause.selector);
    escrow.transfer(subSolver2, 1 ether);
  }

  function test_transfer_reverts_if_sender_frozen() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(op);
    escrow.freeze(subSolver);

    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_AccountFrozen.selector);
    escrow.transfer(subSolver2, 1 ether);
  }

  function test_transfer_reverts_if_receiver_frozen() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(op);
    escrow.freeze(subSolver2);

    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_AccountFrozen.selector);
    escrow.transfer(subSolver2, 1 ether);
  }

  function test_transfer_reverts_if_sender_has_pending_withdrawal() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_WithdrawalPending.selector);
    escrow.transfer(subSolver2, 1 ether);
  }

  function test_transfer_reverts_if_receiver_has_pending_withdrawal() public {
    escrow.deposit{value: 10 ether}(subSolver);
    escrow.deposit{value: 5 ether}(subSolver2);
    vm.prank(subSolver2);
    escrow.requestWithdrawal();

    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_WithdrawalPending.selector);
    escrow.transfer(subSolver2, 1 ether);
  }

  function test_transfer_to_self() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(subSolver);
    escrow.transfer(subSolver, 5 ether);
    assertEq(escrow.balanceOf(subSolver), 10 ether);
  }

  function test_transfer_deploys_trampoline_for_recipient() public {
    escrow.deposit{value: 10 ether}(subSolver);

    address newAddr = makeAddr('newAddr');
    address predicted = factory.addressOf(newAddr);
    assertEq(predicted.code.length, 0);

    vm.prank(subSolver);
    escrow.transfer(newAddr, 3 ether);

    assertGt(predicted.code.length, 0);
  }

  function test_transfer_to_existing_trampoline_is_idempotent() public {
    escrow.deposit{value: 10 ether}(subSolver);
    escrow.deposit{value: 5 ether}(subSolver2);

    address predicted = factory.addressOf(subSolver2);
    assertGt(predicted.code.length, 0);

    vm.prank(subSolver);
    escrow.transfer(subSolver2, 3 ether);

    assertEq(escrow.balanceOf(subSolver2), 8 ether);
    assertGt(predicted.code.length, 0);
  }

  function test_key_rotation_deploys_trampoline_for_new_key() public {
    address oldKey = makeAddr('oldKey');
    address newKey = makeAddr('newKey');

    escrow.deposit{value: 10 ether}(oldKey);

    address predicted = factory.addressOf(newKey);
    assertEq(predicted.code.length, 0);

    vm.prank(oldKey);
    escrow.transfer(newKey, 10 ether);

    assertGt(predicted.code.length, 0);
    assertEq(escrow.balanceOf(newKey), 10 ether);
  }

  function test_key_rotation_via_transfer() public {
    address oldKey = makeAddr('oldKey');
    address newKey = makeAddr('newKey');

    escrow.deposit{value: 10 ether}(oldKey);
    assertEq(escrow.balanceOf(oldKey), 10 ether);

    vm.prank(oldKey);
    escrow.transfer(newKey, 10 ether);

    assertEq(escrow.balanceOf(oldKey), 0);
    assertEq(escrow.balanceOf(newKey), 10 ether);
    assertInvariant();
  }

  // --- Threat analysis coverage ---

  function test_transfer_front_runs_debit() public {
    // Gap G7: between a revert event and the operator calling pause/freeze,
    // a sub-solver can transfer its balance to a fresh address, making the
    // operator's debit fail. The mitigation path is freeze + debit the new address.
    address freshAddr = makeAddr('freshAddr');
    escrow.deposit{value: 10 ether}(subSolver);

    // Sub-solver moves funds before operator can react
    vm.prank(subSolver);
    escrow.transfer(freshAddr, 10 ether);

    // Operator's debit on the original address fails — balance is gone
    vm.prank(op);
    vm.expectRevert(IEscrow.Escrow_InsufficientBalance.selector);
    escrow.debit(subSolver, 10 ether, keccak256('revert-penalty'));

    // Mitigation: operator freezes the new address and debits it
    vm.startPrank(op);
    escrow.freeze(freshAddr);
    escrow.debit(freshAddr, 10 ether, keccak256('revert-penalty'));
    vm.stopPrank();

    assertEq(escrow.balanceOf(freshAddr), 0);
    assertInvariant();
  }

  function test_transfer_to_escrow_contract_sticks_tokens() public {
    // Threat 11: tokens transferred to the escrow's own address are unreachable.
    // No one controls the escrow's "account", so those tokens can never be
    // withdrawn or debited. The contract remains over-collateralized but functional.
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(subSolver);
    escrow.transfer(address(escrow), 5 ether);

    assertEq(escrow.balanceOf(address(escrow)), 5 ether);
    assertEq(escrow.balanceOf(subSolver), 5 ether);

    // Over-collateralized: 10 ether ETH backing 10 ether totalSupply,
    // but 5 ether of tokens are unreachable
    assertEq(address(escrow).balance, 10 ether);
    assertEq(escrow.totalSupply(), 10 ether);

    // All normal operations still work
    vm.prank(subSolver);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);
    vm.prank(subSolver);
    escrow.executeWithdrawal();
    assertEq(subSolver.balance, 5 ether);
    assertInvariant();
  }
}
