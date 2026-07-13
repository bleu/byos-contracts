// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Escrow} from "../../src/contracts/Escrow.sol";
import {EscrowTestBase, ReentrantWithdrawer, RejectETH} from "./EscrowTestBase.sol";

contract SubSolverActionsTest is EscrowTestBase {
    // --- Withdrawal lifecycle ---

    function test_full_withdrawal_lifecycle() public {
        escrow.deposit{value: 10 ether}(subSolver);

        // Request
        vm.prank(subSolver);
        escrow.requestWithdrawal();
        assertEq(escrow.effectiveBalance(subSolver), 0);
        assertEq(escrow.balance(subSolver), 10 ether);

        // Wait cooldown
        vm.warp(block.timestamp + COOLDOWN);

        // Execute
        vm.prank(subSolver);
        escrow.executeWithdrawal();
        assertEq(escrow.balance(subSolver), 0);
        assertEq(subSolver.balance, 10 ether);

        // Verify no leftover state — re-deposit and check clean accounting
        escrow.deposit{value: 4 ether}(subSolver);
        assertEq(escrow.balance(subSolver), 4 ether);
        assertEq(escrow.effectiveBalance(subSolver), 4 ether);
        assertEq(escrow.balances(subSolver), 4 ether);

        // Second withdrawal cycle
        vm.prank(subSolver);
        escrow.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(subSolver);
        escrow.executeWithdrawal();

        assertEq(escrow.balance(subSolver), 0);
        assertEq(escrow.balances(subSolver), 0);
        assertEq(escrow.withdrawalRequestedAt(subSolver), 0);
    }

    function test_withdrawal_reverts_before_cooldown() public {
        escrow.deposit{value: 10 ether}(subSolver);
        vm.prank(subSolver);
        escrow.requestWithdrawal();

        vm.warp(block.timestamp + COOLDOWN - 1);
        vm.prank(subSolver);
        vm.expectRevert(Escrow.CooldownNotElapsed.selector);
        escrow.executeWithdrawal();
    }

    function test_withdrawal_request_reverts_if_no_balance() public {
        vm.prank(subSolver);
        vm.expectRevert(Escrow.InsufficientBalance.selector);
        escrow.requestWithdrawal();
    }

    function test_withdrawal_request_reverts_if_already_requested() public {
        escrow.deposit{value: 1 ether}(subSolver);
        vm.prank(subSolver);
        escrow.requestWithdrawal();

        vm.prank(subSolver);
        vm.expectRevert(Escrow.WithdrawalAlreadyRequested.selector);
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
        vm.expectRevert(Escrow.NoWithdrawalRequested.selector);
        escrow.cancelWithdrawal();
    }

    function test_execute_withdrawal_reverts_after_full_debit_during_cooldown() public {
        escrow.deposit{value: 10 ether}(subSolver);
        vm.prank(subSolver);
        escrow.requestWithdrawal();

        vm.prank(op);
        escrow.debit(subSolver, 10 ether, keccak256("full-debit"));

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(subSolver);
        vm.expectRevert(Escrow.NothingToWithdraw.selector);
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
        // First cycle
        escrow.deposit{value: 5 ether}(subSolver);
        vm.prank(subSolver);
        escrow.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(subSolver);
        escrow.executeWithdrawal();
        assertEq(subSolver.balance, 5 ether);

        // Second cycle
        escrow.deposit{value: 3 ether}(subSolver);
        vm.prank(subSolver);
        escrow.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(subSolver);
        escrow.executeWithdrawal();
        assertEq(subSolver.balance, 8 ether);
        assertEq(escrow.balance(subSolver), 0);
    }

    function test_execute_withdrawal_reverts_if_transfer_fails() public {
        RejectETH rejector = new RejectETH();
        address rejectorAddr = address(rejector);
        escrow.deposit{value: 5 ether}(rejectorAddr);

        vm.prank(rejectorAddr);
        escrow.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(rejectorAddr);
        vm.expectRevert(Escrow.TransferFailed.selector);
        escrow.executeWithdrawal();
    }

    function test_set_cooldown_period_zero_allows_instant_withdrawal() public {
        vm.prank(admin);
        escrow.setCooldownPeriod(0);

        escrow.deposit{value: 5 ether}(subSolver);
        vm.prank(subSolver);
        escrow.requestWithdrawal();

        // Execute immediately in the same block
        vm.prank(subSolver);
        escrow.executeWithdrawal();
        assertEq(subSolver.balance, 5 ether);
    }

    function test_cooldown_reduction_makes_pending_withdrawal_executable() public {
        escrow.deposit{value: 5 ether}(subSolver);
        vm.prank(subSolver);
        escrow.requestWithdrawal();

        // 1 hour passes — still inside the 1-day cooldown
        vm.warp(block.timestamp + 1 hours);
        vm.prank(subSolver);
        vm.expectRevert(Escrow.CooldownNotElapsed.selector);
        escrow.executeWithdrawal();

        // Admin shortens cooldown to 30 minutes
        vm.prank(admin);
        escrow.setCooldownPeriod(30 minutes);

        // Now the 1-hour wait exceeds the new 30-minute cooldown
        vm.prank(subSolver);
        escrow.executeWithdrawal();
        assertEq(subSolver.balance, 5 ether);
    }

    // --- Reentrancy ---

    function test_execute_withdrawal_is_reentrancy_safe() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(escrow);
        address attackerAddr = address(attacker);

        // Another subSolver has funds — contract holds more than attacker's deposit
        escrow.deposit{value: 20 ether}(subSolver);
        escrow.deposit{value: 10 ether}(attackerAddr);

        vm.prank(attackerAddr);
        attacker.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(attackerAddr);
        attacker.executeWithdrawal();

        // Attacker only got their 10 ether, not more
        assertEq(attackerAddr.balance, 10 ether);
        assertEq(escrow.balance(attackerAddr), 0);
        // Other subSolver's balance is untouched
        assertEq(escrow.balance(subSolver), 20 ether);
    }

    // --- Events ---

    function test_withdrawal_lifecycle_emits_events() public {
        escrow.deposit{value: 5 ether}(subSolver);

        vm.prank(subSolver);
        vm.expectEmit(true, false, false, false);
        emit Escrow.WithdrawalRequested(subSolver);
        escrow.requestWithdrawal();

        vm.prank(subSolver);
        vm.expectEmit(true, false, false, false);
        emit Escrow.WithdrawalCancelled(subSolver);
        escrow.cancelWithdrawal();

        vm.prank(subSolver);
        escrow.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(subSolver);
        vm.expectEmit(true, false, false, true);
        emit Escrow.Withdrawn(subSolver, 5 ether);
        escrow.executeWithdrawal();
    }
}
