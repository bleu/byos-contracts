// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract TestERC20 is ERC20 {
  constructor() ERC20('Test Token', 'TST') {}

  function mint(
    address to,
    uint256 amount
  ) external {
    _mint(to, amount);
  }
}
