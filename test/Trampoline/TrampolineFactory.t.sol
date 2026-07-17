// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {Trampoline} from 'contracts/Trampoline.sol';
import {TrampolineFactory} from 'contracts/TrampolineFactory.sol';

contract TrampolineFactoryTest is Test {
  TrampolineFactory factory;
  address settlement;
  address subSolver;

  function setUp() public {
    settlement = makeAddr('settlement');
    subSolver = makeAddr('subSolver');
    factory = new TrampolineFactory(settlement);
  }

  // --- Deployment ---

  function test_ensureDeployed_deploys_at_deterministic_address() public {
    address predicted = factory.addressOf(subSolver);
    assertEq(predicted.code.length, 0);

    address instance = factory.ensureDeployed(subSolver);

    assertEq(instance, predicted);
    assertGt(instance.code.length, 0);
  }

  function test_ensureDeployed_is_idempotent() public {
    address first = factory.ensureDeployed(subSolver);
    address second = factory.ensureDeployed(subSolver);
    assertEq(first, second);
  }

  function test_deployed_instance_wires_immutables() public {
    Trampoline instance = Trampoline(payable(factory.ensureDeployed(subSolver)));
    assertEq(instance.SUB_SOLVER(), subSolver);
    assertEq(instance.SETTLEMENT(), settlement);
    assertEq(instance.DOMAIN_SEPARATOR(), factory.domainSeparator());
    assertEq(instance.ESCROW(), factory.ESCROW());
  }

  function test_factory_records_deployer_as_escrow() public view {
    // In production the Escrow deploys the factory from its constructor; here the
    // test contract plays that role.
    assertEq(factory.ESCROW(), address(this));
  }

  function test_distinct_sub_solvers_get_distinct_instances() public {
    address other = makeAddr('otherSubSolver');
    assertTrue(factory.addressOf(subSolver) != factory.addressOf(other));
  }
}
