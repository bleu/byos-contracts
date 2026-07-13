// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Trampoline} from "../contracts/Trampoline.sol";

/// @dev Mirrors GPv2Trade.Data.
struct GPv2TradeData {
    uint256 sellTokenIndex;
    uint256 buyTokenIndex;
    address receiver;
    uint256 sellAmount;
    uint256 buyAmount;
    uint32 validTo;
    bytes32 appData;
    uint256 feeAmount;
    uint256 flags;
    uint256 executedAmount;
    bytes signature;
}

/// @notice Minimal interface of the CoW Protocol settlement contract. Interactions use
/// Trampoline.Interaction, which mirrors GPv2Interaction.Data field-for-field.
interface IGPv2Settlement {
    function settle(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2TradeData[] calldata trades,
        Trampoline.Interaction[][3] calldata interactions
    ) external;
    function domainSeparator() external view returns (bytes32);
    function vaultRelayer() external view returns (address);
    function authenticator() external view returns (address);
}
