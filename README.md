# BYOS Contracts

Solidity contracts for the **Bring Your Own Solver (BYOS)** project — a bonded CoW Protocol solver that sources proposed solutions from a permissionless set of external sub-solvers. Source RFP: [Bring Your Own Solver (BYOS)](https://forum.cow.fi/t/rfp-bring-your-own-solver-byos/3469).

## Contracts

| Contract | Status | Description |
|----------|--------|-------------|
| [Escrow](src/contracts/Escrow.sol) | implemented | Per-chain, native-token collateral keyed by sub-solver address. Deposits, debits (Track A revert penalties / Track B EBBO passthrough), freeze/unfreeze, and all-or-nothing withdrawal with cooldown. First deposit for a sub-solver deploys its Trampoline. |
| [Trampoline](src/contracts/Trampoline.sol) | implemented | Per-sub-solver execution sandbox: verifies the sub-solver's EIP-712 proposal signature (including the route hash and expiry), runs the signed route in a fund-less context, and settles back exactly `buyAmount` to `GPv2Settlement` (native ETH via the `0xeee…` marker). Immutable, no admin key. |
| [TrampolineFactory](src/contracts/TrampolineFactory.sol) | implemented | CREATE2 deployer for Trampoline instances (salt = sub-solver address) and the EIP-712 domain anchor for proposal signatures. `ensureDeployed` is idempotent and permissionless. |

## Architecture

Sub-solvers submit EIP-712-signed routing proposals to BYOS, collateralized by their escrow balance. BYOS retains exclusive control over on-chain settlement. The Escrow contract is the only sub-solver capital BYOS touches — trade capital flows atomically through `GPv2Settlement`.

Domain language and the architecture map live in [`CONTEXT.md`](CONTEXT.md). CoW protocol background (slashing framework, auction mechanics, solver CIPs) is under [`docs/reference/`](docs/reference/).

See [`docs/adr/`](docs/adr/) for architecture decision records:
- [ADR-0001](docs/adr/0001-trampoline-topology.md) — Trampoline topology (one instance per sub-solver)
- [ADR-0002](docs/adr/0002-escrow-contract.md) — Escrow contract design
- [ADR-0003](docs/adr/0003-trampoline-deployment-settlement-integration.md) — Trampoline deployment & settlement integration
- [ADR-0004](docs/adr/0004-penalty-schedule-and-attribution.md) — Penalty schedule & attribution
- [ADR-0005](docs/adr/0005-trampoline-execution-authority.md) — Trampoline execution authority & proposal signature

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

```bash
forge build
```

### Test

```bash
forge test
```

The fork suite (`test/fork/`) drives a real `GPv2Settlement.settle()` on mainnet state
and needs an RPC endpoint; it skips cleanly when the variable is unset:

```bash
MAINNET_RPC_URL=<url> forge test --match-path 'test/fork/*'
```

### Deploy

```bash
ESCROW_OWNER=<address> ESCROW_OPERATOR=<address> forge script script/Deploy.s.sol --broadcast
```

Deploys the TrampolineFactory and the Escrow wired to it. Optional: `COOLDOWN_PERIOD`
(default: 1 day) and `SETTLEMENT` (default: the canonical GPv2Settlement address).

## License

LGPL-3.0-or-later
