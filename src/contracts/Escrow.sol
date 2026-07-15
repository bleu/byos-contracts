// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {
  AccessControlDefaultAdminRules
} from '@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

import {IEscrow} from 'interfaces/IEscrow.sol';
import {ITrampolineFactory} from 'interfaces/ITrampolineFactory.sol';

contract Escrow is ERC20, AccessControlDefaultAdminRules, IEscrow {
  /// @inheritdoc IEscrow
  bytes32 public constant OPERATOR_ROLE = keccak256('OPERATOR_ROLE');

  /// @inheritdoc IEscrow
  ITrampolineFactory public immutable TRAMPOLINE_FACTORY;

  /// @inheritdoc IEscrow
  mapping(address _subSolver => uint256 _requestedAt) public withdrawalRequestedAt;

  /// @inheritdoc IEscrow
  mapping(address _subSolver => bool _isFrozen) public frozen;

  /// @inheritdoc IEscrow
  uint256 public cooldownPeriod;

  /// @inheritdoc IEscrow
  uint256 public accumulatedDebits;

  /// @inheritdoc IEscrow
  bool public paused;

  /**
   * @notice Sets the initial roles, withdrawal cooldown, and ERC20 metadata
   * @param _adminTransferDelay Seconds the default-admin transfer must wait before acceptance
   * @param _admin Secure wallet (e.g. multisig) that owns the contract; granted DEFAULT_ADMIN_ROLE
   * @param _operator EOA used by the BYOS service for automated debit/freeze operations; granted OPERATOR_ROLE
   * @param _cooldownPeriod Time in seconds a sub-solver must wait after requesting withdrawal
   * @param _trampolineFactory Deployer of per-sub-solver Trampoline instances
   * @param _name ERC20 token name (e.g. "BYOS Escrow" or "BYOS Escrow (Gnosis)")
   * @param _symbol ERC20 token symbol (e.g. "BYOS")
   */
  constructor(
    uint48 _adminTransferDelay,
    address _admin,
    address _operator,
    uint256 _cooldownPeriod,
    ITrampolineFactory _trampolineFactory,
    string memory _name,
    string memory _symbol
  ) ERC20(_name, _symbol) AccessControlDefaultAdminRules(_adminTransferDelay, _admin) {
    if (address(_trampolineFactory) == address(0)) revert Escrow_ZeroAddress();
    _grantRole(OPERATOR_ROLE, _operator);
    cooldownPeriod = _cooldownPeriod;
    TRAMPOLINE_FACTORY = _trampolineFactory;
  }

  /// @dev Enforces transfer restrictions per ADR-0007 and deploys a Trampoline for transfer recipients:
  /// - Transfers: blocked if paused, sender/receiver frozen, or sender/receiver has pending withdrawal.
  ///   Deploys a Trampoline for the recipient via TRAMPOLINE_FACTORY.ensureDeployed.
  /// - Mints: blocked if receiver has pending withdrawal.
  /// - Burns: no restrictions — calling functions enforce their own constraints.
  function _update(
    address _from,
    address _to,
    uint256 _value
  ) internal virtual override {
    bool _isMint = (_from == address(0));
    bool _isBurn = (_to == address(0));

    if (!_isMint && !_isBurn) {
      // Transfer
      if (paused) revert Escrow_EnforcedPause();
      if (frozen[_from]) revert Escrow_AccountFrozen();
      if (frozen[_to]) revert Escrow_AccountFrozen();
      if (withdrawalRequestedAt[_from] != 0) revert Escrow_WithdrawalPending();
      if (withdrawalRequestedAt[_to] != 0) revert Escrow_WithdrawalPending();
    } else if (_isMint) {
      if (withdrawalRequestedAt[_to] != 0) revert Escrow_WithdrawalPending();
    }

    if (!_isBurn) {
      TRAMPOLINE_FACTORY.ensureDeployed(_to);
    }

    super._update(_from, _to, _value);
  }

  // --- Admin-only ---

  /// @inheritdoc IEscrow
  function setCooldownPeriod(
    uint256 _period
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 _oldPeriod = cooldownPeriod;
    cooldownPeriod = _period;
    emit CooldownPeriodUpdated(_oldPeriod, _period);
  }

  // --- Operator-only ---

  /// @inheritdoc IEscrow
  function debit(
    address _subSolver,
    uint256 _amount,
    bytes32 _reason
  ) external onlyRole(OPERATOR_ROLE) {
    if (_amount > balanceOf(_subSolver)) revert Escrow_InsufficientBalance();
    _burn(_subSolver, _amount);
    accumulatedDebits += _amount;
    emit Debited(_subSolver, _amount, _reason);
  }

  /// @inheritdoc IEscrow
  function freeze(
    address _subSolver
  ) external onlyRole(OPERATOR_ROLE) {
    if (frozen[_subSolver]) return;
    frozen[_subSolver] = true;
    emit Frozen(_subSolver);
  }

  /// @inheritdoc IEscrow
  function unfreeze(
    address _subSolver
  ) external onlyRole(OPERATOR_ROLE) {
    if (!frozen[_subSolver]) return;
    frozen[_subSolver] = false;
    emit Unfrozen(_subSolver);
  }

  /// @inheritdoc IEscrow
  function pause() external onlyRole(OPERATOR_ROLE) {
    if (paused) revert Escrow_EnforcedPause();
    paused = true;
    emit Paused(msg.sender);
  }

  /// @inheritdoc IEscrow
  function unpause() external onlyRole(OPERATOR_ROLE) {
    if (!paused) revert Escrow_ExpectedPause();
    paused = false;
    emit Unpaused(msg.sender);
  }

  // --- Sub-solver ---

  /// @inheritdoc IEscrow
  function requestWithdrawal() external {
    if (withdrawalRequestedAt[msg.sender] != 0) revert Escrow_WithdrawalAlreadyRequested();
    if (balanceOf(msg.sender) == 0) revert Escrow_InsufficientBalance();
    withdrawalRequestedAt[msg.sender] = block.timestamp;
    emit WithdrawalRequested(msg.sender);
  }

  /// @inheritdoc IEscrow
  function executeWithdrawal() external {
    if (withdrawalRequestedAt[msg.sender] == 0) revert Escrow_NoWithdrawalRequested();
    if (frozen[msg.sender]) revert Escrow_AccountFrozen();
    if (paused) revert Escrow_EnforcedPause();
    if (block.timestamp < withdrawalRequestedAt[msg.sender] + cooldownPeriod) revert Escrow_CooldownNotElapsed();

    uint256 _amount = balanceOf(msg.sender);
    if (_amount == 0) revert Escrow_NothingToWithdraw();

    // Reset withdrawal state and burn tokens before external call (CEI pattern)
    withdrawalRequestedAt[msg.sender] = 0;
    _burn(msg.sender, _amount);

    // Send ETH to the sub-solver
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

  // --- Anyone ---

  /// @inheritdoc IEscrow
  function deposit(
    address _subSolver
  ) external payable {
    if (msg.value == 0) revert Escrow_ZeroValue();
    _mint(_subSolver, msg.value);
    TRAMPOLINE_FACTORY.ensureDeployed(_subSolver);
    emit Deposited(_subSolver, msg.value);
  }

  /// @inheritdoc IEscrow
  function withdrawDebits() external {
    uint256 _amount = accumulatedDebits;
    if (_amount == 0) revert Escrow_NothingToWithdraw();
    accumulatedDebits = 0;

    address _admin = defaultAdmin();
    if (_admin == address(0)) revert Escrow_NoAdmin();
    (bool _success,) = _admin.call{value: _amount}('');
    if (!_success) revert Escrow_TransferFailed();

    emit DebitsWithdrawn(_admin, _amount);
  }

  // --- Views ---

  /// @inheritdoc IEscrow
  function effectiveBalance(
    address _subSolver
  ) external view returns (uint256 _effectiveBalance) {
    if (withdrawalRequestedAt[_subSolver] != 0) return 0;
    _effectiveBalance = balanceOf(_subSolver);
  }

  /// @inheritdoc IEscrow
  function withdrawableBalance() external view returns (uint256 _withdrawableBalance) {
    _withdrawableBalance = accumulatedDebits;
  }
}
