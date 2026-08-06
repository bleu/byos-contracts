## Summary
- Escrow inherits ERC20: tokens minted 1:1 on deposit, burned on withdrawal/debit. `balanceOf` replaces the `balances` mapping as the single source of truth.
- Transfer restrictions via `_update` override: blocked when paused, sender/receiver frozen, or either party has a pending withdrawal. Mints blocked if receiver has pending withdrawal. Burns unrestricted.
- `approve`/`transferFrom` disabled (revert); `allowance` returns 0. Only direct `transfer` is supported.
- Global pause mechanism (`pause`/`unpause`, operator-only) as an emergency brake for incident response.
- Freeze/unfreeze are now idempotent (no-op without event on repeat calls).
- Zero-value deposits now revert. `withdrawDebits` reverts if admin has been renounced.
- ADR-0006 (style conventions from main) stays as-is; the ERC20 escrow token ADR is now **ADR-0007**. All references updated across CONTEXT.md, ADR README, ADR-0002, and the review issues doc.
- New test suites: ERC20, Transfer, Pause, Integration. All in ADR-006 style.

## Gas optimizations

Three optimizations were applied to the Trampoline contract, reducing overhead from ~69k to ~64k gas:

**Inline `SUBMITTER_ROLE` hash** (-655 gas): The Trampoline previously made two external calls to the Escrow — `SUBMITTER_ROLE()` to fetch the role hash, then `hasRole()` to check membership. Since the role hash is a constant (`keccak256('SUBMITTER_ROLE')`), it is now inlined as a file-level constant, eliminating the first external call.

**Assembly for hashing, ecrecover, and interaction dispatch** (-1,120 gas): Three hot paths were rewritten in inline assembly:

- _Interaction dispatch loop_: Solidity allocates `bytes memory _returnData` on every `call`, even on success when the data is never read. The assembly version skips return data allocation on success and only copies return data on revert (for error bubbling).
- _EIP-712 hashing_: The struct hash and typed data hash are built in scratch memory without advancing the free memory pointer, avoiding `abi.encode` memory allocation.
- _Signature recovery_: Raw `ecrecover` precompile call replaces the OpenZeppelin `ECDSA.recover` library, skipping s-value malleability checks and signature length validation. The nonce in the proposal handles replay; s-malleability is not a concern.

**Remove buy-token sweep** (-3,300 gas): Routes now deliver buy-token output directly to the settlement contract, so the buy-token sweep was always a no-op (cold `balanceOf` finding zero balance). Removed it; only the sell-token sweep remains (returns unconsumed input for buy orders).

| | Gas |
|---|---|
| Before optimizations | 268,981 |
| After inline submitter role | 268,326 |
| After assembly optimizations | 267,206 |
| After removing buy-token sweep | ~263,900 |
| **Total saved** | **~5,100** |

## Test plan
- [x] `forge build` compiles cleanly
- [x] `forge fmt --check` passes
- [x] All 90 tests pass across 9 test suites
- [x] No stale ADR-0006 references in ERC20-related files
- [x] No conflicts with `feat/access-control`

---
*Rebased onto updated `feat/access-control` (post ADR-006 style refactor + main merge). ADR-0006 → ADR-0007 renumbering applied.*
