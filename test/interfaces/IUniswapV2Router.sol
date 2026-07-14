// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

interface IUniswapV2Router {
  function getAmountsOut(
    uint256 amountIn,
    address[] calldata path
  ) external view returns (uint256[] memory);
  function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external returns (uint256[] memory);
}
