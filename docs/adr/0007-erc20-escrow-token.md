# ERC20 escrow token

Status: accepted

> Extends [ADR-0002](0002-escrow-contract.md). All decisions in ADR-0002 remain in effect
> unless explicitly overridden below. The authorization model (blanket authority), role
> separation (owner/operator), withdrawal semantics (all-or-nothing with cooldown), FX
> policy (off-chain), deployment strategy (immutable), and no on-chain disputes are
> unchanged.

## Context

[ADR-0002](0002-escrow-contract.md) tracks sub-solver collateral in a plain
`mapping(address => uint256)`. [ADR-0005](0005-trampoline-execution-authority.md) notes
that rotating a sub-solver's signing key requires a full withdraw-redeposit cycle because
the signer address is also the escrow key. This is operationally expensive and temporarily
leaves the sub-solver uncollateralized during the cooldown window.

Sub-solvers need a way to migrate collateral to a new address (key rotation, operational
changes) without going through the withdrawal cooldown. At the same time, unrestricted
balance transfers would undermine the cooldown's security guarantee — a malicious
sub-solver could dodge debits by transferring funds to a fresh address.

This ADR introduces an ERC20 token model for the Escrow, replacing the `balances` mapping
with ERC20 `balanceOf` as the single source of truth, and adds a global pause mechanism
and transfer restrictions to preserve the security invariants.

## Decision

### ERC20 as the balance model

The Escrow contract inherits OpenZeppelin's ERC20. Tokens are minted 1:1 with deposited
ETH and burned on withdrawal or debit:

- `deposit(subSolver)` mints `msg.value` tokens to `subSolver`.
- `executeWithdrawal()` burns the caller's entire token balance and sends the
  corresponding ETH.
- `debit(subSolver, amount, reason)` burns `amount` tokens from `subSolver` and adds the
  equivalent ETH to `accumulatedDebits`.

The `balances` mapping from ADR-0002 is removed. `balanceOf(subSolver)` is the single
source of truth. `totalSupply()` plus `accumulatedDebits` equals the contract's ETH
balance (invariant).

### Transfers: `transfer` and `transferFrom` with Trampoline deployment

Both `transfer(to, amount)` and `transferFrom(from, to, amount)` are supported.
`approve()` and `allowance()` use standard ERC20 semantics. Both transfer functions
deploy a Trampoline instance for the recipient via `TRAMPOLINE_FACTORY.ensureDeployed(to)`
after moving tokens, ensuring the recipient is ready to participate in settlements
immediately (same behavior as `deposit`).

The `transferFrom` path enables third-party-initiated transfers with prior approval.
This is useful for operational tooling (e.g., a management contract that migrates
collateral on behalf of a sub-solver) and preserves full ERC20 compatibility — block
explorers, wallets, indexers, and standard tooling work without special-casing.

### Transfer restrictions via `_update` override

All ERC20 token movements flow through the internal `_update(from, to, amount)` hook.
The override enforces:

**Transfers** (`from != address(0)` and `to != address(0)`):
- Blocked when the contract is paused.
- Blocked if `from` is frozen.
- Blocked if `to` is frozen.
- Blocked if `from` has a pending withdrawal request.
- Blocked if `to` has a pending withdrawal request.

**Mints** (`from == address(0)`):
- Blocked if `to` has a pending withdrawal request (depositing to an address that
  signaled intent to leave is contradictory).
- Allowed if `to` is frozen (the sub-solver or a third party may top up collateral
  during an investigation; funds can only leave via operator debit or eventual
  unfreeze + withdrawal).
- Allowed when paused.

**Burns** (`to == address(0)`):
- No restrictions in `_update`. The calling function (`debit` or `executeWithdrawal`)
  enforces its own access control.

This means `debit` (operator burn) works during pause and on frozen addresses — the
operator must be able to slash during an incident. `executeWithdrawal` (self-burn)
enforces its existing checks: not frozen, cooldown elapsed, and additionally: not paused.

### Global pause: operator-triggered emergency brake

A new `pause()` / `unpause()` capability, callable by the `OPERATOR_ROLE`:

| Operation | During pause |
|---|---|
| `transfer` / `transferFrom` | Blocked |
| `deposit` (mint) | Allowed |
| `debit` (operator burn) | Allowed |
| `executeWithdrawal` (self-burn) | Blocked |
| `requestWithdrawal` | Allowed |
| `cancelWithdrawal` | Allowed |
| `withdrawDebits` | Allowed |

Pause is the first line of defense in the incident response flow:

1. BYOS detects malicious activity (e.g., a Track A revert followed by rapid transfers).
2. Operator calls `pause()` — all transfers and withdrawals freeze globally.
3. Operator identifies the tainted address chain via `Transfer` event history.
4. Operator calls `freeze(addr)` on each identified address.
5. Operator calls `unpause()` — legitimate sub-solvers resume normal operation.
6. Operator debits the frozen addresses at leisure.

The pause window should be short (minutes). Deposits remain open so legitimate
sub-solvers are minimally disrupted.

### Expanded freeze semantics

ADR-0002 defined freeze as a withdrawal blocker only. With ERC20 transfers, freeze is
expanded to also block token transfers in both directions:

- A frozen address cannot send tokens (prevents escaping via transfer).
- A frozen address cannot receive tokens (prevents complicating accounting during
  investigation and griefing via unsolicited inbound transfers).
- A frozen address can still receive deposits (mints) — see rationale above.
- A frozen address can still cancel a pending withdrawal (funds staying in the contract
  is always safe).

### Off-chain enforcement of transfer-chain debits

When the operator attempts to `debit(A, amount)` and A's balance is insufficient, the
BYOS service traces A's outbound `Transfer` events to identify recipients. The operator
may then debit those recipients up to the amount they received from A.

This cap is enforced **off-chain** by the BYOS service, not on-chain. The operator's
blanket debit authority (ADR-0002) allows debiting any amount up to a sub-solver's
balance. Sub-solvers trust the operator not to over-debit — this is unchanged from the
existing trust model.

Provenance is not tracked on-chain. Multi-hop tracing (A transfers to B, B transfers to
C) relies on `Transfer` event indexing in the BYOS monitoring system. The pause mechanism
is the primary enforcement tool — it halts all movement while the operator traces the
chain.

### Key rotation via transfer

A sub-solver rotating their signing key:

1. Calls `transfer(newAddress, balanceOf(oldAddress))` to move collateral.
2. BYOS service detects the transfer and updates its internal mapping.
3. A new Trampoline instance is deployed for `newAddress` (CREATE2 salt changes).
4. The old Trampoline instance is decommissioned.

This replaces the withdraw-redeposit cycle from ADR-0005, avoiding the cooldown window
where the sub-solver would be uncollateralized. The Trampoline lifecycle is still
one-instance-per-address; only the collateral migration is simplified.

## Interface

Changes to the [ADR-0002 interface](0002-escrow-contract.md#interface):

```solidity
contract Escrow is ERC20, AccessControlDefaultAdminRules {
    // --- Removed (replaced by ERC20 balanceOf) ---
    // mapping(address => uint256) public balances;

    // --- Removed (replaced by AccessControlDefaultAdminRules) ---
    // address public owner;
    // address public pendingOwner;
    // address public operator;
    // function setOperator(address newOperator) external;
    // function transferOwnership(address newOwner) external;
    // function acceptOwnership() external;
    //
    // Owner is now DEFAULT_ADMIN_ROLE via AccessControlDefaultAdminRules
    // (two-step transfer with configurable delay via beginDefaultAdminTransfer /
    // acceptDefaultAdminTransfer). Operator is now OPERATOR_ROLE, managed via
    // grantRole / revokeRole (allows multiple concurrent operators).

    // --- Unchanged state ---
    mapping(address => uint256) public withdrawalRequestedAt;
    mapping(address => bool) public frozen;
    uint256 public cooldownPeriod;
    uint256 public accumulatedDebits;
    bool public paused;

    // --- New: Operator-only ---
    function pause() external;
    function unpause() external;

    // --- New: ERC20 overrides (deploy Trampoline for recipient) ---
    function transfer(address to, uint256 value) public override returns (bool);
    function transferFrom(address from, address to, uint256 value) public override returns (bool);

    // --- Unchanged from ADR-0002 ---
    // (admin-only) setCooldownPeriod
    // (operator-only) debit, freeze, unfreeze
    // (sub-solver) requestWithdrawal, executeWithdrawal, cancelWithdrawal
    // (anyone) deposit, withdrawDebits
    // (views) effectiveBalance, withdrawableBalance

    // --- Updated view ---
    // balance(subSolver) is now balanceOf(subSolver) from ERC20

    // --- New events (in addition to ERC20 Transfer) ---
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    // All ADR-0002 events remain: Deposited, Debited, Withdrawn, Frozen, Unfrozen,
    // DebitsWithdrawn, WithdrawalRequested, WithdrawalCancelled, CooldownPeriodUpdated
    // ADR-0002 ownership events (OperatorUpdated, OwnershipTransferStarted,
    // OwnershipTransferred) are replaced by AccessControl's RoleGranted,
    // RoleRevoked, and DefaultAdminTransfer* events.
}
```

## Alternatives considered

- **Dedicated `migrate(address newAddress)` function with cooldown.** Simplest path for
  key rotation — no ERC20 surface, no pause, no transfer restrictions. Rejected — does
  not support partial collateral transfers and would require its own cooldown mechanism
  (duplicating withdrawal logic). ERC20 transfers are more general and provide ecosystem
  visibility (block explorers, event indexing).
- **ERC-721 (one NFT per sub-solver position).** Natural fit for "one indivisible
  position." Rejected — does not support partial transfers or balance splitting. Fungible
  collateral shares are more flexible.
- **Standard ERC20 with unrestricted transfers.** Simplest ERC20 implementation.
  Rejected — allows cooldown bypass (transfer instead of withdraw) and debit evasion
  (transfer before operator can debit).
- **On-chain transfer provenance tracking (`receivedFrom` mapping).** Would enforce debit
  caps on innocent recipients on-chain. Rejected — gas-expensive, multi-hop provenance
  (A→B→C) is intractable on-chain, and the operator is already trusted. Off-chain
  enforcement via event indexing is sufficient.
- **OpenZeppelin `ERC20Pausable`.** Standard pause implementation. Rejected — pauses
  *all* token operations including mints (deposits) and burns (debits), which must remain
  operational during a pause. A custom `_update` override with granular rules is required.
- **ERC20 with allowances disabled.** Disabling `approve` / `transferFrom` (revert
  unconditionally) to eliminate the approval front-running attack surface. Rejected —
  prevents third-party operational tooling from managing transfers and breaks full ERC20
  compatibility. The transfer restrictions (`_update` override) already guard against
  misuse; allowances add flexibility without weakening security invariants.

## Consequences

- **The Escrow is no longer a "dumb ledger."** The contract now enforces transfer
  validation, pause state, and expanded freeze semantics. This increases the audit surface
  and demands thorough invariant testing (fuzz `_update` conditions, test all state
  combinations of pause/freeze/withdrawal-pending). The immutability decision (no upgrade
  path) makes correctness critical.
- **Sub-solvers gain transfer capability without cooldown.** Key rotation no longer
  requires a withdraw-redeposit cycle. But transfers also introduce a new debit-evasion
  vector, mitigated by pause + freeze + off-chain monitoring.
- **The BYOS monitoring system must trace transfer chains.** When a debit hits an
  insufficient balance, the service must index `Transfer` events, identify recipients,
  and alert the operator. This is a new off-chain requirement.
- **Innocent sub-solvers have implicit debit exposure from unsolicited inbound
  transfers.** A malicious sub-solver can send tokens to an innocent address, making that
  address a potential debit target. The operator is trusted not to over-debit, and the
  debit cap (amount received from the bad actor) is enforced off-chain. This extends the
  existing trust model.
- **The token is ERC20-compliant but transfer-restricted.** Standard `approve` /
  `transferFrom` / `allowance` work normally, but conditional transfer restrictions
  (pause, freeze, pending withdrawal) mean the token won't integrate seamlessly with
  DEXes, lending protocols, or other DeFi composability. This is intentional — the token
  represents escrowed collateral, not a tradeable asset.
- **Pause is a powerful operator capability.** A malicious or compromised operator can
  halt all transfers globally. Mitigation: the owner (cold wallet) can revoke the
  operator role. This is consistent with the existing trust model where a compromised
  operator can grief but not steal.
- **ADR-0005's key rotation consequence is relaxed.** Rotating a sub-solver key no longer
  requires a new escrow deposit — collateral migrates via ERC20 transfer. A new
  Trampoline instance is still required (CREATE2 salt is the sub-solver address).
- **Admin renouncement risk.** `AccessControlDefaultAdminRules` allows the default admin
  to renounce via a two-step process. If this happens, `defaultAdmin()` returns
  `address(0)` permanently — no new admin can ever be appointed, operator roles cannot be
  granted or revoked, and `withdrawDebits()` would send accumulated debits to
  `address(0)`, burning them. The contract guards against this with a
  `require(admin != address(0))` check in `withdrawDebits()`, but renouncement still
  bricks all admin functions irreversibly.
