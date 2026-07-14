// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

contract Reverter {
  error Boom(uint256 code);

  function explode() external pure {
    revert Boom(42);
  }
}
