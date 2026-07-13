# Agent Guidelines

Instructions for AI agents working on this codebase.

## Project overview

This repo contains the Solidity contracts for BYOS (Bring Your Own Solver), a CoW Protocol solver that sources routes from permissionless external sub-solvers. The primary contract is `Escrow` — a per-chain native-token collateral system.

## Repo structure

```
CONTEXT.md        Domain language and architecture map — read first
src/contracts/    Solidity source contracts
test/             Forge tests (one directory per contract)
script/           Deployment scripts
docs/adr/         Architecture decision records
docs/reference/   CoW protocol background (slashing, auctions, CIPs)
docs/agents/      Agent workflow conventions (issue tracker, triage labels)
```

## Before working

- Read [`CONTEXT.md`](CONTEXT.md), then the ADRs in [`docs/adr/`](docs/adr/) that touch
  the area you're about to work in.
- If your output contradicts an existing ADR, surface it explicitly rather than silently
  overriding: _"Contradicts ADR-0002 (all-or-nothing withdrawal) — but worth reopening
  because…"_
- Issues and PRDs live as local markdown under `.scratch/` — see
  [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md).

## Key conventions

- **Foundry** is the build/test framework. Use `forge build`, `forge test`, `forge fmt`.
- **Solidity 0.8.28+**, optimizer enabled with 1M runs, `cancun` EVM target.
- `deny = "warnings"` is set in `foundry.toml` — compiler and lint warnings are errors.
- `forge fmt` enforces import sorting (`sort_imports = true`).
- The `block-timestamp` lint is excluded (cooldown requires `block.timestamp` comparisons).

## Domain language

The glossary lives in [`CONTEXT.md`](CONTEXT.md) — sub-solver, proposal, Trampoline,
Escrow, owner/operator, Track A/B, cooldown, freeze, attribution, `c_l`. Use those terms
exactly in issue titles, test names, and code; don't drift to synonyms. If a concept you
need isn't in the glossary, that's a signal — either you're inventing language the
project doesn't use (reconsider) or there's a real gap (flag it).

## Testing guidelines

- Tests live in `test/<ContractName>/<ContractName>.t.sol`.
- Use `makeAddr("label")` for test addresses.
- Test variable naming: `subSolver`, `subSolver2` (not `solver`).
- Always test event emissions for state-changing functions.
- Test both happy paths and revert cases.
- For ETH transfer failures, use a helper contract that reverts in `receive()`.
- Verify CEI (checks-effects-interactions) pattern with reentrancy tests where applicable.

## Contract design principles

- Immutable deployment — no proxies, no upgrade patterns.
- Two-step ownership transfer to prevent irrecoverable typos.
- Single `balances` mapping (not separate deposits/totalDebited) to avoid indefinite state accumulation.
- Events provide the audit trail; on-chain state is kept minimal.
- The contract is a dumb ledger; business logic (reserve calculations, proposal eligibility) lives in the BYOS service.
