# Trampoline Gas Overhead Analysis

Gas comparison between a Uniswap V2 settlement executed directly by GPv2Settlement vs. routed through the Trampoline sandbox, measured on a mainnet fork with `forge test`.

## Overview

The Trampoline adds **~67k gas (+33%)** of overhead to a single-order settlement compared to a hypothetical direct execution by Settlement. This is the cost of structural isolation: signature verification, access control, the balance-delta floor check, and the token transfers in and out of the sandbox.

The benchmark settles a 1 ETH WETH-to-USDC sell order against Uniswap V2. Both paths use the same order, clearing prices, and swap route -- the only difference is whether Settlement executes the swap itself or delegates to the Trampoline. The route sends swap output directly to Settlement; the trampoline only sweeps the sell token (a no-op for sell orders, a real transfer for buy orders returning unconsumed input).

| Path | Gas | Overhead |
|---|---|---|
| Direct (Settlement calls Uniswap) | 199,920 | -- |
| Trampoline (output to Settlement) | 267,206 | +67,286 (+33%) |

## Overhead Breakdown

| Category | Gas | % |
|---|---|---|
| `WETH.transfer(Settlement -> Trampoline)` | ~25,000 | 37% |
| Settlement calldata/memory overhead | ~18,800 | 28% |
| `balanceOf(Settlement)` before snapshot (cold) | ~9,800 | 15% |
| ABI decoding + memory inside execute | ~5,500 | 8% |
| `balanceOf(Trampoline)` sell-token sweep check | ~2,000 | 3% |
| EIP-712 hashing + ecrecover (assembly) | ~3,200 | 5% |
| `Escrow.hasRole()` submitter check | ~2,700 | 4% |
| `execute()` CALL opcode (cold address) | ~2,600 | 4% |
| `Executed` event | ~1,500 | 2% |
| `balanceOf(Settlement)` after snapshot (warm) | ~1,300 | 2% |
| Warm/cold storage diff on approve | +4,000 | 6% |
| Warm savings (USDC slot pre-warmed by before-snapshot) | -11,000 | -15% |
| **Total** | **~67,300** | |

The warm savings entry is negative because the delta check's before-snapshot reads Settlement's USDC balance slot (cold, ~9,800), which warms it for the Uniswap pair's subsequent `USDC.transfer` to Settlement. In the direct path, that same transfer hits the slot cold and pays ~11,000 more. The cold read cost is paid once in both paths -- it just shifts between callsites. The net cost of the delta check is effectively just the after-snapshot (~1,300, warm).

### Note on buy orders

The numbers above are for sell orders, where the route consumes all sellToken and sends output directly to Settlement -- the sell-token sweep is a no-op. In buy orders using `swapTokensForExactTokens`, the route leaves unconsumed sellToken in the Trampoline. The sell-token sweep does a real `safeTransfer` back to Settlement, adding ~25,000 gas on top of the baseline. A buy order benchmark scenario is included in the test suite.

## Other Optimizations Considered

### Remove on-chain signature verification (-3,200 gas)

The `ecrecover` + EIP-712 hashing exists for non-repudiation: it prevents BYOS from fabricating proposals and blaming sub-solvers for bad routes. The BYOS service already validates the sub-solver's signature before building the settlement, so the on-chain check is redundant for honest operation. Removing it would require sub-solvers to rely on off-chain evidence (signed proposal receipts, submission logs) for disputes instead of on-chain proof.

### Drop `Executed` event (-1,500 gas)

The event emits `orderUidHash`, `delta`, and `floor` on every successful execution. The BYOS service already tracks these values off-chain via simulation and proposal lifecycle. Removing the event loses on-chain observability for third-party monitoring and historical queries.

### Remove delta check (-11,100 gas)

The two `balanceOf(Settlement)` calls (before and after the route) enforce the signed floor. GPv2Settlement itself has no buffer protection -- it pays the user from whatever balance it holds, regardless of source. Without the delta check, a route that under-delivers would silently drain Settlement's existing token buffers. The check is the only on-chain guard against this; removing it would require detecting and penalizing buffer theft after the fact via Track A debits.

## Benchmark

The benchmark script is at `test/fork/GasBenchmark.t.sol`. It compares direct settlement vs. trampoline-routed settlement for sell orders (WETH to USDC, USDC to ETH) and a buy order (USDC to WETH with sell-token dust), all against Uniswap V2 on a mainnet fork. `vm.snapshotState` resets chain state between runs. Router approvals are pre-warmed for a fair comparison, since the mainnet Settlement already holds standing `type(uint256).max` approvals.

```
forge test --match-contract GasBenchmark -vv
```
