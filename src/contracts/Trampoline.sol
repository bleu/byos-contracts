// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import {MessageHashUtils} from '@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol';

import {BUY_ETH_ADDRESS, ITrampoline, PROPOSAL_TYPEHASH} from 'interfaces/ITrampoline.sol';

contract Trampoline is ITrampoline {
  using SafeERC20 for IERC20;

  /// @inheritdoc ITrampoline
  address public immutable SUB_SOLVER;

  /// @inheritdoc ITrampoline
  address public immutable SETTLEMENT;

  /// @inheritdoc ITrampoline
  bytes32 public immutable DOMAIN_SEPARATOR;

  /**
   * @notice Wires the instance to its sub-solver, the settlement contract, and the
   * factory's EIP-712 domain
   * @param _subSolver Sub-solver address; proposal signatures must recover to it
   * @param _settlement GPv2Settlement address
   * @param _domainSeparator The factory's EIP-712 domain separator
   */
  constructor(
    address _subSolver,
    address _settlement,
    bytes32 _domainSeparator
  ) {
    SUB_SOLVER = _subSolver;
    SETTLEMENT = _settlement;
    DOMAIN_SEPARATOR = _domainSeparator;
  }

  /**
   * @notice Accepts native ETH mid-route (e.g. a WETH unwrap or an ETH-paying venue)
   */
  receive() external payable {}

  /// @inheritdoc ITrampoline
  function execute(
    Proposal calldata _proposal,
    Interaction[] calldata _interactions,
    address _buyToken,
    bytes calldata _signature
  ) external {
    if (msg.sender != SETTLEMENT) revert Trampoline_OnlySettlement();
    if (block.timestamp > _proposal.validUntil) revert Trampoline_ProposalExpired();

    bytes32 _structHash = keccak256(
      abi.encode(
        PROPOSAL_TYPEHASH,
        _proposal.orderUidHash,
        _proposal.sellAmount,
        _proposal.buyAmount,
        keccak256(abi.encode(_interactions)),
        _proposal.validUntil,
        _proposal.nonce
      )
    );
    bytes32 _digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, _structHash);
    if (ECDSA.recover(_digest, _signature) != SUB_SOLVER) revert Trampoline_InvalidSignature();

    for (uint256 _i = 0; _i < _interactions.length; ++_i) {
      Interaction calldata _interaction = _interactions[_i];
      (bool _success, bytes memory _returnData) =
        _interaction.target.call{value: _interaction.value}(_interaction.callData);
      if (!_success) {
        // Bubble the interaction's revert data so route failures are
        // attributable from the settlement trace.
        assembly ('memory-safe') {
          revert(add(_returnData, 0x20), mload(_returnData))
        }
      }
    }

    if (_buyToken == BUY_ETH_ADDRESS) {
      (bool _success,) = SETTLEMENT.call{value: _proposal.buyAmount}('');
      if (!_success) revert Trampoline_EthSettleBackFailed();
    } else {
      IERC20(_buyToken).safeTransfer(SETTLEMENT, _proposal.buyAmount);
    }
  }

  /// @inheritdoc ITrampoline
  function claim(
    address[] calldata _tokens,
    address _recipient
  ) external {
    if (msg.sender != SUB_SOLVER) revert Trampoline_OnlySubSolver();

    for (uint256 _i = 0; _i < _tokens.length; ++_i) {
      uint256 _amount;
      if (_tokens[_i] == BUY_ETH_ADDRESS) {
        _amount = address(this).balance;
        (bool _success,) = _recipient.call{value: _amount}('');
        if (!_success) revert Trampoline_EthClaimFailed();
      } else {
        IERC20 _token = IERC20(_tokens[_i]);
        _amount = _token.balanceOf(address(this));
        _token.safeTransfer(_recipient, _amount);
      }
      emit ResidueClaimed(_tokens[_i], _amount, _recipient);
    }
  }
}
