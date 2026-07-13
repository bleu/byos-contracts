// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

import {Escrow} from "../../src/contracts/Escrow.sol";
import {Test} from "forge-std/Test.sol";

contract EscrowTest is Test {
    Escrow escrow;
    address admin;
    address op;
    address subSolver;
    address subSolver2;

    uint256 constant COOLDOWN = 1 days;
    uint48 constant ADMIN_TRANSFER_DELAY = 2 days;
    bytes32 constant ADMIN_ROLE = 0x00;
    bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    function setUp() public {
        admin = makeAddr("admin");
        op = makeAddr("operator");
        subSolver = makeAddr("subSolver");
        subSolver2 = makeAddr("subSolver2");
        escrow = new Escrow(ADMIN_TRANSFER_DELAY, admin, op, COOLDOWN);
    }

    // --- Constructor ---

    function test_constructor_sets_roles() public view {
        assertTrue(escrow.hasRole(ADMIN_ROLE, admin));
        assertTrue(escrow.hasRole(OPERATOR_ROLE, op));
        assertEq(escrow.defaultAdmin(), admin);
        assertEq(escrow.defaultAdminDelay(), ADMIN_TRANSFER_DELAY);
        assertEq(escrow.cooldownPeriod(), COOLDOWN);
    }

    function test_constructor_reverts_zero_admin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new Escrow(ADMIN_TRANSFER_DELAY, address(0), op, COOLDOWN);
    }

    // --- Deposit ---

    function test_deposit_credits_sub_solver() public {
        escrow.deposit{value: 5 ether}(subSolver);
        assertEq(escrow.balance(subSolver), 5 ether);
        assertEq(escrow.effectiveBalance(subSolver), 5 ether);
    }

    function test_deposit_multiple_accumulates() public {
        escrow.deposit{value: 3 ether}(subSolver);
        escrow.deposit{value: 2 ether}(subSolver);
        assertEq(escrow.balance(subSolver), 5 ether);
    }

    function test_deposit_anyone_can_deposit_for_sub_solver() public {
        vm.deal(subSolver2, 10 ether);
        vm.prank(subSolver2);
        escrow.deposit{value: 1 ether}(subSolver);
        assertEq(escrow.balance(subSolver), 1 ether);
    }

    // --- Debit ---

    function test_debit_reduces_balance() public {
        escrow.deposit{value: 10 ether}(subSolver);
        vm.prank(op);
        escrow.debit(subSolver, 3 ether, keccak256("revert-tx-hash"));
        assertEq(escrow.balance(subSolver), 7 ether);
        assertEq(escrow.withdrawableBalance(), 3 ether);
    }

    function test_debit_reverts_non_operator() public {
        escrow.deposit{value: 10 ether}(subSolver);
        vm.prank(subSolver);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, subSolver, OPERATOR_ROLE)
        );
        escrow.debit(subSolver, 1 ether, keccak256("reason"));
    }

    function test_debit_reverts_exceeding_balance() public {
        escrow.deposit{value: 1 ether}(subSolver);
        vm.prank(op);
        vm.expectRevert(Escrow.InsufficientBalance.selector);
        escrow.debit(subSolver, 2 ether, keccak256("reason"));
    }

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

    // --- Debit during cooldown ---

    function test_debit_during_cooldown_reduces_withdrawal_amount() public {
        escrow.deposit{value: 10 ether}(subSolver);

        vm.prank(subSolver);
        escrow.requestWithdrawal();

        // Operator debits during cooldown (Track A revert)
        vm.prank(op);
        escrow.debit(subSolver, 3 ether, keccak256("revert"));

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

        // Balance is now 0 — debit should revert
        vm.prank(op);
        vm.expectRevert(Escrow.InsufficientBalance.selector);
        escrow.debit(subSolver, 1 ether, keccak256("late-debit"));
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
        vm.expectRevert(Escrow.AccountFrozen.selector);
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

        // Withdrawal succeeds immediately — cooldown already served
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

        // Cancel should work even when frozen — funds staying in contract is always safe
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

    // --- withdrawDebits ---

    function test_withdraw_debits_sends_to_admin() public {
        escrow.deposit{value: 10 ether}(subSolver);
        vm.prank(op);
        escrow.debit(subSolver, 4 ether, keccak256("penalty"));

        escrow.withdrawDebits();
        assertEq(admin.balance, 4 ether);
        assertEq(escrow.withdrawableBalance(), 0);
    }

    function test_withdraw_debits_reverts_if_nothing() public {
        vm.expectRevert(Escrow.NothingToWithdraw.selector);
        escrow.withdrawDebits();
    }

    function test_withdraw_debits_callable_by_anyone() public {
        escrow.deposit{value: 10 ether}(subSolver);
        vm.prank(op);
        escrow.debit(subSolver, 2 ether, keccak256("reason"));

        vm.prank(subSolver2);
        escrow.withdrawDebits();
        assertEq(admin.balance, 2 ether);
    }

    // --- Admin functions ---

    function test_set_cooldown_period() public {
        vm.prank(admin);
        escrow.setCooldownPeriod(7 days);
        assertEq(escrow.cooldownPeriod(), 7 days);
    }

    function test_grant_operator_role() public {
        address newOp = makeAddr("newOp");
        vm.prank(admin);
        escrow.grantRole(OPERATOR_ROLE, newOp);
        assertTrue(escrow.hasRole(OPERATOR_ROLE, newOp));

        // New operator can debit
        escrow.deposit{value: 5 ether}(subSolver);
        vm.prank(newOp);
        escrow.debit(subSolver, 1 ether, keccak256("test"));
        assertEq(escrow.balance(subSolver), 4 ether);
    }

    function test_revoke_operator_role() public {
        vm.prank(admin);
        escrow.revokeRole(OPERATOR_ROLE, op);
        assertFalse(escrow.hasRole(OPERATOR_ROLE, op));

        // Old operator can no longer debit
        escrow.deposit{value: 5 ether}(subSolver);
        vm.prank(op);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, op, OPERATOR_ROLE)
        );
        escrow.debit(subSolver, 1 ether, keccak256("reason"));
    }

    function test_begin_accept_admin_transfer() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        escrow.beginDefaultAdminTransfer(newAdmin);

        // Cannot accept before delay
        vm.prank(newAdmin);
        vm.expectRevert();
        escrow.acceptDefaultAdminTransfer();

        // Wait for delay + 1 second (schedule must be in the past)
        vm.warp(block.timestamp + ADMIN_TRANSFER_DELAY + 1);

        vm.prank(newAdmin);
        escrow.acceptDefaultAdminTransfer();

        assertEq(escrow.defaultAdmin(), newAdmin);
        assertFalse(escrow.hasRole(ADMIN_ROLE, admin));

        // New admin can set cooldown
        vm.prank(newAdmin);
        escrow.setCooldownPeriod(2 days);
        assertEq(escrow.cooldownPeriod(), 2 days);
    }

    function test_cancel_admin_transfer() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        escrow.beginDefaultAdminTransfer(newAdmin);

        vm.prank(admin);
        escrow.cancelDefaultAdminTransfer();

        // Even after delay, acceptance reverts because transfer was cancelled
        vm.warp(block.timestamp + ADMIN_TRANSFER_DELAY + 1);
        vm.prank(newAdmin);
        vm.expectRevert();
        escrow.acceptDefaultAdminTransfer();

        // Original admin still works
        assertEq(escrow.defaultAdmin(), admin);
    }

    function test_begin_admin_transfer_reverts_non_admin() public {
        vm.prank(subSolver);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, subSolver, ADMIN_ROLE)
        );
        escrow.beginDefaultAdminTransfer(subSolver);
    }

    function test_admin_functions_revert_non_admin() public {
        vm.prank(subSolver);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, subSolver, ADMIN_ROLE)
        );
        escrow.setCooldownPeriod(0);
    }

    function test_non_admin_cannot_grant_roles() public {
        vm.prank(subSolver);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, subSolver, ADMIN_ROLE)
        );
        escrow.grantRole(OPERATOR_ROLE, subSolver);
    }

    // ==================== Edge case tests ====================

    // --- Deposit edge cases ---

    function test_deposit_zero_value() public {
        escrow.deposit{value: 0}(subSolver);
        assertEq(escrow.balance(subSolver), 0);
    }

    // --- Debit edge cases ---

    function test_debit_exact_full_balance() public {
        escrow.deposit{value: 5 ether}(subSolver);
        vm.prank(op);
        escrow.debit(subSolver, 5 ether, keccak256("full"));
        assertEq(escrow.balance(subSolver), 0);
        assertEq(escrow.withdrawableBalance(), 5 ether);
    }

    function test_debit_zero_amount() public {
        escrow.deposit{value: 5 ether}(subSolver);
        vm.prank(op);
        escrow.debit(subSolver, 0, keccak256("zero"));
        assertEq(escrow.balance(subSolver), 5 ether);
    }

    function test_debit_multiple_incremental() public {
        escrow.deposit{value: 10 ether}(subSolver);
        vm.startPrank(op);
        escrow.debit(subSolver, 3 ether, keccak256("first"));
        escrow.debit(subSolver, 3 ether, keccak256("second"));
        escrow.debit(subSolver, 4 ether, keccak256("third"));
        vm.stopPrank();
        assertEq(escrow.balance(subSolver), 0);
        assertEq(escrow.withdrawableBalance(), 10 ether);
    }

    // --- Withdrawal edge cases ---

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

    // --- Freeze edge cases ---

    function test_double_freeze_is_idempotent() public {
        vm.startPrank(op);
        escrow.freeze(subSolver);
        assertTrue(escrow.frozen(subSolver));
        escrow.freeze(subSolver);
        assertTrue(escrow.frozen(subSolver));
        vm.stopPrank();
    }

    function test_double_unfreeze_is_idempotent() public {
        vm.startPrank(op);
        escrow.freeze(subSolver);
        escrow.unfreeze(subSolver);
        assertFalse(escrow.frozen(subSolver));
        escrow.unfreeze(subSolver);
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

    // --- withdrawDebits edge cases ---

    function test_withdraw_debits_accumulates_across_sub_solvers() public {
        escrow.deposit{value: 10 ether}(subSolver);
        escrow.deposit{value: 10 ether}(subSolver2);

        vm.startPrank(op);
        escrow.debit(subSolver, 3 ether, keccak256("r1"));
        escrow.debit(subSolver2, 4 ether, keccak256("r2"));
        vm.stopPrank();

        assertEq(escrow.withdrawableBalance(), 7 ether);
        escrow.withdrawDebits();
        assertEq(admin.balance, 7 ether);
    }

    function test_withdraw_debits_reverts_if_admin_rejects_eth() public {
        RejectETH rejector = new RejectETH();
        Escrow escrowBadAdmin = new Escrow(ADMIN_TRANSFER_DELAY, address(rejector), op, COOLDOWN);
        escrowBadAdmin.deposit{value: 10 ether}(subSolver);

        vm.prank(op);
        escrowBadAdmin.debit(subSolver, 5 ether, keccak256("reason"));

        vm.expectRevert(Escrow.TransferFailed.selector);
        escrowBadAdmin.withdrawDebits();
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

    // --- Admin edge cases ---

    function test_revoke_operator_bricks_operator_functions() public {
        vm.prank(admin);
        escrow.revokeRole(OPERATOR_ROLE, op);

        // Old operator can no longer debit
        escrow.deposit{value: 5 ether}(subSolver);
        vm.prank(op);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, op, OPERATOR_ROLE)
        );
        escrow.debit(subSolver, 1 ether, keccak256("reason"));
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

    function test_multiple_operators_can_coexist() public {
        address secondOp = makeAddr("secondOp");
        vm.prank(admin);
        escrow.grantRole(OPERATOR_ROLE, secondOp);

        escrow.deposit{value: 10 ether}(subSolver);

        // Both operators can debit
        vm.prank(op);
        escrow.debit(subSolver, 3 ether, keccak256("first-op"));
        vm.prank(secondOp);
        escrow.debit(subSolver, 2 ether, keccak256("second-op"));

        assertEq(escrow.balance(subSolver), 5 ether);
    }

    // --- Event emissions ---

    function test_deposit_emits_event() public {
        vm.expectEmit(true, false, false, true);
        emit Escrow.Deposited(subSolver, 5 ether);
        escrow.deposit{value: 5 ether}(subSolver);
    }

    function test_debit_emits_event() public {
        escrow.deposit{value: 10 ether}(subSolver);
        bytes32 reason = keccak256("revert-tx");

        vm.prank(op);
        vm.expectEmit(true, false, false, true);
        emit Escrow.Debited(subSolver, 3 ether, reason);
        escrow.debit(subSolver, 3 ether, reason);
    }

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

    function test_freeze_unfreeze_emits_events() public {
        vm.prank(op);
        vm.expectEmit(true, false, false, false);
        emit Escrow.Frozen(subSolver);
        escrow.freeze(subSolver);

        vm.prank(op);
        vm.expectEmit(true, false, false, false);
        emit Escrow.Unfrozen(subSolver);
        escrow.unfreeze(subSolver);
    }

    function test_admin_functions_emit_events() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit Escrow.CooldownPeriodUpdated(COOLDOWN, 7 days);
        escrow.setCooldownPeriod(7 days);
    }

    function test_withdraw_debits_emits_event() public {
        escrow.deposit{value: 10 ether}(subSolver);
        vm.prank(op);
        escrow.debit(subSolver, 4 ether, keccak256("penalty"));

        vm.expectEmit(true, false, false, true);
        emit Escrow.DebitsWithdrawn(escrow.defaultAdmin(), 4 ether);
        escrow.withdrawDebits();
    }

    function test_role_grant_revoke_emits_events() public {
        address newOp = makeAddr("newOp");

        vm.prank(admin);
        vm.expectEmit(true, true, true, false);
        emit IAccessControl.RoleGranted(OPERATOR_ROLE, newOp, admin);
        escrow.grantRole(OPERATOR_ROLE, newOp);

        vm.prank(admin);
        vm.expectEmit(true, true, true, false);
        emit IAccessControl.RoleRevoked(OPERATOR_ROLE, newOp, admin);
        escrow.revokeRole(OPERATOR_ROLE, newOp);
    }
}

/// @dev Contract that rejects ETH transfers.
contract RejectETH {
    receive() external payable {
        revert("rejected");
    }
}

/// @dev Contract that attempts reentrancy on executeWithdrawal.
contract ReentrantWithdrawer {
    Escrow public target;
    uint256 public reentrancyCount;

    constructor(Escrow _target) {
        target = _target;
    }

    function requestWithdrawal() external {
        target.requestWithdrawal();
    }

    function executeWithdrawal() external {
        target.executeWithdrawal();
    }

    receive() external payable {
        if (reentrancyCount == 0) {
            reentrancyCount++;
            try target.executeWithdrawal() {} catch {}
        }
    }
}
