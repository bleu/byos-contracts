# Contract Deployment

This guide describes how to deploy the BYOS contracts to a new chain.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)
- Git
- A funded deployer wallet

## Environment variables

Copy `.env` and fill in the values below.

### Required

| Variable | Description | Example |
|----------|-------------|---------|
| `PRIVATE_KEY` | Private key of the deployer wallet | `0xabc...` |
| `ESCROW_ADMIN` | Address that holds the admin role on the Escrow contract | `0x1234...` |
| `ESCROW_OPERATOR` | Address that the BYOS service uses to submit penalty debits on-chain | `0x5678...` |
| `BYOS_SUBMITTERS` | Comma-separated list of addresses allowed to submit proposals to the Escrow | `0xaaaa...,0xbbbb...` |
| `SETTLEMENT` | GPv2Settlement address on the target chain. The default (`0x9008D19f58AAbD9eD0D60971565AA8510560ab41`) is correct for Ethereum mainnet and Gnosis Chain only. Set this for all other chains. | `0xf553d0...` |

> **Cross-repo dependency.** The `ESCROW_OPERATOR` address set here must match the address derived from `OPERATOR_PRIVATE_KEY` in the BYOS service configuration. Use the same key for both.

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `ADMIN_TRANSFER_DELAY` | `172800` (2 days) | Delay in seconds before an admin key transfer takes effect |
| `COOLDOWN_PERIOD` | `86400` (1 day) | Delay in seconds between a withdrawal request and execution |
| `ESCROW_TOKEN_NAME` | `BYOS Escrow` | ERC20 name for the escrow receipt token. Recommended pattern: `BYOS <native-token-name>` — e.g. `BYOS BNB` |
| `ESCROW_TOKEN_SYMBOL` | `BYOS` | ERC20 symbol for the escrow receipt token. Recommended pattern: `byos<symbol>` — e.g. `byosBNB` |
| `BSCSCAN_API_KEY` | — | Block explorer API key. Required only for contract verification (see below). |

## Deploy

Run the deploy script:

```bash
forge script script/Deploy.s.sol \
  --broadcast \
  --rpc-url <RPC_URL>
```

The script deploys the Escrow and TrampolineFactory contracts and prints their addresses:

```
Escrow deployed at: 0x...
TrampolineFactory deployed at: 0x...
```

**Save both addresses.** You will need them to configure the BYOS service.

## Verify contracts

Verify the contracts on the block explorer. This step is recommended but not required.

```bash
forge verify-contract <ESCROW_ADDRESS> \
  src/contracts/Escrow.sol:Escrow \
  --chain-id <CHAIN_ID>
```

This step requires a block explorer API key configured in `foundry.toml` under `[etherscan]`. See [Foundry verification docs](https://book.getfoundry.sh/forge/deploying#verifying-a-pre-existing-contract) for chain-specific setup.

## Fund the operator

Send native tokens to the `ESCROW_OPERATOR` address. The operator wallet submits penalty transactions on-chain and must have enough balance to cover gas costs.
