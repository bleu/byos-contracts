// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IEscrow} from 'interfaces/IEscrow.sol';

import {EscrowTestBase} from './EscrowTestBase.sol';

contract ERC20Test is EscrowTestBase {
  function test_erc20_name_and_symbol() public view {
    assertEq(escrow.name(), 'BYOS Escrow');
    assertEq(escrow.symbol(), 'BYOS');
  }

  function test_erc20_decimals_is_18() public view {
    assertEq(escrow.decimals(), 18);
  }

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

  // --- Disabled allowances ---

  function test_approve_always_reverts() public {
    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_AllowancesDisabled.selector);
    escrow.approve(subSolver2, 1 ether);
  }

  function test_transfer_from_always_reverts() public {
    vm.prank(subSolver);
    vm.expectRevert(IEscrow.Escrow_AllowancesDisabled.selector);
    escrow.transferFrom(subSolver, subSolver2, 1 ether);
  }

  function test_allowance_always_returns_zero() public view {
    assertEq(escrow.allowance(subSolver, subSolver2), 0);
  }
}
