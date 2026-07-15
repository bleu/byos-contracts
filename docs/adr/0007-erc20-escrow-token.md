# ERC20 escrow token

Status: accepted

> Extends [ADR-0002](0002-escrow-contract.md). All decisions in ADR-0002 remain in effect
> unless explicitly overridden below.

## Context

[ADR-0002](0002-escrow-contract.md) tracks sub-solver collateral in a plain
`mapping(address => uint256)`. Rotating a sub-solver's signing key requires a full
withdraw-redeposit cycle ([ADR-0005](0005-trampoline-execution-authority.md)), which is
expensive and leaves the sub-solver uncollateralized during the cooldown window.

Sub-solvers need collateral transfers without cooldown. But unrestricted transfers would
undermine security — a malicious sub-solver could dodge debits by moving funds to a fresh
address.

## Decision

### ERC20 as the balance model

The Escrow inherits OpenZeppelin's ERC20. Tokens are minted 1:1 with deposited ETH and
burned on withdrawal or debit. `balanceOf` replaces the `balances` mapping as the single
source of truth. Invariant: `totalSupply() + accumulatedDebits == address(this).balance`.

### Transfers with Trampoline deployment

Standard `transfer`, `transferFrom`, and `approve` are supported. Both transfer functions
deploy a Trampoline for the recipient via `TRAMPOLINE_FACTORY.ensureDeployed(to)`,
ensuring immediate settlement readiness (same as `deposit`).

### Transfer restrictions via `_update` override

All token movements flow through `_update(from, to, amount)`:

| | Paused | Sender frozen | Receiver frozen | Sender withdrawing | Receiver withdrawing |
|---|---|---|---|---|---|
| **Transfer** | Blocked | Blocked | Blocked | Blocked | Blocked |
| **Mint** | Allowed | n/a | Allowed | n/a | Blocked |
| **Burn** | No restriction | No restriction | n/a | No restriction | n/a |

Burns have no restrictions in `_update` — the calling function (`debit` or
`executeWithdrawal`) enforces its own access control. This means `debit` works during
pause and on frozen addresses (the operator must be able to slash during an incident),
while `executeWithdrawal` independently checks: not frozen, not paused, cooldown elapsed.

### Global pause

`pause()` / `unpause()`, callable by `OPERATOR_ROLE`. Blocks transfers and
`executeWithdrawal`. All other operations remain available.

Incident response flow:

1. Operator calls `pause()` — transfers and withdrawals stop globally.
2. Operator traces tainted addresses via `Transfer` event history.
3. Operator calls `freeze(addr)` on each identified address.
4. Operator calls `unpause()` — legitimate sub-solvers resume.
5. Operator debits frozen addresses at leisure.

The pause window should be short (minutes). Deposits stay open so legitimate sub-solvers
are minimally disrupted.

### Expanded freeze semantics

ADR-0002 defined freeze as a withdrawal blocker. With transfers, freeze now also blocks
sending and receiving tokens (prevents escape and griefing via unsolicited inbound).
Deposits (mints) to frozen addresses are still allowed — collateral can be topped up
during an investigation but can only leave via operator debit or eventual
unfreeze + withdrawal.

### Off-chain transfer-chain debit enforcement

When `debit(A, amount)` hits an insufficient balance, the BYOS service traces A's
outbound `Transfer` events and debits recipients up to what they received from A. This cap
is enforced off-chain — the operator's blanket debit authority (ADR-0002) is unchanged.
Multi-hop tracing (A→B→C) relies on `Transfer` event indexing. The pause mechanism halts
all movement while the operator traces the chain.

### Key rotation via transfer

A sub-solver calls `transfer(newAddress, fullBalance)`. BYOS detects the transfer, updates
its mapping, and a new Trampoline is deployed for `newAddress`. This replaces the
withdraw-redeposit cycle from ADR-0005, avoiding the cooldown gap.

## Alternatives considered

- **Dedicated `migrate(newAddress)` with cooldown.** No ERC20 surface needed. Rejected —
  no partial transfers, duplicates withdrawal logic.
- **ERC-721 (one NFT per position).** Rejected — no partial transfers or balance splitting.
- **Unrestricted ERC20 transfers.** Rejected — allows cooldown bypass and debit evasion.
- **On-chain provenance tracking.** Rejected — gas-expensive, multi-hop is intractable
  on-chain, operator is already trusted.
- **OpenZeppelin `ERC20Pausable`.** Rejected — pauses *all* operations including mints
  and burns, which must stay available during a pause.
- **Disabling allowances.** Rejected — prevents third-party operational tooling, breaks
  ERC20 compatibility without meaningful security benefit.

## Consequences

- **Increased audit surface.** Transfer validation, pause, and expanded freeze semantics
  make the contract more complex. Immutability (no upgrade path) makes correctness
  critical.
- **Transfers enable debit evasion.** Mitigated by pause + freeze + off-chain monitoring.
- **BYOS must trace transfer chains.** New off-chain requirement: index `Transfer` events
  to follow funds when a debit hits insufficient balance.
- **Implicit debit exposure from unsolicited transfers.** A malicious sub-solver can send
  tokens to an innocent address, making it a potential debit target. The off-chain debit
  cap and operator trust model mitigate this.
- **Transfer-restricted ERC20.** Pause, freeze, and pending-withdrawal restrictions mean
  the token won't integrate with DeFi protocols. Intentional — it represents escrowed
  collateral, not a tradeable asset.
- **Pause is powerful.** A compromised operator can halt all transfers. Mitigation: admin
  can revoke the operator role. Consistent with the existing trust model.
- **ADR-0005's key rotation consequence is relaxed.** Collateral migrates via transfer;
  a new Trampoline is still required per address.
- **Admin renouncement risk.** If the default admin renounces,
  `defaultAdmin()` returns `address(0)` permanently — admin functions are bricked and
  `withdrawDebits()` reverts. The contract guards with a `require(admin != address(0))`
  check.
