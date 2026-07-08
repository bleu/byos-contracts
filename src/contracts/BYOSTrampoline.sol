// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @title BYOS Trampoline
/// @author CoW Protocol Developers
contract BYOSTrampoline {
    address public owner;

    event Executed(address indexed target, uint256 value, bytes data);

    error OnlyOwner();
    error ExecutionFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Execute a call to a target contract.
    /// @param target The address of the target contract.
    /// @param value The amount of ETH to send with the call.
    /// @param data The calldata to send.
    /// @return result The return data from the call.
    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (bytes memory result)
    {
        bool success;
        (success, result) = target.call{value: value}(data);
        if (!success) revert ExecutionFailed();
        emit Executed(target, value, data);
    }

    receive() external payable {}
}
