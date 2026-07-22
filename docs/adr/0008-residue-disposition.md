# Residue disposition: swept to the settlement

Status: accepted; decision inverted 2026-07-22

> Previously residue was sub-solver property, reclaimable via `claimToken`/`claimTokens`
> on the instance; inverted after the CoW fee-mechanics review showed that surplus
> parked in the settlement contract returns to the solver through CoW's weekly
> accounting ([docs/reference/cow-fee-collection.md](../reference/cow-fee-collection.md)).

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

## Decision

There is no residue. `execute` sweeps the instance's full remaining balance of both
trade tokens to `GPv2Settlement` and enforces `buyAmount` as a floor via the
balance-delta check ([ADR-0003](0003-trampoline-deployment-settlement-integration.md)):
the instance ends every settlement holding none of the trade tokens. Over-delivery and
unconsumed sell tokens are BYOS-owned settlement slippage, returned weekly by CoW's
accounting. The claim functions are removed; the trampoline keeps zero privileged
keys — with nothing resting in the instance, nobody needs one.

### Strays are written off

Tokens that land on an instance outside the settlement flow — mistaken transfers,
airdrops, intermediate-token dust — are nobody's problem by design. A sub-solver with a
standing route-planted approval can take them; preventing that is the un-enumerable
approval-fighting ADR-0001 rejected, and the amounts at stake are donations and dust —
never user funds, trade capital, buffers, or escrow, all of which are protected by
settlement atomicity and the floor check. If a sub-solver skims strays, the response is
off-chain (gatekeeping, eviction), not a contract mechanism.

### In-route capture is tolerated

A sub-solver can still keep surplus by capturing it inside the route (sending part of
the output to its own address before the sweep). This is accepted rather than
prevented: it is bid-neutral, touches only value above the sub-solver's own signed
floor, and guarding against it would reopen the filtered-approval arms race. Padding
left uncaptured is a donation to BYOS; how tightly to quote is the sub-solver's own
risk/competitiveness tradeoff.

### What survives

Per-instance isolation, the storage-free instance, and signature-gated execution are
unchanged. ADR-0001's containment story reverts to its original, stronger form: the
instance is genuinely empty at rest, so a planted approval drains nothing — "the
instance is not a wallet" is now literal.

## Alternatives considered

- **Sub-solver-reclaimable residue via claim functions** (this ADR's original
  decision). Coherent while its premises held; each fell: surplus swept to the
  settlement is returned to BYOS weekly rather than confiscated into a void, the DEX
  persona is paid in-route rather than by leftovers, and the submitter gate closed the
  replay window that made prompt claiming a doctrine. Removing the claims also deletes
  an entry point and an event from the security-critical contract.
- **Permissionless `sweep(token)` for strays, recipient hardcoded to the settlement.**
  No key and no theft surface, and BYOS would win most stray races. Dropped: strays
  are declared out of scope, and the function would exist only to chase donations and
  dust.
- **Operator-gated claim with a free recipient.** Breaks the "operator can grief but
  not steal" invariant ([CONTEXT.md](../../CONTEXT.md)). Rejected.
- **BYOS debit or freeze over the instance.** Still rejected for the original reason —
  a key over sub-solver execution infrastructure — and now also pointless, since
  nothing rests there.

## Consequences

- The Trampoline loses `claimToken`/`claimTokens`, the `ResidueClaimed` event, and the
  only-sub-solver error; `execute` gains the sweep and the delta check (implementation
  follows ADR-0003). One external entry point remains.
- Sub-solvers hold no on-chain property in the instance and need no claim workflow;
  their compensation is in-route (venue fees) plus whatever they capture above their
  own floor.
- BYOS's weekly settlement-slippage line includes sub-solver over-delivery; any
  per-sub-solver rebate would be an off-chain service choice, not a contract concern.
- ADR-0001's zero-at-rest post-condition is restored as the enforced invariant for
  trade tokens.
