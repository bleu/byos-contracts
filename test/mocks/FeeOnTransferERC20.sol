// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/// @dev ERC-20 that burns a 1% fee on every non-mint, non-burn transfer.
/// Recipients receive `amount - fee`; `balanceOf` reflects the net amount.
contract FeeOnTransferERC20 is ERC20 {
  uint256 public constant FEE_BPS = 100; // 1%

  constructor() ERC20('Fee Token', 'FEE') {}

  function mint(
    address to,
    uint256 amount
  ) external {
    _mint(to, amount);
  }

  function _update(
    address from,
    address to,
    uint256 amount
  ) internal override {
    if (from != address(0) && to != address(0)) {
      uint256 fee = amount * FEE_BPS / 10_000;
      super._update(from, to, amount - fee);
      if (fee > 0) super._update(from, address(0), fee);
    } else {
      super._update(from, to, amount);
    }
  }
}
