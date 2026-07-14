# ERC20 Escrow Refactor — Review Issues

Review of `Escrow.sol` after the ERC20 refactor ([ADR-0007](adr/0007-erc20-escrow-token.md)).

---

All identified issues have been resolved:

- **Admin renouncement burning debits** — `withdrawDebits()` now reverts with `NoAdmin()`
  when `defaultAdmin() == address(0)`. Documented in ADR-0007 consequences.
- **Zero-value deposits** — `deposit()` now reverts with `ZeroValue()` on `msg.value == 0`.
- **Freeze/unfreeze no-op events** — `freeze()`/`unfreeze()` now early-return when state
  is unchanged, avoiding spurious events.
- **`allowance()` vs ADR text** — ADR-0007 updated to match implementation (returns 0).
- **Ownership interface undocumented** — ADR-0007 interface section now documents the
  `AccessControlDefaultAdminRules` replacement.
