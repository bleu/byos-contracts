// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IEscrow} from 'interfaces/IEscrow.sol';

import {EscrowTestBase} from './EscrowTestBase.sol';

contract IntegrationTest is EscrowTestBase {
  function test_invariant_total_supply_plus_debits_equals_eth_balance() public {
    // Deposit
    escrow.deposit{value: 10 ether}(subSolver);
    escrow.deposit{value: 5 ether}(subSolver2);
    assertInvariant();

    // Transfer
    vm.prank(subSolver);
    escrow.transfer(subSolver2, 3 ether);
    assertInvariant();

    // Debit
    vm.prank(op);
    escrow.debit(subSolver, 2 ether, keccak256('r1'));
    assertInvariant();

    // Withdraw debits
    escrow.withdrawDebits();
    assertInvariant();

    // Withdrawal
    vm.prank(subSolver2);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);
    vm.prank(subSolver2);
    escrow.executeWithdrawal();
    assertInvariant();
  }

  function test_incident_response_flow() public {
    address badActor = makeAddr('badActor');
    address accomplice = makeAddr('accomplice');
    address innocent = makeAddr('innocent');

    // Setup: multiple sub-solvers deposit
    escrow.deposit{value: 10 ether}(badActor);
    escrow.deposit{value: 5 ether}(innocent);

    // Bad actor transfers funds to accomplice before operator can react
    vm.prank(badActor);
    escrow.transfer(accomplice, 8 ether);

    // 1. Operator pauses — all transfers stop
    vm.prank(op);
    escrow.pause();

    // Accomplice cannot transfer further
    vm.prank(accomplice);
    vm.expectRevert(IEscrow.Escrow_EnforcedPause.selector);
    escrow.transfer(innocent, 1 ether);

    // 2. Operator freezes both bad actor and accomplice
    vm.startPrank(op);
    escrow.freeze(badActor);
    escrow.freeze(accomplice);
    vm.stopPrank();

    // 3. Operator unpauses — innocent sub-solver is free
    vm.prank(op);
    escrow.unpause();

    // Innocent can still transfer
    vm.prank(innocent);
    escrow.transfer(makeAddr('newInnocentKey'), 5 ether);

    // Frozen bad actor still cannot transfer
    vm.prank(badActor);
    vm.expectRevert(IEscrow.Escrow_AccountFrozen.selector);
    escrow.transfer(innocent, 1 ether);

    // 4. Operator debits frozen addresses
    vm.startPrank(op);
    escrow.debit(badActor, 2 ether, keccak256('penalty-main'));
    escrow.debit(accomplice, 8 ether, keccak256('penalty-accomplice'));
    vm.stopPrank();

    assertEq(escrow.balanceOf(badActor), 0);
    assertEq(escrow.balanceOf(accomplice), 0);
    assertInvariant();
  }
}
