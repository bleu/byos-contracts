// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestERC20 is ERC20 {
    constructor() ERC20("Test Token", "TST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "MockWETH: ETH transfer failed");
    }
}

contract Reverter {
    error Boom(uint256 code);

    function explode() external pure {
        revert Boom(42);
    }
}

/// @dev Swaps an exact sellAmount for an exact buyAmount from its own inventory.
/// The caller must have approved sellAmount beforehand.
contract MockRouter {
    function swap(IERC20 sellToken, IERC20 buyToken, uint256 sellAmount, uint256 buyAmount) external {
        require(sellToken.transferFrom(msg.sender, address(this), sellAmount), "MockRouter: pull failed");
        require(buyToken.transfer(msg.sender, buyAmount), "MockRouter: pay failed");
    }
}
