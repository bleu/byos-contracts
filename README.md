# BYOS Contracts

Solidity contracts for the **Bring Your Own Solver (BYOS)** project — a bonded CoW Protocol solver that sources proposed solutions from a permissionless set of external sub-solvers.

## Contracts

| Contract | Description |
|----------|-------------|
| [Escrow](src/contracts/Escrow.sol) | Per-chain, native-token collateral keyed by sub-solver address. Deposits, debits (Track A revert penalties / Track B EBBO passthrough), freeze/unfreeze, and all-or-nothing withdrawal with cooldown. |

## Architecture

Sub-solvers submit EIP-712-signed routing proposals to BYOS, collateralized by their escrow balance. BYOS retains exclusive control over on-chain settlement. The Escrow contract is the only sub-solver capital BYOS touches — trade capital flows atomically through `GPv2Settlement`.

See [`docs/adr/`](docs/adr/) for architecture decision records:
- [ADR-0001](docs/adr/0001-trampoline-topology.md) — Trampoline topology (one instance per sub-solver)
- [ADR-0002](docs/adr/0002-escrow-contract.md) — Escrow contract design

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

### Deploy

```bash
ESCROW_OWNER=<address> ESCROW_OPERATOR=<address> forge script script/Deploy.s.sol --broadcast
```

Optional: `COOLDOWN_PERIOD` (default: 1 day).

## License

LGPL-3.0-or-later
