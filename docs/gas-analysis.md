# Trampoline Gas Overhead Analysis

Gas comparison between a Uniswap V2 settlement executed directly by GPv2Settlement vs. routed through the Trampoline sandbox, measured on a mainnet fork with `forge test`.

## Overview

The Trampoline adds **~67k gas (+33%)** of overhead to a single-order settlement compared to a hypothetical direct execution by Settlement. This is the cost of structural isolation: signature verification, access control, the balance-delta floor check, and the token transfers in and out of the sandbox.

The benchmark settles a 1 ETH WETH-to-USDC sell order against Uniswap V2. Both paths use the same order, clearing prices, and swap route -- the only difference is whether Settlement executes the swap itself or delegates to the Trampoline. The Trampoline path uses the output-to-Settlement routing optimization, where the sub-solver's route sends swap output directly to Settlement rather than to the Trampoline instance, making the buyToken sweep a no-op.

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
| `balanceOf(Trampoline)` sweep checks (2 tokens) | ~3,900 | 6% |
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

The numbers above are for sell orders, where the route consumes all sellToken and sends output directly to Settlement -- both sweeps are no-ops. In buy orders using `swapTokensForExactTokens`, the route leaves unconsumed sellToken in the Trampoline. The sellToken sweep then does a real `safeTransfer` back to Settlement, adding ~25,000 gas on top of the baseline.

## Applied Optimizations

Two changes were applied to the Trampoline contract, reducing overhead from ~69k to ~67k:

**Inline `SUBMITTER_ROLE` hash** (-655 gas): The Trampoline previously made two external calls to the Escrow -- `SUBMITTER_ROLE()` to fetch the role hash, then `hasRole()` to check membership. Since the role hash is a constant (`keccak256('SUBMITTER_ROLE')`), it is now inlined as a file-level constant, eliminating the first external call.

**Assembly for hashing, ecrecover, and interaction dispatch** (-1,120 gas): Three hot paths were rewritten in inline assembly:

- _Interaction dispatch loop_: Solidity allocates `bytes memory _returnData` on every `call`, even on success when the data is never read. The assembly version skips return data allocation on success and only copies return data on revert (for error bubbling).
- _EIP-712 hashing_: The struct hash and typed data hash are built in scratch memory without advancing the free memory pointer, avoiding `abi.encode` memory allocation.
- _Signature recovery_: Raw `ecrecover` precompile call replaces the OpenZeppelin `ECDSA.recover` library, skipping s-value malleability checks and signature length validation. The nonce in the proposal handles replay; s-malleability is not a concern.

| | Gas |
|---|---|
| Before optimizations | 268,981 |
| After inline submitter role | 268,326 |
| After assembly optimizations | 267,206 |
| **Total saved** | **1,775** |

## Other Changes Discussed

### Route output directly to Settlement (driver-level, no contract change)

The sub-solver's route can set the swap's `to` parameter to Settlement instead of the Trampoline instance. The Trampoline's `_sweep` finds zero buyToken balance and skips the `safeTransfer` back. The balance-delta check still passes because Settlement's balance grew from the router's direct output. This saves ~19-26k gas depending on the scenario and is purely a routing decision by the BYOS driver -- the current contract already supports it.

Measured impact (before other optimizations):

| Scenario | Output to Trampoline | Output to Settlement | Saved |
|---|---|---|---|
| WETH to USDC | 294,740 | 268,981 | 25,759 |
| USDC to ETH | 304,416 | 285,773 | 18,643 |

The ERC20 case saves more because it fully eliminates a `safeTransfer`. The ETH case still needs a Settlement-level `WETH.withdraw` interaction after `execute` returns, since the Trampoline cannot unwrap WETH it doesn't hold.

### Remove on-chain signature verification (-3,200 gas)

The `ecrecover` + EIP-712 hashing exists for non-repudiation: it prevents BYOS from fabricating proposals and blaming sub-solvers for bad routes. The BYOS service already validates the sub-solver's signature before building the settlement, so the on-chain check is redundant for honest operation. Removing it would require sub-solvers to rely on off-chain evidence (signed proposal receipts, submission logs) for disputes instead of on-chain proof.

### Drop `Executed` event (-1,500 gas)

The event emits `orderUidHash`, `delta`, and `floor` on every successful execution. The BYOS service already tracks these values off-chain via simulation and proposal lifecycle. Removing the event loses on-chain observability for third-party monitoring and historical queries.

### Skip buyToken sweep (-3,300 gas)

When output is routed to Settlement, the buyToken sweep always finds zero balance. Skipping it saves a cold `balanceOf` call on the Trampoline. However, this bakes a routing assumption into the contract -- if a route ever sends output to the Trampoline (intentionally or by mistake), the tokens would be stranded.

### Remove delta check (-11,100 gas)

The two `balanceOf(Settlement)` calls (before and after the route) enforce the signed floor. GPv2Settlement itself has no buffer protection -- it pays the user from whatever balance it holds, regardless of source. Without the delta check, a route that under-delivers would silently drain Settlement's existing token buffers. The check is the only on-chain guard against this; removing it would require detecting and penalizing buffer theft after the fact via Track A debits.

## Benchmark

The benchmark script is at `test/fork/GasBenchmark.t.sol`. It runs three settlement paths (direct, trampoline with output to trampoline, trampoline with output to Settlement) against the same Uniswap V2 swap on a mainnet fork, using `vm.snapshotState` to reset chain state between runs. Router approvals are pre-warmed for a fair comparison, since the mainnet Settlement already holds standing `type(uint256).max` approvals.

```
forge test --match-contract GasBenchmark -vv
```
