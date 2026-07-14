// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IEscrow} from 'interfaces/IEscrow.sol';
import {ITrampolineFactory} from 'interfaces/ITrampolineFactory.sol';

contract Escrow is IEscrow {
  /// @inheritdoc IEscrow
  ITrampolineFactory public immutable TRAMPOLINE_FACTORY;

  /// @inheritdoc IEscrow
  mapping(address _subSolver => uint256 _balance) public balances;

  /// @inheritdoc IEscrow
  mapping(address _subSolver => uint256 _requestedAt) public withdrawalRequestedAt;

  /// @inheritdoc IEscrow
  mapping(address _subSolver => bool _isFrozen) public frozen;

  /// @inheritdoc IEscrow
  address public owner;

  /// @inheritdoc IEscrow
  address public pendingOwner;

  /// @inheritdoc IEscrow
  address public operator;

  /// @inheritdoc IEscrow
  uint256 public cooldownPeriod;

  /// @inheritdoc IEscrow
  uint256 public accumulatedDebits;

  /**
   * @notice Reverts in case the function was not called by the owner of the contract
   */
  modifier onlyOwner() {
    if (msg.sender != owner) revert Escrow_OnlyOwner();
    _;
  }

  /**
   * @notice Reverts in case the function was not called by the operator
   */
  modifier onlyOperator() {
    if (msg.sender != operator) revert Escrow_OnlyOperator();
    _;
  }

  /**
   * @notice Sets the initial roles and withdrawal cooldown
   * @param _owner Secure wallet (e.g. multisig) that owns the contract; receives debited funds
   * @param _operator EOA used by the BYOS service for automated debit/freeze operations
   * @param _cooldownPeriod Time in seconds a sub-solver must wait after requesting withdrawal
   * @param _trampolineFactory Deployer of per-sub-solver Trampoline instances
   */
  constructor(
    address _owner,
    address _operator,
    uint256 _cooldownPeriod,
    ITrampolineFactory _trampolineFactory
  ) {
    if (_owner == address(0) || address(_trampolineFactory) == address(0)) revert Escrow_ZeroAddress();
    owner = _owner;
    operator = _operator;
    cooldownPeriod = _cooldownPeriod;
    TRAMPOLINE_FACTORY = _trampolineFactory;
  }

  /// @inheritdoc IEscrow
  function setOperator(
    address _newOperator
  ) external onlyOwner {
    address _oldOperator = operator;
    operator = _newOperator;
    emit OperatorUpdated(_oldOperator, _newOperator);
  }

  /// @inheritdoc IEscrow
  function setCooldownPeriod(
    uint256 _period
  ) external onlyOwner {
    uint256 _oldPeriod = cooldownPeriod;
    cooldownPeriod = _period;
    emit CooldownPeriodUpdated(_oldPeriod, _period);
  }

  /// @inheritdoc IEscrow
  function transferOwnership(
    address _newOwner
  ) external onlyOwner {
    if (_newOwner == address(0)) revert Escrow_ZeroAddress();
    pendingOwner = _newOwner;
    emit OwnershipTransferStarted(owner, _newOwner);
  }

  /// @inheritdoc IEscrow
  function acceptOwnership() external {
    if (msg.sender != pendingOwner) revert Escrow_OnlyPendingOwner();
    address _oldOwner = owner;
    owner = msg.sender;
    pendingOwner = address(0);
    emit OwnershipTransferred(_oldOwner, msg.sender);
  }

  /// @inheritdoc IEscrow
  function debit(
    address _subSolver,
    uint256 _amount,
    bytes32 _reason
  ) external onlyOperator {
    if (_amount > balances[_subSolver]) revert Escrow_InsufficientBalance();
    balances[_subSolver] -= _amount;
    // Track debits for later sweep to owner
    accumulatedDebits += _amount;
    emit Debited(_subSolver, _amount, _reason);
  }

  /// @inheritdoc IEscrow
  function freeze(
    address _subSolver
  ) external onlyOperator {
    frozen[_subSolver] = true;
    emit Frozen(_subSolver);
  }

  /// @inheritdoc IEscrow
  function unfreeze(
    address _subSolver
  ) external onlyOperator {
    frozen[_subSolver] = false;
    emit Unfrozen(_subSolver);
  }

  /// @inheritdoc IEscrow
  function requestWithdrawal() external {
    if (withdrawalRequestedAt[msg.sender] != 0) revert Escrow_WithdrawalAlreadyRequested();
    if (balances[msg.sender] == 0) revert Escrow_InsufficientBalance();
    withdrawalRequestedAt[msg.sender] = block.timestamp;
    emit WithdrawalRequested(msg.sender);
  }

  /// @inheritdoc IEscrow
  function executeWithdrawal() external {
    if (withdrawalRequestedAt[msg.sender] == 0) revert Escrow_NoWithdrawalRequested();
    if (frozen[msg.sender]) revert Escrow_AccountFrozen();
    if (block.timestamp < withdrawalRequestedAt[msg.sender] + cooldownPeriod) revert Escrow_CooldownNotElapsed();

    uint256 _amount = balances[msg.sender];
    if (_amount == 0) revert Escrow_NothingToWithdraw();

    // Reset sub-solver state before external call (CEI pattern)
    balances[msg.sender] = 0;
    withdrawalRequestedAt[msg.sender] = 0;

    // Send remaining balance (deposits - debits) to the sub-solver
    (bool _success,) = msg.sender.call{value: _amount}('');
    if (!_success) revert Escrow_TransferFailed();

    emit Withdrawn(msg.sender, _amount);
  }

  /// @inheritdoc IEscrow
  function cancelWithdrawal() external {
    if (withdrawalRequestedAt[msg.sender] == 0) revert Escrow_NoWithdrawalRequested();
    withdrawalRequestedAt[msg.sender] = 0;
    emit WithdrawalCancelled(msg.sender);
  }

  /// @inheritdoc IEscrow
  function deposit(
    address _subSolver
  ) external payable {
    balances[_subSolver] += msg.value;
    TRAMPOLINE_FACTORY.ensureDeployed(_subSolver);
    emit Deposited(_subSolver, msg.value);
  }

  /// @inheritdoc IEscrow
  function withdrawDebits() external {
    uint256 _amount = accumulatedDebits;
    if (_amount == 0) revert Escrow_NothingToWithdraw();
    accumulatedDebits = 0;

    // Send accumulated debits to owner
    (bool _success,) = owner.call{value: _amount}('');
    if (!_success) revert Escrow_TransferFailed();

    emit DebitsWithdrawn(owner, _amount);
  }

  /// @inheritdoc IEscrow
  function balance(
    address _subSolver
  ) external view returns (uint256 _balance) {
    _balance = balances[_subSolver];
  }

  /// @inheritdoc IEscrow
  function effectiveBalance(
    address _subSolver
  ) external view returns (uint256 _effectiveBalance) {
    if (withdrawalRequestedAt[_subSolver] != 0) return 0;
    _effectiveBalance = balances[_subSolver];
  }

  /// @inheritdoc IEscrow
  function withdrawableBalance() external view returns (uint256 _withdrawableBalance) {
    _withdrawableBalance = accumulatedDebits;
  }
}
