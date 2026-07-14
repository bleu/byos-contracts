// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @dev Swaps an exact sellAmount for an exact buyAmount from its own inventory.
/// The caller must have approved sellAmount beforehand.
contract MockRouter {
  function swap(
    IERC20 sellToken,
    IERC20 buyToken,
    uint256 sellAmount,
    uint256 buyAmount
  ) external {
    require(sellToken.transferFrom(msg.sender, address(this), sellAmount), 'MockRouter: pull failed');
    require(buyToken.transfer(msg.sender, buyAmount), 'MockRouter: pay failed');
  }
}
