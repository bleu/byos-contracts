# Residue disposition: sub-solver reclaimable

Status: accepted; decision inverted 2026-07-22; sweep removed and claim restored
2026-08-10 for the Private Market Maker use case

> Originally residue was sub-solver property, reclaimable via
> `claimToken`/`claimTokens` on the instance. The 2026-07-22 inversion swept
> everything to the settlement after the CoW fee-mechanics review showed that surplus
> parked in the settlement returns to the solver through CoW's weekly accounting. The
> 2026-08-10 change removes the sweep and restores the claim functions for the Private
> Market Maker (Private MM) use case, where the sub-solver is a market maker that needs
> to reclaim unconsumed sell tokens and intermediate residue from its instance.

## Context

[ADR-0003](0003-trampoline-deployment-settlement-integration.md) fixes the settlement
value flow. Its original form settled back exactly `buyAmount` and left whatever the
route produced beyond it in the sub-solver's Trampoline instance — **residue**: route
surplus beyond the quote, unconsumed `sellToken` (buy orders over-provision their
input), intermediate-token dust, stray native ETH. The first version of this ADR made
that residue sub-solver property behind claim functions, on three grounds: sweeping it
to the settlement would confiscate the sub-solver's alpha and push its capture in-route
via approval helpers (the pattern ADR-0001's filter rejects); a live replay exposure
(COW-1151) made parked residue unsafe anyway; and a BYOS key over the instance would
break the no-privileged-key posture that ADR-0005's trust argument rests on.

Three findings changed those premises (CoW solvers-team meeting and fee-mechanics
review, 2026-07-22):

- Fees and slippage are price wedges: whatever `GPv2Settlement` pulls in and does not
  pay out is credited to the solver — after protocol and partner fees — and returned
  weekly in native token. Surplus parked in the settlement is not lost to BYOS; it is
  the normal way solvers collect.
- The sub-solver persona is a DEX or routing API compensated by its own venue fees
  inside the route, not by leftovers. The floor is the bid: everything above it was
  never promised to anyone, and in-route capture of it is bid-neutral — it takes only
  what the sub-solver could have kept by signing a higher floor.
- The replay exposure was closed by the submitter gate (#11), so nothing about parked
  balances is urgent anymore.

Those premises hold for the DEX/routing-API persona. The **Private Market Maker** use
case introduces a different sub-solver persona (COW-1253):

- The Private MM is an active market maker that provides its own liquidity and needs
  tight control over capital flows. Unconsumed sell tokens from buy orders and
  intermediate residue are working capital the MM must recover promptly.
- Sweeping to the settlement and waiting for CoW's weekly accounting introduces
  unacceptable settlement latency for an active market-making strategy.
- The MM operates on its own dedicated Trampoline instance, so residue is its own
  property by construction.

## Decision

The sweep is removed from `execute`. Routes deliver buy-token output directly to
`GPv2Settlement`. `execute` enforces `buyAmount` as a floor via the balance-delta check
([ADR-0003](0003-trampoline-deployment-settlement-integration.md)). Tokens remaining on
the instance after execution — unconsumed sell tokens, intermediate dust — are the
sub-solver's property, reclaimable via `claimToken`/`claimTokens`. The claim functions
are gated by `msg.sender == SUB_SOLVER`.

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

### What survives

Per-instance isolation, the storage-free instance, and signature-gated execution are
unchanged. The instance may hold tokens at rest (unconsumed sell tokens from the last
settlement), reclaimable only by the sub-solver.

## Alternatives considered

- **Sweep to settlement** (this ADR's 2026-07-22 decision). Coherent for the
  DEX/routing-API persona where surplus recovery via CoW's weekly accounting is
  acceptable. Introduces unacceptable latency for the Private MM use case.
- **Permissionless `sweep(token)` for strays, recipient hardcoded to the settlement.**
  No key and no theft surface, and BYOS would win most stray races. Dropped: strays
  are declared out of scope, and the function would exist only to chase donations and
  dust.
- **Operator-gated claim with a free recipient.** Breaks the "operator can grief but
  not steal" invariant ([CONTEXT.md](../../CONTEXT.md)). Rejected.
- **BYOS debit or freeze over the instance.** Still rejected for the original reason —
  a key over sub-solver execution infrastructure — and now also pointless with the
  claim gate.

## Consequences

- The Trampoline loses the sell-token sweep; `execute` no longer returns unconsumed
  sell tokens to the settlement. The instance may hold tokens at rest.
- `claimToken`/`claimTokens` are restored, gated to the sub-solver. The
  `ResidueClaimed` event, `Trampoline_OnlySubSolver`, and `Trampoline_EthClaimFailed`
  errors are added back.
- Sub-solvers hold reclaimable property in their instance and must actively claim.
- BYOS's settlement slippage line no longer includes unconsumed sell tokens.
- Same-token hook orders (sellToken == buyToken) where delivery depended on the sweep
  are not supported; the route must deliver buy-token output directly to the settlement.
