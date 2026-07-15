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
}
