// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {
  IAccessControlDefaultAdminRules
} from '@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol';

import {IEscrow} from 'interfaces/IEscrow.sol';

import {EscrowTestBase} from './EscrowTestBase.sol';
import {Escrow} from 'contracts/Escrow.sol';
import {TrampolineFactory} from 'contracts/TrampolineFactory.sol';

contract AccessControlTest is EscrowTestBase {
  // --- Constructor ---

  function test_constructor_sets_roles() public view {
    assertTrue(escrow.hasRole(ADMIN_ROLE, admin));
    assertTrue(escrow.hasRole(OPERATOR_ROLE, op));
    assertEq(escrow.defaultAdmin(), admin);
    assertEq(escrow.defaultAdminDelay(), ADMIN_TRANSFER_DELAY);
    assertEq(escrow.cooldownPeriod(), COOLDOWN);
    assertEq(address(escrow.TRAMPOLINE_FACTORY()), address(factory));
  }

  function test_constructor_reverts_zero_admin() public {
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0))
    );
    new Escrow(ADMIN_TRANSFER_DELAY, address(0), op, COOLDOWN, factory);
  }

  function test_constructor_reverts_zero_factory() public {
    vm.expectRevert(IEscrow.Escrow_ZeroAddress.selector);
    new Escrow(ADMIN_TRANSFER_DELAY, admin, op, COOLDOWN, TrampolineFactory(address(0)));
  }

  // --- Admin functions ---

  function test_set_cooldown_period() public {
    vm.prank(admin);
    escrow.setCooldownPeriod(7 days);
    assertEq(escrow.cooldownPeriod(), 7 days);
  }

  function test_grant_operator_role() public {
    address newOp = makeAddr('newOp');
    vm.prank(admin);
    escrow.grantRole(OPERATOR_ROLE, newOp);
    assertTrue(escrow.hasRole(OPERATOR_ROLE, newOp));

    // New operator can debit
    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(newOp);
    escrow.debit(subSolver, 1 ether, keccak256('test'));
    assertEq(escrow.balance(subSolver), 4 ether);
  }

  function test_revoke_operator_role() public {
    vm.prank(admin);
    escrow.revokeRole(OPERATOR_ROLE, op);
    assertFalse(escrow.hasRole(OPERATOR_ROLE, op));

    // Old operator can no longer debit
    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(op);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, op, OPERATOR_ROLE));
    escrow.debit(subSolver, 1 ether, keccak256('reason'));
  }

  function test_begin_accept_admin_transfer() public {
    address newAdmin = makeAddr('newAdmin');

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
    address newAdmin = makeAddr('newAdmin');

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

  function test_setCooldownPeriod_reverts_non_admin() public {
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

  function test_revoke_operator_bricks_operator_functions() public {
    vm.prank(admin);
    escrow.revokeRole(OPERATOR_ROLE, op);

    // Old operator can no longer debit
    escrow.deposit{value: 5 ether}(subSolver);
    vm.prank(op);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, op, OPERATOR_ROLE));
    escrow.debit(subSolver, 1 ether, keccak256('reason'));
  }

  function test_old_admin_loses_access_after_transfer() public {
    address newAdmin = makeAddr('newAdmin');

    vm.prank(admin);
    escrow.beginDefaultAdminTransfer(newAdmin);
    vm.warp(block.timestamp + ADMIN_TRANSFER_DELAY + 1);
    vm.prank(newAdmin);
    escrow.acceptDefaultAdminTransfer();

    // Old admin can no longer act
    vm.prank(admin);
    vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, ADMIN_ROLE));
    escrow.setCooldownPeriod(99);

    // New admin can act
    vm.prank(newAdmin);
    escrow.setCooldownPeriod(2 days);
    assertEq(escrow.cooldownPeriod(), 2 days);
  }

  // --- Events ---

  function test_setCooldownPeriod_emits_event() public {
    vm.prank(admin);
    vm.expectEmit(false, false, false, true);
    emit IEscrow.CooldownPeriodUpdated(COOLDOWN, 7 days);
    escrow.setCooldownPeriod(7 days);
  }
}
