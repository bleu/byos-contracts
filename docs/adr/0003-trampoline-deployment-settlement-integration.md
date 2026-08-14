# Trampoline deployment & settlement integration

Status: accepted; revised 2026-07-22 (floors, delta-check guard); revised 2026-08-14 (minBuyAmount/maxBuyAmount split)

Spec: docs/shared/design-document.md#order-flow
      https://bleu.github.io/byos-docs/design-document#order-flow

Builds on [ADR-0001](0001-trampoline-topology.md) (one Trampoline instance per sub-solver). That ADR fixed the topology. This one fixes the lifecycle: when an instance is deployed, how a settlement routes value through it, and how the trade is kept self-funding so BYOS's buffers are never drained by a sub-solver.

## Context

Three facts about `GPv2Settlement.settle` drive the decisions below. First, interactions run as `GPv2Settlement` (bare `call`), so BYOS encodes the value flow as ordinary interactions. Second, the user is paid from `GPv2Settlement`'s own commingled balance — BYOS's buffer plus whatever the trampoline just pushed in — never pulled from an external contract. Third, fees are a price wedge, not a transfer: the driver collects fees by shifting clearing prices, and settlement-parked surplus is returned to the solver by CoW's weekly accounting ([docs/shared/reference/cow-fee-collection.md](../shared/reference/cow-fee-collection.md)).

## Decision

### Deployment

Instances are deployed at escrow-deposit time, paid by the sub-solver: `Escrow.deposit()` triggers the factory deploy. Settlements assume the instance exists — no on-chain `ensureDeployed` guard in the hot path.

Rationale: the expected shape is few sub-solvers and many orders, so speculative deploys are rare and cheap, and the settlement path stays as simple and fast as possible. Since the API is collateral-gated and deploy happens at deposit, a valid proposal implies a deployed trampoline, making "assume existence" a guarantee rather than a hope.

### Settlement value flow

See the specification for the full value flow, including sequence diagrams for the happy path, shortfall, and buy orders. The key contract-level decisions:

- BYOS encodes two intra-interactions that push the user's sell tokens into the instance and call `execute`, which runs the sub-solver's route and reverts unless the settlement's buy-token balance delta covers the signed `minBuyAmount` floor. Tokens remaining on the instance after execution are the sub-solver's property ([ADR-0008](0008-residue-disposition.md)).
- Access control layers three independent gates: settlement context (`msg.sender == GPv2Settlement`), BYOS submission (`tx.origin` holds SUBMITTER_ROLE), and the sub-solver's EIP-712 signature for non-repudiation ([ADR-0005](0005-trampoline-execution-authority.md)).
- Amounts are raw pre-fee quotes the sub-solver signed; the fee wedge the user pays on top accrues in `GPv2Settlement`, where the weekly accounting expects it.

### Funding guard: the balance-delta check is the guard

The buy-token output that funds the user must arrive fresh during `execute`, never be quietly covered from `GPv2Settlement`'s commingled buffer. The settlement's absolute balance proves nothing — the buffer would mask a route that delivers almost nothing — so `execute` asserts the *delta*: the buy-token balance after the route against the balance on entry. `settle` is `nonReentrant` and only the route runs between the two readings, so the delta is attributable to the route. It passes when at least `minBuyAmount` arrived fresh (buffer never net-drained); it reverts on shortfall (no trade happens). No matching assertion is needed on the sell side — BYOS itself authors the interaction that pushes exactly `sellAmount` into the isolated instance.

### Floor and ceiling: `minBuyAmount` and `maxBuyAmount`

The proposal carries two signed buy-amount fields. `minBuyAmount` is the floor — the hard revert threshold the delta check enforces on-chain. `maxBuyAmount` is the ceiling — the clearing-price commitment used by the BYOS service for off-chain accounting.

**Sell orders:** `sellAmount` (and therefore `minSellAmount` / `maxSellAmount` in the service) equals the order's sell amount. When `minBuyAmount` equals `maxBuyAmount`, the behaviour matches a fixed-amount proposal: the expected output must arrive or the settlement reverts, and the clearing price fully accounts for slippage. When `minBuyAmount` is lower than `maxBuyAmount`, the sub-solver accepts aggressive slippage. The delta check enforces `minBuyAmount`; the clearing price is set from `maxBuyAmount`. The difference `maxBuyAmount − actualDelta` is charged against the sub-solver's escrow (because BYOS is charged the same way by CoW). If the route over-delivers (`actualDelta > maxBuyAmount`), BYOS credits the sub-solver later.

**Buy orders:** the same struct fields exist, but aggressive slippage works differently. In a sell order the sub-solver promises to deliver tokens; in a buy order the promise is to consume fewer tokens. The extra tokens (those not priced into the clearing price) must be available on the Trampoline at the start of execution, but BYOS has no mechanism to source them for the sub-solver. A sub-solver who wants aggressive slippage on buy orders should pre-fund their Trampoline instance with buffer tokens — the equivalent skin-in-the-game posture.

The floor is the bid. The sub-solver signs the minimum it is sure to deliver, below its simulated route output; margin sizing is its own tradeoff — too thin reverts and lands Track A debits, too thick loses auctions.

### Infra-failure attribution

A settlement that reverts because the trampoline was not deployed (a stale off-chain view or a reorg) is BYOS's own infra failure, not the sub-solver's, so it must not trigger a Track-A escrow debit. The solver engine must distinguish "sub-solver route reverted" from "BYOS orchestration failed" ([ADR-0004](0004-penalty-schedule-and-attribution.md)).

## Non-goals

Fee-on-transfer buy tokens are out of scope for v0. The delta check measures what the settlement actually received — the right primitive for them — but their pricing and accounting are a known CoW special case to handle later.

## Alternatives considered

A lazy in-settlement deploy (an idempotent `ensureDeployed` guard) was rejected because it puts the one-time deploy gas on the sub-solver's first winning settlement, inflating that solution's score in the auction, and adds a per-settlement check forever. Deposit-time deploy keeps the hot path clean.

A commingled payout with no check (relying solely on `transferToAccounts`) was rejected because BYOS's buffer can silently mask a sub-solver shortfall. A malicious instance that routes `sellAmount` to the sub-solver and delivers almost nothing would drain BYOS principal up to the buffer size, with no revert to trigger Track A. Per-instance isolation does not cover this, because the loss lands at `GPv2Settlement`, outside any trampoline. The delta assertion is what closes it — not the settlement's absolute balance.

An exact-amount transfer as the guard (this ADR's original decision) has the same revert threshold — a transfer of exactly X reverts below X — but it strands benign over-delivery in the instance, cannot support routes that pay the settlement directly, and forces more complex residue disposition machinery. Replaced by the floor and delta check once the fee-mechanics review established that settlement-parked surplus returns to the solver weekly.

## Consequences

- The hot path stays minimal: one transfer in, `execute` (route plus one delta assertion), and the settlement completes. Tokens remaining on the instance are the sub-solver's property ([ADR-0008](0008-residue-disposition.md)).
- Self-funding is structural rather than a hope. A sub-solver's settlement can never net-drain BYOS's buffers, since the delta check reverts on shortfall against `minBuyAmount`.
- The `maxBuyAmount` ceiling enables aggressive slippage for sell orders without weakening the on-chain revert guard. Off-chain accounting uses `maxBuyAmount` to compute escrow charges; the contract only enforces the floor.
- Amounts are raw pre-fee quotes; the fee wedge accrues in `GPv2Settlement` by never being forwarded, and surplus custody is settled by [ADR-0008](0008-residue-disposition.md).
- Couplings: deployment couples to the escrow-deposit flow ([ADR-0002](0002-escrow-contract.md)); the infra-failure-versus-sub-solver-fault split couples to attribution ([ADR-0004](0004-penalty-schedule-and-attribution.md)).
- Solver-engine invariant: never submit a settlement routing through a non-deployed trampoline, since there is no on-chain safety net by design.
