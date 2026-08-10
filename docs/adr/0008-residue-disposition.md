# Residue disposition: sub-solver reclaimable

Status: accepted

## Context

After `execute` completes, tokens can remain on the instance: unconsumed sell tokens
(buy orders over-provision their input), intermediate-token dust, route surplus the
sub-solver did not capture in-route. This ADR settles who owns that residue and how it
is recovered.

Two sub-solver personas drive the decision:

- **DEX / routing-API sub-solvers** are compensated by their own venue fees inside the
  route. Residue is incidental surplus they never counted on.
- **Private Market Makers** provide their own liquidity and need tight control over
  capital flows. Unconsumed sell tokens and intermediate residue are working capital the
  MM must recover promptly.

CoW's fee mechanics make a sweep to settlement viable for the first persona: surplus
parked in `GPv2Settlement` is credited to the solver — after protocol and partner fees —
and returned weekly in native token
([docs/reference/cow-fee-collection.md](../reference/cow-fee-collection.md)). But weekly
accounting introduces unacceptable capital-recovery latency for the Private MM persona,
where capital velocity is the core requirement. Because the Trampoline must serve both
personas with a single contract, the residue model must accommodate the stricter
requirement.

## Decision

Residue is the sub-solver's property. `claimToken`/`claimTokens` transfer the instance's
full balance of the requested token(s) to a caller-chosen recipient, gated by
`msg.sender == SUB_SOLVER`. There is no sweep from `execute`: routes deliver buy-token
output directly to `GPv2Settlement`, and `execute` enforces `buyAmount` as a floor via
the balance-delta check
([ADR-0003](0003-trampoline-deployment-settlement-integration.md)). Tokens remaining on
the instance after execution stay there until claimed.

### Strays are written off

Tokens that land on an instance outside the settlement flow — mistaken transfers,
airdrops, intermediate-token dust — are nobody's problem by design. A sub-solver with a
standing route-planted approval can take them; preventing that is the un-enumerable
approval-fighting ADR-0001 rejected, and the amounts at stake are donations and dust —
never user funds, trade capital, buffers, or escrow, all of which are protected by
settlement atomicity and the floor check. If a sub-solver skims strays, the response is
off-chain (gatekeeping, eviction), not a contract mechanism.

### In-route capture is tolerated

A sub-solver can keep surplus by capturing it in-route before the delta check. Accepted:
it is bid-neutral, touches only value above its own signed floor, and guarding against it
would reopen the filtered-approval arms race. Uncaptured padding is a donation to BYOS.

### Residue and planted approvals

The instance may hold tokens at rest (unconsumed sell tokens from the last settlement).
Route-planted approvals from previous settlements can interact with this residue.
Per-instance isolation ([ADR-0001](0001-trampoline-topology.md)) confines the exposure:
the only approvals on the instance are ones the sub-solver's own routes planted, and
the only tokens at risk are the sub-solver's own residue — any drain through a planted
approval is self-harm, not cross-sub-solver theft. The mitigation is prompt claiming
and the BYOS approve-filter (defense-in-depth, best-effort).

## Alternatives considered

- **Sweep to settlement (no claim functions).** `execute` sweeps the instance's
  remaining sell-token balance to `GPv2Settlement` after the route; residue returns to
  BYOS through CoW's weekly accounting. Viable for the DEX/routing-API persona where
  capital-recovery latency is acceptable. Rejected: introduces gas costs and makes it
  impossible to implement the Private MM use case.
- **Permissionless `sweep(token)` for strays, recipient hardcoded to the settlement.**
  No key and no theft surface, and BYOS would win most stray races. Dropped: strays
  are declared out of scope, and the function would exist only to chase donations and
  dust.
- **Operator-gated claim with a free recipient.** Breaks the "operator can grief but
  not steal" invariant ([CONTEXT.md](../../CONTEXT.md)). Rejected.
- **BYOS debit or freeze over the instance.** Rejected — introduces a privileged key
  over sub-solver execution infrastructure, undermining the trust model.

## Consequences

- The instance may hold tokens at rest. The security argument shifts from "approvals
  drain nothing because the instance is empty" to "approvals can only drain the
  sub-solver's own residue" (per-instance isolation). ADR-0001's allowance-hygiene
  section and ADR-0003's settlement-flow description must reflect this change.
- `claimToken`/`claimTokens` are gated to the sub-solver. The `ResidueClaimed` event,
  `Trampoline_OnlySubSolver`, and `Trampoline_EthClaimFailed` errors are part of the
  contract surface.
- Sub-solvers hold reclaimable property in their instance and must actively claim.
  Residue is at risk to route-planted approvals while unclaimed.
- BYOS's settlement slippage line no longer includes unconsumed sell tokens; only
  buy-token over-delivery above the floor lands in the settlement.
- Same-token hook orders (sellToken == buyToken) where delivery depends on returning
  unconsumed sell tokens to the settlement are not supported; the route must deliver
  buy-token output directly to the settlement.
