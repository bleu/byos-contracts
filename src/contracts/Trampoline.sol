// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {BUY_ETH_ADDRESS, ITrampoline, PROPOSAL_TYPEHASH} from 'interfaces/ITrampoline.sol';

/// @dev Inlined from Escrow.SUBMITTER_ROLE to avoid an external call on every execute
bytes32 constant SUBMITTER_ROLE = keccak256('SUBMITTER_ROLE');

contract Trampoline is ITrampoline {
  using SafeERC20 for IERC20;

  /// @inheritdoc ITrampoline
  address public immutable SUB_SOLVER;

  /// @inheritdoc ITrampoline
  address public immutable SETTLEMENT;

  /// @inheritdoc ITrampoline
  bytes32 public immutable DOMAIN_SEPARATOR;

  /// @inheritdoc ITrampoline
  address public immutable ESCROW;

  /**
   * @notice Wires the instance to its sub-solver, the settlement contract, the
   * factory's EIP-712 domain, and the Escrow acting as submitter registry
   * @param _subSolver Sub-solver address; proposal signatures must recover to it
   * @param _settlement GPv2Settlement address
   * @param _domainSeparator The factory's EIP-712 domain separator
   * @param _escrow Escrow whose SUBMITTER_ROLE gates settlement submission
   */
  constructor(
    address _subSolver,
    address _settlement,
    bytes32 _domainSeparator,
    address _escrow
  ) {
    SUB_SOLVER = _subSolver;
    SETTLEMENT = _settlement;
    DOMAIN_SEPARATOR = _domainSeparator;
    ESCROW = _escrow;
  }

  /**
   * @notice Accepts native ETH mid-route (e.g. a WETH unwrap or an ETH-paying venue)
   */
  receive() external payable {}

  /// @inheritdoc ITrampoline
  function execute(
    Proposal calldata _proposal,
    Interaction[] calldata _interactions,
    address,
    address _buyToken,
    bytes calldata _signature
  ) external {
    if (msg.sender != SETTLEMENT) revert Trampoline_OnlySettlement();
    // Settlements are permissionless at the protocol level: once this proposal's
    // signature is public calldata, any allow-listed CoW solver could replay it
    // (or front-run it) in its own settlement.
    // tx.origin identifies the submitting solver; only BYOS's own EOAs pass.
    if (!IAccessControl(ESCROW).hasRole(SUBMITTER_ROLE, tx.origin)) {
      revert Trampoline_UnauthorizedSubmitter();
    }
    if (block.timestamp > _proposal.validUntil) revert Trampoline_ProposalExpired();

    _verifySignature(_proposal, _interactions, _signature);

    uint256 _buyBalanceBefore = _settlementBuyTokenBalance(_buyToken);

    for (uint256 _i = 0; _i < _interactions.length; ++_i) {
      Interaction calldata _interaction = _interactions[_i];
      address _target = _interaction.target;
      uint256 _value = _interaction.value;
      bytes calldata _callData = _interaction.callData;
      // Skip return data allocation on success — only copy on revert to
      // bubble the interaction's error for settlement-trace attribution.
      assembly ('memory-safe') {
        let _ptr := mload(0x40)
        calldatacopy(_ptr, _callData.offset, _callData.length)
        let _success := call(gas(), _target, _value, _ptr, _callData.length, 0, 0)
        if iszero(_success) {
          returndatacopy(_ptr, 0, returndatasize())
          revert(_ptr, returndatasize())
        }
      }
    }

    uint256 _delta = _settlementBuyTokenBalance(_buyToken) - _buyBalanceBefore;
    if (_delta < _proposal.buyAmount) revert Trampoline_FloorNotMet(_delta, _proposal.buyAmount);

    emit Executed(_proposal.orderUidHash, _delta, _proposal.buyAmount);
  }

  /// @dev Verifies the sub-solver's EIP-712 signature over the proposal and
  /// interactions using inline assembly for hashing and raw ecrecover
  function _verifySignature(
    Proposal calldata _proposal,
    Interaction[] calldata _interactions,
    bytes calldata _signature
  ) internal view {
    bytes32 _interactionsHash;
    {
      bytes memory _encoded = abi.encode(_interactions);
      assembly ('memory-safe') {
        _interactionsHash := keccak256(add(_encoded, 0x20), mload(_encoded))
      }
    }

    bytes32 _structHash;
    bytes32 _typeHash = PROPOSAL_TYPEHASH;
    assembly ('memory-safe') {
      let _ptr := mload(0x40)
      mstore(_ptr, _typeHash)
      mstore(add(_ptr, 0x20), calldataload(_proposal)) // orderUidHash
      mstore(add(_ptr, 0x40), calldataload(add(_proposal, 0x20))) // sellAmount
      mstore(add(_ptr, 0x60), calldataload(add(_proposal, 0x40))) // buyAmount
      mstore(add(_ptr, 0x80), _interactionsHash)
      mstore(add(_ptr, 0xa0), calldataload(add(_proposal, 0x60))) // validUntil
      mstore(add(_ptr, 0xc0), calldataload(add(_proposal, 0x80))) // nonce
      _structHash := keccak256(_ptr, 0xe0)
    }

    bytes32 _digest;
    bytes32 _domainSep = DOMAIN_SEPARATOR;
    assembly ('memory-safe') {
      let _ptr := mload(0x40)
      mstore(_ptr, 0x1901000000000000000000000000000000000000000000000000000000000000)
      mstore(add(_ptr, 0x02), _domainSep)
      mstore(add(_ptr, 0x22), _structHash)
      _digest := keccak256(_ptr, 0x42)
    }

    // Raw ecrecover — skip OZ ECDSA library's malleability checks.
    // The signature format (r || s || v) is fixed by the BYOS service; nonce
    // handles replay, so s-malleability is not a concern.
    address _recovered;
    assembly ('memory-safe') {
      let _ptr := mload(0x40)
      mstore(_ptr, _digest)
      mstore(add(_ptr, 0x20), byte(0, calldataload(add(_signature.offset, 0x40))))
      mstore(add(_ptr, 0x40), calldataload(_signature.offset)) // r
      mstore(add(_ptr, 0x60), calldataload(add(_signature.offset, 0x20))) // s
      pop(staticcall(gas(), 0x01, _ptr, 0x80, _ptr, 0x20))
      _recovered := mload(_ptr)
    }
    if (_recovered != SUB_SOLVER) revert Trampoline_InvalidSignature();
  }

  /// @dev Reads the settlement's balance of `_buyToken`; native ETH when BUY_ETH_ADDRESS
  function _settlementBuyTokenBalance(
    address _buyToken
  ) internal view returns (uint256 _balance) {
    _balance = _buyToken == BUY_ETH_ADDRESS ? SETTLEMENT.balance : IERC20(_buyToken).balanceOf(SETTLEMENT);
  }

  /// @inheritdoc ITrampoline
  function claimToken(
    address _token,
    address _recipient
  ) external {
    if (msg.sender != SUB_SOLVER) revert Trampoline_OnlySubSolver();

    _claimToken(_token, _recipient);
  }

  /// @inheritdoc ITrampoline
  function claimTokens(
    address[] calldata _tokens,
    address _recipient
  ) external {
    if (msg.sender != SUB_SOLVER) revert Trampoline_OnlySubSolver();

    for (uint256 _i = 0; _i < _tokens.length; ++_i) {
      _claimToken(_tokens[_i], _recipient);
    }
  }

  /**
   * @notice Transfers the instance's full balance of `_token` to `_recipient`
   * @param _token The token to claim; BUY_ETH_ADDRESS for native ETH
   * @param _recipient The address receiving the claimed balance
   */
  function _claimToken(
    address _token,
    address _recipient
  ) internal {
    uint256 _amount;
    if (_token == BUY_ETH_ADDRESS) {
      _amount = address(this).balance;
      if (_amount == 0) return;
      (bool _success,) = _recipient.call{value: _amount}('');
      if (!_success) revert Trampoline_EthClaimFailed();
    } else {
      _amount = IERC20(_token).balanceOf(address(this));
      if (_amount == 0) return;
      IERC20(_token).safeTransfer(_recipient, _amount);
    }
    emit ResidueClaimed(_token, _amount, _recipient);
  }
}
