// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {EscrowTestBase} from './EscrowTestBase.sol';

contract SubmitterRoleTest is EscrowTestBase {
  function test_constructor_deploys_factory_and_grants_initial_submitter() public view {
    // The Escrow deploys its own factory so trampolines can reference the Escrow
    // as submitter registry without a circular constructor dependency.
    assertGt(address(escrow.TRAMPOLINE_FACTORY()).code.length, 0);
    assertEq(factory.ESCROW(), address(escrow));
    assertTrue(escrow.hasRole(SUBMITTER_ROLE, submitter));
  }
}
