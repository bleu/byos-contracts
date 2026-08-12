# Trampoline topology: one instance per sub-solver

Status: accepted

Spec: docs/shared/design-document.md#topology
      https://bleu.github.io/byos-docs/design-document#topology

## Context

The **Trampoline** is the contract that receives `sellAmount`, runs a sub-solver's arbitrary interactions, and returns `buyAmount` to `GPv2Settlement` ([CONTEXT.md](../../CONTEXT.md); [RFP §High-Level Design](https://forum.cow.fi/t/rfp-bring-your-own-solver-byos/3469)). The RFP flags two topologies and leaves the call to the Core-Team Reviewer and grantee in M1:

- a single shared Trampoline with strict allowance hygiene, or
- one instance per sub-solver address.

### Why a Trampoline is needed at all

In `GPv2Settlement.settle`, every interaction executes as a bare `call` from the settlement contract, inheriting buffer-spend and arbitrary-approve power. A permissionless sub-solver's code must never run in that context. The Trampoline re-runs the sub-solver's interactions as itself, isolated from settlement buffers and approvals. That holds for both topologies, so topology is not what buys buffer safety.

### Why structural isolation rather than a filter

CoW protects buffers through social and economic means — a permissioned, bonded solver set and circuit-breaker slashing — rather than constraining interactions in-contract. BYOS's sub-solvers are permissionless and unbonded (collateral-gated only), so BYOS cannot reuse CoW's social boundary. It rebuilds it structurally: the Trampoline replaces the allowlist (a sandbox instead of vouching), escrow replaces the bond, and debit/slash replace slashing. A recognize-and-block approve filter cannot carry that boundary — CoW itself does not filter, and "grant an allowance" has shapes a filter misses (e.g., `Permit2.approve`). What a sub-solver cannot get around is a contract isolated from settlement buffers, where each sub-solver reaches only its own instance.

### What topology actually governs

Because the Trampoline runs sub-solver-authored `call`s as itself, it grants ERC-20 approvals to sub-solver-chosen targets and may hold balances between settlements. Approvals and balances are persistent contract state. An exploit needs both a planted approval and a resting balance; per-instance isolation confines both to the same sub-solver.

## Decision

Adopt one Trampoline instance per sub-solver address.

See the specification for the full topology, deployment mechanics, allowance hygiene details, and native ETH handling.

## Alternatives considered

A single shared Trampoline is achievable securely: BYOS can enumerate touched tokens and `(token, spender)` approvals from simulation and append sweep and approval-reset interactions every settlement. We rejected it for three reasons.

Gas cost recurs instead of amortizing. The shared design pays roughly 30-80k gas for sweeps and approval resets on every settlement, forever, while per-instance pays a one-time clone deploy per sub-solver and then runs lighter (no mandatory resets, with approval reuse). Per-instance is cheaper for any sub-solver that settles more than one to three times, which covers every repeat winner, and repeat winners are the whole model.

Safety is fragile rather than structural. Shared safety rests on an enumeration that must be complete for every exotic token (fee-on-transfer, rebasing, non-standard `approve`) now and forever, and one miss is a cross-sub-solver hole. Per-instance containment is a free property of EVM storage isolation.

A shared contract pools risk. The residual that simulation-versus-execution divergence produces (a different block, MEV, a state-dependent route) collects across all sub-solvers and is drainable by any one bad actor, including slippage that honest sub-solvers' trades produced. Per-instance confines that residual to its originating sub-solver, where draining one's own residue gains nothing.

The hooks-trampoline precedent (`cowprotocol/hooks-trampoline`) is the only safe form of a shared executor, and it is safe because it never custodies funds or grants approvals; hooks act through the user's own approvals. A BYOS swap requires the executor to custody `sellAmount` and approve a router, so that precedent argues against a shared swap-executor.

Per-instance isolation earns its keep on three separate things: confining residue to its originating sub-solver, safe approval reuse for gas, and on-chain attribution.

## Consequences

- On-chain attribution ([ADR-0004](0004-penalty-schedule-and-attribution.md)): a distinct CREATE2 address per sub-solver means the settlement calldata proves which sub-solver's route ran. With the working "one sub-solver per settlement tx" decision, the per-instance call is itself the attribution, which gives a self-evidencing Track-A escrow debit with no reliance on BYOS's private records.
- Deployment is permissionless and deterministic. Anyone may trigger the counterfactual deploy, and the address is derived from the sub-solver address.
- The isolation claim this ADR rests on — a route reaches only its own instance's balance, never settlement buffers, user funds, escrow collateral, or another instance — is proven adversarially against the real `GPv2Settlement` in [docs/shared/security/trampoline-settlement-isolation.md](../shared/security/trampoline-settlement-isolation.md).
