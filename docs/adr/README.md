# Architecture Decision Records

One file per crystallized decision: `NNNN-short-slug.md`, numbered from `0001`. ADRs are
**append-only** — when a decision changes, write a new ADR that supersedes the old one
rather than editing history. Each ADR states: **context**, the **decision**,
**alternatives considered**, and **consequences**. Terminology comes from
[`CONTEXT.md`](../../CONTEXT.md).

This repo owns the contract-scoped ADRs for BYOS. ADR-0004 and ADR-0005 are
contract-scoped extracts of broader design decisions; their API and operations aspects
live with the BYOS service.

## Decisions

| ADR | Decision | Status |
|-----|----------|--------|
| [0001](0001-trampoline-topology.md) | Trampoline topology: one instance per sub-solver | accepted |
| [0002](0002-escrow-contract.md) | Escrow contract design (auth, withdrawal/freeze, FX) | accepted |
| [0003](0003-trampoline-deployment-settlement-integration.md) | Trampoline deployment & settlement integration | accepted |
| [0004](0004-penalty-schedule-and-attribution.md) | Penalty schedule & attribution | accepted |
| [0005](0005-trampoline-execution-authority.md) | Trampoline execution authority & proposal signature | accepted |
| [0006](0006-solidity-style-and-natspec.md) | Solidity coding style & natspec conventions | accepted |
| [0008](0008-residue-disposition.md) | Residue disposition: sub-solver-reclaimable | accepted |

## Known open questions

- **Trampoline upgrade-key posture** — immutable clones versus an upgrade path; the lean
  is immutable with no privileged key ([ADR-0001](0001-trampoline-topology.md)).
