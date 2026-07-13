# BYOS Contracts

Solidity contracts for the **Bring Your Own Solver (BYOS)** project — a bonded CoW Protocol solver that sources proposed solutions from a permissionless set of external sub-solvers. Source RFP: [Bring Your Own Solver (BYOS)](https://forum.cow.fi/t/rfp-bring-your-own-solver-byos/3469).

## Contracts

| Contract | Status | Description |
|----------|--------|-------------|
| [Escrow](src/contracts/Escrow.sol) | implemented | Per-chain, native-token collateral keyed by sub-solver address. Deposits, debits (Track A revert penalties / Track B EBBO passthrough), freeze/unfreeze, and all-or-nothing withdrawal with cooldown. |
| Trampoline | planned | Per-sub-solver execution sandbox: receives `sellAmount`, runs the sub-solver's signed route in a fund-less context, returns `buyAmount` to `GPv2Settlement`. Specified in ADRs 0001, 0003, and 0005. |

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

### Deploy

```bash
ESCROW_OWNER=<address> ESCROW_OPERATOR=<address> forge script script/Deploy.s.sol --broadcast
```

Optional: `COOLDOWN_PERIOD` (default: 1 day).

## License

LGPL-3.0-or-later
