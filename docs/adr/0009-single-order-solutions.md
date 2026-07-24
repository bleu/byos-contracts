# Single-order solutions: one order per proposal, per settlement

Status: accepted

> Resolves the order-count question that [ADR-0003](0003-trampoline-deployment-settlement-integration.md)
> deferred and [ADR-0004](0004-penalty-schedule-and-attribution.md) left open (it fixed
> only the sub-solver count). An earlier draft of this ADR proposed the opposite —
> batch proposals with net token flows; see Alternatives considered.

## Context

CoW's original single-winner batch auction rewarded batching: netting opposing orders
peer-to-peer was the winning edge. CIP-67 replaced it with the fair combinatorial
auction ([reference](../reference/solver-auctions.md)): reference bids are computed per
directed token pair, and a batched bid is filtered out if it underperforms the
reference on any pair it covers.

That changes the math for BYOS:

- Coincidence of wants in a single auction is small. Most directed pairs carry one
  order, so a batch usually has nothing to net.
- Sub-solvers are mainly DEXes and routing APIs that want a seamless integration —
  quote one order, sign one proposal. Batch solving means netting logic and
  multi-order routing, the solver-team work they joined BYOS to avoid.

The current proposal schema ([ADR-0005](0005-trampoline-execution-authority.md)) is
already single-order.

## Decision

**A solution contains exactly one order.** One proposal commits to one order; one
settlement carries one proposal (and one sub-solver, per ADR-0004). Batch proposals
are out of scope for this repo.

This means:

- ADR-0005's schema and `execute` path stand as-is — no new typehash, no domain bump.
- ADR-0003's multi-order sketch ("repeat transfer-in + `execute` per trade") is
  retired.
- ADR-0004's static minimum escrow balance stays correctly sized: worst-case exposure
  per settlement is one order's `gas + c_l`.
- One invariant for everything downstream: every BYOS settlement has exactly one
  order, one trampoline call, one sub-solver.

## Alternatives considered

- **Batch proposals with net token flows** (the earlier draft of this ADR). One
  proposal covering N orders, signing net inflows/outflows so netting surplus becomes
  reachable. Sound mechanism, rejected on demand: under the fair combinatorial auction
  that surplus rarely exists, while the costs are certain — a new typehash and domain
  bump, gatekeeper batch-consistency validation, per-proposal collateral sizing, and a
  proposal format the DEX-style sub-solver audience won't produce. If the competition
  mechanism ever rewards batching again, that draft is the starting point for a new
  ADR.
- **N single-order proposals per settlement** (ADR-0003's sketch). No contract change,
  amortizes settlement overhead. Rejected: routes still run gross so there is no
  netting benefit, and worst-case gas grows with order count, breaking the static
  collateral minimum.

## Consequences

- Settlement overhead is paid per order, never amortized. Accepted — bids are scored
  per solution and the overhead is priced in like any other solver's cost.
- Netting surplus is out of reach. Accepted — it is rarely on offer, and BYOS's niche
  is per-pair routing bids from sub-solvers, which the single-order schema serves
  exactly.
- Relaxing the one-order rule later is a signed-schema change: a domain-version bump
  and a new ADR.
