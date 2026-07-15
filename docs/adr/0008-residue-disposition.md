# Residue disposition: sub-solver-reclaimable

Status: accepted

## Context

[ADR-0003](0003-trampoline-deployment-settlement-integration.md) fixed the settlement
value flow: `execute` settles back exactly `buyAmount` and whatever the route produced
beyond it stays in the sub-solver's Trampoline instance. It deliberately left the
disposition of that **residue** open. This ADR settles it.

Residue is any balance left in an instance after a settlement: route surplus beyond
`buyAmount`, unconsumed `sellToken`, intermediate-token dust, stray native ETH. There is
no negative counterpart to dispose of — a route that falls short reverts the whole
settlement via the exact-amount transfer guard (ADR-0003), so only positive surplus can
strand.

Two earlier positions are in tension. [ADR-0001](0001-trampoline-topology.md) stated a
sweep post-condition ("the instance ends holding zero of the trade tokens; sweep any
remainder back to `GPv2Settlement`"), treating residue as BYOS's positive slippage. The
implementation that landed in PR #4 instead transfers exactly `buyAmount` and leaves the
rest, per ADR-0003. One of the two had to give.

The PR #4 review also surfaced a replay exposure (COW-1151): once a settlement lands,
the proposal signature and route are public calldata, and while `validUntil` has not
passed any other allow-listed CoW solver can carry a replayed `execute` in their own
settlement. A replayed route that produces less than `buyAmount` pays the difference out
of the instance's residue, credited to the replayer through CoW's slippage accounting.
Whatever the disposition, residue is not safely parked in the meantime.

Directions weighed (from the issue): BYOS-collected (swept and coupled into
collateral/reward accounting), sub-solver-reclaimable (a claim mechanism; residue is a
reward outside the collateral model), or counted into how the BYOS service scores
proposals.

## Decision

Residue is the sub-solver's property, reclaimable through the claim functions on their
instance. It sits entirely outside the collateral model: BYOS has no key over it — no
sweep, no freeze, no debit.

### Why the sub-solver owns it

Surplus is route output beyond what the sub-solver promised. If BYOS swept it to
`GPv2Settlement` (where CoW's slippage accounting would credit it to BYOS), rational
sub-solvers would capture it in-route instead. The surplus amount is unknown at signing
time, so in-route capture means an approval to a sweep-helper contract — precisely the
sub-solver-authored-approval pattern ADR-0001's preventive filter tries to reject.
Confiscation wouldn't collect the value; it would push its capture into the shape we
least want to see in routes. A claim function makes the sanctioned path the easy path.

Ownership also makes ADR-0001's containment argument cleaner rather than weaker. The
planted-approval story was "an approval over an empty contract drains nothing"; with
residue as sub-solver property it becomes "a standing approval reaches only the
sub-solver's own money". Per-instance isolation already guarantees no other party's
value is reachable, so the worst case of a planted approval plus resting residue is the
owner taking their own reward through a side door.

Finally, this keeps the merged hot path untouched: `execute`'s exact-amount transfer
remains the funding guard, with no per-settlement sweep gas.

### The claim functions

```solidity
function claimToken(address token, address recipient) external;
function claimTokens(address[] calldata tokens, address recipient) external;
```

`claimTokens` is the batch form of `claimToken`; both share the same per-token logic.

- Callable only by `SUB_SOLVER`. Gating makes the free `recipient` parameter safe, and
  the recipient matters: the sub-solver key is already load-bearing three ways (proposal
  signer, escrow key, CREATE2 salt) and necessarily lives hot in their infrastructure.
  Forcing residue to pile up at that same hot address would be strictly worse than
  letting them direct it to a treasury.
- Transfers the full balance of each listed token to `recipient`. Partial amounts buy
  nothing. The trampoline stays storage-free, so it cannot know what it holds; the
  caller enumerates tokens off-chain and passes them in.
- Native ETH is claimed with the existing `BUY_ETH_ADDRESS` sentinel in the token array,
  matching `execute`'s settle-back convention.
- Emits a `ResidueClaimed` event per token for off-chain accounting.

One behavior is documented rather than guarded: if `SUB_SOLVER` is a contract, a route
interaction could call back into it and reenter a claim mid-settlement, pulling trade
capital out from under the route. The exact-amount settle-back transfer then reverts,
which reverts the entire settlement — the sub-solver gains nothing and eats their own
Track A debit. Self-harm needs no guard; the transfer-as-guard posture of ADR-0003
already covers it.

### Replay exposure: accepted and documented

Residue is at risk to allow-listed-solver replay for as long as any proposal signed for
the instance is unexpired. This ADR accepts that exposure without a dependency on
COW-1151 (restricting `execute` to BYOS-submitted settlements): the at-risk value
belongs to the party that controls both exposure knobs — the sub-solver chooses
`validUntil` when signing and chooses when to claim. The operational doctrine is that
**the instance is not a wallet**: claim promptly, keep `validUntil` short. COW-1151
remains open as independent hardening, not a precondition.

### Outside the collateral model

Residue is not reachable for Track B recovery. A debit or freeze on the trampoline was
considered and left out of scope: it would put a BYOS key over sub-solver assets on a
contract whose no-privileged-key posture is load-bearing — ADR-0005's signature-gating
argument is exactly that BYOS cannot touch sub-solver assets or fabricate outcomes — and
it would be unenforceable anyway, since a live sub-solver claims within a block while a
Track B certificate takes days to months. Collateral adequacy stays the Escrow's job
alone; the risk table in [CONTEXT.md](../../CONTEXT.md) is unchanged.

### What this supersedes

ADR-0001's allowance-hygiene post-condition (steps 3–4: instance ends holding zero of
the trade tokens, sweep any remainder back to `GPv2Settlement` or revert) is superseded.
The enforced invariant was always the narrower one and is now stated plainly: **the
instance holds no protocol balance at rest** — user funds are protected by settlement
atomicity upstream of any residue, and buffers never transit the instance. "Empty at
rest" becomes an operational expectation the sub-solver has every incentive to maintain,
not a contract invariant.

## Alternatives considered

- **BYOS-collected via in-settlement sweep** (ADR-0001's original post-condition):
  assert `balance >= buyAmount`, transfer the full balance, and let CoW's slippage
  accounting credit it to BYOS. Restores zero-at-rest and leaves nothing for a replay to
  skim, in roughly the same gas. Rejected on incentives: it confiscates the sub-solver's
  alpha, pushing them either to in-route capture helpers (the approval pattern we
  filter) or to quoting with thinner margins that revert more often and land Track A
  debits. It also reopens the merged hot path for an economics question.
- **Reclaimable plus BYOS debit** (residue as collateral of last resort, "unclaimed
  residue is at-risk; claiming makes it yours"): internally coherent, but it trades the
  trampoline's no-key posture for recovery that only ever catches abandoned dust, and it
  dilutes the property-rights rationale this decision rests on. Out of scope; may be
  revisited if abandoned residue turns out to be material.
- **Counted into solution scoring**: not actually an alternative — it is an off-chain
  service concern that composes with any physical disposition. The BYOS service is free
  to score proposals on expected slippage; nothing on-chain hangs on it.
- **Permissionless claim with fixed recipient** (anyone may trigger, funds always to
  `SUB_SOLVER`): no theft surface, but it forces residue onto the hot signer address and
  bricks ETH claims for contract sub-solvers that cannot receive. Rejected.
- **Relayable EIP-712-signed claim**: consistent with the proposal pattern but adds
  replay-salt and expiry machinery for what is usually dust. Rejected.

## Consequences

- The Trampoline gains `claimToken`/`claimTokens`, a `ResidueClaimed` event, and an
  only-sub-solver error.
  It stays storage-free and keeps zero privileged keys.
- ADR-0001's sweep post-condition is superseded (pointer note added there); ADR-0003's
  open question closes.
- Sub-solvers carry an operational duty: enumerate their residue off-chain and claim
  promptly, because unclaimed residue is exposed to replay skim until COW-1151 lands and
  to nothing else.
- Residue never counts toward collateral. The BYOS service must not assume instance
  balances are recoverable when sizing sub-solver exposure.
- Exotic tokens (fee-on-transfer, rebasing) are the claimer's own concern; a claim
  transfers whatever the token contract does with a full-balance transfer.
