# Penalty schedule & attribution

Status: accepted

> Contract-scoped extract of the BYOS slashing-policy design. This ADR records the
> penalty schedule, the escrow debit/freeze flows, and the attribution model the
> contracts serve. The operational side (dispute handling, notification, gatekeeping
> pipeline, monitoring) lives with the BYOS service.

## Context

When CoW imposes a cost on BYOS, BYOS must attribute it to the responsible sub-solver
and recover it from escrow ([ADR-0002](0002-escrow-contract.md)) — without being able to
fabricate a slash against an honest sub-solver.

CoW's own penalty framework has four enforcement layers (see
[`../reference/cow-solver-slashing-policy.md`](../reference/cow-solver-slashing-policy.md)):

1. **Smart contract** (limit price reverts, whitelist) — architecturally prevented by
   the Trampoline ([ADR-0001](0001-trampoline-topology.md)); sub-solvers never call
   `settle`.
2. **Automated off-chain** (participation guards, banning) — subsumed by BYOS's
   gatekeeping + Track A escrow debits + collateral gate. No separate replication
   needed.
3. **DAO governance** (EBBO, score inflation, surplus shifts, overbidding, hooks,
   catch-all) — only **EBBO/unfair pricing** and the **catch-all** apply to sub-solvers.
   Score inflation, illegal buffer usage, surplus shifting, and overbidding are either
   architecturally prevented or are BYOS's own responsibility (BYOS controls score
   construction, buffer access, and settlement composition).
4. **Economic penalties** (reward formula, `missingScore`, `c_l` cap) — mirrored via the
   Track A `gas + c_l` debit. Sub-solvers receive no rewards in v1, so the escrow debit
   is the only lever.

Sub-solvers are responsible for including required pre/post hooks from order app data in
their proposal `interactions` — the EIP-712 signature is the sub-solver accepting
responsibility for their complete route. Passing BYOS's pre-settlement gatekeeping does
not absolve them.

## Decision

### Penalty schedule

| Scenario | Track | Amount | Timing | Dispute | Arbiter |
|---|---|---|---|---|---|
| Settlement reverts on-chain | A | `gas + c_l` | Immediate debit | 72h | BYOS |
| Settlement misses block deadline | A | `gas + c_l` | Immediate debit | 72h | BYOS |
| Won auction, BYOS chose not to settle | A (non-settlement) | 10% of `c_l` | Immediate debit | 72h | BYOS |
| EBBO / unfair pricing | B | CoW certificate amount | Freeze on receipt | 36h | CoW core team |
| Catch-all malicious behavior | B | CoW-determined amount | Freeze on receipt | 36h | CoW core team |

**Stacking:** Track A and Track B penalties for the same settlement stack. No crediting
of Track A against Track B — if a settlement causes both a revert and an EBBO ruling,
the sub-solver pays both.

### Track A — revert & gas penalties (routine, fast, provable)

| Stage | Actor | What happens | Timing |
|---|---|---|---|
| Trigger | Chain | Settlement tx reverts, misses deadline, or BYOS elects not to settle after winning | T₀ |
| Debit | BYOS | Operator calls `debit(S, amount, reason)` for `gas + c_l` (revert/deadline) or `0.1 × c_l` (non-settlement) | T₀ + seconds |
| Dispute | Sub-solver | 72h window; narrow grounds: wrong attribution, tx didn't revert, amount exceeds `gas + c_l` | 72h |
| Resolution | BYOS | BYOS reviews and decides (unilateral) | After dispute window |

Track A is BYOS-unilateral. For reverts and deadline misses, everything is
on-chain-verifiable (tx receipt, gas cost, Trampoline CREATE2 address → sub-solver
attribution per [ADR-0001](0001-trampoline-topology.md)). The non-settlement
sub-category is based on BYOS's internal auction records and is not independently
verifiable by the sub-solver — this is an accepted trust assumption.

A settlement that reverts because of BYOS's own orchestration (e.g., a non-deployed
trampoline after a deposit-tx reorg) is an infra failure and must not trigger a Track A
debit ([ADR-0003](0003-trampoline-deployment-settlement-integration.md)).

### Track B — EBBO / fairness passthrough (rare, slow, CIP-52 mirror)

```
CoW core team ──EBBO certificate──▶ BYOS ──slash claim──▶ sub-solver S
   (72h for BYOS to comply/challenge)     (36h window inside BYOS's 72h)
```

| Stage | Actor | What happens | Timing |
|---|---|---|---|
| Trigger | CoW core team | EBBO certificate against a BYOS settlement | T_c (days to 3 months post-trade) |
| Identify | BYOS | Maps cited settlement → proposal → sub-solver S | T_c + minutes |
| Freeze + notify | Escrow operator | `freeze(S)` blocks withdrawal; BYOS notifies S with full evidence (certificate, settlement ref, amount) | T_c + minutes |
| Challenge | S → BYOS → CoW | S supplies refutation within 36h; BYOS relays into its CoW challenge | 36h |
| Resolution | CoW | Upholds or overturns | Within BYOS's 72h |
| Settle | BYOS + Escrow | Upheld: operator calls `debit(S, amount, reason)`, BYOS reimburses CoW; shortfall → BYOS absorbs. Overturned: `unfreeze(S)` | After resolution |

Arbiter: **CoW core team** — they already adjudicate EBBO; routing Track B to them
ensures BYOS cannot fabricate a certificate. Sub-solvers receive the same evidence
standard, challenge window, and appeal rights that CoW gives BYOS.

### Attribution: one sub-solver per settlement tx

Enforce **one sub-solver per settlement tx**. The per-sub-solver Trampoline CREATE2
address ([ADR-0001](0001-trampoline-topology.md)) in the settlement calldata
self-evidences which sub-solver's route ran — no reliance on BYOS's private records.
This makes Track A debits indisputable and Track B attribution clean.

Cost: less batching efficiency. Accepted — clean attribution is worth more than marginal
gas savings from multi-sub-solver settlements.

### `c_l` values

Referenced from CoW's reward mechanism by pointer (read from CoW's accounting/reward
contract or API at debit time). Hardcoded fallback for v1 if the on-chain source isn't
cleanly accessible. Current values:

| Chain | `c_l` |
|---|---|
| Ethereum | 0.010 ETH |
| Gnosis | 10 xDAI |

### Minimum escrow balance

Sized to cover worst-case Track A: `gas + c_l` for a single settlement. This keeps the
barrier to entry low for a permissionless system. Track B is inherently
under-collateralized (claims arrive months later, in a different token); gatekeeping is
the primary Track B defense, not escrow sizing.

### Escrow shortfall

If a Track B claim exceeds the sub-solver's escrow balance, BYOS drains the remaining
balance and absorbs the shortfall. The sub-solver is naturally suspended (zero
collateral = ineligible for proposals). No permanent ban, no debt tracking — bans are
meaningless in a permissionless system; the escrow loss is the penalty.

### Transparency

The Escrow contract's on-chain events are the public record (per
[ADR-0002](0002-escrow-contract.md): `Debited`, `Frozen`, `Unfrozen`). No additional
public reporting or dashboard. BYOS notifies the affected sub-solver privately with full
evidence for any penalty.

### Policy lifecycle

Immutable for v1. No unilateral updates. Changes require a v2 policy with a new escrow
deployment or migration.

## Alternatives considered

- **Replicate all four CoW enforcement layers.** Rejected — Layers 1 and 2 are either
  architecturally prevented or already covered by gatekeeping + escrow + collateral
  gate. Adding separate participation guards (ban timers) would be redundant.
- **Pass all Layer 3 violations through to sub-solvers** (score inflation, buffer abuse,
  surplus shifting, overbidding). Rejected — sub-solvers cannot cause most of these
  violations. BYOS controls score construction, buffer access, and settlement
  composition.
- **No penalty for non-settlement** (BYOS wins auction but doesn't settle). Rejected —
  non-settlement degrades BYOS's participation-guard standing with CoW. Sub-solvers
  should internalize this cost.
- **Credit Track A against Track B for the same settlement.** Rejected — if both
  penalties hit BYOS, the sub-solver should pay both. The sub-solver's proposal caused
  both problems.
- **Formal dispute mechanism for Track A with external arbiter.** Rejected — Track A is
  on-chain-verifiable. BYOS-unilateral adjudication is sufficient given the trust model.
- **Permanent ban or debt tracking on escrow shortfall.** Rejected — meaningless in a
  permissionless system. New address = new identity. The escrow loss itself is the
  penalty.
- **Higher minimum escrow (proportional to order value, or fixed large amount).**
  Rejected — Track B is inherently under-collateralized regardless of minimum size. Low
  barriers to entry matter for a permissionless system. `gas + c_l` covers the common
  case (Track A).
- **Public slashing dashboard / reporting.** Rejected — leaks competitive intelligence
  about sub-solver routing quality. On-chain escrow events are sufficient for the
  sub-solver to audit their own history.
- **Versioned or updatable policy.** Rejected for v1 — adds complexity. Ship, learn,
  revisit in v2.

## Consequences

- **Sub-solvers trust BYOS for Track A adjudication.** BYOS is both debitor and dispute
  judge. Mitigation: Track A parameters are on-chain-verifiable; a provably incorrect
  debit is an operational bug, not a policy failure. All debits emit events with
  reasons.
- **Track B has an unrecoverable gap.** If the sub-solver withdrew or escrow < claim,
  BYOS absorbs the shortfall. This is why gatekeeping is mandatory — it is the primary
  Track B defense.
- **Non-settlement penalty (10% of `c_l`) relies on BYOS's internal records.**
  Sub-solvers cannot independently verify that BYOS won an auction with their proposal.
  Accepted trust assumption, consistent with the operator trust model.
- **One sub-solver per settlement tx reduces batching efficiency.** Accepted — clean
  attribution enables indisputable Track A debits and clean Track B passthrough.
- **Immutable v1 policy means no ability to adjust parameters.** If 10% of `c_l` for
  non-settlement proves too low or too high, it stays until v2. Mitigated by
  conservative initial sizing and the expectation that v1 is a learning phase.
- **36h sub-solver challenge window for Track B is tight.** Sub-solvers need responsive
  operations to gather evidence within 36h. Accepted — BYOS needs the remaining 36h of
  its 72h CoW window to process and relay.
