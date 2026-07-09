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

        // Verify no leftover state — re-deposit and check clean accounting
        escrow.deposit{value: 4 ether}(solver);
        assertEq(escrow.balance(solver), 4 ether);
        assertEq(escrow.effectiveBalance(solver), 4 ether);
        assertEq(escrow.deposits(solver), 4 ether);
        assertEq(escrow.totalDebited(solver), 0);

        // Second withdrawal cycle
        vm.prank(solver);
        escrow.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(solver);
        escrow.executeWithdrawal();

        assertEq(escrow.balance(solver), 0);
        assertEq(escrow.deposits(solver), 0);
        assertEq(escrow.totalDebited(solver), 0);
        assertEq(escrow.withdrawalRequestedAt(solver), 0);
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

    function test_debit_after_withdrawal_reverts() public {
        escrow.deposit{value: 10 ether}(solver);

        vm.prank(solver);
        escrow.requestWithdrawal();

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(solver);
        escrow.executeWithdrawal();

        // Balance is now 0 — debit should revert
        vm.prank(op);
        vm.expectRevert(Escrow.InsufficientBalance.selector);
        escrow.debit(solver, 1 ether, keccak256("late-debit"));
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

    function test_transfer_ownership_two_step() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: initiate transfer — owner does not change yet
        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        assertEq(escrow.owner(), owner);
        assertEq(escrow.pendingOwner(), newOwner);

        // Step 2: new owner accepts
        vm.prank(newOwner);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), newOwner);
        assertEq(escrow.pendingOwner(), address(0));
    }

    function test_transfer_ownership_second_call_overrides_first() public {
        address firstCandidate = makeAddr("first");
        address secondCandidate = makeAddr("second");

        vm.prank(owner);
        escrow.transferOwnership(firstCandidate);
        assertEq(escrow.pendingOwner(), firstCandidate);

        // Owner changes their mind
        vm.prank(owner);
        escrow.transferOwnership(secondCandidate);
        assertEq(escrow.pendingOwner(), secondCandidate);

        // First candidate cannot accept
        vm.prank(firstCandidate);
        vm.expectRevert(Escrow.OnlyPendingOwner.selector);
        escrow.acceptOwnership();

        // Second candidate can
        vm.prank(secondCandidate);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), secondCandidate);
    }

    function test_accept_ownership_reverts_non_pending_owner() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(newOwner);

        vm.prank(solver);
        vm.expectRevert(Escrow.OnlyPendingOwner.selector);
        escrow.acceptOwnership();
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

    // ==================== Edge case tests ====================

    // --- Deposit edge cases ---

    function test_deposit_zero_value() public {
        escrow.deposit{value: 0}(solver);
        assertEq(escrow.balance(solver), 0);
    }

    // --- Debit edge cases ---

    function test_debit_exact_full_balance() public {
        escrow.deposit{value: 5 ether}(solver);
        vm.prank(op);
        escrow.debit(solver, 5 ether, keccak256("full"));
        assertEq(escrow.balance(solver), 0);
        assertEq(escrow.withdrawableBalance(), 5 ether);
    }

    function test_debit_zero_amount() public {
        escrow.deposit{value: 5 ether}(solver);
        vm.prank(op);
        escrow.debit(solver, 0, keccak256("zero"));
        assertEq(escrow.balance(solver), 5 ether);
    }

    function test_debit_multiple_incremental() public {
        escrow.deposit{value: 10 ether}(solver);
        vm.startPrank(op);
        escrow.debit(solver, 3 ether, keccak256("first"));
        escrow.debit(solver, 3 ether, keccak256("second"));
        escrow.debit(solver, 4 ether, keccak256("third"));
        vm.stopPrank();
        assertEq(escrow.balance(solver), 0);
        assertEq(escrow.withdrawableBalance(), 10 ether);
    }

    // --- Withdrawal edge cases ---

    function test_execute_withdrawal_after_full_debit_during_cooldown() public {
        escrow.deposit{value: 10 ether}(solver);
        vm.prank(solver);
        escrow.requestWithdrawal();

        vm.prank(op);
        escrow.debit(solver, 10 ether, keccak256("full-debit"));

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(solver);
        escrow.executeWithdrawal();

        // Sub-solver gets nothing, state is fully cleared
        assertEq(solver.balance, 0);
        assertEq(escrow.deposits(solver), 0);
        assertEq(escrow.totalDebited(solver), 0);
        assertEq(escrow.withdrawalRequestedAt(solver), 0);
    }

    function test_withdrawal_at_exact_cooldown_boundary() public {
        escrow.deposit{value: 5 ether}(solver);
        uint256 requestTime = block.timestamp;
        vm.prank(solver);
        escrow.requestWithdrawal();

        vm.warp(requestTime + COOLDOWN);
        vm.prank(solver);
        escrow.executeWithdrawal();
        assertEq(solver.balance, 5 ether);
    }

    function test_re_deposit_and_withdraw_after_completed_cycle() public {
        // First cycle
        escrow.deposit{value: 5 ether}(solver);
        vm.prank(solver);
        escrow.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(solver);
        escrow.executeWithdrawal();
        assertEq(solver.balance, 5 ether);

        // Second cycle
        escrow.deposit{value: 3 ether}(solver);
        vm.prank(solver);
        escrow.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(solver);
        escrow.executeWithdrawal();
        assertEq(solver.balance, 8 ether);
        assertEq(escrow.balance(solver), 0);
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
        escrow.freeze(solver);
        assertTrue(escrow.frozen(solver));
        escrow.freeze(solver);
        assertTrue(escrow.frozen(solver));
        vm.stopPrank();
    }

    function test_double_unfreeze_is_idempotent() public {
        vm.startPrank(op);
        escrow.freeze(solver);
        escrow.unfreeze(solver);
        assertFalse(escrow.frozen(solver));
        escrow.unfreeze(solver);
        assertFalse(escrow.frozen(solver));
        vm.stopPrank();
    }

    function test_unfreeze_reverts_non_operator() public {
        vm.prank(op);
        escrow.freeze(solver);

        vm.prank(solver);
        vm.expectRevert(Escrow.OnlyOperator.selector);
        escrow.unfreeze(solver);
    }

    // --- withdrawDebits edge cases ---

    function test_withdraw_debits_accumulates_across_solvers() public {
        escrow.deposit{value: 10 ether}(solver);
        escrow.deposit{value: 10 ether}(solver2);

        vm.startPrank(op);
        escrow.debit(solver, 3 ether, keccak256("r1"));
        escrow.debit(solver2, 4 ether, keccak256("r2"));
        vm.stopPrank();

        assertEq(escrow.withdrawableBalance(), 7 ether);
        escrow.withdrawDebits();
        assertEq(owner.balance, 7 ether);
    }

    function test_withdraw_debits_reverts_if_owner_rejects_eth() public {
        RejectETH rejector = new RejectETH();
        Escrow escrowBadOwner = new Escrow(address(rejector), op, COOLDOWN);
        escrowBadOwner.deposit{value: 10 ether}(solver);

        vm.prank(op);
        escrowBadOwner.debit(solver, 5 ether, keccak256("reason"));

        vm.expectRevert(Escrow.TransferFailed.selector);
        escrowBadOwner.withdrawDebits();
    }

    // --- Reentrancy ---

    function test_execute_withdrawal_is_reentrancy_safe() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(escrow);
        address attackerAddr = address(attacker);

        // Another solver has funds — contract holds more than attacker's deposit
        escrow.deposit{value: 20 ether}(solver);
        escrow.deposit{value: 10 ether}(attackerAddr);

        vm.prank(attackerAddr);
        attacker.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(attackerAddr);
        attacker.executeWithdrawal();

        // Attacker only got their 10 ether, not more
        assertEq(attackerAddr.balance, 10 ether);
        assertEq(escrow.balance(attackerAddr), 0);
        // Other solver's balance is untouched
        assertEq(escrow.balance(solver), 20 ether);
    }

    // --- Owner admin edge cases ---

    function test_set_operator_to_zero_bricks_operator_functions() public {
        vm.prank(owner);
        escrow.setOperator(address(0));
        assertEq(escrow.operator(), address(0));

        // Old operator can no longer debit
        escrow.deposit{value: 5 ether}(solver);
        vm.prank(op);
        vm.expectRevert(Escrow.OnlyOperator.selector);
        escrow.debit(solver, 1 ether, keccak256("reason"));
    }

    function test_set_cooldown_period_zero_allows_instant_withdrawal() public {
        vm.prank(owner);
        escrow.setCooldownPeriod(0);

        escrow.deposit{value: 5 ether}(solver);
        vm.prank(solver);
        escrow.requestWithdrawal();

        // Execute immediately in the same block
        vm.prank(solver);
        escrow.executeWithdrawal();
        assertEq(solver.balance, 5 ether);
    }

    function test_old_owner_loses_access_after_transfer() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        vm.prank(newOwner);
        escrow.acceptOwnership();

        // Old owner can no longer act
        vm.prank(owner);
        vm.expectRevert(Escrow.OnlyOwner.selector);
        escrow.setOperator(makeAddr("x"));

        // New owner can act
        vm.prank(newOwner);
        escrow.setOperator(makeAddr("x"));
        assertEq(escrow.operator(), makeAddr("x"));
    }

    function test_cooldown_reduction_makes_pending_withdrawal_executable() public {
        escrow.deposit{value: 5 ether}(solver);
        vm.prank(solver);
        escrow.requestWithdrawal();

        // 1 hour passes — still inside the 1-day cooldown
        vm.warp(block.timestamp + 1 hours);
        vm.prank(solver);
        vm.expectRevert(Escrow.CooldownNotElapsed.selector);
        escrow.executeWithdrawal();

        // Owner shortens cooldown to 30 minutes
        vm.prank(owner);
        escrow.setCooldownPeriod(30 minutes);

        // Now the 1-hour wait exceeds the new 30-minute cooldown
        vm.prank(solver);
        escrow.executeWithdrawal();
        assertEq(solver.balance, 5 ether);
    }

    // --- Event emissions ---

    function test_deposit_emits_event() public {
        vm.expectEmit(true, false, false, true);
        emit Escrow.Deposited(solver, 5 ether);
        escrow.deposit{value: 5 ether}(solver);
    }

    function test_debit_emits_event() public {
        escrow.deposit{value: 10 ether}(solver);
        bytes32 reason = keccak256("revert-tx");

        vm.prank(op);
        vm.expectEmit(true, false, false, true);
        emit Escrow.Debited(solver, 3 ether, reason);
        escrow.debit(solver, 3 ether, reason);
    }

    function test_withdrawal_lifecycle_emits_events() public {
        escrow.deposit{value: 5 ether}(solver);

        vm.prank(solver);
        vm.expectEmit(true, false, false, false);
        emit Escrow.WithdrawalRequested(solver);
        escrow.requestWithdrawal();

        vm.prank(solver);
        vm.expectEmit(true, false, false, false);
        emit Escrow.WithdrawalCancelled(solver);
        escrow.cancelWithdrawal();

        vm.prank(solver);
        escrow.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(solver);
        vm.expectEmit(true, false, false, true);
        emit Escrow.Withdrawn(solver, 5 ether);
        escrow.executeWithdrawal();
    }

    function test_freeze_unfreeze_emits_events() public {
        vm.prank(op);
        vm.expectEmit(true, false, false, false);
        emit Escrow.Frozen(solver);
        escrow.freeze(solver);

        vm.prank(op);
        vm.expectEmit(true, false, false, false);
        emit Escrow.Unfrozen(solver);
        escrow.unfreeze(solver);
    }

    function test_admin_functions_emit_events() public {
        address newOp = makeAddr("newOp");
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit Escrow.OperatorUpdated(op, newOp);
        escrow.setOperator(newOp);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit Escrow.CooldownPeriodUpdated(COOLDOWN, 7 days);
        escrow.setCooldownPeriod(7 days);

        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit Escrow.OwnershipTransferStarted(owner, newOwner);
        escrow.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectEmit(true, true, false, false);
        emit Escrow.OwnershipTransferred(owner, newOwner);
        escrow.acceptOwnership();
    }

    function test_withdraw_debits_emits_event() public {
        escrow.deposit{value: 10 ether}(solver);
        vm.prank(op);
        escrow.debit(solver, 4 ether, keccak256("penalty"));

        vm.expectEmit(true, false, false, true);
        emit Escrow.DebitsWithdrawn(owner, 4 ether);
        escrow.withdrawDebits();
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
