# No on-chain proposal cancellation

Status: accepted

## Context

Sub-solvers submit signed proposals to BYOS off-chain. Once BYOS holds a proposal it
may forward it to the Driver as part of a batch auction. A natural question is whether
sub-solvers should be able to **cancel** a proposal *on-chain* — independent of BYOS —
so they do not have to trust BYOS to honour a cancellation request.

The strawman design: the Trampoline (or Escrow) maintains a mapping
`rejectedProposals(proposalId => bool)`, checked at the start of `execute`. A
sub-solver calls `rejectProposal(id)` and the proposal becomes unexecutable regardless
of what BYOS does.

## Decision

**Proposal cancellation remains off-chain only.** No `rejectedProposals` mapping, no
on-chain cancel transaction. Sub-solvers request cancellation through the BYOS API;
BYOS drops the proposal from its active set.

The reason is that on-chain cancellation introduces revert risk in every scenario where
it could matter, and revert risk is exactly the harm the escrow system exists to
recover from:

1. **Proposal is active in BYOS but not yet submitted to an auction.** On-chain
   cancellation adds nothing — the off-chain path already works: sub-solver asks BYOS
   to cancel, BYOS drops the proposal, the Driver never sees it.

2. **Proposal was submitted to an auction whose outcome is unknown.** Off-chain
   cancellation can still remove the proposal from future auctions. On-chain
   cancellation is dangerous: if the Driver has already selected this proposal as the
   winning solution and submits the settlement, the `rejectedProposals` check reverts
   the transaction. Both BYOS and the sub-solver are penalised (gas + c_l,
   [ADR-0004](0004-penalty-schedule-and-attribution.md)).

3. **Proposal won the auction and settlement is imminent or in-flight.** Off-chain
   cancellation is correctly blocked — the proposal is committed. On-chain cancellation
   *would* succeed at blocking execution, but the result is a guaranteed revert and
   penalty.

Scenarios 2 and 3 share the same failure mode: on-chain cancellation turns a
sub-solver's unilateral action into a settlement revert, penalising BYOS and — through
the escrow debit — the sub-solver itself. Worse, it opens an attack surface: a
malicious actor could deliberately win auctions and cancel on-chain to force reverts,
burning BYOS's gas budget and potentially causing BYOS to become temporarily
unavailable to the protocol.

## Alternatives considered

- **On-chain `rejectedProposals` mapping checked in `execute`.** The design sketched
  above. Rejected because it cannot be used safely in the only scenarios where it
  differs from off-chain cancellation (scenarios 2 and 3), and it introduces a griefing
  vector.
- **Time-locked on-chain cancellation** (cancellation takes effect only after N blocks).
  Mitigates scenario 3 but not scenario 2 — the auction outcome is unknown until the
  Driver commits, and the lock window cannot cover that gap without making cancellation
  useless. Adds contract complexity for no safe operating point.

## Consequences

- Sub-solvers must trust the BYOS service to honour off-chain cancellation requests.
  This is consistent with the broader trust model: BYOS already controls submission
  timing, proposal selection, and settlement construction. Cancellation is one more
  service-layer responsibility.
- No additional storage or gas cost on the Trampoline or Escrow.
- The `valid_until` field on proposals ([ADR-0005](0005-trampoline-execution-authority.md))
  remains the sub-solver's on-chain bound on how long a proposal can be used —
  a natural expiry rather than an active cancellation.
