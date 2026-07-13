// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Escrow} from "../../src/contracts/Escrow.sol";
import {EscrowTestBase, RejectETH} from "./EscrowTestBase.sol";

contract WithdrawDebitsTest is EscrowTestBase {
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

    // --- Events ---

    function test_withdraw_debits_emits_event() public {
        escrow.deposit{value: 10 ether}(subSolver);
        vm.prank(op);
        escrow.debit(subSolver, 4 ether, keccak256("penalty"));

        vm.expectEmit(true, false, false, true);
        emit Escrow.DebitsWithdrawn(escrow.defaultAdmin(), 4 ether);
        escrow.withdrawDebits();
    }
}
