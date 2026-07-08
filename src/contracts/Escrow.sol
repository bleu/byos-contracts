// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

/// @title BYOS Escrow
/// @author CoW Protocol Developers
/// @notice Per-chain, native-token escrow holding sub-solver collateral keyed by sub-solver address.
/// Anyone may deposit; the sub-solver withdraws subject to a cooldown.
/// The operator holds exclusive debit authority for revert penalties (Track A)
/// and EBBO passthrough (Track B). Debited funds are swept to the owner.
contract Escrow {
    // --- State ---
    mapping(address => uint256) public deposits;
    mapping(address => uint256) public withdrawalRequestedAt;
    mapping(address => uint256) public totalDebited;
    mapping(address => bool) public frozen;

    address public owner;
    address public operator;
    uint256 public cooldownPeriod;
    uint256 public accumulatedDebits;

    // --- Events ---
    event Deposited(address indexed subSolver, uint256 amount);
    event Debited(address indexed subSolver, uint256 amount, bytes32 reason);
    event Withdrawn(address indexed subSolver, uint256 amount);
    event Frozen(address indexed subSolver);
    event Unfrozen(address indexed subSolver);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event DebitsWithdrawn(address indexed to, uint256 amount);
    event WithdrawalRequested(address indexed subSolver);
    event WithdrawalCancelled(address indexed subSolver);
    event CooldownPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // --- Errors ---
    error OnlyOwner();
    error OnlyOperator();
    error InsufficientBalance();
    error TransferFailed();
    error NoWithdrawalRequested();
    error CooldownNotElapsed();
    error AccountFrozen();
    error WithdrawalAlreadyRequested();
    error ZeroAddress();
    error NothingToWithdraw();

    // --- Modifiers ---
    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier onlyOperator() {
        _onlyOperator();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert OnlyOwner();
    }

    function _onlyOperator() internal view {
        if (msg.sender != operator) revert OnlyOperator();
    }

    /// @param _owner Secure wallet (e.g. multisig) that owns the contract. Receives debited funds.
    /// @param _operator EOA used by the BYOS service for automated debit/freeze operations.
    /// @param _cooldownPeriod Time in seconds a sub-solver must wait after requesting withdrawal.
    constructor(address _owner, address _operator, uint256 _cooldownPeriod) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        operator = _operator;
        cooldownPeriod = _cooldownPeriod;
    }

    // --- Owner-only ---

    /// @notice Replace the operator address.
    function setOperator(address newOperator) external onlyOwner {
        address oldOperator = operator;
        operator = newOperator;
        emit OperatorUpdated(oldOperator, newOperator);
    }

    /// @notice Update the withdrawal cooldown period.
    function setCooldownPeriod(uint256 period) external onlyOwner {
        uint256 oldPeriod = cooldownPeriod;
        cooldownPeriod = period;
        emit CooldownPeriodUpdated(oldPeriod, period);
    }

    /// @notice Transfer contract ownership to a new address.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // --- Operator-only ---

    /// @notice Debit a sub-solver's balance. Used for revert penalties (Track A) and EBBO passthrough (Track B).
    /// @param subSolver The sub-solver whose balance to debit.
    /// @param amount The amount to debit in native token.
    /// @param reason An identifier for the debit (e.g. tx hash for Track A, claim ID for Track B).
    function debit(address subSolver, uint256 amount, bytes32 reason) external onlyOperator {
        if (amount > deposits[subSolver] - totalDebited[subSolver]) revert InsufficientBalance();
        totalDebited[subSolver] += amount;
        accumulatedDebits += amount;
        emit Debited(subSolver, amount, reason);
    }

    /// @notice Freeze a sub-solver, blocking withdrawal execution. Used during Track B investigations.
    function freeze(address subSolver) external onlyOperator {
        frozen[subSolver] = true;
        emit Frozen(subSolver);
    }

    /// @notice Unfreeze a sub-solver, allowing pending withdrawals to proceed.
    function unfreeze(address subSolver) external onlyOperator {
        frozen[subSolver] = false;
        emit Unfrozen(subSolver);
    }

    // --- Sub-solver ---

    /// @notice Request withdrawal of full balance. Effective balance drops to 0 immediately.
    /// The sub-solver must wait for the cooldown period before executing.
    function requestWithdrawal() external {
        if (withdrawalRequestedAt[msg.sender] != 0) revert WithdrawalAlreadyRequested();
        if (deposits[msg.sender] <= totalDebited[msg.sender]) revert InsufficientBalance();
        withdrawalRequestedAt[msg.sender] = block.timestamp;
        emit WithdrawalRequested(msg.sender);
    }

    /// @notice Execute a pending withdrawal after cooldown has elapsed. Blocked if frozen.
    function executeWithdrawal() external {
        if (withdrawalRequestedAt[msg.sender] == 0) revert NoWithdrawalRequested();
        if (frozen[msg.sender]) revert AccountFrozen();
        if (block.timestamp < withdrawalRequestedAt[msg.sender] + cooldownPeriod) revert CooldownNotElapsed();

        uint256 amount = deposits[msg.sender] - totalDebited[msg.sender];

        deposits[msg.sender] = 0;
        totalDebited[msg.sender] = 0;
        withdrawalRequestedAt[msg.sender] = 0;

        if (amount > 0) {
            (bool success,) = msg.sender.call{value: amount}("");
            if (!success) revert TransferFailed();
        }

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Cancel a pending withdrawal request. Restores effective balance.
    /// Can be called regardless of freeze state.
    function cancelWithdrawal() external {
        if (withdrawalRequestedAt[msg.sender] == 0) revert NoWithdrawalRequested();
        withdrawalRequestedAt[msg.sender] = 0;
        emit WithdrawalCancelled(msg.sender);
    }

    // --- Anyone ---

    /// @notice Deposit native token into a sub-solver's escrow balance.
    /// @param subSolver The sub-solver address to credit.
    function deposit(address subSolver) external payable {
        deposits[subSolver] += msg.value;
        emit Deposited(subSolver, msg.value);
    }

    /// @notice Sweep accumulated debits to the owner. Callable by anyone.
    function withdrawDebits() external {
        uint256 amount = accumulatedDebits;
        if (amount == 0) revert NothingToWithdraw();
        accumulatedDebits = 0;

        (bool success,) = owner.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit DebitsWithdrawn(owner, amount);
    }

    // --- Views ---

    /// @notice Sub-solver's current balance (deposits minus debits).
    function balance(address subSolver) external view returns (uint256) {
        return deposits[subSolver] - totalDebited[subSolver];
    }

    /// @notice Sub-solver's effective balance for proposal eligibility.
    /// Returns 0 if a withdrawal is pending, otherwise returns the balance.
    function effectiveBalance(address subSolver) external view returns (uint256) {
        if (withdrawalRequestedAt[subSolver] != 0) return 0;
        return deposits[subSolver] - totalDebited[subSolver];
    }

    /// @notice Amount of accumulated debits available for owner withdrawal.
    function withdrawableBalance() external view returns (uint256) {
        return accumulatedDebits;
    }
}
