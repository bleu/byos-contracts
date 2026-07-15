// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ITrampoline} from 'interfaces/ITrampoline.sol';

/// @dev Etched at a sub-solver's address to reenter claim from inside its own route.
contract ReentrantClaimer {
  function reenter(
    ITrampoline trampoline,
    address token,
    address recipient
  ) external {
    address[] memory tokens = new address[](1);
    tokens[0] = token;
    trampoline.claim(tokens, recipient);
  }
}
