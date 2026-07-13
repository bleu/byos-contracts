// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @notice Minimal interface of GPv2AllowListAuthentication, the solver allowlist
/// gating GPv2Settlement.settle.
interface IGPv2Authentication {
    function manager() external view returns (address);
    function addSolver(address solver) external;
}
