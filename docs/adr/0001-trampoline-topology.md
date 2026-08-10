# Trampoline topology: one instance per sub-solver

Status: accepted

## Context

The **Trampoline** is the contract that receives `sellAmount`, runs a sub-solver's
arbitrary interactions, and returns `buyAmount` to `GPv2Settlement`
([CONTEXT.md](../../CONTEXT.md);
[RFP §High-Level Design](https://forum.cow.fi/t/rfp-bring-your-own-solver-byos/3469)). The RFP flags two topologies and leaves the call to the
Core-Team Reviewer and grantee in M1:

- a single shared Trampoline with strict allowance hygiene, or
- one instance per sub-solver address.

### Why a Trampoline is needed at all

In `GPv2Settlement.settle`, every interaction executes as a bare `call` from the
settlement contract. `msg.sender` is `GPv2Settlement`, which holds all buffers and can
be made to grant any approval. The only target it hard-blocks is the vault relayer
([`GPv2Settlement.sol#L446-L465`](https://github.com/cowprotocol/contracts/blob/c6b61ce75841ce4c25ab126def9cc981c568e6c6/src/contracts/GPv2Settlement.sol#L446-L465);
`GPv2Interaction.execute`). A
permissionless sub-solver's code must never run in that context, or it would inherit
buffer-spend and arbitrary-approve power over a contract shared by every CoW solver.
The Trampoline re-runs the sub-solver's interactions as itself, isolated from settlement
buffers and approvals. That holds for both topologies, so topology is not what buys
buffer safety.

### Why structural isolation rather than a filter

CoW's settlement contract does almost nothing to stop a solver from draining buffers or
planting approvals; the only hard guard is the vault-relayer block. Its protection is
social and economic. `settle` is `onlySolver`, gated by a manager-curated allowlist
(`authenticator.isSolver`,
[`GPv2Settlement.sol#L87-L89`](https://github.com/cowprotocol/contracts/blob/c6b61ce75841ce4c25ab126def9cc981c568e6c6/src/contracts/GPv2Settlement.sol#L87-L89);
`addSolver`/`removeSolver` are `onlyManager`,
[`GPv2AllowListAuthentication.sol#L86-L97`](https://github.com/cowprotocol/contracts/blob/c6b61ce75841ce4c25ab126def9cc981c568e6c6/src/contracts/GPv2AllowListAuthentication.sol#L86-L97)); vouched solvers post a bond;
and a circuit breaker slashes or jails misbehavior. CoW trusts a permissioned, bonded
set and punishes them, rather than constraining interactions in-contract.

BYOS's sub-solvers are permissionless and unbonded (collateral-gated only), which is
the actor that model refuses to let near `settle`. BYOS cannot reuse CoW's social
boundary, so it rebuilds the boundary structurally: the Trampoline replaces the
`onlySolver` allowlist (a sandbox instead of vouching), escrow replaces the DAO bond,
and debit/slash replace circuit-breaker slashing. A recognize-and-block approve filter
cannot carry that boundary, because CoW itself does not filter and "grant an allowance"
has shapes a filter misses. For example, `Permit2.approve` uses a different target and
selector yet still grants a drainable allowance on a real token. What a sub-solver
cannot get around is a contract isolated from settlement buffers, where each sub-solver
reaches only its own instance.

### What topology actually governs

Because the Trampoline runs sub-solver-authored `call`s as itself, it grants ERC-20
approvals to sub-solver-chosen targets and may hold balances between settlements.
Approvals and balances are persistent contract state. An exploit needs both a planted
approval and a resting balance; per-instance isolation confines both to the same
sub-solver.

The instance may hold residue between settlements — unconsumed sell tokens, intermediate
dust — which is the sub-solver's own property, reclaimable via claim functions
([ADR-0008](0008-residue-disposition.md)). Users are paid by `GPv2Settlement` at clearing
price and the settlement reverts on shortfall, so atomicity protects them upstream of any
residue. Other sub-solvers' collateral lives in escrow and never transits the Trampoline.
The worst case of residue plus a planted approval is a sub-solver draining its own
reclaimable property through its own route-planted approvals — self-harm, not theft of
user, counterparty, or cross-sub-solver funds.

## Decision

Adopt one Trampoline instance per sub-solver address.

Instances live at a deterministic CREATE2 address keyed by the sub-solver address
(recovered from the proposal's EIP-712 signature), counterfactual, with no registry and
no governance step: the address is computed, not tracked. Deployment timing (at
escrow-deposit time, paid by the sub-solver) is settled in
[ADR-0003](0003-trampoline-deployment-settlement-integration.md).

### Allowance hygiene and desired execution

The containment control is per-instance isolation, combined with the balance-delta check
that enforces the buy-token floor ([ADR-0008](0008-residue-disposition.md)):

1. `GPv2Settlement` transfers exactly `sellAmount` of `sellToken` into the instance.
2. The instance runs the sub-solver interactions (approve a router, swap, produce `buyToken`).
3. The instance returns at least `buyAmount` of `buyToken` to `GPv2Settlement`, enforced by
   the balance-delta check. Over-delivery above the floor lands in the settlement as
   BYOS-owned slippage.
4. Tokens remaining on the instance (unconsumed sell tokens, intermediate dust) are the
   sub-solver's property, reclaimable via `claimToken`/`claimTokens`
   ([ADR-0008](0008-residue-disposition.md)).

Approvals are not reset to zero. The invariant we enforce is per-instance isolation
rather than zero approvals, because approvals are per-`(token, spender)` over an
unbounded, sub-solver-authored set and cannot be generically enumerated to reset, whereas
per-instance isolation is a free property of EVM storage isolation. With the instance
isolated per sub-solver, a standing or even over-broad approval can only interact with
that sub-solver's own residue — it drains nothing belonging to the protocol or another
sub-solver. BYOS-encoded approvals to known routers may be left standing and reused
across that sub-solver's future settlements, a gas saving the shared design cannot
safely take. Failed settlements revert atomically, including on-chain reverts, rolling
back any approval set in the attempt, so no dangling-approval cleanup is required.

Defense in depth pairs this containment with a cheap preventive layer. BYOS authors the
approvals itself: exact `sellAmount`, route-derived, granted only to the venues the
route uses (mirroring how the CoW driver separates declared allowances from solver swap
calls in
[`crates/driver/src/domain/competition/solution/encoding.rs`](https://github.com/cowprotocol/services/blob/main/crates/driver/src/domain/competition/solution/encoding.rs)), and
rejects obvious sub-solver-authored `approve`-like calls. This kills the common
planted-approval case at the source and reduces reliance on isolation without replacing
it: "approve-like" is not one selector (`approve`, `increaseAllowance`, EIP-2612 / DAI
`permit`, Permit2, ERC-777 operator grants, and others), and filtering all variants on
arbitrary calldata is the same un-enumerable problem per-instance isolation avoids.
Fully forbidding sub-solver-authored approvals would require structured routes instead
of raw `interactions`, sacrificing permissionless any-DEX generality, so the preventive
layer stays best-effort and per-instance isolation remains the backstop.

### Native ETH wrap/unwrap

The instance performs any required WETH wrap/unwrap internally, within the single
settlement. Native ETH remaining on the instance after execution is reclaimable by the
sub-solver via claim functions using the `BUY_ETH_ADDRESS` sentinel
([ADR-0008](0008-residue-disposition.md)).

## Alternatives considered

A single shared Trampoline is achievable securely: BYOS can enumerate touched tokens and
`(token, spender)` approvals from simulation and append sweep and approval-reset
interactions every settlement. We rejected it for three reasons.

Gas cost recurs instead of amortizing. The shared design pays roughly 30-80k gas for
sweeps and approval resets on every settlement, forever, while per-instance pays a
one-time clone deploy per sub-solver and then runs lighter (no mandatory resets, with
approval reuse). Per-instance is cheaper for any sub-solver that settles more than one
to three times, which covers every repeat winner, and repeat winners are the whole
model.

Safety is fragile rather than structural. Shared safety rests on an enumeration that
must be complete for every exotic token (fee-on-transfer, rebasing, non-standard
`approve`) now and forever, and one miss is a cross-sub-solver hole. Per-instance
containment is a free property of EVM storage isolation.

A shared contract pools risk. The residual that simulation-versus-execution divergence
produces (a different block, MEV, a state-dependent route) collects across all
sub-solvers and is drainable by any one bad actor, including slippage that honest
sub-solvers' trades produced. Per-instance confines that residual to its originating
sub-solver, where draining one's own residue gains nothing.

The hooks-trampoline precedent (`cowprotocol/hooks-trampoline`) is the only safe form of
a shared executor, and it is safe because it never custodies funds or grants approvals;
hooks act through the user's own approvals. A BYOS swap requires the executor to custody
`sellAmount` and approve a router, so that precedent argues against a shared
swap-executor.

Per-instance isolation earns its keep on three separate things: confining residue to its
originating sub-solver, safe approval reuse for gas, and on-chain attribution.

## Consequences

- On-chain attribution ([ADR-0004](0004-penalty-schedule-and-attribution.md)): a
  distinct CREATE2 address per sub-solver means the
  settlement calldata proves which sub-solver's route ran. With the working "one
  sub-solver per settlement tx" decision, the per-instance call is itself the
  attribution, which gives a self-evidencing Track-A escrow debit with no reliance on
  BYOS's private records.
- Deployment is permissionless and deterministic. Anyone may trigger the counterfactual
  deploy, and the address is derived from the sub-solver address. The RFP's stated
  downside of per-instance, "more deploys and bookkeeping", is largely neutralized by
  deterministic addressing.
- The isolation claim this ADR rests on — a route reaches only its own instance's
  balance, never settlement buffers, user funds, escrow collateral, or another instance —
  is proven adversarially against the real `GPv2Settlement` in
  [docs/security/trampoline-settlement-isolation.md](../security/trampoline-settlement-isolation.md).

### Flagged downstream decisions (coupled, not settled here)

Since acceptance, the first two forks were settled by
[ADR-0005](0005-trampoline-execution-authority.md): execution is signature-gated and the
payload is raw interactions. The upgrade-key posture was settled with the
implementation: immutable full contracts per instance, deployed by the factory, with no
proxy and no privileged key ([`Trampoline.sol`](../../src/contracts/Trampoline.sol)).
The original flags are preserved below.

- Execution authority: signature-gated versus BYOS-unilateral. The recommendation is
  signature-gated, so the reverted tx self-evidences exactly what the sub-solver
  authorized and the escrow debit is indisputable. This couples the proposal EIP-712
  schema to the instance's authorization format, so it is settled with the proposal-API
  and attribution ADRs. cow-shed (`cowdao-grants/cow-shed`) is a per-user,
  signature-gated, CREATE2 proxy that already implements this shape and bubbles reverts,
  which BYOS needs, so it is a candidate implementation vehicle against a bespoke
  EIP-1167 clone.
- Proposal payload shape: raw `interactions` versus a structured route. Raw calldata
  preserves any-DEX generality but makes the preventive approve-filter best-effort; a
  structured route (venues plus amounts, BYOS encodes every call) would let BYOS author
  all approvals and forbid sub-solver-authored ones outright, at the cost of generality.
  Settled with the proposal-API ADR; the topology and per-instance isolation hold either
  way.
- Upgrade-key posture: immutable clones versus a cow-shed-style per-instance or beacon
  upgrade. Immutable clones carry no admin key, but a bug means deploying a new
  generation, with counterfactual migration and rotated attribution addresses. A beacon
  gives central upgradeability at the cost of a key over sub-solver execution. The
  recommended lean is immutable with no privileged key, to be confirmed alongside the
  execution-authority choice.
