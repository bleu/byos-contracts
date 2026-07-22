# Architecture Decision Records

One file per crystallized decision: `NNNN-short-slug.md`, numbered from `0001`. ADRs are
**append-only** — original text is never rewritten. A brand-new decision gets a new ADR;
when an existing decision changes, a dated **Revision** section is appended to the
affected ADR (with pointer blockquotes at the superseded passages), keeping each
decision's full history in one file. Each ADR states: **context**, the **decision**,
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
| [0003](0003-trampoline-deployment-settlement-integration.md) | Trampoline deployment & settlement integration | accepted; revised 2026-07-22 (floors, delta-check guard) |
| [0004](0004-penalty-schedule-and-attribution.md) | Penalty schedule & attribution | accepted |
| [0005](0005-trampoline-execution-authority.md) | Trampoline execution authority & proposal signature | accepted |
| [0006](0006-solidity-style-and-natspec.md) | Solidity coding style & natspec conventions | accepted |
| [0007](0007-erc20-escrow-token.md) | ERC20 escrow token (transfers, pause, expanded freeze) | accepted |
| [0008](0008-residue-disposition.md) | Residue disposition: sub-solver-reclaimable | accepted; inverted 2026-07-22 (surplus to settlement, claims removed) |

## Known open questions

- **Trampoline upgrade-key posture** — immutable clones versus an upgrade path; the lean
  is immutable with no privileged key ([ADR-0001](0001-trampoline-topology.md)).
