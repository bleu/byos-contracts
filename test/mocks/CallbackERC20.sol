// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/// @dev ERC-20 that fires an arbitrary callback on the first non-mint transfer
/// after arming. Used to simulate ERC-777-style transfer hooks in tests.
contract CallbackERC20 is ERC20 {
  address public callbackTarget;
  bytes public callbackData;
  bool public armed;

  constructor() ERC20('Callback Token', 'CB') {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  /// @dev Arm the callback. The next non-mint, non-burn transfer will call
  /// `target` with `data`. The callback fires once then disarms.
  function arm(address target, bytes calldata data) external {
    callbackTarget = target;
    callbackData = data;
    armed = true;
  }

  function _update(address from, address to, uint256 amount) internal override {
    super._update(from, to, amount);
    if (armed && from != address(0) && to != address(0)) {
      armed = false;
      // Low-level call: swallow failure so the transfer itself completes.
      (bool _success,) = callbackTarget.call(callbackData);
      (_success); // silence unused-variable warning
    }
  }
}
