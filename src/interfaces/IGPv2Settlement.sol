// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ITrampoline} from 'interfaces/ITrampoline.sol';

/**
 * @notice Mirrors GPv2Trade.Data
 * @param sellTokenIndex Index of the sell token in the settlement's token array
 * @param buyTokenIndex Index of the buy token in the settlement's token array
 * @param receiver The order's buy token recipient
 * @param sellAmount The order's sell amount
 * @param buyAmount The order's buy amount (limit)
 * @param validTo The order's expiry timestamp
 * @param appData The order's app data hash
 * @param feeAmount The order's fee amount in sell token
 * @param flags Encoded order kind, fill behavior, balance locations, and signing scheme
 * @param executedAmount The amount to execute (sell amount for fill-or-kill sell orders)
 * @param signature The order owner's signature
 */
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

/**
 * @title GPv2Settlement
 * @notice Minimal interface of the CoW Protocol settlement contract. Interactions use
 * ITrampoline.Interaction, which mirrors GPv2Interaction.Data field-for-field.
 */
interface IGPv2Settlement {
  /**
   * @notice Settles a batch of trades against the given clearing prices and interactions
   * @param _tokens The tokens traded in the batch
   * @param _clearingPrices The clearing price of each token, indexed like _tokens
   * @param _trades The trades to settle
   * @param _interactions The pre-, intra-, and post-settlement interactions
   */
  function settle(
    address[] calldata _tokens,
    uint256[] calldata _clearingPrices,
    GPv2TradeData[] calldata _trades,
    ITrampoline.Interaction[][3] calldata _interactions
  ) external;

  /**
   * @notice Returns the settlement contract's EIP-712 domain separator for order signatures
   * @return _domainSeparator The domain separator
   */
  function domainSeparator() external view returns (bytes32 _domainSeparator);

  /**
   * @notice Returns the vault relayer users approve to pull their sell tokens
   * @return _vaultRelayer The vault relayer address
   */
  function vaultRelayer() external view returns (address _vaultRelayer);

  /**
   * @notice Returns the allowlist contract gating settle to authorized solvers
   * @return _authenticator The authenticator address
   */
  function authenticator() external view returns (address _authenticator);
}
