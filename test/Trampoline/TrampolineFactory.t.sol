// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {ITrampolineFactory} from 'interfaces/ITrampolineFactory.sol';

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

  function test_existing_instance_is_stable_after_chain_id_change() public {
    address instance = factory.ensureDeployed(subSolver);
    bytes32 domain = factory.domainSeparator();

    vm.chainId(block.chainid + 1);

    assertEq(factory.domainSeparator(), domain);
    assertEq(factory.addressOf(subSolver), instance);
    assertEq(factory.ensureDeployed(subSolver), instance);
    assertEq(Trampoline(payable(instance)).DOMAIN_SEPARATOR(), domain);
  }

  function test_first_deployment_after_chain_id_change_uses_original_address_and_domain() public {
    address predicted = factory.addressOf(subSolver);
    bytes32 domain = factory.domainSeparator();

    vm.chainId(block.chainid + 1);

    vm.expectEmit(address(factory));
    emit ITrampolineFactory.TrampolineDeployed(subSolver, predicted);
    address instance = factory.ensureDeployed(subSolver);

    assertEq(instance, predicted);
    assertGt(instance.code.length, 0);
    assertEq(Trampoline(payable(instance)).DOMAIN_SEPARATOR(), domain);
    assertEq(factory.domainSeparator(), domain);
  }

  function test_domain_introspection_reports_deployment_chain_after_chain_id_change() public {
    uint256 deploymentChainId = block.chainid;
    bytes32 domain = factory.domainSeparator();

    vm.chainId(deploymentChainId + 1);

    (
      bytes1 fields,
      string memory name,
      string memory version,
      uint256 chainId,
      address verifyingContract,
      bytes32 salt,
      uint256[] memory extensions
    ) = factory.eip712Domain();

    assertEq(fields, hex'0f');
    assertEq(chainId, deploymentChainId);
    assertEq(verifyingContract, address(factory));
    assertEq(salt, bytes32(0));
    assertEq(extensions.length, 0);
    assertEq(
      keccak256(
        abi.encode(
          keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
          keccak256(bytes(name)),
          keccak256(bytes(version)),
          chainId,
          verifyingContract
        )
      ),
      domain
    );
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
