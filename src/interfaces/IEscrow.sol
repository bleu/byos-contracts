// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {ITrampolineFactory} from 'interfaces/ITrampolineFactory.sol';

/**
 * @title BYOS Escrow
 * @author CoW Protocol Developers
 * @notice Per-chain, native-token escrow holding sub-solver collateral keyed by sub-solver
 * address. Anyone may deposit; the sub-solver withdraws subject to a cooldown.
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
   * @notice A sub-solver has been frozen, blocking withdrawal execution
   * @param _subSolver The frozen sub-solver
   */
  event Frozen(address indexed _subSolver);

  /**
   * @notice A sub-solver has been unfrozen, allowing pending withdrawals to proceed
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
   * @notice Returns the current balance of a sub-solver (increased by deposits, decreased by debits)
   * @param _subSolver The sub-solver to query
   * @return _balance The sub-solver's current balance
   */
  function balances(
    address _subSolver
  ) external view returns (uint256 _balance);

  /**
   * @notice Returns the timestamp of a sub-solver's pending withdrawal request, or 0 if none
   * @param _subSolver The sub-solver to query
   * @return _requestedAt The request timestamp, or 0 if no request is pending
   */
  function withdrawalRequestedAt(
    address _subSolver
  ) external view returns (uint256 _requestedAt);

  /**
   * @notice Returns whether a sub-solver is frozen (blocks executeWithdrawal)
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
   * Only callable by accounts with OPERATOR_ROLE.
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
   * @notice Freezes a sub-solver, blocking withdrawal execution
   * @dev Used during Track B investigations. Only callable by accounts with OPERATOR_ROLE.
   * @param _subSolver The sub-solver to freeze
   */
  function freeze(
    address _subSolver
  ) external;

  /**
   * @notice Unfreezes a sub-solver, allowing pending withdrawals to proceed
   * @dev Only callable by accounts with OPERATOR_ROLE
   * @param _subSolver The sub-solver to unfreeze
   */
  function unfreeze(
    address _subSolver
  ) external;

  /**
   * @notice Requests withdrawal of the caller's full balance
   * @dev Effective balance drops to 0 immediately; the sub-solver must wait for the
   * cooldown period before executing
   */
  function requestWithdrawal() external;

  /**
   * @notice Executes a pending withdrawal after cooldown has elapsed
   * @dev Blocked if the caller is frozen
   */
  function executeWithdrawal() external;

  /**
   * @notice Cancels a pending withdrawal request, restoring effective balance
   * @dev Can be called regardless of freeze state
   */
  function cancelWithdrawal() external;

  /**
   * @notice Deposits native token into a sub-solver's escrow balance
   * @dev The first deposit for a sub-solver also deploys its Trampoline instance, so the
   * deploy gas is paid by the depositing party (ADR-0003, deploy-at-deposit-time)
   * @param _subSolver The sub-solver address to credit
   */
  function deposit(
    address _subSolver
  ) external payable;

  /**
   * @notice Sweeps accumulated debits to the default admin
   * @dev Callable by anyone
   */
  function withdrawDebits() external;

  /**
   * @notice Returns a sub-solver's current balance
   * @param _subSolver The sub-solver to query
   * @return _balance The sub-solver's current balance
   */
  function balance(
    address _subSolver
  ) external view returns (uint256 _balance);

  /**
   * @notice Returns a sub-solver's effective balance for proposal eligibility
   * @dev Returns 0 if a withdrawal is pending, otherwise returns the balance
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
