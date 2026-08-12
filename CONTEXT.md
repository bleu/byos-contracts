# BYOS Contracts — Project Context

The stable domain language for the **Bring Your Own Solver (BYOS)** project, scoped to its on-chain contracts. Read this before exploring; use its vocabulary in issues, ADRs, and code. Source RFP: [Bring Your Own Solver (BYOS)](https://forum.cow.fi/t/rfp-bring-your-own-solver-byos/3469).

## What BYOS is

A **bonded CoW solver** whose proposed solutions are sourced from a permissionless set of **external sub-solvers**. Sub-solvers submit signed routing proposals against specific order UIDs, collateralized by an escrow balance held by BYOS. BYOS retains exclusive control over on-chain settlement submission. From the protocol's perspective BYOS is a single, ordinary bonded solver — the sub-solver relationship is entirely internal to BYOS.

This repo holds the on-chain half of that design: the **Escrow** ([`src/contracts/Escrow.sol`](src/contracts/Escrow.sol)) and the **Trampoline** ([`src/contracts/Trampoline.sol`](src/contracts/Trampoline.sol), deployed per sub-solver by [`src/contracts/TrampolineFactory.sol`](src/contracts/TrampolineFactory.sol)). The off-chain BYOS service — proposal API, solver engine, gatekeeping, monitoring — lives in a separate repo and is out of scope here.

Domain vocabulary and the normative specification are in `docs/shared/`. See `docs/shared/glossary.md` for terms and `docs/shared/design-document.md` for the spec.

## Contract design posture

- The contracts are **immutable** — no proxies, no upgrade keys. A v2 means a new deployment; the cooldown-based withdrawal makes migration straightforward.
- The Escrow is an **ERC20 ledger with transfer controls**: it enforces bounds (who may debit, cooldown, pause, freeze, transfer restrictions) but never the correctness of a debit's reason. Reserve calculations, proposal eligibility, and transfer-chain debit caps live in the BYOS service.
- The Trampoline's containment is **structural, not filtered**: it holds no funds at rest and each sub-solver reaches only its own instance, so a planted approval drains nothing.

v1 targets **Ethereum mainnet + Gnosis**; the Escrow is chain-agnostic from day one.
