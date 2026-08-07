// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {EscrowTestBase} from './EscrowTestBase.sol';

contract IntegrationTest is EscrowTestBase {
  function test_deposit() public {
    escrow.deposit{value: 10 ether}(subSolver);
    escrow.deposit{value: 5 ether}(subSolver2);
    assertInvariant();
  }

  function test_transfer() public {
    escrow.deposit{value: 10 ether}(subSolver);
    escrow.deposit{value: 5 ether}(subSolver2);

    vm.prank(subSolver);
    escrow.transfer(subSolver2, 3 ether);
    assertInvariant();
  }

  function test_transferFrom() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(subSolver);
    escrow.approve(subSolver2, 4 ether);

    vm.prank(subSolver2);
    escrow.transferFrom(subSolver, subSolver2, 4 ether);
    assertInvariant();
  }

  function test_debit() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(op);
    escrow.debit(subSolver, 2 ether, keccak256('r1'));
    assertInvariant();
  }

  function test_withdrawDebits() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(op);
    escrow.debit(subSolver, 2 ether, keccak256('r1'));

    escrow.withdrawDebits();
    assertInvariant();
  }

  function test_requestWithdrawal() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(subSolver);
    escrow.requestWithdrawal();
    assertInvariant();
  }

  function test_executeWithdrawal() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(subSolver);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);

    vm.prank(subSolver);
    escrow.executeWithdrawal();
    assertInvariant();
  }

  function test_cancelWithdrawal() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(subSolver);
    escrow.requestWithdrawal();

    vm.prank(subSolver);
    escrow.cancelWithdrawal();
    assertInvariant();
  }

  function test_freeze() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(op);
    escrow.freeze(subSolver);
    assertInvariant();
  }

  function test_unfreeze() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.startPrank(op);
    escrow.freeze(subSolver);
    escrow.unfreeze(subSolver);
    vm.stopPrank();
    assertInvariant();
  }

  function test_pause() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(op);
    escrow.pause();
    assertInvariant();
  }

  function test_unpause() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.startPrank(op);
    escrow.pause();
    escrow.unpause();
    vm.stopPrank();
    assertInvariant();
  }

  function test_setCooldownPeriod() public {
    escrow.deposit{value: 10 ether}(subSolver);

    vm.prank(admin);
    escrow.setCooldownPeriod(2 days);
    assertInvariant();
  }

  // --- Threat analysis coverage ---

  function test_force_sent_eth_breaks_invariant_benignly() public {
    // Threat 5: force-sent ETH (via SELFDESTRUCT / coinbase reward) breaks the
    // totalSupply + accumulatedDebits == balance invariant in the benign direction
    // (more ETH than tokens). The excess is permanently stuck but all operations
    // still work.
    escrow.deposit{value: 10 ether}(subSolver);
    assertInvariant();

    // Simulate force-sent ETH (SELFDESTRUCT or coinbase reward bypasses receive())
    vm.deal(address(escrow), address(escrow).balance + 1 ether);

    // Invariant broken: more ETH than tokens
    assertGt(address(escrow).balance, escrow.totalSupply() + escrow.accumulatedDebits());
    assertEq(address(escrow).balance, 11 ether);
    assertEq(escrow.totalSupply() + escrow.accumulatedDebits(), 10 ether);

    // All operations still work despite the excess
    vm.prank(op);
    escrow.debit(subSolver, 2 ether, keccak256('reason'));
    escrow.withdrawDebits();
    escrow.deposit{value: 3 ether}(subSolver2);

    vm.prank(subSolver);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);
    vm.prank(subSolver);
    escrow.executeWithdrawal();

    // The excess 1 ether is permanently stuck
    assertGt(address(escrow).balance, escrow.totalSupply() + escrow.accumulatedDebits());
  }
}
