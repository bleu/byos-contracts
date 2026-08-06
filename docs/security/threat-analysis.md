# Threat analysis

Status: draft (2026-08-06)

Comprehensive threat scenario breakdown for the Escrow and Trampoline contracts,
organized by attacker persona. Each leaf scenario should be investigated and confirmed
as "cannot happen given the current design" or flagged as a gap. References ADRs and
contract code throughout.

---

## 1. Sub-solver is malicious

- **It can extract value from the escrow**
  - It can steal another sub-solver's collateral
    - Via calling `debit` on another sub-solver — blocked: `OPERATOR_ROLE` required
    - Via `transferFrom` from another sub-solver — blocked: requires prior `approve` from victim
    - Via triggering an unsolicited transfer TO an innocent address, making that address a debit target in BYOS's off-chain transfer-chain enforcement — off-chain debit cap mitigates, but the innocent address has an implicit exposure it didn't consent to
  - It can withdraw more than its entitled balance
    - Via depositing into its own account after requesting withdrawal, inflating balance before `executeWithdrawal` — blocked: `_update` rejects mints when `withdrawalRequestedAt[to] != 0`
    - Via receiving a transfer while withdrawal is pending — blocked: `_update` rejects transfers when receiver has pending withdrawal
    - Via reentrancy on `executeWithdrawal` (the ETH `.call` is external) — blocked: CEI pattern — burn happens before the external call, so reentering finds `balanceOf == 0`
    - Via manipulating the `balanceOf` read between `requestWithdrawal` and `executeWithdrawal` — only `debit` (operator-only) can reduce it; no path for a sub-solver to inflate it once withdrawal is pending
  - It can evade a debit by moving funds before the operator acts
    - Via transferring tokens to a fresh address just before a debit — mitigated by pause + freeze + off-chain monitoring, but there IS a race: in the same block, a sub-solver could transfer and the debit could fail for insufficient balance
    - Via requesting withdrawal to make `effectiveBalance == 0` (stopping future proposals), waiting for debit window to pass, then cancelling — `effectiveBalance` is a view for the BYOS service; `balanceOf` (the actual balance) is unchanged, so `debit` still works on the actual balance
    - Via multiple hops (A->B->C) to obscure the trail before operator can freeze — the pause mechanism halts ALL movement while operator traces; relies on off-chain monitoring latency being shorter than block confirmation
  - It can front-run a `debit` with `requestWithdrawal` + immediate `executeWithdrawal` (cooldown == 0) — possible only if admin sets cooldown to 0; otherwise cooldown window is the operator's debit window

- **It can extract value from the settlement / drain BYOS buffers**
  - It signs a route that sends `sellAmount` to itself instead of producing `buyAmount`
    - The sweep finds nothing to sweep — delta check fails — settlement reverts — no drain
  - It signs a route that siphons `sellAmount` to itself AND delivers `buyAmount` from its own funds to pass the delta check
    - This IS an EBBO / unfair pricing violation (the user gets their limit price, but market rate was better) — Track B handles this off-chain
    - The delta check passes but the sub-solver captured the spread — gatekeeping is the primary defense; escrow debit is recovery
    - The user's limit price is still enforced by `GPv2Settlement.transferToAccounts` — user funds are not stolen, but surplus that should flow to the user (via better pricing) is captured
  - It signs a route with `buyAmount = 0` (or trivially low floor)
    - Delta check passes with almost any output — any value above 0 satisfies the guard
    - BYOS gatekeeping must reject proposals with unreasonably low floors — no on-chain minimum floor check
    - **Gap G1:** there is no on-chain `buyAmount > 0` check in `Trampoline.execute`
  - It signs a route that delivers buy tokens directly to the settlement (bypassing the trampoline) while keeping sell tokens in-route
    - The delta check measures settlement balance growth regardless of delivery path — this passes correctly
    - The sweep returns any remaining sell tokens — no sell-side leakage
    - In-route capture above the floor is explicitly tolerated (ADR-0008)
  - It signs a route that interacts with fee-on-transfer buy tokens, exploiting the discrepancy
    - The delta check measures actual balance received, accounting for the fee — the sub-solver doesn't gain; if the fee makes delta < buyAmount, settlement reverts
    - Out of scope for v0 pricing, but the delta primitive is correct

- **It can extract value by inputting malicious interactions in the proposals**
  - It plants an ERC-20 approval on the trampoline for a contract it controls
    - The trampoline is empty at rest (sell-token sweep + direct buy-token delivery to settlement enforce zero trade tokens after each settlement) — an approval over an empty contract drains nothing
    - Stray tokens (airdrops, mistaken transfers) could be drained via a planted approval — accepted risk per ADR-0008 ("strays are written off")
    - Between the `sellToken.transfer` and the sweep within a single `execute`, the trampoline holds value — the approval would need to be exploited DURING the same settlement (calling the approve target from within the route to pull tokens back) — this is just in-route capture, equivalent to the route sending tokens to sub-solver directly
  - It includes interactions that `SELFDESTRUCT` the trampoline
    - Post-Cancun (EIP-6780): `SELFDESTRUCT` only works in the same tx as creation — trampoline survives
    - Pre-Cancun chains (if deployed there): the trampoline could be destroyed, bricking future settlements for that sub-solver — only self-harm (the sub-solver's own trampoline)
    - The route uses `CALL` not `DELEGATECALL`, so `SELFDESTRUCT` in a target contract destroys the target, not the trampoline
  - It includes interactions that re-enter `GPv2Settlement.settle()`
    - `settle` is `nonReentrant` — reverts before `onlySolver` is even reached — settlement reverts (Track A debit)
    - `onlySolver` is the backstop: the trampoline isn't an allow-listed solver
  - It includes interactions that call the vault relayer to pull user funds
    - Vault relayer has `onlyCreator` gate — only the settlement can call it — reverts
  - It includes interactions that call another sub-solver's trampoline `execute`
    - `execute` requires `msg.sender == SETTLEMENT` — the calling trampoline is not the settlement — reverts
  - It includes interactions that call `Escrow.deposit` or other escrow functions
    - `deposit` requires `msg.value > 0` — if the trampoline has ETH (e.g., from a WETH unwrap), it could deposit ETH into any address's escrow balance — the attacker creates collateral for an arbitrary address, but this costs the attacker their own route capital and the delta check would fail
    - Other escrow functions (debit, freeze, etc.) require roles the trampoline doesn't have
  - It includes interactions with enormous gas consumption
    - The settlement consumes more gas than expected — reverts — Track A debit on the sub-solver who signed those interactions
    - The sub-solver signed the interactions so they bear the cost
  - It includes interactions that send all native ETH out via the `value` field
    - If buyToken is ETH, the route must deliver ETH directly to settlement — if it was sent out, delta check fails — revert
    - If buyToken is not ETH, the ETH loss is the sub-solver's own route capital (came from sell side)
  - It includes interactions targeting a contract that calls back into the trampoline's `execute`
    - `execute` has no reentrancy guard itself BUT `msg.sender` must be `SETTLEMENT`, and settlement is in a `nonReentrant` lock — the callback can't go through settlement to re-enter `execute`
    - Direct callback to `execute` fails the `msg.sender == SETTLEMENT` check

- **It can manipulate the EIP-712 signature system**
  - It forges another sub-solver's signature — infeasible without private key; `ecrecover` is deterministic
  - It exploits signature malleability (skipped OZ ECDSA checks) — the nonce ensures each proposal has a unique digest; a malleable `(r, s')` for the same digest still recovers to the same signer address
  - It exploits `ecrecover` returning `address(0)` on invalid signature — **if a trampoline exists for `address(0)`, any garbage signature passes** (see Gap G2)
  - It replays a valid proposal within the `validUntil` window — blocked by submitter gate (`tx.origin` must hold `SUBMITTER_ROLE`); the sub-solver cannot submit settlements

- **It can grief the system without extracting value**
  - It submits proposals that pass gatekeeping but revert on-chain (simulation divergence)
    - Track A debit recovers `gas + c_l` — the sub-solver pays
    - Persistent griefing — BYOS evicts the sub-solver off-chain (gatekeeping)
  - It submits proposals that technically pass but produce terrible prices (barely above floor)
    - BYOS loses competitiveness in the solver auction — off-chain gatekeeping concern
  - It deposits a tiny amount to deploy a trampoline but never submits proposals — no harm, just unused trampoline

## 2. Operator key is compromised

- **Attacker can grief but not steal (by design)**
  - It can debit all sub-solvers' full balances — funds go to `defaultAdmin()`, not the attacker
  - It can freeze all sub-solvers — DoS on withdrawals and transfers
  - It can pause the contract — global DoS on transfers and withdrawal execution
  - It can freeze + debit in sequence (freeze everyone, then drain all balances to admin) — still, funds go to admin
- **Attacker cannot escalate privileges**
  - It cannot grant itself `SUBMITTER_ROLE` — only `DEFAULT_ADMIN_ROLE` can call `grantRole`
  - It cannot become admin — `AccessControlDefaultAdminRules` requires a two-step transfer with delay
  - It cannot call `setCooldownPeriod` — requires `DEFAULT_ADMIN_ROLE`
- **Attacker cannot access settlement funds**
  - It cannot submit settlements — no `SUBMITTER_ROLE` (and even if it had it, proposals require sub-solver signatures)
  - It cannot interact with trampolines — they only accept calls from the settlement contract
- **Attacker CAN debit a sub-solver and immediately call `withdrawDebits`** — funds go to admin, attacker still gets nothing (unless attacker IS the admin — see section 4)
- **Mitigation speed matters** — admin (cold wallet) must revoke and replace operator; during the window, damage is limited to illegitimate debits and freezes

## 3. Submitter key is compromised

- **Attacker can submit settlements through the BYOS solver EOA**
  - But proposals require valid sub-solver EIP-712 signatures — attacker can only execute proposals that sub-solvers actually signed
  - Attacker could replay a signed proposal within its `validUntil` window
    - If the order is already filled — `GPv2Settlement` rejects (order already settled)
    - If the order is not yet filled — the settlement executes as the sub-solver intended; the sub-solver isn't harmed because their signed route runs
    - **To verify:** Can a "tradeless settlement" (empty `_trades` array) call `execute` via intra-interactions? If so, the route runs without any sell tokens being transferred in — route fails or produces nothing — delta check fails — revert — but no Track A debit (no trade was attempted)
  - Attacker could construct a malicious settlement that calls `execute` with a valid signature but wrong `_sellToken`/`_buyToken`
    - Wrong `_buyToken`: delta check measures the wrong token — could pass if settlement happens to have growing balance of that token, but `settle` is `nonReentrant` and one tx per sub-solver, so no concurrent balance change — the only source of delta is the route itself, which won't produce the wrong token — revert
    - Wrong `_sellToken`: sell-token sweep targets the wrong token — actual sell token stays on trampoline — could be drained later via planted approval if one exists — strays are accepted risk (ADR-0008)
  - Attacker could submit settlement without the preceding `sellToken.transfer` — route runs without input — likely reverts — Track A debit on the sub-solver for a fault they didn't cause — **this is a risk: the signature proves the sub-solver consented to the route, but not that BYOS delivered the sell tokens**
    - Dispute evidence: on-chain calldata shows no transfer-in interaction — sub-solver can prove fabricated fault
    - **Gap G3:** is there an on-chain guard that the trampoline actually received `sellAmount` before running the route?
- **Attacker cannot access escrow** — `SUBMITTER_ROLE` has no escrow authority (no debit, freeze, or withdrawal powers)
- **Mitigation:** admin revokes the compromised submitter key and grants a new one; submitter rotation is a role change, not a redeploy

## 4. Admin is compromised (worst case by design)

- **Attacker controls the entire system**
  - It can grant itself `OPERATOR_ROLE` — can debit all sub-solvers — BUT funds go to itself as `defaultAdmin()` — **this IS theft**
  - It can grant `SUBMITTER_ROLE` to an attacker-controlled EOA — can now submit settlements
  - It can set cooldown to 0 — instant withdrawals, disabling debit recovery window
  - It can revoke all legitimate operators and submitters — total DoS
  - It can transfer admin to another attacker address (after the `_adminTransferDelay`)
- **The `_adminTransferDelay` is the only brake** — gives the community/multisig signers time to react
- **Admin renouncement (intentional or accidental)**
  - `defaultAdmin()` returns `address(0)` permanently
  - `withdrawDebits()` reverts forever — debited ETH is stuck (Gap G8)
  - No new roles can be granted — system slowly freezes as keys rotate out
  - Sub-solvers can still withdraw (cooldown, freeze, pause are still controlled by existing operator)
  - **But if operator key is also lost** — frozen sub-solvers are locked forever

## 5. External attacker (no role, no sub-solver relationship)

- **It can deposit ETH for arbitrary addresses**
  - Deploys a trampoline for the target — no harm, just an unrequested trampoline
  - Creates escrow collateral — the depositor pays their own ETH; no way to force a debit on the recipient
  - **Gap G2:** depositing for `address(0)` creates a trampoline where `SUB_SOLVER == address(0)`, and `ecrecover` returns `address(0)` on invalid signatures — any garbage signature would pass verification on that trampoline
- **It can call `withdrawDebits`** — permissionless, but funds always go to `defaultAdmin()` — no harm
- **It can call `ensureDeployed` on the factory** — permissionless trampoline deploy — no harm
- **It can force-send ETH to the escrow via `SELFDESTRUCT` / coinbase reward**
  - Breaks the `totalSupply + accumulatedDebits == balance` invariant in the benign direction (more ETH than tokens)
  - Excess ETH is permanently stuck — not exploitable
- **It can observe pending withdrawal requests and front-run**
  - The sub-solver's `requestWithdrawal` is public — anyone can see the cooldown expiry
  - Cannot deposit (blocked by pending withdrawal), cannot transfer to that address (blocked)
  - Operator could front-run `executeWithdrawal` with a `debit` — this is by design, not an attack

## 6. Rival CoW solver

- **It observes BYOS settlement calldata and attempts replay**
  - Submitter gate blocks: `tx.origin` must hold `SUBMITTER_ROLE` on the BYOS escrow — rival's EOA doesn't have it
  - Even if rival calls the trampoline directly — `msg.sender` must be `GPv2Settlement` — blocked
- **It front-runs BYOS's settlement with its own settlement for the same order**
  - If rival fills the order first — BYOS's settlement reverts (order already filled) — Track A debit on the sub-solver? — **this is a risk only if BYOS can't distinguish "order already filled" from "sub-solver route failed"**
  - ADR-0004 says BYOS must distinguish infra failure from sub-solver fault — off-chain concern
- **It includes the BYOS trampoline's `execute` as an interaction in its own settlement**
  - `msg.sender` would be `GPv2Settlement` (correct) but `tx.origin` would be the rival's EOA — submitter gate fails — revert

## 7. Malicious or exotic ERC-20 token (in settlement, not escrow)

- **Fee-on-transfer token as buyToken**
  - Delta check measures actual balance received (net of fee) — correct accounting
  - If the fee makes delta < buyAmount — settlement reverts — sub-solver underbid
- **Rebasing token as buyToken**
  - A rebase between `_buyBalanceBefore` and the delta check could inflate or deflate delta
  - Upward rebase — delta appears larger — settlement succeeds but the extra is from the rebase, not the route
  - Downward rebase — delta appears smaller — settlement may fail (false negative)
  - Not a security vulnerability (no value extracted), but a correctness concern
- **ERC-777 token with transfer hooks / reentrancy**
  - The sweep calls `safeTransfer` which could trigger a callback
  - `settle` is `nonReentrant` — callback can't re-enter settlement — can't re-enter `execute` via settlement
  - A callback into the trampoline directly (not via settlement) can't call `execute` (requires `msg.sender == SETTLEMENT`)
  - Other trampoline functions: only `receive()` — no harmful reentrancy path
- **Token that returns `false` instead of reverting** — `SafeERC20.safeTransfer` reverts on false return — handled
- **Token where `balanceOf` returns inconsistent results** — delta check would be unreliable — off-chain concern (BYOS shouldn't settle with such tokens)
- **Poisoned buyToken address (attacker-controlled contract with manipulated `balanceOf`)**
  - `_buyToken` is an unsigned call parameter controlled by BYOS — if BYOS is honest, this is fine
  - If BYOS passes a malicious buyToken that returns inflated balances — delta check could be manipulated — but BYOS controls this and is the one harmed by manipulation

## 8. `address(0)` trampoline attack

- **`ensureDeployed(address(0))` or `deposit{value: X}(address(0))` creates a trampoline with `SUB_SOLVER == address(0)`**
  - `ecrecover` returns `address(0)` for any invalid signature — `_recovered == SUB_SOLVER` passes
  - If a BYOS submitter constructs a settlement routing through this trampoline with a garbage signature — the route executes
  - **Mitigation:** BYOS service would never do this; submitter gate limits who can trigger it; the route interactions still need to be provided (but with address(0) as "signer" they can be anything)
  - **Gap G2:** no on-chain guard against `SUB_SOLVER == address(0)` in the Trampoline constructor or factory

## 9. Unsigned parameters in `execute` (`_sellToken`, `_buyToken`)

- **These are not part of the EIP-712 signed Proposal — BYOS supplies them**
  - The sub-solver's `interactionsHash` commits to the route (which implicitly encodes token addresses), but not the sweep/delta-check tokens
  - If BYOS passes a `_buyToken` different from what the route produces — delta check fails — revert — no harm
  - If BYOS passes a `_sellToken` different from what was transferred in — sweep targets the wrong token — actual sell tokens remain on trampoline (stranded)
  - **sellAmount is signed but not enforced on-chain** — BYOS could transfer less than `sellAmount` into the trampoline — route fails — sub-solver gets Track A debited for a fault BYOS caused
    - Sub-solver dispute defense: the settlement calldata shows the transfer-in amount differs from the signed `sellAmount`
    - **Gap G3:** should the trampoline verify `IERC20(sellToken).balanceOf(address(this)) >= _proposal.sellAmount` before running the route?

## 10. Timing and ordering attacks

- **Operator front-runs `executeWithdrawal` with `debit`**
  - By design: the cooldown window IS the operator's debit window
  - A compromised operator could drain a sub-solver's entire balance right before withdrawal executes — grief, not steal (funds go to admin)
- **Sub-solver front-runs `debit` with `transfer`**
  - Requires the transfer to be mined before the debit in the same block
  - Mitigated by pause (stops all transfers) — but pause must be triggered first
  - **Window of vulnerability (Gap G7):** between the revert event and the operator calling pause/freeze
- **Block timestamp manipulation (validator)**
  - `validUntil` check: `block.timestamp > _proposal.validUntil` — validators can shift ~12 seconds — negligible given typical validity windows
  - Cooldown check: `block.timestamp < withdrawalRequestedAt + cooldownPeriod` — same minor concern, cooldowns are typically hours
- **Admin changes cooldown while withdrawals are pending**
  - A longer cooldown retroactively extends pending withdrawals
  - A shorter cooldown (or 0) retroactively accelerates them — could enable withdrawal before expected debit window
  - **Gap G5:** is this acceptable, or should pending withdrawals lock in their cooldown period at request time?

## 11. ERC-20 surface of the escrow token

- **Approve + transferFrom race condition**
  - Classic ERC-20 issue: Alice approves Bob for 100, changes to 50; Bob front-runs to spend 100 then 50
  - Standard and well-known; escrow token has transfer restrictions (freeze, pause, withdrawal) that add complexity but don't introduce new races
- **Transfer to the escrow contract itself**
  - Tokens stuck in the escrow address — `totalSupply` unchanged, but those tokens are unreachable
  - ETH backing those tokens is still in the contract — slightly over-collateralized — not exploitable
- **Approval to a contract that can pull tokens** (e.g., a sub-solver approves a helper contract)
  - `transferFrom` enforces the same `_update` restrictions (pause, freeze, pending withdrawal)
  - The helper inherits the same restrictions as a direct transfer — no bypass

## 12. Multi-chain / deployment concerns

- **Same private key used as sub-solver on two chains**
  - Different escrow, different factory, different domain separator (includes `chainId`) — signatures don't cross-chain replay
- **Same factory deployed at the same address on two chains but with different escrows**
  - Not possible: factory is deployed by the escrow's constructor, so different escrow — different factory address
  - Domain separator includes `verifyingContract` (factory address) — cross-chain replay blocked

## 13. Settlement-level atomicity assumptions

- **`settle` reverts partially** (some state changes persist)
  - `settle` is atomic (EVM transaction) — either all state changes persist or none
  - Approvals granted by the route during `execute` are rolled back on revert — no dangling approvals
- **Multiple BYOS settlements in the same block**
  - One sub-solver per settlement tx (ADR-0004/0009) — each tx is independent
  - Both route through `GPv2Settlement` — but `settle` is `nonReentrant`, so they can't overlap
  - Sequential settlements in the same block are fine: each is a separate tx
- **What if the same sub-solver's trampoline is called twice in one settlement?**
  - ADR-0009 mandates one order per settlement — but on-chain there's no enforcement
  - If BYOS (or a compromised submitter) includes two `execute` calls — the second would measure a delta that includes the first's delivery — could under-report or over-report the second order's actual contribution
  - **Gap G6:** this is an off-chain invariant (one execute per settlement), not enforced on-chain

---

## Summary of gaps flagged for investigation

| # | Gap | Severity | On-chain / Off-chain |
|---|---|---|---|
| G1 | No `buyAmount > 0` check in `execute` | Medium | On-chain |
| G2 | `address(0)` trampoline accepts any invalid signature | Medium | On-chain |
| G3 | `sellAmount` is signed but not enforced — trampoline doesn't verify it received `sellAmount` before running route | Low (dispute-provable) | On-chain |
| G4 | `_sellToken` and `_buyToken` are unsigned call parameters | Low (BYOS-controlled) | Design |
| G5 | Cooldown change retroactively affects pending withdrawals | Low | On-chain |
| G6 | One-execute-per-settlement is not enforced on-chain | Low | Off-chain invariant |
| G7 | Race between sub-solver `transfer` and operator `debit` before pause is triggered | Low (operational) | Off-chain |
| G8 | Admin renouncement bricks `withdrawDebits` permanently | Low | On-chain (guarded but irrecoverable) |
