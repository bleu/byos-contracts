// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

/**
 * @title BYOS Trampoline Factory
 * @author CoW Protocol Developers
 * @notice CREATE2 deployer for per-sub-solver Trampoline instances and the EIP-712
 * domain anchor for proposal signatures (ADR-0005): signatures verify against this
 * factory's domain, so a factory redeployment cleanly invalidates old signatures.
 */
interface ITrampolineFactory {
  /*///////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice A sub-solver's Trampoline instance has been deployed
   * @param _subSolver The sub-solver the instance executes proposals for
   * @param _instance The deployed instance address
   */
  event TrampolineDeployed(address indexed _subSolver, address _instance);

  /*///////////////////////////////////////////////////////////////
                             VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the GPv2Settlement contract baked into every deployed instance
   * @return _settlement The settlement contract address
   */
  // solhint-disable-next-line func-name-mixedcase
  function SETTLEMENT() external view returns (address _settlement);

  /**
   * @notice Returns the Escrow that deployed this factory, baked into every deployed
   * instance as its submitter registry
   * @return _escrow The Escrow address
   */
  // solhint-disable-next-line func-name-mixedcase
  function ESCROW() external view returns (address _escrow);

  /*///////////////////////////////////////////////////////////////
                               LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Deploys the Trampoline instance for a sub-solver if it does not exist yet
   * @dev Idempotent and permissionless; called by Escrow.deposit on first deposit (ADR-0003)
   * @param _subSolver The sub-solver to deploy an instance for
   * @return _instance The instance address (freshly deployed or pre-existing)
   */
  function ensureDeployed(
    address _subSolver
  ) external returns (address _instance);

  /**
   * @notice Returns the EIP-712 domain separator proposal signatures are verified against
   * @return _domainSeparator The domain separator
   */
  function domainSeparator() external view returns (bytes32 _domainSeparator);

  /**
   * @notice Returns the deterministic CREATE2 address of a sub-solver's Trampoline instance
   * @param _subSolver The sub-solver to compute the address for
   * @return _trampoline The instance address, deployed or not
   */
  function addressOf(
    address _subSolver
  ) external view returns (address _trampoline);
}
