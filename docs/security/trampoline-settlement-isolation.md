# Trampoline isolation from GPv2Settlement funds

Status: proven (COW-1152)

## What this guarantees

A sub-solver authors an arbitrary route — a list of `(target, value, callData)`
interactions — that the Trampoline runs during a settlement. This document states, and
backs with tests, what such a route can and cannot reach.

The guarantee is structural rather than filtered. Routes execute as the Trampoline
instance (`msg.sender` is the instance), never as `GPv2Settlement`, so they inherit none
of the settlement's buffer-spend or approval-granting authority ([ADR-0001](../adr/0001-trampoline-topology.md)).
The Trampoline holds no funds at rest beyond its own sub-solver's residue, and each
sub-solver has a distinct instance, so the blast radius of any route is that one
instance's leftovers.

The tests demonstrate this against the **real deployed `GPv2Settlement`** on a mainnet
fork, not a mock — the point is to exercise CoW's actual semantics (allowance checks,
`onlySolver`, the reentrancy guard, owner-scoped order state), since a mock would only
restate our own assumptions. A controlled ERC-20 buffer is seeded into the settlement in
`setUp`, so every "no value moved" assertion runs against real, non-zero value rather
than a vacuous zero-to-zero.

The invariant asserted is that value does not move — buffer balances, allowances, and
order state are unchanged after the route runs. A revert is one mechanism that enforces
this, but it is not the bar: several attacks are also proven inside a settlement that
**succeeds** (the failed attack swallowed so the transaction finalizes), because a real
adversary wants the settlement to complete unattributed rather than self-abort.

## Reachability

| Target | Reachable by a route | Why | Backing |
| --- | --- | --- | --- |
| Own instance residue | **yes** | The route runs as the instance, so it moves the instance's own balance freely. This is the boundary's positive edge: the same token held by the settlement is untouched. | `test_route_can_sweep_its_own_residue` |
| Settlement token buffers | no | A `transferFrom` from the settlement needs an allowance the settlement never granted the instance; it reverts. Proven both as a bubbled revert and inside a *successful* settlement where the revert is swallowed. | `test_route_cannot_transferFrom_settlement_buffer`, `test_settlement_succeeds_but_buffer_transferFrom_moves_nothing` |
| Settlement via re-entering `settle()` | no | `settle` is `nonReentrant onlySolver`. A route always runs inside a live `settle`, so the reentrancy guard (the first modifier) reverts before `onlySolver` is even reached. `onlySolver` is the backstop that applies if the guard weren't engaged — the instance is not an allow-listed solver. | `test_route_cannot_reenter_settle` (guard), `test_route_settle_call_is_rejected_by_onlySolver` (backstop) |
| Another party's order state | no | `setPreSignature` and `invalidateOrder` require the order's encoded owner to equal `msg.sender`. A route is the instance, so it cannot pre-sign or cancel an order owned by anyone else; the victim's state is unchanged. | `test_route_cannot_presign_another_owners_order`, `test_route_cannot_invalidate_another_owners_order` |
| Own order state | yes, but inert | A route can pre-sign an order it owns (owner == the instance), but nobody places orders naming a Trampoline, and the pre-signature grants no pull power over any buffer. | `test_route_can_presign_own_order_but_moves_nothing` |
| Vault-relayer allowances (user funds) | no | The vault relayer pulls users' sell tokens and is `onlyCreator` — only the settlement may call it. A route calling it is rejected at the gate even against a user who really approved the relayer. | `test_route_cannot_pull_through_vault_relayer` |
| Other instances' residue | no | Cross-instance isolation is a property of per-instance EVM storage; an approval or call from one instance grants nothing over another's balance. | Cited: `test_route_cannot_call_another_instances_execute`, `test_planted_approval_cannot_reach_other_instances_residue`, `test_signature_from_other_factory_generation_fails` (`test/Trampoline/Trampoline.t.sol`, PR #4) |
| Escrow collateral | no | Collateral lives in the `Escrow` contract, which never routes funds through a Trampoline; payouts are gated to escrow's own access-controlled roles, unreachable from a route. | Cited: `test/Escrow/AccessControl.t.sol`, `test/Escrow/SubSolverActions.t.sol` |

Two directions are deliberately inert rather than blocked, because they move value
*toward* the settlement:

| Action | Effect | Backing |
| --- | --- | --- |
| Approving the settlement | Grants the settlement an allowance over the *instance's* funds, not the reverse; the instance holds nothing for it to reach. | `test_route_approving_settlement_is_inert` |
| Sending native value at the settlement | A one-way donation; the settlement ends richer, the instance poorer, nothing extracted. | `test_route_sending_value_at_settlement_is_inert` |

## Running the proofs

The suite (`test/fork/SettlementIsolation.t.sol`) is fork-gated. It uses a public RPC by
default, so it runs in CI without extra configuration; override with `MAINNET_RPC_URL`,
or set it empty to skip when offline.

```
MAINNET_RPC_URL=<url> forge test --match-path test/fork/SettlementIsolation.t.sol
```
