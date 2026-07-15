## Summary
- Escrow inherits ERC20: tokens minted 1:1 on deposit, burned on withdrawal/debit. `balanceOf` replaces the `balances` mapping as the single source of truth.
- Transfer restrictions via `_update` override: blocked when paused, sender/receiver frozen, or either party has a pending withdrawal. Mints blocked if receiver has pending withdrawal. Burns unrestricted.
- `approve`/`transferFrom` disabled (revert); `allowance` returns 0. Only direct `transfer` is supported.
- Global pause mechanism (`pause`/`unpause`, operator-only) as an emergency brake for incident response.
- Freeze/unfreeze are now idempotent (no-op without event on repeat calls).
- Zero-value deposits now revert. `withdrawDebits` reverts if admin has been renounced.
- ADR-0006 (style conventions from main) stays as-is; the ERC20 escrow token ADR is now **ADR-0007**. All references updated across CONTEXT.md, ADR README, ADR-0002, and the review issues doc.
- New test suites: ERC20, Transfer, Pause, Integration. All in ADR-006 style.

## Test plan
- [x] `forge build` compiles cleanly
- [x] `forge fmt --check` passes
- [x] All 90 tests pass across 9 test suites
- [x] No stale ADR-0006 references in ERC20-related files
- [x] No conflicts with `feat/access-control`

---
*Rebased onto updated `feat/access-control` (post ADR-006 style refactor + main merge). ADR-0006 → ADR-0007 renumbering applied.*
