// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Escrow} from "../../src/contracts/Escrow.sol";
import {Test} from "forge-std/Test.sol";

contract EscrowTest is Test {
    Escrow escrow;
    address owner;
    address op;
    address solver;
    address solver2;

    uint256 constant COOLDOWN = 1 days;

    function setUp() public {
        owner = makeAddr("owner");
        op = makeAddr("operator");
        solver = makeAddr("solver");
        solver2 = makeAddr("solver2");
        escrow = new Escrow(owner, op, COOLDOWN);
    }

    // --- Constructor ---

    function test_constructor_sets_roles() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.operator(), op);
        assertEq(escrow.cooldownPeriod(), COOLDOWN);
    }

    function test_constructor_reverts_zero_owner() public {
        vm.expectRevert(Escrow.ZeroAddress.selector);
        new Escrow(address(0), op, COOLDOWN);
    }

    // --- Deposit ---

    function test_deposit_credits_sub_solver() public {
        escrow.deposit{value: 5 ether}(solver);
        assertEq(escrow.balance(solver), 5 ether);
        assertEq(escrow.effectiveBalance(solver), 5 ether);
    }

    function test_deposit_multiple_accumulates() public {
        escrow.deposit{value: 3 ether}(solver);
        escrow.deposit{value: 2 ether}(solver);
        assertEq(escrow.balance(solver), 5 ether);
    }

    function test_deposit_anyone_can_deposit_for_solver() public {
        vm.deal(solver2, 10 ether);
        vm.prank(solver2);
        escrow.deposit{value: 1 ether}(solver);
        assertEq(escrow.balance(solver), 1 ether);
    }

    // --- Debit ---

    function test_debit_reduces_balance() public {
        escrow.deposit{value: 10 ether}(solver);
        vm.prank(op);
        escrow.debit(solver, 3 ether, keccak256("revert-tx-hash"));
        assertEq(escrow.balance(solver), 7 ether);
        assertEq(escrow.withdrawableBalance(), 3 ether);
    }

    function test_debit_reverts_non_operator() public {
        escrow.deposit{value: 10 ether}(solver);
        vm.prank(solver);
        vm.expectRevert(Escrow.OnlyOperator.selector);
        escrow.debit(solver, 1 ether, keccak256("reason"));
    }

    function test_debit_reverts_exceeding_balance() public {
        escrow.deposit{value: 1 ether}(solver);
        vm.prank(op);
        vm.expectRevert(Escrow.InsufficientBalance.selector);
        escrow.debit(solver, 2 ether, keccak256("reason"));
    }

    // --- Withdrawal lifecycle ---

    function test_full_withdrawal_lifecycle() public {
        escrow.deposit{value: 10 ether}(solver);

        // Request
        vm.prank(solver);
        escrow.requestWithdrawal();
        assertEq(escrow.effectiveBalance(solver), 0);
        assertEq(escrow.balance(solver), 10 ether);

        // Wait cooldown
        vm.warp(block.timestamp + COOLDOWN);

        // Execute
        vm.prank(solver);
        escrow.executeWithdrawal();
        assertEq(escrow.balance(solver), 0);
        assertEq(solver.balance, 10 ether);
    }

    function test_withdrawal_reverts_before_cooldown() public {
        escrow.deposit{value: 10 ether}(solver);
        vm.prank(solver);
        escrow.requestWithdrawal();

        vm.warp(block.timestamp + COOLDOWN - 1);
        vm.prank(solver);
        vm.expectRevert(Escrow.CooldownNotElapsed.selector);
        escrow.executeWithdrawal();
    }

    function test_withdrawal_request_reverts_if_no_balance() public {
        vm.prank(solver);
        vm.expectRevert(Escrow.InsufficientBalance.selector);
        escrow.requestWithdrawal();
    }

    function test_withdrawal_request_reverts_if_already_requested() public {
        escrow.deposit{value: 1 ether}(solver);
        vm.prank(solver);
        escrow.requestWithdrawal();

        vm.prank(solver);
        vm.expectRevert(Escrow.WithdrawalAlreadyRequested.selector);
        escrow.requestWithdrawal();
    }

    function test_cancel_withdrawal_restores_effective_balance() public {
        escrow.deposit{value: 5 ether}(solver);
        vm.prank(solver);
        escrow.requestWithdrawal();
        assertEq(escrow.effectiveBalance(solver), 0);

        vm.prank(solver);
        escrow.cancelWithdrawal();
        assertEq(escrow.effectiveBalance(solver), 5 ether);
    }

    function test_cancel_withdrawal_reverts_if_none_pending() public {
        vm.prank(solver);
        vm.expectRevert(Escrow.NoWithdrawalRequested.selector);
        escrow.cancelWithdrawal();
    }

    // --- Debit during cooldown ---

    function test_debit_during_cooldown_reduces_withdrawal_amount() public {
        escrow.deposit{value: 10 ether}(solver);

        vm.prank(solver);
        escrow.requestWithdrawal();

        // Operator debits during cooldown (Track A revert)
        vm.prank(op);
        escrow.debit(solver, 3 ether, keccak256("revert"));

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(solver);
        escrow.executeWithdrawal();

        assertEq(solver.balance, 7 ether);
        assertEq(escrow.withdrawableBalance(), 3 ether);
    }

    // --- Freeze ---

    function test_freeze_blocks_execute_withdrawal() public {
        escrow.deposit{value: 10 ether}(solver);
        vm.prank(solver);
        escrow.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(op);
        escrow.freeze(solver);

        vm.prank(solver);
        vm.expectRevert(Escrow.AccountFrozen.selector);
        escrow.executeWithdrawal();
    }

    function test_unfreeze_allows_withdrawal_without_re_requesting() public {
        escrow.deposit{value: 10 ether}(solver);
        vm.prank(solver);
        escrow.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(op);
        escrow.freeze(solver);

        vm.prank(op);
        escrow.unfreeze(solver);

        // Withdrawal succeeds immediately — cooldown already served
        vm.prank(solver);
        escrow.executeWithdrawal();
        assertEq(solver.balance, 10 ether);
    }

    function test_cancel_withdrawal_allowed_while_frozen() public {
        escrow.deposit{value: 5 ether}(solver);
        vm.prank(solver);
        escrow.requestWithdrawal();

        vm.prank(op);
        escrow.freeze(solver);

        // Cancel should work even when frozen — funds staying in contract is always safe
        vm.prank(solver);
        escrow.cancelWithdrawal();
        assertEq(escrow.effectiveBalance(solver), 5 ether);
    }

    function test_freeze_reverts_non_operator() public {
        vm.prank(solver);
        vm.expectRevert(Escrow.OnlyOperator.selector);
        escrow.freeze(solver);
    }

    // --- withdrawDebits ---

    function test_withdraw_debits_sends_to_owner() public {
        escrow.deposit{value: 10 ether}(solver);
        vm.prank(op);
        escrow.debit(solver, 4 ether, keccak256("penalty"));

        escrow.withdrawDebits();
        assertEq(owner.balance, 4 ether);
        assertEq(escrow.withdrawableBalance(), 0);
    }

    function test_withdraw_debits_reverts_if_nothing() public {
        vm.expectRevert(Escrow.NothingToWithdraw.selector);
        escrow.withdrawDebits();
    }

    function test_withdraw_debits_callable_by_anyone() public {
        escrow.deposit{value: 10 ether}(solver);
        vm.prank(op);
        escrow.debit(solver, 2 ether, keccak256("reason"));

        vm.prank(solver2);
        escrow.withdrawDebits();
        assertEq(owner.balance, 2 ether);
    }

    // --- Owner functions ---

    function test_set_operator() public {
        address newOp = makeAddr("newOp");
        vm.prank(owner);
        escrow.setOperator(newOp);
        assertEq(escrow.operator(), newOp);
    }

    function test_set_cooldown_period() public {
        vm.prank(owner);
        escrow.setCooldownPeriod(7 days);
        assertEq(escrow.cooldownPeriod(), 7 days);
    }

    function test_transfer_ownership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        assertEq(escrow.owner(), newOwner);
    }

    function test_transfer_ownership_reverts_zero_address() public {
        vm.prank(owner);
        vm.expectRevert(Escrow.ZeroAddress.selector);
        escrow.transferOwnership(address(0));
    }

    function test_owner_functions_revert_non_owner() public {
        vm.startPrank(solver);
        vm.expectRevert(Escrow.OnlyOwner.selector);
        escrow.setOperator(solver);
        vm.expectRevert(Escrow.OnlyOwner.selector);
        escrow.setCooldownPeriod(0);
        vm.expectRevert(Escrow.OnlyOwner.selector);
        escrow.transferOwnership(solver);
        vm.stopPrank();
    }
}
