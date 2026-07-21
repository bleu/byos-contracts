// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {IGPv2Authentication} from 'interfaces/IGPv2Authentication.sol';
import {GPv2TradeData, IGPv2Settlement} from 'interfaces/IGPv2Settlement.sol';
import {ITrampoline} from 'interfaces/ITrampoline.sol';

import {Escrow} from 'contracts/Escrow.sol';
import {Trampoline} from 'contracts/Trampoline.sol';
import {TrampolineFactory} from 'contracts/TrampolineFactory.sol';

import {AttackerRouter} from '../mocks/AttackerRouter.sol';
import {TestERC20} from '../mocks/TestERC20.sol';
import {ProposalSigning} from '../utils/ProposalSigning.sol';

/// @dev Order-signing surface of GPv2Settlement used only by these tests. Kept local
/// rather than added to the production interface, which needs none of it.
interface IGPv2Signing {
  function setPreSignature(
    bytes calldata orderUid,
    bool signed
  ) external;
  function invalidateOrder(
    bytes calldata orderUid
  ) external;
  function preSignature(
    bytes calldata orderUid
  ) external view returns (uint256);
  function filledAmount(
    bytes calldata orderUid
  ) external view returns (uint256);
}

/// @dev Pull surface of GPv2VaultRelayer, callable only by its creator (the settlement).
/// Local to these tests; mirrors GPv2Transfer.Data field-for-field.
interface IGPv2VaultRelayer {
  struct Transfer {
    address account;
    address token;
    uint256 amount;
    bytes32 balance;
  }

  function transferFromAccounts(
    Transfer[] calldata transfers
  ) external;
}

/// @notice Adversarial proof (COW-1152) that a sub-solver's signed route cannot reach
/// GPv2Settlement funds. Routes run as the Trampoline instance, never as the settlement
/// contract (ADR-0001); these tests demonstrate the isolation against the real deployed
/// GPv2Settlement rather than asserting it. A controlled buffer token is seeded into the
/// settlement in setUp so every "buffer unchanged" assertion runs against real value.
/// Fork-gated: uses a public RPC by default; override with MAINNET_RPC_URL or set it
/// empty to skip (e.g. offline).
contract SettlementIsolationTest is Test {
  IGPv2Settlement constant SETTLEMENT = IGPv2Settlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);

  string constant DEFAULT_RPC_URL = 'https://ethereum-rpc.publicnode.com';

  /// @dev Value the settlement demonstrably holds in the seeded buffer token.
  uint256 constant BUFFER_AMOUNT = 500_000 ether;

  string rpcUrl;
  TrampolineFactory factory;
  Trampoline trampoline;
  address solver;
  address subSolver;
  uint256 subSolverKey;
  address attacker;

  /// @dev A controlled ERC-20 the settlement holds a buffer of; the target of every
  /// buffer-theft attempt.
  TestERC20 bufferToken;

  /// @dev Route target that swallows a failed attack so the settlement still succeeds.
  AttackerRouter attackerRouter;

  modifier onlyFork() {
    vm.skip(bytes(rpcUrl).length == 0);
    _;
  }

  function setUp() public {
    rpcUrl = vm.envOr('MAINNET_RPC_URL', DEFAULT_RPC_URL);
    if (bytes(rpcUrl).length == 0) return;
    vm.createSelectFork(rpcUrl);

    solver = makeAddr('byosSolver');
    (subSolver, subSolverKey) = makeAddrAndKey('subSolver');
    attacker = makeAddr('attacker');

    // Allow-list the BYOS solver as the authenticator's manager would.
    IGPv2Authentication auth = IGPv2Authentication(SETTLEMENT.authenticator());
    vm.prank(auth.manager());
    auth.addSolver(solver);

    // Deploy the escrow (which deploys the factory); the sub-solver's first deposit
    // deploys its Trampoline. The BYOS solver is the initial settlement submitter.
    address[] memory submitters = new address[](1);
    submitters[0] = solver;
    Escrow escrow = new Escrow(
      2 days, makeAddr('admin'), makeAddr('operator'), submitters, 1 days, address(SETTLEMENT), 'BYOS Escrow', 'BYOS'
    );
    factory = TrampolineFactory(address(escrow.TRAMPOLINE_FACTORY()));
    escrow.deposit{value: 1 ether}(subSolver);
    trampoline = Trampoline(payable(factory.addressOf(subSolver)));

    // Seed a known settlement buffer so "no value moved" runs against real value.
    bufferToken = new TestERC20();
    bufferToken.mint(address(SETTLEMENT), BUFFER_AMOUNT);

    attackerRouter = new AttackerRouter();
  }

  // --- Helpers ---

  function _sign(
    ITrampoline.Proposal memory proposal,
    ITrampoline.Interaction[] memory route
  ) internal view returns (bytes memory) {
    bytes32 digest = ProposalSigning.digest(factory.domainSeparator(), proposal, route);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(subSolverKey, digest);
    return abi.encodePacked(r, s, v);
  }

  /// @dev A proposal with no swap: buyAmount 0, so execute settles nothing back and the
  /// route's own interactions are all that runs.
  function _emptyProposal() internal view returns (ITrampoline.Proposal memory) {
    return ITrampoline.Proposal({
      orderUidHash: keccak256('isolation-order-uid'),
      sellAmount: 0,
      buyAmount: 0,
      validUntil: block.timestamp + 1 hours,
      nonce: 0
    });
  }

  /// @dev Signs `route` under an empty proposal. Kept separate from execution so a test
  /// can arm `vm.expectRevert` immediately before `execute` — the signing does its own
  /// external call (`factory.domainSeparator`) that must not absorb the expectation.
  function _signRoute(
    ITrampoline.Interaction[] memory route
  ) internal view returns (ITrampoline.Proposal memory proposal, bytes memory signature) {
    proposal = _emptyProposal();
    signature = _sign(proposal, route);
  }

  /// @dev Drives `execute` directly from the settlement — the only caller it accepts.
  /// `tx.origin` is the BYOS submitter (`solver`), which the execute submitter gate
  /// requires; native `settle` reentrancy is covered separately; this exercises the
  /// route alone.
  function _executeAsSettlement(
    ITrampoline.Proposal memory proposal,
    ITrampoline.Interaction[] memory route,
    bytes memory signature
  ) internal {
    vm.prank(address(SETTLEMENT), solver);
    trampoline.execute(proposal, route, address(bufferToken), signature);
  }

  /// @dev Runs a real, successful `settle()` whose single intra-interaction drives the
  /// Trampoline's `execute` with `route` (no trades: the attack is all that runs). The
  /// call finalizing without reverting is the point — a route embedded in a settlement
  /// that succeeds must still move no value.
  function _settleWithRoute(
    ITrampoline.Proposal memory proposal,
    ITrampoline.Interaction[] memory route,
    bytes memory signature
  ) internal {
    address[] memory tokens = new address[](0);
    uint256[] memory prices = new uint256[](0);
    GPv2TradeData[] memory trades = new GPv2TradeData[](0);

    ITrampoline.Interaction[][3] memory interactions;
    interactions[1] = new ITrampoline.Interaction[](1);
    interactions[1][0] = ITrampoline.Interaction({
      target: address(trampoline),
      value: 0,
      callData: abi.encodeCall(ITrampoline.execute, (proposal, route, address(bufferToken), signature))
    });

    // msg.sender and tx.origin are both the submitter solver: the protocol's onlySolver
    // gate and the trampoline's submitter gate each read one of them.
    vm.prank(solver, solver);
    SETTLEMENT.settle(tokens, prices, trades, interactions);
  }

  /// @dev Calldata for a no-op `settle()` — empty tokens/prices/trades/interactions. Its
  /// only use here is as a reentrancy target: the guard is the first modifier, so it trips
  /// before any argument is inspected.
  function _emptySettleCalldata() internal pure returns (bytes memory) {
    address[] memory tokens = new address[](0);
    uint256[] memory prices = new uint256[](0);
    GPv2TradeData[] memory trades = new GPv2TradeData[](0);
    ITrampoline.Interaction[][3] memory interactions;
    return abi.encodeCall(IGPv2Settlement.settle, (tokens, prices, trades, interactions));
  }

  /// @dev A 56-byte GPv2 order UID (orderDigest ++ owner ++ validTo). setPreSignature and
  /// invalidateOrder both extract `owner` from these bytes and require it to equal the
  /// caller, so the encoded owner is what scopes the two functions.
  function _orderUid(
    address owner
  ) internal view returns (bytes memory) {
    return abi.encodePacked(keccak256('isolation-order'), owner, uint32(block.timestamp + 1 hours));
  }

  /// @dev A one-interaction route calling `callData` on `target`, run as the trampoline.
  function _singleCallRoute(
    address target,
    bytes memory callData
  ) internal pure returns (ITrampoline.Interaction[] memory route) {
    route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({target: target, value: 0, callData: callData});
  }

  /// @dev Wraps `attackData` against `attackTarget` in a swallow so the route completes.
  function _swallowingRoute(
    address attackTarget,
    bytes memory attackData
  ) internal view returns (ITrampoline.Interaction[] memory route) {
    route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({
      target: address(attackerRouter),
      value: 0,
      callData: abi.encodeCall(AttackerRouter.tryCall, (attackTarget, attackData))
    });
  }

  // --- Settlement buffers ---

  /// A route calling transferFrom on the settlement's buffer has no allowance to draw on.
  /// The attempt is swallowed so the settlement still finalizes successfully, yet the
  /// buffer is untouched: there was never an allowance for the trampoline to spend.
  function test_settlement_succeeds_but_buffer_transferFrom_moves_nothing() public onlyFork {
    ITrampoline.Interaction[] memory route = _swallowingRoute(
      address(bufferToken), abi.encodeCall(IERC20.transferFrom, (address(SETTLEMENT), attacker, BUFFER_AMOUNT))
    );
    (ITrampoline.Proposal memory proposal, bytes memory signature) = _signRoute(route);

    _settleWithRoute(proposal, route, signature);

    assertEq(bufferToken.balanceOf(address(SETTLEMENT)), BUFFER_AMOUNT);
    assertEq(bufferToken.balanceOf(attacker), 0);
  }

  // --- settle() re-entry ---

  /// A route calling settle() runs inside a live settle(); the reentrancy guard (the
  /// first modifier, ahead of onlySolver) reverts, the route bubbles it, and the whole
  /// settlement unwinds. This is the barrier a real in-settlement attacker actually hits.
  function test_route_cannot_reenter_settle() public onlyFork {
    ITrampoline.Interaction[] memory route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({target: address(SETTLEMENT), value: 0, callData: _emptySettleCalldata()});
    (ITrampoline.Proposal memory proposal, bytes memory signature) = _signRoute(route);

    // The trampoline bubbles the inner guard's revert verbatim (Trampoline.sol).
    vm.expectRevert('ReentrancyGuard: reentrant call');
    _settleWithRoute(proposal, route, signature);

    assertEq(bufferToken.balanceOf(address(SETTLEMENT)), BUFFER_AMOUNT);
  }

  /// The backstop behind the reentrancy guard: even reached outside a live settlement
  /// (driven here via a direct execute so no guard is engaged), a route calling settle()
  /// runs as the trampoline, which is not an allow-listed solver, so onlySolver reverts.
  function test_route_settle_call_is_rejected_by_onlySolver() public onlyFork {
    ITrampoline.Interaction[] memory route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({target: address(SETTLEMENT), value: 0, callData: _emptySettleCalldata()});
    (ITrampoline.Proposal memory proposal, bytes memory signature) = _signRoute(route);

    vm.expectRevert('GPv2: not a solver');
    _executeAsSettlement(proposal, route, signature);

    assertEq(bufferToken.balanceOf(address(SETTLEMENT)), BUFFER_AMOUNT);
  }

  // --- Order state (pre-signature / invalidation) ---

  /// setPreSignature is scoped to the order's encoded owner. A route runs as the
  /// trampoline, so it cannot pre-sign an order owned by anyone else; the victim's
  /// pre-signature state is untouched.
  function test_route_cannot_presign_another_owners_order() public onlyFork {
    address victim = makeAddr('victim');
    bytes memory orderUid = _orderUid(victim);
    ITrampoline.Interaction[] memory route =
      _singleCallRoute(address(SETTLEMENT), abi.encodeCall(IGPv2Signing.setPreSignature, (orderUid, true)));
    (ITrampoline.Proposal memory proposal, bytes memory signature) = _signRoute(route);

    vm.expectRevert('GPv2: cannot presign order');
    _executeAsSettlement(proposal, route, signature);

    assertEq(IGPv2Signing(address(SETTLEMENT)).preSignature(orderUid), 0);
  }

  /// invalidateOrder is likewise owner-scoped: a route cannot cancel someone else's order,
  /// so the victim's fill state is untouched.
  function test_route_cannot_invalidate_another_owners_order() public onlyFork {
    address victim = makeAddr('victim');
    bytes memory orderUid = _orderUid(victim);
    ITrampoline.Interaction[] memory route =
      _singleCallRoute(address(SETTLEMENT), abi.encodeCall(IGPv2Signing.invalidateOrder, (orderUid)));
    (ITrampoline.Proposal memory proposal, bytes memory signature) = _signRoute(route);

    vm.expectRevert('GPv2: caller does not own order');
    _executeAsSettlement(proposal, route, signature);

    assertEq(IGPv2Signing(address(SETTLEMENT)).filledAmount(orderUid), 0);
  }

  // --- Inert directions (value flows toward the settlement) ---

  /// Approving the settlement grants it an allowance over the trampoline's own funds, not
  /// the reverse. It confers no power over any buffer, and the trampoline holds nothing
  /// for that allowance to reach anyway.
  function test_route_approving_settlement_is_inert() public onlyFork {
    ITrampoline.Interaction[] memory route =
      _singleCallRoute(address(bufferToken), abi.encodeCall(IERC20.approve, (address(SETTLEMENT), type(uint256).max)));
    (ITrampoline.Proposal memory proposal, bytes memory signature) = _signRoute(route);

    _executeAsSettlement(proposal, route, signature);

    // The allowance exists but points at the trampoline's (empty) balance; buffer intact.
    assertEq(bufferToken.allowance(address(trampoline), address(SETTLEMENT)), type(uint256).max);
    assertEq(bufferToken.balanceOf(address(trampoline)), 0);
    assertEq(bufferToken.balanceOf(address(SETTLEMENT)), BUFFER_AMOUNT);
  }

  /// Sending native value at the settlement only makes it richer: the flow is one-way in,
  /// the trampoline ends poorer, and nothing is extracted.
  function test_route_sending_value_at_settlement_is_inert() public onlyFork {
    uint256 sent = 1 ether;
    vm.deal(address(trampoline), sent);
    uint256 settlementEthBefore = address(SETTLEMENT).balance;

    ITrampoline.Interaction[] memory route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({target: address(SETTLEMENT), value: sent, callData: ''});
    (ITrampoline.Proposal memory proposal, bytes memory signature) = _signRoute(route);

    _executeAsSettlement(proposal, route, signature);

    assertEq(address(SETTLEMENT).balance, settlementEthBefore + sent);
    assertEq(address(trampoline).balance, 0);
    assertEq(bufferToken.balanceOf(address(SETTLEMENT)), BUFFER_AMOUNT);
  }

  // --- Vault relayer ---

  /// The vault relayer is what pulls users' sell tokens, and only its creator (the
  /// settlement) may call it. A route runs as the trampoline, so even a fully-formed pull
  /// against a victim who really approved the relayer is rejected at the gate; the
  /// victim's balance is untouched.
  function test_route_cannot_pull_through_vault_relayer() public onlyFork {
    address vaultRelayer = SETTLEMENT.vaultRelayer();
    address victim = makeAddr('relayerVictim');
    uint256 amount = 1000 ether;

    // The victim holds and has approved the relayer, so only onlyCreator stands in the way.
    bufferToken.mint(victim, amount);
    vm.prank(victim);
    IERC20(address(bufferToken)).approve(vaultRelayer, type(uint256).max);

    IGPv2VaultRelayer.Transfer[] memory transfers = new IGPv2VaultRelayer.Transfer[](1);
    transfers[0] = IGPv2VaultRelayer.Transfer({
      account: victim, token: address(bufferToken), amount: amount, balance: keccak256('erc20')
    });
    ITrampoline.Interaction[] memory route =
      _singleCallRoute(vaultRelayer, abi.encodeCall(IGPv2VaultRelayer.transferFromAccounts, (transfers)));
    (ITrampoline.Proposal memory proposal, bytes memory signature) = _signRoute(route);

    vm.expectRevert('GPv2: not creator');
    _executeAsSettlement(proposal, route, signature);

    assertEq(bufferToken.balanceOf(victim), amount);
  }
}
