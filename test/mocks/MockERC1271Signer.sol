// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC1271} from '@openzeppelin/contracts/interfaces/IERC1271.sol';

/// @dev A minimal EIP-1271 signer whose owner pre-approves specific digests.
/// Used in tests to exercise the contract-signer path without depending on a
/// full Safe deploy.
contract MockERC1271Signer is IERC1271 {
  mapping(bytes32 => bool) public approvedDigests;

  function approveDigest(
    bytes32 _digest
  ) external {
    approvedDigests[_digest] = true;
  }

  function isValidSignature(bytes32 _hash, bytes memory) external view returns (bytes4) {
    return approvedDigests[_hash] ? IERC1271.isValidSignature.selector : bytes4(0);
  }
}

/// @dev An EIP-1271 signer whose isValidSignature always reverts.
/// Used to verify that a reverting contract signer produces Trampoline_InvalidSignature.
contract RevertingERC1271Signer is IERC1271 {
  error AlwaysReverts();

  function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
    revert AlwaysReverts();
  }
}
