// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {EscrowTestBase} from './EscrowTestBase.sol';
import {Escrow} from 'contracts/Escrow.sol';

contract SubmitterRoleTest is EscrowTestBase {
  function test_constructor_deploys_factory_and_grants_initial_submitters() public {
    // The Escrow deploys its own factory so trampolines can reference the Escrow
    // as submitter registry without a circular constructor dependency.
    assertGt(address(escrow.TRAMPOLINE_FACTORY()).code.length, 0);
    assertEq(factory.ESCROW(), address(escrow));
    assertTrue(escrow.hasRole(SUBMITTER_ROLE, submitter));

    // The constructor takes a submitter list so every submission identity can be
    // wired at deploy time — the allow-listed solver EOA plus Solver7702Delegate
    // auxiliary accounts for the parallel path (ADR-0005).
    address[] memory submitters = new address[](3);
    submitters[0] = makeAddr('solverEoa');
    submitters[1] = makeAddr('aux0');
    submitters[2] = makeAddr('aux1');
    Escrow multi =
      new Escrow(ADMIN_TRANSFER_DELAY, admin, op, submitters, COOLDOWN, makeAddr('settlement'), 'BYOS Escrow', 'BYOS');
    for (uint256 i = 0; i < submitters.length; ++i) {
      assertTrue(multi.hasRole(SUBMITTER_ROLE, submitters[i]));
    }
  }
}
