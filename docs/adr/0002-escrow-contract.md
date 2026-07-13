# Escrow contract design

Status: accepted

## Context

The **Escrow** is a per-chain, native-token contract holding sub-solver collateral keyed by sub-solver address. Anyone may deposit; the sub-solver withdraws subject to a cooldown; BYOS holds an exclusive **debit** function for revert penalties/gas (Track A) and EBBO passthrough (Track B). It is the *only* sub-solver capital BYOS touches — trade capital flows atomically through `GPv2Settlement → Trampoline` (see [ADR-0001](0001-trampoline-topology.md)). Must be chain-agnostic from day one (v1: Ethereum mainnet + Gnosis).

This ADR settles three coupled sub-decisions from the early economics design
exploration:

- Authorization model (blanket vs per-proposal signature-gated)
- Withdrawal & freeze semantics
- FX / reserve policy for Track B claims

Plus additional decisions on role separation, interface design, and deployment strategy.

## Decision

### Authorization model: blanket authority

**Option A — blanket.** Depositing grants BYOS standing debit authority up to the sub-solver's balance. Simpler, lower gas, easier to develop and maintain. Matches the RFP's "exclusive debit function."

Rejected: Option B (per-proposal EIP-712 signature verification on-chain). Trust-minimized but adds significant gas and complexity for marginal benefit — the operator is already a trusted role, and sub-solvers have an off-chain relationship with BYOS.

### Role separation: owner and operator

Two distinct roles with separated concerns:

- **Owner** — a secure wallet (e.g., multisig/Safe) that owns the contract. Can set the operator, configure parameters (cooldown period), transfer ownership, and withdraw accumulated debits. All debited funds flow to the owner. Ownership transfer is two-step: owner calls `transferOwnership(newOwner)` to nominate a `pendingOwner`, then the pending owner calls `acceptOwnership()` to finalize. This prevents irrecoverable loss from address typos.
- **Operator** — an EOA that sits in the BYOS service for automated operation. Can debit sub-solvers, freeze, and unfreeze. Cannot withdraw funds or change configuration.

**Why separate?** The operator's private key is more exposed (lives in the BYOS service). If compromised, the attacker can debit sub-solver balances — but those funds go to the owner, not the attacker. The owner (cold wallet) can replace a compromised operator immediately. This limits the blast radius of a key compromise to griefing (illegitimate debits), not theft.

### Withdrawal semantics: all-or-nothing with cooldown

- **`requestWithdrawal()`** — sub-solver signals intent to withdraw their entire balance. Effective balance drops to 0 immediately (sub-solver is offline for new proposals). Cooldown clock starts.
- **`executeWithdrawal()`** — after cooldown expires, sub-solver withdraws their full remaining balance. No partial withdrawals.
- **`cancelWithdrawal()`** — sub-solver aborts the withdrawal request, effective balance restores, back online. Can be called regardless of freeze state (funds staying in the contract is always safe).

All-or-nothing eliminates partial withdrawal edge cases and balance fragmentation. A sub-solver who wants to reduce their position does a full cycle (withdraw → re-deposit).

### Freeze semantics: withdrawal blocker only

- **`freeze(address)`** — operator-only. Sets a boolean flag that blocks `executeWithdrawal()`. Does **not** affect on-chain effective balance.
- **`unfreeze(address)`** — operator-only. Clears the flag.
- A pending withdrawal request survives a freeze — after unfreeze, the sub-solver can execute immediately without re-requesting (cooldown already served).

Freeze is a blunt withdrawal gate for when a Track B investigation is open. No on-chain freeze timeout or dispute mechanism — handled off-chain. The owner can replace an unresponsive operator.

### FX / reserve policy: off-chain

No on-chain reserve multiplier or frozen-amount tracking. The contract is a dumb ledger; the BYOS service is the brain.

**Track B flow:**
1. CoW upholds EBBO claim → slashes BYOS in surplus token.
2. BYOS service calls CoW quote API to convert claim amount to native-token equivalent.
3. Operator calls `debit(subSolver, quotedAmount, reason)`.
4. BYOS service tracks a **5× reserve** off-chain against pending claims, reducing the sub-solver's *service-level* effective balance (not on-chain). This buffer covers token appreciation over the investigation window (up to 3 months). If appreciation exceeds 5×, BYOS absorbs the tail risk.

The 5× multiplier is a BYOS service parameter, tunable without contract changes.

### Debit withdrawals: permissionless sweep to owner

`withdrawDebits()` is callable by anyone — funds always go to the owner address. Enables automated sweeping by keepers or the BYOS service itself without requiring the owner's cold wallet to sign.

### Deployment: immutable

Simple, non-upgradeable contract. No proxy pattern. Immutability is a trust signal for sub-solvers — the code they deposit into won't change. If a v2 is needed, deploy a new contract; the cooldown-based withdrawal makes migration straightforward.

### No on-chain dispute mechanisms

No per-debit caps, no freeze timeouts, no challenge windows enforced on-chain. Disputes are handled off-chain — sub-solvers have a direct relationship with BYOS in v1. On-chain guardrails can be layered in later if the sub-solver base grows.

## Interface

```solidity
contract Escrow {
    // --- State ---
    mapping(address => uint256) public balances;
    mapping(address => uint256) public withdrawalRequestedAt;
    mapping(address => bool) public frozen;

    address public owner;
    address public pendingOwner;
    address public operator;
    uint256 public cooldownPeriod;
    uint256 public accumulatedDebits;

    // --- Owner-only ---
    function setOperator(address newOperator) external;
    function setCooldownPeriod(uint256 period) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external; // only callable by pendingOwner

    // --- Operator-only ---
    function debit(address subSolver, uint256 amount, bytes32 reason) external;
    function freeze(address subSolver) external;
    function unfreeze(address subSolver) external;

    // --- Sub-solver ---
    function requestWithdrawal() external;
    function executeWithdrawal() external;
    function cancelWithdrawal() external;

    // --- Anyone ---
    function deposit(address subSolver) external payable;
    function withdrawDebits() external;

    // --- Views ---
    function balance(address subSolver) external view returns (uint256);
    function effectiveBalance(address subSolver) external view returns (uint256);
    function withdrawableBalance() external view returns (uint256);

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
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
}
```

**State design:** A single `balances` mapping tracks each sub-solver's current balance directly — deposits add to it, debits subtract from it, withdrawal zeroes it. This avoids indefinite accumulation of stale `deposits`/`totalDebited` counters for long-lived sub-solvers who never do a full withdrawal cycle. The cumulative history is available via events.

**View semantics:**
- `balance(S)` = `balances[S]` (direct read).
- `effectiveBalance(S)` = `0` if withdrawal pending, else `balances[S]`. Freeze does not affect this — reserve logic lives in the BYOS service layer.
- `withdrawableBalance()` = `accumulatedDebits` — the debit pool available for owner withdrawal.

## Alternatives considered

- **Option B (per-proposal signature-gated debits):** On-chain EIP-712 verification per debit. Rejected — adds gas and complexity; blanket authority is sufficient given the operator trust model and off-chain dispute path.
- **Effective balance = 0 when frozen (nuclear freeze):** Zeroing effective balance on-chain during freeze. Rejected — freeze is a withdrawal gate only; the BYOS service applies reserve logic (5× multiplier) off-chain, allowing well-capitalized sub-solvers to keep operating during investigations.
- **On-chain reserve multiplier:** Storing the 5× reserve factor in the contract. Rejected — the reserve calculation is a service-level concern, not a contract concern. Keeping it off-chain allows tuning without contract changes.
- **Batch debit:** `batchDebit(address[], uint256[], bytes32[])`. Rejected — no realistic scenario requires atomic multi-sub-solver debits. Single `debit()` is simpler.
- **Partial withdrawals:** Allowing sub-solvers to withdraw specific amounts. Rejected — all-or-nothing eliminates edge cases around balance fragmentation and pending-withdrawal accounting.
- **On-chain dispute mechanisms (debit caps, freeze timeouts):** Rejected for v1 — adds complexity for a small initial sub-solver base with direct off-chain relationships. Can be layered in later.
- **Upgradeable proxy:** Rejected — immutability is a trust signal; migration via withdraw/re-deposit is straightforward given the cooldown mechanism.
- **Separate `deposits` and `totalDebited` mappings:** Original design used two mappings with `balance = deposits - totalDebited`. Rejected — both values accumulate indefinitely for sub-solvers who never do a full withdrawal, and the subtraction introduces an underflow surface. A single `balances` mapping is simpler and eliminates both issues.
- **Direct ownership transfer:** Original design transferred ownership in a single call. Rejected — a typo in the new owner address would irrecoverably brick the contract. Two-step transfer (`transferOwnership` + `acceptOwnership`) ensures the new owner can actually act.

## Consequences

- **Sub-solvers trust BYOS with debit authority.** The operator can debit any amount up to balance unilaterally. Mitigation: debited funds go to owner (not operator), owner can replace compromised operator, all debits emit events with reason for auditability.
- **BYOS absorbs tail FX risk.** If a Track B claim's token appreciates >5× between trade and resolution, the escrow may not cover the full claim. Accepted as priced-in residual risk; primary defense is gatekeeping, not escrow recovery.
- **Freeze without on-chain timeout means a sub-solver can be locked indefinitely.** Mitigation: owner can replace unresponsive operator; sub-solvers have off-chain recourse. Acceptable for v1's trust model.
- **All-or-nothing withdrawal means sub-solvers go offline during the cooldown.** This is intentional — it prevents the "withdraw-after-known-revert" race and simplifies accounting.
- **Immutable deployment means contract bugs require migration.** Mitigated by keeping the contract simple (dumb ledger + withdrawal gate) and auditing before deployment.
- **The BYOS service becomes the critical path for reserve calculations and proposal eligibility.** A service bug could accept proposals from under-collateralized sub-solvers. Mitigated by the on-chain effective balance check (must have balance to lose) and monitoring.
