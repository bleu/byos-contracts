# Agent Guidelines

Instructions for AI agents working on this codebase.

## Project overview

This repo contains the Solidity contracts for BYOS (Bring Your Own Solver), a CoW Protocol solver that sources routes from permissionless external sub-solvers. The primary contract is `Escrow` — a per-chain native-token collateral system.

## Repo structure

```
src/contracts/    Solidity source contracts
test/             Forge tests (one directory per contract)
script/           Deployment scripts
docs/adr/         Architecture decision records
```

## Key conventions

- **Foundry** is the build/test framework. Use `forge build`, `forge test`, `forge fmt`.
- **Solidity 0.8.28+**, optimizer enabled with 1M runs, `cancun` EVM target.
- `deny = "warnings"` is set in `foundry.toml` — compiler and lint warnings are errors.
- `forge fmt` enforces import sorting (`sort_imports = true`).
- The `block-timestamp` lint is excluded (cooldown requires `block.timestamp` comparisons).

## Domain language

Use the vocabulary from the ADRs and BYOS project context:

- **Sub-solver** — external party that submits signed routing proposals to BYOS. Never holds submission keys.
- **Owner** — secure wallet (multisig) that owns the Escrow, receives debited funds, configures parameters.
- **Operator** — EOA in the BYOS service for automated debit/freeze operations. Cannot withdraw funds.
- **Track A** — routine debit for gas + revert penalty when a settlement reverts on-chain.
- **Track B** — rare passthrough of a CoW EBBO/fairness penalty to the responsible sub-solver.
- **Cooldown** — waiting period between requesting and executing a withdrawal.
- **Freeze** — operator blocks withdrawal execution during Track B investigations; does not affect effective balance.

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
