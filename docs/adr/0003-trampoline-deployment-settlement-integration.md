# Trampoline deployment & settlement integration

Status: accepted

Builds on [ADR-0001](0001-trampoline-topology.md) (one Trampoline instance per
sub-solver). That ADR fixed the topology. This one fixes the lifecycle: when an instance
is deployed, how a settlement routes value through it, and how the trade is kept
self-funding so BYOS's buffers are never drained by a sub-solver.

## Context

Verified `settle()` order
([`GPv2Settlement.sol#L127-L142`](https://github.com/cowprotocol/contracts/blob/c6b61ce75841ce4c25ab126def9cc981c568e6c6/src/contracts/GPv2Settlement.sol#L127-L142)):
pre-interactions, then `vaultRelayer.transferFromAccounts` (pull the user's `sellAmount`
into `GPv2Settlement`), then intra-interactions, then `transferToAccounts` (pay the
user), then post-interactions. Two facts drive the decisions below.

First, interactions run as `GPv2Settlement` (bare `call`), so BYOS encodes the value
flow as ordinary interactions.

Second, the user is paid from `GPv2Settlement`'s own balance, never pulled from an
external contract
([`GPv2Transfer.sol#L145-L181`](https://github.com/cowprotocol/contracts/blob/c6b61ce75841ce4c25ab126def9cc981c568e6c6/src/contracts/libraries/GPv2Transfer.sol#L145-L181):
ERC20 `safeTransfer` from `address(this)`, vault `sender = address(this)`, ETH from
`this`). That balance is commingled: BYOS's buffer plus whatever the trampoline just
pushed in. The trampoline cannot pay the user directly.

## Decision

### Deployment

Instances are deployed at a deterministic CREATE2 address keyed by sub-solver address,
at escrow-deposit time, paid by the sub-solver: `Escrow.deposit()` triggers the factory
deploy for the credited sub-solver. The hook lands together with the Trampoline factory
(tracked as a TODO in [`Escrow.sol`](../../src/contracts/Escrow.sol)). Settlements
assume the instance exists: there is no on-chain `ensureDeployed` guard in the hot path,
though BYOS may `eth_getCode` off-chain as a sanity check when building the solution.

Rationale: the expected shape is few sub-solvers and many orders, so speculative deploys
are rare and cheap, and the settlement path stays as simple and fast as possible (the
guiding principle for this work). Cost is attributed to the party that benefits.

Existence invariant: the API is permissionless but collateral-gated, so no escrow
deposit means no valid proposal ([CONTEXT.md](../../CONTEXT.md)). Since deploy happens
at deposit, a valid proposal implies a deployed trampoline, which makes "assume
existence" a guarantee rather than a hope. The only residual is a reorg of the deposit
tx, handled as an infra failure (see below).

### Settlement value flow

BYOS encodes these intra-interactions (run as `GPv2Settlement`, after `sellAmount` has
been pulled in):

1. `sellToken.transfer(Trampoline_S, sellAmount)` pushes the trade capital into the
   instance (legitimate: the user's sell tokens in transit, not buffers).
2. `Trampoline_S.execute(route, buyToken, buyAmount)` runs the sub-solver's `route` (raw
   interactions from the proposal), then its own contract code performs
   `buyToken.transfer(GPv2Settlement, buyAmount)` for the exact required amount.

`GPv2Settlement` then pays the user via `transferToAccounts` out of its now-replenished
balance.

The final transfer is trampoline contract code, parameterized by BYOS-supplied
`(buyToken, buyAmount)`, rather than a sub-solver-authored interaction. That distinction
is essential, because a malicious sub-solver could otherwise omit or redirect it. The
sub-solver supplies only the `route`; the settle-back is enforced by the immutable
trampoline logic. This is the same posture as the preventive approve-authoring layer in
[ADR-0001](0001-trampoline-topology.md): BYOS authors the value-moving calls, and the
sub-solver supplies only the route.

Access control: `execute` is callable only in a settlement context
(`msg.sender == GPv2Settlement`) and additionally requires the sub-solver's EIP-712
signature over the route, for non-repudiation
([ADR-0005](0005-trampoline-execution-authority.md)).

Batching: the flow above is per-trade. A settlement carrying multiple orders from the
same sub-solver repeats steps 1 and 2 per trade through the one `Trampoline_S`. Whether
a settlement may carry more than one order, or more than one sub-solver, is governed by
the attribution decision ([ADR-0004](0004-penalty-schedule-and-attribution.md)). Native
ETH legs follow the same exact-amount rule, with wrap/unwrap internal to the instance,
per [ADR-0001](0001-trampoline-topology.md). `settle` is `nonReentrant`, so sub-solver
route code cannot re-enter the settlement.

### Funding guard: the exact-amount transfer is the guard

The buyAmount that funds the user must come from `Trampoline_S`'s own transfer of the
exact required amount, never from `GPv2Settlement`'s commingled buffer. Because the
trampoline is fund-less at rest (ADR-0001), its balance is exactly what the sub-solver's
route produced, so a standard ERC20 `transfer(buyAmount)` behaves as the guard:

- it succeeds when the route produced at least `buyAmount`, so the settlement receives
  exactly `buyAmount` fresh, pays the user, and BYOS's buffer net change is zero;
- it reverts when the route fell short, so the settlement reverts and no trade happens.

The transfer's own insufficient-balance revert enforces that the trade is self-funding
and that BYOS's buffer is never net-drained by a sub-solver, so no separate `balanceOf`
assertion is needed. Surplus the route produces beyond `buyAmount` stays in the isolated
trampoline as residue; its disposition (collected by BYOS and coupled into collateral
sizing, versus left as a sub-solver-reclaimable reward outside the collateral model) is
an open question, not yet an ADR.

### Infra-failure attribution

A settlement that reverts because the trampoline was not deployed (a stale off-chain
view or a reorg) is BYOS's own infra failure, not the sub-solver's, so it must not
trigger a Track-A escrow debit. The solver engine must distinguish "sub-solver route
reverted" from "BYOS orchestration failed"
([ADR-0004](0004-penalty-schedule-and-attribution.md)).

## Non-goals

Fee-on-transfer buy tokens are out of scope for v0. The exact-amount transfer assumes
that the amount sent equals the amount received, which does not hold for them; they are
a known CoW special case to handle later.

## Alternatives considered

A lazy in-settlement deploy (an idempotent `ensureDeployed` guard) was rejected because
it puts the one-time deploy gas on the sub-solver's first winning settlement, inflating
that solution's score in the auction, and adds a per-settlement check forever.
Deposit-time deploy keeps the hot path clean.

A commingled payout (relying solely on `transferToAccounts`) was rejected because BYOS's
buffer can silently mask a sub-solver shortfall. A malicious instance that routes
`sellAmount` to the sub-solver and delivers almost nothing would drain BYOS principal up
to the buffer size, with no revert to trigger Track A. Per-instance isolation does not
cover this, because the loss lands at `GPv2Settlement`, outside any trampoline.

An explicit `balanceOf` delta-assertion inside `execute` has the same effect but is
redundant, since the exact-amount `transfer` already reverts on shortfall. We dropped it
to keep the contract minimal.

## Consequences

- The hot path is minimal: one transfer in, `execute`, one transfer out. This serves the
  "execution as simple and fast as possible" principle.
- Self-funding is structural rather than a hope. A sub-solver's settlement can never
  net-drain BYOS's buffers, since an ordinary ERC20 revert enforces it.
- Couplings: residue disposition remains open (see above); deployment couples to the
  escrow-deposit flow ([ADR-0002](0002-escrow-contract.md)); the
  infra-failure-versus-sub-solver-fault split couples to attribution
  ([ADR-0004](0004-penalty-schedule-and-attribution.md)).
- Solver-engine invariant: never submit a settlement routing through a non-deployed
  trampoline, since there is no on-chain safety net by design.
