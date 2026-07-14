// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

/**
 * @title GPv2AllowListAuthentication
 * @notice Minimal interface of the solver allowlist gating GPv2Settlement.settle
 */
interface IGPv2Authentication {
  /**
   * @notice Returns the account allowed to add and remove solvers
   * @return _manager The manager address
   */
  function manager() external view returns (address _manager);

  /**
   * @notice Adds a solver to the allowlist
   * @param _solver The solver to allow
   */
  function addSolver(
    address _solver
  ) external;
}
