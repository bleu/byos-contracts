# Penalty schedule & attribution

Status: accepted

Spec: docs/shared/design-document.md#penalties
      https://bleu.github.io/byos-docs/design-document#penalties

> Contract-scoped extract of the BYOS slashing-policy design. This ADR records the
> penalty schedule, the escrow debit/freeze flows, and the attribution model the
> contracts serve. The operational side (dispute handling, notification, gatekeeping
> pipeline, monitoring) lives with the BYOS service.

## Context

When CoW imposes a cost on BYOS, BYOS must attribute it to the responsible sub-solver and recover it from escrow ([ADR-0002](0002-escrow-contract.md)) — without being able to fabricate a slash against an honest sub-solver.

CoW's own penalty framework has four enforcement layers (see [`../shared/reference/cow-solver-slashing-policy.md`](../shared/reference/cow-solver-slashing-policy.md)). The specification describes how BYOS maps onto those layers rather than replicating them.

Sub-solvers are responsible for including required pre/post hooks from order app data in their proposal `interactions` — the EIP-712 signature is the sub-solver accepting responsibility for their complete route. Passing BYOS's pre-settlement gatekeeping does not absolve them.

## Decision

The penalty schedule, Track A and Track B flows, `c_l` values, minimum escrow balance sizing, and escrow shortfall policy are defined in the specification.

### Attribution: one sub-solver per settlement tx

Enforce **one sub-solver per settlement tx**. The per-sub-solver Trampoline CREATE2 address ([ADR-0001](0001-trampoline-topology.md)) in the settlement calldata self-evidences which sub-solver's route ran — no reliance on BYOS's private records. This makes Track A debits indisputable and Track B attribution clean.

Cost: less batching efficiency. Accepted — clean attribution is worth more than marginal gas savings from multi-sub-solver settlements.

### Transparency

The Escrow contract's on-chain events are the public record (per [ADR-0002](0002-escrow-contract.md): `Debited`, `Frozen`, `Unfrozen`). No additional public reporting or dashboard. BYOS notifies the affected sub-solver privately with full evidence for any penalty.

### Policy lifecycle

Immutable for v1. No unilateral updates. Changes require a v2 policy with a new escrow deployment or migration.

## Alternatives considered

- **Replicate all four CoW enforcement layers.** Rejected — Layers 1 and 2 are either architecturally prevented or already covered by gatekeeping + escrow + collateral gate. Adding separate participation guards (ban timers) would be redundant.
- **Pass all Layer 3 violations through to sub-solvers** (score inflation, buffer abuse, surplus shifting, overbidding). Rejected — sub-solvers cannot cause most of these violations. BYOS controls score construction, buffer access, and settlement composition.
- **No penalty for non-settlement** (BYOS wins auction but doesn't settle). Rejected — non-settlement degrades BYOS's participation-guard standing with CoW. Sub-solvers should internalize this cost.
- **Credit Track A against Track B for the same settlement.** Rejected — if both penalties hit BYOS, the sub-solver should pay both. The sub-solver's proposal caused both problems.
- **Formal dispute mechanism for Track A with external arbiter.** Rejected — Track A is on-chain-verifiable. BYOS-unilateral adjudication is sufficient given the trust model.
- **Permanent ban or debt tracking on escrow shortfall.** Rejected — meaningless in a permissionless system. New address = new identity. The escrow loss itself is the penalty.
- **Higher minimum escrow (proportional to order value, or fixed large amount).** Rejected — Track B is inherently under-collateralized regardless of minimum size. Low barriers to entry matter for a permissionless system. `gas + c_l` covers the common case (Track A).
- **Public slashing dashboard / reporting.** Rejected — leaks competitive intelligence about sub-solver routing quality. On-chain escrow events are sufficient for the sub-solver to audit their own history.
- **Versioned or updatable policy.** Rejected for v1 — adds complexity. Ship, learn, revisit in v2.

## Consequences

- **Sub-solvers trust BYOS for Track A adjudication.** BYOS is both debitor and dispute judge. Mitigation: Track A parameters are on-chain-verifiable; a provably incorrect debit is an operational bug, not a policy failure. All debits emit events with reasons.
- **Track B has an unrecoverable gap.** If the sub-solver withdrew or escrow < claim, BYOS absorbs the shortfall. This is why gatekeeping is mandatory — it is the primary Track B defense.
- **Non-settlement penalty (10% of `c_l`) relies on BYOS's internal records.** Sub-solvers cannot independently verify that BYOS won an auction with their proposal. Accepted trust assumption, consistent with the operator trust model.
- **One sub-solver per settlement tx reduces batching efficiency.** Accepted — clean attribution enables indisputable Track A debits and clean Track B passthrough.
- **Immutable v1 policy means no ability to adjust parameters.** If 10% of `c_l` for non-settlement proves too low or too high, it stays until v2. Mitigated by conservative initial sizing and the expectation that v1 is a learning phase.
- **36h sub-solver challenge window for Track B is tight.** Sub-solvers need responsive operations to gather evidence within 36h. Accepted — BYOS needs the remaining 36h of its 72h CoW window to process and relay.
