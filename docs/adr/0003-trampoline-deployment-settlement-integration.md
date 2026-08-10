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
user), then post-interactions. Three facts drive the decisions below.

First, interactions run as `GPv2Settlement` (bare `call`), so BYOS encodes the value
flow as ordinary interactions.

Second, the user is paid from `GPv2Settlement`'s own balance, never pulled from an
external contract
([`GPv2Transfer.sol#L145-L181`](https://github.com/cowprotocol/contracts/blob/c6b61ce75841ce4c25ab126def9cc981c568e6c6/src/contracts/libraries/GPv2Transfer.sol#L145-L181):
ERC20 `safeTransfer` from `address(this)`, vault `sender = address(this)`, ETH from
`this`). That balance is commingled: BYOS's buffer plus whatever the trampoline just
pushed in. The trampoline cannot pay the user directly.

Third, fees are a price wedge, not a transfer: the driver collects protocol and partner
fees — and BYOS its gas cut — by shifting only the clearing prices, so a fee is whatever
`GPv2Settlement` pulls in and does not send out, and settlement-parked surplus is
returned to the solver by CoW's weekly accounting
([docs/reference/cow-fee-collection.md](../reference/cow-fee-collection.md)).

## Decision

### Deployment

Instances are deployed at a deterministic CREATE2 address keyed by sub-solver address,
at escrow-deposit time, paid by the sub-solver: `Escrow.deposit()` triggers the factory
deploy for the credited sub-solver (implemented: `Escrow.deposit` calls the factory's
idempotent `ensureDeployed`). Settlements
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

BYOS encodes these intra-interactions (run as `GPv2Settlement`, after the user's sell
amount has been pulled in):

1. `sellToken.transfer(Trampoline_S, sellAmount)` pushes the route's consumption into
   the instance (legitimate: the user's sell tokens in transit, not buffers).
   `sellAmount` is the raw pre-fee quote the sub-solver signed; the fee wedge the user
   pays on top is never forwarded, so it accrues in `GPv2Settlement`, where the weekly
   accounting expects it.
2. `Trampoline_S.execute(proposal, route, sellToken, buyToken, signature)` records the
   settlement's buy-token balance, runs the sub-solver's `route` (raw interactions
   from the proposal, delivering buy-token output directly to the settlement), then
   reverts unless the settlement's buy-token balance delta covers `buyAmount` — the
   signed floor. Tokens remaining on the instance after execution (unconsumed sell
   tokens, intermediate dust) are the sub-solver's property, reclaimable via claim
   functions ([ADR-0008](0008-residue-disposition.md)).

`GPv2Settlement` then pays the user via `transferToAccounts` out of its now-replenished
balance.

The floor check is trampoline contract code, rather than a sub-solver-authored
interaction. That distinction is essential, because a malicious sub-solver could
otherwise omit or redirect the value return. The sub-solver supplies only the `route`;
the buy-token floor is enforced by the immutable trampoline logic. This is the same
posture as the preventive approve-authoring layer in
[ADR-0001](0001-trampoline-topology.md): BYOS authors the value-moving calls, and the
sub-solver supplies only the route.

Access control: `execute` is callable only in a settlement context
(`msg.sender == GPv2Settlement`), only in a settlement submitted by BYOS
(`tx.origin` must hold the Escrow's SUBMITTER_ROLE — settlements are permissionless at
the protocol level, so once BYOS submits a settlement the route and sub-solver signature
become public calldata that any allow-listed solver could otherwise replay), and
additionally requires the sub-solver's EIP-712 signature over the route, for
non-repudiation ([ADR-0005](0005-trampoline-execution-authority.md)).

Batching: the flow above is per-trade. A settlement carrying multiple orders from the
same sub-solver repeats steps 1 and 2 per trade through the one `Trampoline_S`. Whether
a settlement may carry more than one order, or more than one sub-solver, is governed by
the attribution decision ([ADR-0004](0004-penalty-schedule-and-attribution.md)). Native
ETH legs follow the same rules, with wrap/unwrap internal to the instance, per
[ADR-0001](0001-trampoline-topology.md). `settle` is `nonReentrant`, so sub-solver
route code cannot re-enter the settlement.

### Funding guard: the balance-delta check is the guard

The `buyAmount` that funds the user must arrive fresh during `execute`, never be
quietly covered from `GPv2Settlement`'s commingled buffer. The settlement's absolute
balance proves nothing — the buffer would mask a route that delivers almost nothing —
so `execute` asserts the *delta*: the settlement's buy-token balance after the route,
against its balance on entry. `settle` is `nonReentrant` and only the route runs
between the two readings, so the delta is attributable to the route:

- it passes when at least `buyAmount` arrived fresh, so the settlement pays the user
  and BYOS's buffer is never net-drained; anything above the floor lands in the
  settlement as BYOS-owned slippage ([ADR-0008](0008-residue-disposition.md));
- it reverts when the route fell short of the signed floor, so the settlement reverts
  and no trade happens.

No matching assertion is needed on the sell side. BYOS itself authors the interaction
that pushes exactly `sellAmount` into the instance, and the route runs as the
instance — isolated from `GPv2Settlement`'s balance
([ADR-0001](0001-trampoline-topology.md)). The settlement's net sell-token outflow is
exactly `sellAmount` by construction — the push is the only transfer from
`GPv2Settlement` to the instance, and unconsumed sell tokens remain on the instance as
sub-solver property ([ADR-0008](0008-residue-disposition.md)).

The floor is the bid. The sub-solver signs the minimum it is sure to deliver, below its
simulated route output; margin sizing is its own tradeoff — too thin reverts and lands
Track A debits, too thick loses auctions. Whether the proposal API suggests floors or
filters thin ones is service policy, out of scope here.

### Both order kinds, one mechanism

Nothing above is specific to sell orders. For either kind the instance receives the
signed `sellAmount`, runs the route, and `execute` asserts the same buy-token delta
floor. Routes deliver buy-token output directly to the settlement. What changes is
which amount the user fixed, and so where the slack shows up:

| | Sell order | Buy order |
|---|---|---|
| User fixes | `sellAmount`; the route normally consumes all of it | `buyAmount`, the exact amount owed to the user |
| Floor means | the minimum output the sub-solver commits to deliver | at least the user's exact `buyAmount` |
| Typical leftover | buy-token over-delivery above the floor (lands in settlement) | unconsumed sell token (stays on instance, sub-solver's property) |

Buy-token over-delivery lands in `GPv2Settlement` as BYOS-owned slippage
([ADR-0008](0008-residue-disposition.md)). Unconsumed sell tokens remain on the instance,
reclaimable by the sub-solver. The user-facing fee wedge also flips sides — buy token for
sell orders, sell token for buy orders — but that is the driver's price shift, downstream
of and invisible to the trampoline; worked examples for both kinds are in
[docs/reference/cow-fee-collection.md](../reference/cow-fee-collection.md).

Same-token hook orders (`sellToken == buyToken`) where the delivery depends on returning
unconsumed sell tokens to the settlement are not supported: the route must deliver
buy-token output directly to the settlement, and tokens remaining on the instance are
not swept back ([ADR-0008](0008-residue-disposition.md)).

### Infra-failure attribution

A settlement that reverts because the trampoline was not deployed (a stale off-chain
view or a reorg) is BYOS's own infra failure, not the sub-solver's, so it must not
trigger a Track-A escrow debit. The solver engine must distinguish "sub-solver route
reverted" from "BYOS orchestration failed"
([ADR-0004](0004-penalty-schedule-and-attribution.md)).

## Non-goals

Fee-on-transfer buy tokens are out of scope for v0. The delta check measures what the
settlement actually received — the right primitive for them — but their pricing and
accounting are a known CoW special case to handle later.

## Alternatives considered

A lazy in-settlement deploy (an idempotent `ensureDeployed` guard) was rejected because
it puts the one-time deploy gas on the sub-solver's first winning settlement, inflating
that solution's score in the auction, and adds a per-settlement check forever.
Deposit-time deploy keeps the hot path clean.

A commingled payout with no check (relying solely on `transferToAccounts`) was rejected
because BYOS's buffer can silently mask a sub-solver shortfall. A malicious instance
that routes `sellAmount` to the sub-solver and delivers almost nothing would drain BYOS
principal up to the buffer size, with no revert to trigger Track A. Per-instance
isolation does not cover this, because the loss lands at `GPv2Settlement`, outside any
trampoline. The delta assertion is what closes it — not the settlement's absolute
balance.

An exact-amount `buyAmount` transfer as the guard (this ADR's original decision) has
the same revert threshold — a transfer of exactly X reverts below X — but it strands
benign over-delivery in the instance, cannot support routes that pay the settlement
directly, and forces more complex residue disposition machinery. Replaced by the floor
and delta check once the fee-mechanics review established that settlement-parked surplus
returns to the solver weekly.

## Consequences

- The hot path stays minimal: one transfer in, `execute` (route plus one delta
  assertion), and the settlement completes. Tokens remaining on the instance are the
  sub-solver's property ([ADR-0008](0008-residue-disposition.md)).
- Self-funding is structural rather than a hope. A sub-solver's settlement can never
  net-drain BYOS's buffers, since the delta check reverts on shortfall.
- Amounts are raw pre-fee quotes; the fee wedge accrues in `GPv2Settlement` by never
  being forwarded, and surplus custody is settled by
  [ADR-0008](0008-residue-disposition.md).
- Couplings: deployment couples to the escrow-deposit flow
  ([ADR-0002](0002-escrow-contract.md)); the infra-failure-versus-sub-solver-fault
  split couples to attribution
  ([ADR-0004](0004-penalty-schedule-and-attribution.md)).
- Solver-engine invariant: never submit a settlement routing through a non-deployed
  trampoline, since there is no on-chain safety net by design.
