// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IEscrow} from 'interfaces/IEscrow.sol';

import {EscrowTestBase} from './EscrowTestBase.sol';

contract ERC20Test is EscrowTestBase {
  function test_erc20_total_supply_tracks_deposits_and_withdrawals() public {
    assertEq(escrow.totalSupply(), 0);

    escrow.deposit{value: 10 ether}(subSolver);
    assertEq(escrow.totalSupply(), 10 ether);

    escrow.deposit{value: 5 ether}(subSolver2);
    assertEq(escrow.totalSupply(), 15 ether);

    // Debit reduces totalSupply
    vm.prank(op);
    escrow.debit(subSolver, 3 ether, keccak256('reason'));
    assertEq(escrow.totalSupply(), 12 ether);

    // Withdrawal reduces totalSupply
    vm.prank(subSolver2);
    escrow.requestWithdrawal();
    vm.warp(block.timestamp + COOLDOWN);
    vm.prank(subSolver2);
    escrow.executeWithdrawal();
    assertEq(escrow.totalSupply(), 7 ether);

    assertInvariant();
  }

  function test_transfer_from_deploys_trampoline_for_recipient() public {
    escrow.deposit{value: 10 ether}(subSolver);
    address newAddr = makeAddr('newAddr');

    vm.prank(subSolver);
    escrow.approve(subSolver2, 5 ether);

    address predicted = escrow.TRAMPOLINE_FACTORY().addressOf(newAddr);
    assertEq(predicted.code.length, 0);

    vm.prank(subSolver2);
    escrow.transferFrom(subSolver, newAddr, 3 ether);

    assertGt(predicted.code.length, 0);
    assertEq(escrow.balanceOf(newAddr), 3 ether);
  }

  function test_transfer_from_reverts_when_paused() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(subSolver);
    escrow.approve(subSolver2, 5 ether);

    vm.prank(op);
    escrow.pause();

    vm.prank(subSolver2);
    vm.expectRevert(IEscrow.Escrow_EnforcedPause.selector);
    escrow.transferFrom(subSolver, subSolver2, 1 ether);
  }

  function test_transfer_from_reverts_if_sender_frozen() public {
    escrow.deposit{value: 10 ether}(subSolver);
    vm.prank(subSolver);
    escrow.approve(subSolver2, 5 ether);

    vm.prank(op);
    escrow.freeze(subSolver);

    vm.prank(subSolver2);
    vm.expectRevert(IEscrow.Escrow_AccountFrozen.selector);
    escrow.transferFrom(subSolver, subSolver2, 1 ether);
  }
}
