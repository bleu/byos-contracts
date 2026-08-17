# Private market-maker use case

Status: accepted

Spec: [design-document#topology](https://bleu.github.io/byos-docs/design-document#topology)

## Context

BYOS sub-solvers today are routing actors: they compute routes through external DEXes,
sign a proposal, and the Trampoline executes those routes in a fund-less sandbox. The
Trampoline receives sell tokens from `GPv2Settlement` at the start of each settlement
and sweeps everything back at the end.

A private market maker (MM) operates differently. It holds its own inventory and prices
trades from it. An MM joining BYOS as a sub-solver would want to hold buy-token
inventory persistently, sign proposals whose route simply transfers buy tokens to the
settlement, and keep its pricing logic entirely off-chain.

The Trampoline itself looked like a natural place to park that inventory — the MM
deposits funds into its instance and the route transfers directly from there. The
problem: the Trampoline receives sell tokens only because BYOS encodes a
`sellToken.transfer(trampoline, sellAmount)` interaction in the settlement. If BYOS
omits that transfer, the MM's route still executes — delivering buy tokens to the
settlement — but the MM never receives the corresponding sell tokens. Those tokens stay
in `GPv2Settlement`'s buffers as BYOS-owned surplus. The MM has no on-chain guarantee
that the funding transfer will be included.

This trust gap does not exist for routing sub-solvers: their routes consume sell tokens
through DEX swaps, so omitting the funding transfer simply reverts the route (the
Trampoline has nothing to swap).

## Decision

**The Trampoline contract is unchanged. Private MMs use an external funds contract or
EOA to hold inventory, with the Trampoline as the execution sandbox only.**

The recommended pattern:

1. The MM deploys its own contract (or uses an EOA) to hold buy-token inventory.
2. The MM grants an ERC-20 approval from that contract to its Trampoline instance.
3. The signed route calls `buyToken.transferFrom(mmContract, settlement, buyAmount)`
   through the Trampoline, pulling inventory directly into `GPv2Settlement`.
4. Sell tokens arrive in the Trampoline via the funding transfer and are swept back to
   the settlement by `execute`. The MM collects them through a route interaction that
   transfers sell tokens from the Trampoline to its own contract before the sweep, or
   retrieves them post-settlement via `claimToken`.

The MM's inventory is safe because the approval is from the MM's contract to the
Trampoline only. The route is signed via `interactionsHash`
([ADR-0005](0005-trampoline-execution-authority.md)), so BYOS cannot substitute
different interactions that would drain the approval. And the Trampoline is isolated
per sub-solver ([ADR-0001](0001-trampoline-topology.md)), so no other actor can invoke
the approval.

## Alternatives considered

- **`shouldUseTransferFrom` flag in the proposal signature.** A boolean field in
  `ProposalData` that, when true, makes the Trampoline pull sell tokens from the
  settlement via `transferFrom` instead of relying on BYOS to encode the funding
  transfer. On-chain, this would require the settlement to have approved the Trampoline,
  and the Trampoline would call `transferFrom` then `approve(settlement, 0)` to reset.
  Rejected for two reasons: it adds a signed field and on-chain branching that increase
  gas cost for every sub-solver (including the majority who do not need it), and MMs
  with significant inventory are unlikely to trust the Trampoline contract with custody
  regardless — they want their own contracts with their own access controls.

- **Use the Trampoline as the inventory contract (trust BYOS).** The MM deposits
  funds into its Trampoline instance and trusts that BYOS will always include the
  funding transfer. This works in practice — BYOS has no incentive to omit it — but the
  trust assumption is stronger than necessary. BYOS controls settlement construction,
  and a bug or compromise could silently drain the MM's inventory. Not recommended, but
  not prevented: a sub-solver may deposit tokens into its instance at its own risk.

## Consequences

- No contract changes. No new fields in the proposal signature. Gas cost is unchanged
  for all sub-solvers.
- Private MMs need their own funds contract (or EOA) with an approval to their
  Trampoline instance. This is additional setup compared to a routing sub-solver.
- The `claimToken` / `claimTokens` functions on the Trampoline remain useful: an MM
  whose route does not explicitly forward sell tokens before the sweep can retrieve them
  post-settlement.
- The sub-solver integration guide documents the recommended MM pattern.
