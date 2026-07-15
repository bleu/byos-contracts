// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ITrampolineFactory} from 'interfaces/ITrampolineFactory.sol';

/**
 * @title BYOS Escrow
 * @author CoW Protocol Developers
 * @notice Per-chain, native-token ERC20 escrow holding sub-solver collateral keyed by sub-solver
 * address. Tokens are minted 1:1 with deposited ETH and burned on withdrawal or debit.
 * Sub-solvers may transfer tokens to migrate collateral (e.g. key rotation) but
 * approve/transferFrom are disabled — only direct transfer is supported.
 * Transfers are restricted by pause state, freeze state, and pending withdrawal status.
 * The operator (OPERATOR_ROLE) holds exclusive debit authority for revert penalties
 * (Track A) and EBBO passthrough (Track B). Debited funds are swept to the default admin.
 * Access control is provided by OpenZeppelin's AccessControlDefaultAdminRules:
 * the default admin manages roles and contract parameters, while the OPERATOR_ROLE
 * is granted to the automated BYOS service EOA.
 */
interface IEscrow {
  /*///////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Native token has been deposited into a sub-solver's escrow balance
   * @param _subSolver The credited sub-solver
   * @param _amount The deposited amount
   */
  event Deposited(address indexed _subSolver, uint256 _amount);

  /**
   * @notice A sub-solver's balance has been debited by the operator
   * @param _subSolver The debited sub-solver
   * @param _amount The debited amount
   * @param _reason An identifier for the debit (e.g. tx hash for Track A, claim ID for Track B)
   */
  event Debited(address indexed _subSolver, uint256 _amount, bytes32 _reason);

  /**
   * @notice A sub-solver has withdrawn its remaining balance
   * @param _subSolver The withdrawing sub-solver
   * @param _amount The withdrawn amount
   */
  event Withdrawn(address indexed _subSolver, uint256 _amount);

  /**
   * @notice A sub-solver has been frozen, blocking withdrawal execution and transfers
   * @param _subSolver The frozen sub-solver
   */
  event Frozen(address indexed _subSolver);

  /**
   * @notice A sub-solver has been unfrozen, allowing pending withdrawals and transfers to proceed
   * @param _subSolver The unfrozen sub-solver
   */
  event Unfrozen(address indexed _subSolver);

  /**
   * @notice Accumulated debits have been swept to the default admin
   * @param _to The recipient of the sweep
   * @param _amount The swept amount
   */
  event DebitsWithdrawn(address indexed _to, uint256 _amount);

  /**
   * @notice A sub-solver has requested withdrawal of its full balance
   * @param _subSolver The requesting sub-solver
   */
  event WithdrawalRequested(address indexed _subSolver);

  /**
   * @notice A sub-solver has cancelled its pending withdrawal request
   * @param _subSolver The cancelling sub-solver
   */
  event WithdrawalCancelled(address indexed _subSolver);

  /**
   * @notice The withdrawal cooldown period has been updated
   * @param _oldPeriod The previous cooldown period in seconds
   * @param _newPeriod The new cooldown period in seconds
   */
  event CooldownPeriodUpdated(uint256 _oldPeriod, uint256 _newPeriod);

  /**
   * @notice All transfers and withdrawal executions have been globally paused
   * @param _account The account that triggered the pause
   */
  event Paused(address indexed _account);

  /**
   * @notice The global pause has been lifted
   * @param _account The account that triggered the unpause
   */
  event Unpaused(address indexed _account);

  /*///////////////////////////////////////////////////////////////
                              ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Throws if the sub-solver's balance is insufficient for the operation
   */
  error Escrow_InsufficientBalance();

  /**
   * @notice Throws if a native token transfer fails
   */
  error Escrow_TransferFailed();

  /**
   * @notice Throws if the caller has no pending withdrawal request
   */
  error Escrow_NoWithdrawalRequested();

  /**
   * @notice Throws if the withdrawal cooldown period has not elapsed yet
   */
  error Escrow_CooldownNotElapsed();

  /**
   * @notice Throws if the sub-solver is frozen
   */
  error Escrow_AccountFrozen();

  /**
   * @notice Throws if the caller already has a pending withdrawal request
   */
  error Escrow_WithdrawalAlreadyRequested();

  /**
   * @notice Throws if there is nothing to withdraw
   */
  error Escrow_NothingToWithdraw();

  /**
   * @notice Throws if the operation is blocked by a global pause
   */
  error Escrow_EnforcedPause();

  /**
   * @notice Throws if trying to unpause when not paused
   */
  error Escrow_ExpectedPause();

  /**
   * @notice Throws if trying to use approve or transferFrom (disabled)
   */
  error Escrow_AllowancesDisabled();

  /**
   * @notice Throws if a transfer involves an address with a pending withdrawal
   */
  error Escrow_WithdrawalPending();

  /**
   * @notice Throws if a zero-value deposit is attempted
   */
  error Escrow_ZeroValue();

  /**
   * @notice Throws if the default admin has been renounced
   */
  error Escrow_NoAdmin();

  /**
   * @notice Throws if a required address parameter is the zero address
   */
  error Escrow_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                             VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Role identifier for the operator (automated BYOS service EOA)
   * @return _operatorRole The keccak256 hash of "OPERATOR_ROLE"
   */
  // solhint-disable-next-line func-name-mixedcase
  function OPERATOR_ROLE() external view returns (bytes32 _operatorRole);

  /**
   * @notice Returns the timestamp of a sub-solver's pending withdrawal request, or 0 if none
   * @param _subSolver The sub-solver to query
   * @return _requestedAt The request timestamp, or 0 if no request is pending
   */
  function withdrawalRequestedAt(
    address _subSolver
  ) external view returns (uint256 _requestedAt);

  /**
   * @notice Returns whether a sub-solver is frozen (blocks executeWithdrawal and transfers)
   * @param _subSolver The sub-solver to query
   * @return _isFrozen True if the sub-solver is frozen
   */
  function frozen(
    address _subSolver
  ) external view returns (bool _isFrozen);

  /**
   * @notice Returns the seconds a sub-solver must wait between requestWithdrawal and executeWithdrawal
   * @return _cooldownPeriod The cooldown period in seconds
   */
  function cooldownPeriod() external view returns (uint256 _cooldownPeriod);

  /**
   * @notice Returns the debit pool not yet swept to the default admin via withdrawDebits
   * @return _accumulatedDebits The accumulated debit amount
   */
  function accumulatedDebits() external view returns (uint256 _accumulatedDebits);

  /**
   * @notice Returns whether all transfers and withdrawal executions are globally paused
   * @return _paused True if the contract is paused
   */
  function paused() external view returns (bool _paused);

  /**
   * @notice Returns the factory that deploys a sub-solver's Trampoline on first deposit (ADR-0003)
   * @return _trampolineFactory The Trampoline factory
   */
  // solhint-disable-next-line func-name-mixedcase
  function TRAMPOLINE_FACTORY() external view returns (ITrampolineFactory _trampolineFactory);

  /*///////////////////////////////////////////////////////////////
                               LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Updates the withdrawal cooldown period
   * @dev Only callable by the default admin
   * @param _period The new cooldown period in seconds
   */
  function setCooldownPeriod(
    uint256 _period
  ) external;

  /**
   * @notice Debits a sub-solver's balance
   * @dev Used for revert penalties (Track A) and EBBO passthrough (Track B).
   * Only callable by accounts with OPERATOR_ROLE. Burns ERC20 tokens and
   * adds the equivalent ETH to accumulatedDebits.
   * @param _subSolver The sub-solver whose balance to debit
   * @param _amount The amount to debit in native token
   * @param _reason An identifier for the debit (e.g. tx hash for Track A, claim ID for Track B)
   */
  function debit(
    address _subSolver,
    uint256 _amount,
    bytes32 _reason
  ) external;

  /**
   * @notice Freezes a sub-solver, blocking withdrawal execution and transfers
   * @dev Used during Track B investigations. Only callable by accounts with OPERATOR_ROLE.
   * No-op if the sub-solver is already frozen.
   * @param _subSolver The sub-solver to freeze
   */
  function freeze(
    address _subSolver
  ) external;

  /**
   * @notice Unfreezes a sub-solver, allowing pending withdrawals and transfers to proceed
   * @dev Only callable by accounts with OPERATOR_ROLE. No-op if not frozen.
   * @param _subSolver The sub-solver to unfreeze
   */
  function unfreeze(
    address _subSolver
  ) external;

  /**
   * @notice Pauses all transfers and withdrawal executions. Emergency brake.
   * @dev Only callable by accounts with OPERATOR_ROLE
   */
  function pause() external;

  /**
   * @notice Unpauses, restoring normal transfer and withdrawal operations
   * @dev Only callable by accounts with OPERATOR_ROLE
   */
  function unpause() external;

  /**
   * @notice Requests withdrawal of the caller's full balance
   * @dev Effective balance drops to 0 immediately; the sub-solver must wait for the
   * cooldown period before executing
   */
  function requestWithdrawal() external;

  /**
   * @notice Executes a pending withdrawal after cooldown has elapsed
   * @dev Blocked if the caller is frozen or the contract is paused.
   * Burns ERC20 tokens and sends the corresponding ETH.
   */
  function executeWithdrawal() external;

  /**
   * @notice Cancels a pending withdrawal request, restoring effective balance
   * @dev Can be called regardless of freeze or pause state
   */
  function cancelWithdrawal() external;

  /**
   * @notice Deposits native token into a sub-solver's escrow balance (mints ERC20 tokens 1:1)
   * @dev Reverts on zero-value deposits. Blocked if the receiver has a pending withdrawal.
   * The first deposit for a sub-solver also deploys its Trampoline instance, so the
   * deploy gas is paid by the depositing party (ADR-0003, deploy-at-deposit-time).
   * @param _subSolver The sub-solver address to credit
   */
  function deposit(
    address _subSolver
  ) external payable;

  /**
   * @notice Sweeps accumulated debits to the default admin
   * @dev Callable by anyone. Reverts if the admin has been renounced.
   */
  function withdrawDebits() external;

  /**
   * @notice Returns a sub-solver's effective balance for proposal eligibility
   * @dev Returns 0 if a withdrawal is pending, otherwise returns the balanceOf
   * @param _subSolver The sub-solver to query
   * @return _effectiveBalance The effective balance
   */
  function effectiveBalance(
    address _subSolver
  ) external view returns (uint256 _effectiveBalance);

  /**
   * @notice Returns the amount of accumulated debits available for default admin withdrawal
   * @return _withdrawableBalance The withdrawable debit amount
   */
  function withdrawableBalance() external view returns (uint256 _withdrawableBalance);
}
