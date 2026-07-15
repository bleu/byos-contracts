# Trampoline execution authority & proposal signature

Status: accepted

> Contract-scoped extract of the BYOS proposal-API design. This ADR records what the
> Trampoline verifies on-chain: the execution-authority model, the EIP-712 schema, the
> domain separator, and the nonce semantics. The HTTP API itself (endpoints,
> rate limiting, proposal lifecycle, persistence) lives with the BYOS service.

## Context

Sub-solvers submit proposals
`{order_uid, sell_amount, buy_amount, interactions, valid_until, nonce, signature}` to
the BYOS service. [ADR-0001](0001-trampoline-topology.md) flagged two decisions as
coupled to the proposal schema:

- **Execution authority** — whether the Trampoline's `execute` requires a sub-solver
  EIP-712 signature (signature-gated) or BYOS can call it unilaterally.
- **Proposal payload shape** — raw `interactions` (any-DEX generality; approve-filter is
  best-effort) vs structured route (BYOS authors every call, can forbid sub-solver
  approvals; less general).

## Decision

### Execution authority: signature-gated

The Trampoline's `execute` requires an EIP-712 signature from the sub-solver that
commits to the route being executed. A reverted settlement self-evidences exactly what
the sub-solver authorized — the signed data is in the calldata, recoverable from the tx.
This makes Track A escrow debits ([ADR-0004](0004-penalty-schedule-and-attribution.md))
indisputable by any third party, not just BYOS.

Why not BYOS-unilateral:

- Sub-solver signatures ensure BYOS cannot act maliciously. Without on-chain proof of
  what the sub-solver authorized, BYOS could fabricate faults — substitute different
  interactions, submit a settlement that reverts, then debit the sub-solver's escrow
  under Track A. The signature makes each settlement's interactions verifiably consented
  to by the sub-solver, and any tampering fails on-chain verification.
- The gas cost is a single `ecrecover` (~3k gas) per settlement — negligible against DEX
  swap costs.
- Sub-solvers get an on-chain audit trail for disputes, which matters in a
  permissionless system with no pre-existing trust relationship.
- Aligns with cow-shed (`cowdao-grants/cow-shed`), which implements the same pattern: a
  per-user, signature-gated, CREATE2 proxy with revert bubbling.

### Submitter gating: `tx.origin` must hold the Escrow's SUBMITTER_ROLE

The `msg.sender == GPv2Settlement` check alone does not establish *which solver*
submitted the settlement. Once BYOS settles a proposal, its signature and route are
public calldata, and while `validUntil` is live any other allow-listed CoW solver can
carry a replayed `execute` in its own settlement — or front-run the original if it is
visible in a public mempool. A replayed route that produces less than `buyAmount` pays
the difference out of the instance's residue into the attacker's settlement buffer,
where CoW slippage accounting credits it to them. Bounded (only residue is reachable),
but real.

`execute` therefore additionally requires `tx.origin` to hold the Escrow's
`SUBMITTER_ROLE`. `tx.origin` is the right identity signal here: GPv2Settlement exposes
no "current solver" context on-chain, CoW solvers submit `settle()` from an EOA that is
both `msg.sender` to the settlement and `tx.origin`, and EIP-7702 delegation preserves
`tx.origin`. The classic `tx.origin` caveats (contract wallets, ERC-4337) don't apply
because BYOS controls its own submission path.

The allowed-submitter set lives on the Escrow as a role rather than as an immutable
address because submitter rotation is a realistic event (key hygiene, multiple
submission EOAs), and an immutable address would make rotation cascade: new factory →
new EIP-712 domain (all outstanding signatures invalid) → new trampoline addresses →
new Escrow. Role management is `DEFAULT_ADMIN_ROLE` only (the Owner multisig), so the
operator's grief-only threat model is unchanged. To break the resulting circular
constructor dependency, the Escrow deploys the factory from its own constructor:
Escrow, factory, and EIP-712 domain form one deployment generation.

### EIP-712 typed-data schema

```solidity
struct ProposalData {
    bytes32 orderUidHash;      // keccak256(order_uid) — ties to a specific order
    uint256 sellAmount;         // what the sub-solver expects to receive
    uint256 buyAmount;          // what the sub-solver promises to deliver
    bytes32 interactionsHash;   // keccak256(abi.encode(interactions)) — the route
    uint256 validUntil;         // expiry timestamp
    uint256 nonce;              // unique salt for signature uniqueness
}
```

**`interactionsHash` is required.** Without it, BYOS could substitute different
interactions while presenting the same signed amounts — accepting a valid proposal,
substituting broken interactions, submitting (reverts), then debiting the sub-solver
under Track A. With `interactionsHash`, the Trampoline verifies
`keccak256(abi.encode(interactions)) == interactionsHash` before executing; substituted
interactions fail signature verification, preventing the fabricated-fault attack vector.

This differs from CoW order signatures (which don't sign interactions) because the
threat model is inverted: sub-solvers need protection against the *operator*, not the
execution path.

**`escrow_account` is not in the signed struct.** The signer address (recovered from the
signature) IS the escrow key. Adding delegation (sign with key K, collateral from
account E) would complicate the escrow contract's "dumb ledger" design
([ADR-0002](0002-escrow-contract.md)). A sub-solver who wants multiple strategies
deposits separately per address. Delegation is a v2 concern.

### EIP-712 domain separator

```solidity
Eip712Domain {
    name: "BYOS",
    version: "0.1",
    chainId: <chain_id>,
    verifyingContract: <trampoline_factory_address>
}
```

`verifyingContract` is the Trampoline Factory — the CREATE2 deployer for per-sub-solver
instances. It is a natural singleton per chain, per deployment generation. Binding to
the factory cleanly separates contract generations (v1 factory signatures don't verify
against v2). Trampoline instances can hardcode or inherit the factory address (deployed
by it), making on-chain verification straightforward. The factory itself is deployed by
the Escrow's constructor (see submitter gating above), so a generation is anchored by
its Escrow.

### Nonce semantics: unique salt, no enforcement

The nonce is a unique salt that makes each proposal's EIP-712 hash distinct. No ordering
or uniqueness enforcement, either on-chain (trampoline) or off-chain (BYOS).

Fill tracking alone does not prevent replay of `execute`: a settlement need not include
the order at all, so a third party could re-run a live proposal in a tradeless
settlement (the COW-1151 attack). Third-party replay is instead blocked by the
submitter gate above. Replay by BYOS's own submitter remains possible by design — BYOS
is trusted not to resubmit, `validUntil` bounds the window and is enforced on-chain,
and a filled order can't be settled again. Keeping the trampoline storage-free (no
nonce mapping) preserves the immutable, minimal contract design.

### Proposal payload shape: raw interactions

`Vec<{target, value, calldata}>` — the sub-solver encodes arbitrary calls against any
DEX or protocol. The Trampoline executes them as-is.

Restricting to BYOS-known venues (structured routes) would defeat the permissionless
any-DEX value proposition. [ADR-0001](0001-trampoline-topology.md) resolved that
per-instance isolation + zero-balance sweep is the robust containment layer, and the
approve-filter is best-effort defense-in-depth. The sub-solver is fully responsible for
the complete route, including required hooks and approvals. BYOS can only accept or
reject at gatekeeping, never patch.

## Alternatives considered

- **BYOS-unilateral execution (no signature on trampoline).** Simpler (no `ecrecover`),
  but sub-solvers have zero on-chain proof of consent. BYOS could fabricate faults.
  Rejected — the trust cost outweighs the small gas saving.
- **No `interactionsHash` in signed struct (sign amounts only).** Follows the CoW order
  pattern more closely, but opens the fabricated-fault vector (substitute interactions,
  blame sub-solver for revert). Rejected — the threat model is inverted vs CoW orders.
- **`escrow_account` in signed struct (delegated collateral).** Allows signing with one
  key, collateral from another. Rejected for v1 — complicates the escrow contract, and
  signer == escrow key is the cleanest invariant. Delegation is a v2 concern.
- **Monotonic on-chain nonce (trampoline stores nonce mapping).** Strongest replay
  protection, but adds storage writes to the trampoline. Rejected — third-party replay
  is blocked by the submitter gate, BYOS-side replay is bounded by `validUntil` and
  fill tracking; keeping the trampoline storage-free is more valuable.
- **Executed-digest mapping instead of submitter gating.** Mark each proposal digest on
  first execution; replays revert. Keyless, but adds an SSTORE per settlement and does
  not stop a rival solver front-running the original settlement from a public mempool —
  the gate closes both. Rejected.
- **BYOS co-signature on execute.** A second EIP-712 signature from a BYOS key becomes
  public calldata itself and is equally replayable unless paired with storage. Rejected
  — key management without closing the hole.
- **Immutable submitter address (in factory or instances).** Purest no-key posture, but
  submitter rotation would force redeploying the whole generation, including the Escrow
  and every sub-solver's collateral cycle. Rejected.
- **Factory-held submitter allowlist.** Equivalent power to the Escrow role, but adds a
  second admin surface next to the Escrow's existing `AccessControlDefaultAdminRules`.
  Rejected in favor of one admin surface; the Escrow deploys the factory to avoid the
  circular constructor dependency.
- **Structured routes instead of raw interactions.** BYOS encodes every low-level call,
  can forbid sub-solver approvals entirely. Rejected — kills any-DEX generality,
  requires BYOS to maintain a venue registry, bottlenecks sub-solver innovation.

## Consequences

- **The Trampoline Factory becomes a domain anchor.** The EIP-712 domain binds to the
  factory address, so a factory redeployment (v2) invalidates all outstanding
  signatures — clean generation separation, but sub-solver clients must update their
  domain configuration.
- **Sub-solvers must include all required interactions (hooks, approvals) in their
  proposals.** The signature covers the complete route; a sub-solver who passes
  gatekeeping but causes an EBBO violation is still liable (gatekeeping is
  non-exculpatory per [ADR-0004](0004-penalty-schedule-and-attribution.md)).
- **The signature address is load-bearing three ways.** One address is the proposal
  signer, the escrow key, and the Trampoline CREATE2 salt. Rotating a sub-solver key
  means a new escrow deposit and a new trampoline instance.
- **BYOS must submit settlements directly from EOAs holding SUBMITTER_ROLE.** The
  `tx.origin` gate ties submission to keys the Owner has granted; a submission path
  where the originating EOA is not the granted key (e.g. a third-party relayer signing
  with its own key) would fail the gate. Rotation is a `grantRole`/`revokeRole` on the
  Escrow, not a redeploy.
- **Trampoline execution now reads Escrow state.** The instances are no longer
  dependency-free: `execute` performs two staticcalls into the Escrow per settlement
  (role id + role check), and a compromised Owner could block settlements by revoking
  all submitters — no worse than the pre-existing Owner trust.
