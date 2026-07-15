# BYOS Contracts — Project Context

The stable domain language for the **Bring Your Own Solver (BYOS)** project, scoped to its on-chain contracts. Read this before exploring; use its vocabulary in issues, ADRs, and code. Source RFP: [Bring Your Own Solver (BYOS)](https://forum.cow.fi/t/rfp-bring-your-own-solver-byos/3469). CoW protocol background: [`docs/reference/`](docs/reference).

## What BYOS is

A **bonded CoW solver** whose proposed solutions are sourced from a permissionless set of **external sub-solvers**. Sub-solvers submit signed routing proposals against specific order UIDs, collateralized by an escrow balance held by BYOS. BYOS retains exclusive control over on-chain settlement submission. From the protocol's perspective BYOS is a single, ordinary bonded solver — the sub-solver relationship is entirely internal to BYOS.

This repo holds the on-chain half of that design: the **Escrow** ([`src/contracts/Escrow.sol`](src/contracts/Escrow.sol)) and the **Trampoline** ([`src/contracts/Trampoline.sol`](src/contracts/Trampoline.sol), deployed per sub-solver by [`src/contracts/TrampolineFactory.sol`](src/contracts/TrampolineFactory.sol)). The off-chain BYOS service — proposal API, solver engine, gatekeeping, monitoring — lives in a separate repo and is out of scope here.

## Glossary

- **Sub-solver** — an external, permissionless party that computes a route for a specific order and submits a signed **proposal** to BYOS. Never holds submission keys; never calls settle. Identified by its address (recovered from its EIP-712 signature); that same address is its escrow key and its Trampoline CREATE2 salt.
- **Proposal** — an EIP-712-signed message `{order_uid, sell_amount, buy_amount, interactions, valid_until, nonce, signature}` authorizing BYOS to attempt a settlement of those interactions and consenting to the associated escrow risk. The Trampoline verifies the signature on-chain before executing ([ADR-0005](docs/adr/0005-trampoline-execution-authority.md)).
- **Trampoline** — a contract that receives `sellAmount`, executes the sub-solver's interactions, returns `buyAmount` to `GPv2Settlement`, and holds **no protocol balance** outside a single settlement. Confines sub-solver code to a fund-less context so it cannot exfiltrate buffers or plant exploitable approvals. One instance per sub-solver at a deterministic CREATE2 address, deployed at escrow-deposit time ([ADR-0001](docs/adr/0001-trampoline-topology.md), [ADR-0003](docs/adr/0003-trampoline-deployment-settlement-integration.md)).
- **Escrow** — a per-chain, native-token contract holding sub-solver collateral keyed by sub-solver address ([ADR-0002](docs/adr/0002-escrow-contract.md)). Anyone may deposit; the sub-solver withdraws subject to a cooldown; BYOS holds an exclusive **debit** function. The collateral-at-risk is the *only* sub-solver capital BYOS touches — trade capital flows atomically through `GPv2Settlement → Trampoline`.
- **Owner** — the secure wallet (multisig/Safe) that owns the Escrow. Receives debited funds, sets the operator, configures the cooldown. Ownership transfer is two-step.
- **Operator** — an EOA in the BYOS service for automated operations: debit, freeze, unfreeze. Cannot withdraw funds or change configuration; a compromised operator can grief but not steal.
- **Debit (Track A)** — routine, provable recovery of `gas + c_l` from escrow when a winning settlement carrying a proposal reverts on-chain ([ADR-0004](docs/adr/0004-penalty-schedule-and-attribution.md)).
- **Slash / clawback (Track B)** — rare passthrough of a CoW EBBO/fairness penalty (CIP-52) to the responsible sub-solver's escrow, mirroring the process CoW runs against BYOS.
- **Cooldown** — the waiting period between requesting and executing an escrow withdrawal.
- **Freeze** — operator blocks withdrawal execution while a Track B investigation is open. Does not affect effective balance.
- **Attribution** — mapping a settlement tx back to the sub-solver whose proposal it contained. Enforced by settling **one sub-solver per settlement tx**; the per-sub-solver Trampoline CREATE2 address in the calldata self-evidences which sub-solver's route ran ([ADR-0004](docs/adr/0004-penalty-schedule-and-attribution.md)).
- **Residue** — whatever balance is left in a Trampoline instance after a settlement: route surplus beyond `buyAmount`, unconsumed sell tokens, dust, stray ETH. Sub-solver property, reclaimable via the instance's `claim`; strictly outside the collateral model (no BYOS sweep, freeze, or debit) and at risk to allow-listed-solver replay while any signed proposal for the instance is unexpired — the instance is not a wallet ([ADR-0008](docs/adr/0008-residue-disposition.md)).
- **Gatekeeping** — the BYOS service's *preventive* control: validating each proposal (limit price, EBBO baseline, simulation) before settling. Distinct from escrow, which is *recovery*. A service concern, but ADRs reference it because it is the primary Track B defense — escrow cannot be.
- **`c_l`** — CoW's per-auction lower reward cap = the max revert penalty (0.010 ETH mainnet, 10 xDAI Gnosis). BYOS's debit per reverted auction is bounded by `gas + c_l`. See [`docs/reference/cow-solver-slashing-policy.md`](docs/reference/cow-solver-slashing-policy.md).

## Two risk classes (the core economic framing)

| | Track A — gas + revert penalty | Track B — EBBO / fairness slash |
|---|---|---|
| Determined by | On-chain fact (tx reverted) | Off-chain CIP-52 certificate + DAO |
| Timing | Seconds → ~1 accounting week | Days → up to 3 months |
| Attributable cleanly? | Yes (tx → proposal) | Murky; BYOS *chose* to settle it |
| Recoverable from escrow? | Yes | Only if funds still present; else BYOS eats it |
| Primary defense | Escrow debit | BYOS pre-settlement **gatekeeping** |

## Contract design posture

- The contracts are **immutable** — no proxies, no upgrade keys. A v2 means a new deployment; the cooldown-based withdrawal makes migration straightforward.
- The Escrow is a **dumb ledger**: it enforces bounds (who may debit, cooldown, events) but never the correctness of a debit's reason. Reserve calculations and proposal eligibility live in the BYOS service.
- The Trampoline's containment is **structural, not filtered**: it holds no funds at rest and each sub-solver reaches only its own instance, so a planted approval drains nothing.

v1 targets **Ethereum mainnet + Gnosis**; the Escrow is chain-agnostic from day one.
