# Trampoline execution authority & proposal signature

Status: accepted

Spec: docs/shared/design-document.md#execution-authority
      https://bleu.github.io/byos-docs/design-document#execution-authority

> Contract-scoped extract of the BYOS proposal-API design. This ADR records what the
> Trampoline verifies on-chain: the execution-authority model, the EIP-712 schema, the
> domain separator, and the nonce semantics. The HTTP API itself (endpoints,
> rate limiting, proposal lifecycle, persistence) lives with the BYOS service.

## Context

Sub-solvers submit proposals `{order_uid, sell_amount, min_buy_amount, quoted_buy_amount, interactions, valid_until, nonce, signature}` to the BYOS service. [ADR-0001](0001-trampoline-topology.md) flagged two decisions as coupled to the proposal schema:

- **Execution authority** — whether the Trampoline's `execute` requires a sub-solver EIP-712 signature (signature-gated) or BYOS can call it unilaterally.
- **Proposal payload shape** — raw `interactions` (any-DEX generality; approve-filter is best-effort) vs structured route (BYOS authors every call, can forbid sub-solver approvals; less general).

## Decision

### Execution authority: signature-gated

The Trampoline's `execute` requires an EIP-712 signature from the sub-solver that commits to the route being executed. A reverted settlement self-evidences exactly what the sub-solver authorized — the signed data is in the calldata, recoverable from the tx. This makes Track A escrow debits ([ADR-0004](0004-penalty-schedule-and-attribution.md)) indisputable by any third party, not just BYOS.

Why not BYOS-unilateral:

- Sub-solver signatures ensure BYOS cannot act maliciously. Without on-chain proof of what the sub-solver authorized, BYOS could fabricate faults — substitute different interactions, submit a settlement that reverts, then debit the sub-solver's escrow under Track A. The signature makes each settlement's interactions verifiably consented to by the sub-solver, and any tampering fails on-chain verification.
- The gas cost is a single `ecrecover` (~3k gas) per settlement — negligible against DEX swap costs.
- Sub-solvers get an on-chain audit trail for disputes, which matters in a permissionless system with no pre-existing trust relationship.
- Aligns with cow-shed (`cowdao-grants/cow-shed`), which implements the same pattern: a per-user, signature-gated, CREATE2 proxy with revert bubbling.

### Submitter gating: `tx.origin` must hold the Escrow's SUBMITTER_ROLE

Once BYOS settles a proposal, its signature and route are public calldata, so while `validUntil` is live any other allow-listed CoW solver could replay or front-run the `execute` in its own settlement — rerunning the signed route outside BYOS's control and muddying Track A attribution. `execute` therefore also requires `tx.origin` to hold the Escrow's grantable `SUBMITTER_ROLE` — granted at deploy time to the solver EOA and, for parallel submission through CoW's `Solver7702Delegate`, each approved auxiliary account.

### Proposal payload shape: raw interactions

`Vec<{target, value, calldata}>` — the sub-solver encodes arbitrary calls against any DEX or protocol. The Trampoline executes them as-is.

Restricting to BYOS-known venues (structured routes) would defeat the permissionless any-DEX value proposition. [ADR-0001](0001-trampoline-topology.md) resolved that per-instance isolation is the robust containment layer, and the approve-filter is best-effort defense-in-depth. The sub-solver is fully responsible for the complete route, including required hooks and approvals. BYOS can only accept or reject at gatekeeping, never patch.

The EIP-712 signed struct is `ProposalData` with seven fields: `orderUidHash`, `sellAmount`, `minBuyAmount`, `quotedBuyAmount`, `interactionsHash`, `validUntil`, `nonce`. The Solidity `Proposal` struct omits `interactionsHash` (recomputed on-chain from the interactions supplied at execution time). The `minBuyAmount`/`quotedBuyAmount` split allows sub-solvers to opt into loose slippage — see [ADR-0003](0003-trampoline-deployment-settlement-integration.md) for the floor/ceiling semantics. See the specification for the full domain separator and nonce semantics.

## Alternatives considered

- **BYOS-unilateral execution (no signature on trampoline).** Simpler (no `ecrecover`), but sub-solvers have zero on-chain proof of consent. BYOS could fabricate faults. Rejected — the trust cost outweighs the small gas saving.
- **No `interactionsHash` in signed struct (sign amounts only).** Follows the CoW order pattern more closely, but opens the fabricated-fault vector (substitute interactions, blame sub-solver for revert). Rejected — the threat model is inverted vs CoW orders.
- **`escrow_account` in signed struct (delegated collateral).** Allows signing with one key, collateral from another. Rejected for v1 — complicates the escrow contract, and signer == escrow key is the cleanest invariant. Delegation is a v2 concern.
- **Monotonic on-chain nonce (trampoline stores nonce mapping).** Initially rejected in favor of a storage-free trampoline, then adopted (COW-1254): the nonce mapping provides hard replay protection independent of BYOS trust, at the cost of one SSTORE per settlement (~20k gas cold / 5k warm). The submitter gate remains for third-party replay; the nonce check hardens against BYOS-side replay.
- **Executed-digest mapping instead of submitter gating.** Mark each proposal digest on first execution; replays revert. Keyless, but adds an SSTORE per settlement and does not stop a rival solver front-running the original settlement from a public mempool — the gate closes both. Rejected.
- **BYOS co-signature on execute.** A second EIP-712 signature from a BYOS key becomes public calldata itself and is equally replayable unless paired with storage. Rejected — key management without closing the hole.
- **Immutable submitter address (in factory or instances).** Purest no-key posture, but submitter rotation would force redeploying the whole generation, including the Escrow and every sub-solver's collateral cycle. Rejected.
- **Factory-held submitter allowlist.** Equivalent power to the Escrow role, but adds a second admin surface next to the Escrow's existing `AccessControlDefaultAdminRules`. Rejected in favor of one admin surface; the Escrow deploys the factory to avoid the circular constructor dependency.
- **Structured routes instead of raw interactions.** BYOS encodes every low-level call, can forbid sub-solver approvals entirely. Rejected — kills any-DEX generality, requires BYOS to maintain a venue registry, bottlenecks sub-solver innovation.

## Consequences

- **The Trampoline Factory becomes a domain anchor.** The EIP-712 domain binds to the factory address, so a factory redeployment (v2) invalidates all outstanding signatures — clean generation separation, but sub-solver clients must update their domain configuration.
- **Sub-solvers must include all required interactions (hooks, approvals) in their proposals.** The signature covers the complete route; a sub-solver who passes gatekeeping but causes an EBBO violation is still liable (gatekeeping is non-exculpatory per [ADR-0004](0004-penalty-schedule-and-attribution.md)).
- **The signature address is load-bearing three ways.** One address is the proposal signer, the escrow key, and the Trampoline CREATE2 salt. Rotating a sub-solver key means a new escrow deposit and a new trampoline instance.
- **BYOS must submit settlements from EOAs holding SUBMITTER_ROLE.** The `tx.origin` gate ties submission to keys the Owner has granted; a submission path where the originating EOA is not a granted key (e.g. a third-party relayer signing with its own key) would fail the gate. Rotation is a `grantRole`/`revokeRole` on the Escrow, not a redeploy.
- **The submitter set must stay in sync with the 7702 delegate's approved callers.** `Solver7702Delegate`'s auxiliary accounts are immutable constructor arguments, so rotating an auxiliary key or adding lanes means a new delegate deploy plus a fresh EIP-7702 authorization — and matching `grantRole`/`revokeRole` calls on the Escrow. This is a deployment-runbook item, not a contract change; an auxiliary account missing its grant fails settlements at the Trampoline, it does not create risk.
- **Trampoline execution now reads Escrow state.** The instances are no longer dependency-free: `execute` performs two staticcalls into the Escrow per settlement (role id + role check), and a compromised Owner could block settlements by revoking all submitters — no worse than the pre-existing Owner trust.
- **Sub-solvers must use unique nonces.** Each nonce value is consumed on first execution and permanently rejected afterwards. Sub-solvers are responsible for tracking which nonces they have used (or using a scheme like random `uint256` values that is statistically collision-free). Resubmitting a proposal with a consumed nonce reverts at the trampoline.
