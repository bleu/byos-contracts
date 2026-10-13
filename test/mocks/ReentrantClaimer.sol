// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC1271} from '@openzeppelin/contracts/interfaces/IERC1271.sol';
import {ITrampoline} from 'interfaces/ITrampoline.sol';

/// @dev Etched at a sub-solver's address to reenter claim from inside its own route.
/// Implements EIP-1271 (approving any digest) so the trampoline's contract-signer path
/// does not block the test — reentrancy and delta-check behaviour is what is under test.
contract ReentrantClaimer is IERC1271 {
  function isValidSignature(
    bytes32,
    bytes memory
  ) external pure returns (bytes4) {
    return IERC1271.isValidSignature.selector;
  }

  function reenter(
    ITrampoline trampoline,
    address token,
    address recipient
  ) external {
    trampoline.claimToken(token, recipient);
  }
}
