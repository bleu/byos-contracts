# Solidity coding style and natspec conventions

Status: accepted

## Context

The first contract (Escrow) was written with ad-hoc conventions: events and errors
declared inside the contract, unprefixed function parameters, doc comments attached to
the implementation. That works at one contract but gives reviewers no fixed place to
read a contract's external surface, and it leaves naming decisions to whoever writes
the next file — the Trampoline and its factory are already in flight.

These contracts hold sub-solver collateral and sit in the settlement path, so they will
be audited. Audit-friendliness — a complete, machine-checkable external surface per
contract — is worth more here than brevity.

## Decision

Adopt a single set of conventions, enforced by solhint and `forge fmt`, applied to
`src/` and `script/` (tests follow the naming rules where practical but keep relaxed
lint settings).

### Interfaces are separated from contracts

Every contract in `src/contracts/` has a matching interface in `src/interfaces/`
(currently `IEscrow`; new contracts follow the same pattern). The interface declares
the contract's events, errors, structs, and external/public functions, organized under
section banners (EVENTS / ERRORS / STRUCTS / VARIABLES / LOGIC).

The interface is the single home for documentation: block-style natspec with `@notice`
on every item, `@param` for every function parameter, event parameter, and struct
member, and named `@return` values. Implementations carry `/// @inheritdoc` instead of
repeating docs. Design rationale that used to live in contract comments (ADR
references, invariants) moves into the interface natspec.

### Naming

- **Errors** are prefixed with the contract name in CapWords: `Escrow_OnlyOwner`,
  `Escrow_TransferFailed`. A revert in a settlement trace identifies its source
  contract without address lookup.
- **Events** are named in the past tense and emitted on every state change.
- **Constants and immutables** use `UPPER_SNAKE_CASE`, including their public getters.
  Functions that compute a value stay camelCase even when they play the role of a
  constant.
- **Function parameters, named returns, and local variables** use `_camelCase` with a
  leading underscore, so storage reads and argument reads are distinguishable at a
  glance inside a function body. Private/internal state variables and functions take
  the same prefix.
- **Mappings** declare named key/value parameters:
  `mapping(address _subSolver => uint256 _balance) public balances`.

### Imports

Named imports only (`import {X} from '...'`), through remappings rather than relative
paths — `interfaces/` and `contracts/` map to `src/interfaces/` and `src/contracts/`.
Import groups are ordered: external libraries, then local interfaces, then local
contracts.

### Enforcement

- `.solhint.json` at the repo root (with `script/` and `test/` variants) carries the
  ruleset: `private-vars-leading-underscore`, `ordering`, `named-parameters-mapping`,
  named imports. Test config relaxes naming and assembly rules.
- `[fmt]` in `foundry.toml` pins formatting: 2-space indent, 120-column lines, single
  quotes, thousands underscores in number literals, sorted imports. CI runs
  `forge fmt --check`.
- Two solhint warnings are accepted as inherent to the interface layout and stay at
  warn level: uppercase getter names for immutables (`func-name-mixedcase`) and view
  getters preceding logic functions in interfaces (`ordering`).

## Alternatives considered

- **Keep docs on the contracts, skip interfaces.** Fewer files and no `@inheritdoc`
  indirection, but consumers (tests, the BYOS service, integrators) would import
  implementation bytecode-bearing files just for types, and there is no single artifact
  that states the external surface. Rejected.
- **Abstract-contract bases instead of interfaces.** Allows shared modifiers but blurs
  the declaration/implementation line that makes the interface useful as an audit
  artifact. Rejected.
- **Keep the old error and getter names to avoid ABI churn.** Would have kept
  pre-refactor selectors, but nothing is deployed yet and the conventions are cheapest
  to adopt before the surface grows. Rejected; renames done now, before any deployment.

## Consequences

- Contracts hold logic only; any change to the external surface (new event, error,
  function) starts in the interface, and the natspec requirement travels with it.
- Error selectors changed (`OnlyOwner` → `Escrow_OnlyOwner`, ...). Anything encoding
  selectors against the old ABI — none deployed — would break; done pre-deployment on
  purpose.
- Tests reference the interface (`IEscrow.Escrow_*`) for reverts and events; new tests
  should do the same rather than reaching into the implementation.
- In-flight branches (the Trampoline work) pick up the conventions when they rebase:
  interfaces for their contracts, prefixed errors, uppercase immutables.
