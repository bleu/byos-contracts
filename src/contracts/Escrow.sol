// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {
  AccessControlDefaultAdminRules
} from '@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol';

import {IEscrow} from 'interfaces/IEscrow.sol';
import {ITrampolineFactory} from 'interfaces/ITrampolineFactory.sol';

contract Escrow is AccessControlDefaultAdminRules, IEscrow {
  /// @inheritdoc IEscrow
  bytes32 public constant OPERATOR_ROLE = keccak256('OPERATOR_ROLE');

  /// @inheritdoc IEscrow
  ITrampolineFactory public immutable TRAMPOLINE_FACTORY;

  /// @inheritdoc IEscrow
  mapping(address _subSolver => uint256 _balance) public balances;

  /// @inheritdoc IEscrow
  mapping(address _subSolver => uint256 _requestedAt) public withdrawalRequestedAt;

  /// @inheritdoc IEscrow
  mapping(address _subSolver => bool _isFrozen) public frozen;

  /// @inheritdoc IEscrow
  uint256 public cooldownPeriod;

  /// @inheritdoc IEscrow
  uint256 public accumulatedDebits;

  /**
   * @notice Sets the initial roles and withdrawal cooldown
   * @param _adminTransferDelay Seconds the default-admin transfer must wait before acceptance
   * @param _admin Secure wallet (e.g. multisig) that owns the contract; granted DEFAULT_ADMIN_ROLE
   * @param _operator EOA used by the BYOS service for automated debit/freeze operations; granted OPERATOR_ROLE
   * @param _cooldownPeriod Time in seconds a sub-solver must wait after requesting withdrawal
   * @param _trampolineFactory Deployer of per-sub-solver Trampoline instances
   */
  constructor(
    uint48 _adminTransferDelay,
    address _admin,
    address _operator,
    uint256 _cooldownPeriod,
    ITrampolineFactory _trampolineFactory
  ) AccessControlDefaultAdminRules(_adminTransferDelay, _admin) {
    if (address(_trampolineFactory) == address(0)) revert Escrow_ZeroAddress();
    _grantRole(OPERATOR_ROLE, _operator);
    cooldownPeriod = _cooldownPeriod;
    TRAMPOLINE_FACTORY = _trampolineFactory;
  }

  /// @inheritdoc IEscrow
  function setCooldownPeriod(
    uint256 _period
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 _oldPeriod = cooldownPeriod;
    cooldownPeriod = _period;
    emit CooldownPeriodUpdated(_oldPeriod, _period);
  }

  /// @inheritdoc IEscrow
  function debit(
    address _subSolver,
    uint256 _amount,
    bytes32 _reason
  ) external onlyRole(OPERATOR_ROLE) {
    if (_amount > balances[_subSolver]) revert Escrow_InsufficientBalance();
    balances[_subSolver] -= _amount;
    // Track debits for later sweep to admin
    accumulatedDebits += _amount;
    emit Debited(_subSolver, _amount, _reason);
  }

  /// @inheritdoc IEscrow
  function freeze(
    address _subSolver
  ) external onlyRole(OPERATOR_ROLE) {
    frozen[_subSolver] = true;
    emit Frozen(_subSolver);
  }

  /// @inheritdoc IEscrow
  function unfreeze(
    address _subSolver
  ) external onlyRole(OPERATOR_ROLE) {
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

    address _admin = defaultAdmin();
    // Send accumulated debits to admin
    (bool _success,) = _admin.call{value: _amount}('');
    if (!_success) revert Escrow_TransferFailed();

    emit DebitsWithdrawn(_admin, _amount);
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
