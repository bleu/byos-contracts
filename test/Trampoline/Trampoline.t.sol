// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test, Vm} from 'forge-std/Test.sol';

import {BUY_ETH_ADDRESS, ITrampoline} from 'interfaces/ITrampoline.sol';

import {Escrow} from 'contracts/Escrow.sol';
import {Trampoline} from 'contracts/Trampoline.sol';
import {TrampolineFactory} from 'contracts/TrampolineFactory.sol';

import {MockRouter} from '../mocks/MockRouter.sol';
import {MockWETH} from '../mocks/MockWETH.sol';
import {Reverter} from '../mocks/Reverter.sol';
import {TestERC20} from '../mocks/TestERC20.sol';
import {ProposalSigning} from '../utils/ProposalSigning.sol';

contract TrampolineTest is Test {
  Escrow escrow;
  TrampolineFactory factory;
  Trampoline trampoline;
  address settlement;
  address submitter;
  address subSolver;
  uint256 subSolverKey;

  TestERC20 sellToken;
  TestERC20 buyToken;
  MockRouter router;

  uint256 constant SELL_AMOUNT = 100 ether;
  uint256 constant BUY_AMOUNT = 90 ether;

  function setUp() public {
    settlement = makeAddr('settlement');
    submitter = makeAddr('submitter');
    (subSolver, subSolverKey) = makeAddrAndKey('subSolver');
    escrow = new Escrow(
      2 days,
      makeAddr('admin'),
      makeAddr('operator'),
      _soloSubmitters(submitter),
      1 days,
      settlement,
      'BYOS Escrow',
      'BYOS'
    );
    factory = TrampolineFactory(address(escrow.TRAMPOLINE_FACTORY()));
    trampoline = Trampoline(payable(factory.ensureDeployed(subSolver)));

    sellToken = new TestERC20();
    buyToken = new TestERC20();
    router = new MockRouter();
    buyToken.mint(address(router), 1_000_000 ether);
  }

  // --- Helpers ---

  /// @dev Wraps a single submitter in the constructor's submitter-list shape.
  function _soloSubmitters(
    address _submitter
  ) internal pure returns (address[] memory _submitters) {
    _submitters = new address[](1);
    _submitters[0] = _submitter;
  }

  function _proposal() internal view returns (ITrampoline.Proposal memory) {
    return ITrampoline.Proposal({
      orderUidHash: keccak256('order-uid'),
      sellAmount: SELL_AMOUNT,
      buyAmount: BUY_AMOUNT,
      validUntil: block.timestamp + 1 hours,
      nonce: 0
    });
  }

  function _sign(
    uint256 key,
    ITrampoline.Proposal memory proposal,
    ITrampoline.Interaction[] memory interactions
  ) internal view returns (bytes memory) {
    bytes32 digest = ProposalSigning.digest(factory.domainSeparator(), proposal, interactions);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
    return abi.encodePacked(r, s, v);
  }

  /// @dev A route that approves the router and swaps the full SELL_AMOUNT for
  /// `buyAmountOut` of buyToken.
  function _swapRoute(
    uint256 buyAmountOut
  ) internal view returns (ITrampoline.Interaction[] memory route) {
    route = _swapRoute(SELL_AMOUNT, buyAmountOut);
  }

  /// @dev A route that approves the router and swaps `sellAmountIn` of sellToken for
  /// `buyAmountOut` of buyToken.
  function _swapRoute(
    uint256 sellAmountIn,
    uint256 buyAmountOut
  ) internal view returns (ITrampoline.Interaction[] memory route) {
    route = new ITrampoline.Interaction[](2);
    route[0] = ITrampoline.Interaction({
      target: address(sellToken), value: 0, callData: abi.encodeCall(IERC20.approve, (address(router), sellAmountIn))
    });
    route[1] = ITrampoline.Interaction({
      target: address(router),
      value: 0,
      callData: abi.encodeCall(MockRouter.swap, (sellToken, buyToken, sellAmountIn, buyAmountOut))
    });
  }

  // --- Happy path ---

  function test_execute_sweeps_full_route_output_and_emits_executed() public {
    // GPv2Settlement pushes the trade's sell tokens in before calling execute (ADR-0003).
    uint256 surplus = 5 ether;
    sellToken.mint(address(trampoline), SELL_AMOUNT);

    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT + surplus);
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.expectEmit(address(trampoline));
    emit ITrampoline.Executed(proposal.orderUidHash, BUY_AMOUNT + surplus, BUY_AMOUNT);

    vm.prank(settlement, submitter);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);

    // The whole output sweeps: surplus lands in the settlement as BYOS-owned
    // slippage (ADR-0008), never strands in the instance.
    assertEq(buyToken.balanceOf(settlement), BUY_AMOUNT + surplus);
    assertEq(buyToken.balanceOf(address(trampoline)), 0);
    assertEq(sellToken.balanceOf(address(trampoline)), 0);
  }

  // --- Gates ---

  function test_execute_reverts_when_caller_not_settlement() public {
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.prank(makeAddr('notSettlement'));
    vm.expectRevert(ITrampoline.Trampoline_OnlySettlement.selector);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);
  }

  function test_execute_reverts_when_tx_origin_not_a_submitter() public {
    // The COW-1151 replay: once BYOS settles a proposal its signature and route are
    // public calldata, and another allow-listed CoW solver carries the same execute
    // in its own settlement. msg.sender is still GPv2Settlement, but the tx
    // originates from the rival solver, which holds no SUBMITTER_ROLE.
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.prank(settlement, makeAddr('rivalSolver'));
    vm.expectRevert(ITrampoline.Trampoline_UnauthorizedSubmitter.selector);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);
  }

  function test_execute_reverts_after_submitter_revoked() public {
    // Submitter rotation is a role change on the Escrow, not a redeploy: once the
    // admin revokes the key, settlements it originates stop passing the gate.
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    bytes32 submitterRole = escrow.SUBMITTER_ROLE();
    vm.prank(escrow.defaultAdmin());
    escrow.revokeRole(submitterRole, submitter);

    vm.prank(settlement, submitter);
    vm.expectRevert(ITrampoline.Trampoline_UnauthorizedSubmitter.selector);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);
  }

  function test_execute_accepts_newly_granted_submitter() public {
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    address newSubmitter = makeAddr('newSubmitter');
    bytes32 submitterRole = escrow.SUBMITTER_ROLE();
    vm.prank(escrow.defaultAdmin());
    escrow.grantRole(submitterRole, newSubmitter);

    vm.prank(settlement, newSubmitter);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);

    assertEq(buyToken.balanceOf(settlement), BUY_AMOUNT);
  }

  function test_execute_accepts_solver_7702_delegate_auxiliary_submitters() public {
    // CoW's Solver7702Delegate parallel path: an auxiliary account signs and
    // broadcasts the settlement transaction to the delegated solver EOA, so at the
    // Trampoline tx.origin is the auxiliary account, not the allow-listed solver.
    // Wiring the solver EOA and every auxiliary account as constructor submitters
    // keeps the gate satisfied on all submission lanes (ADR-0005).
    address solverEoa = makeAddr('solverEoa');
    address[] memory submitters = new address[](3);
    submitters[0] = solverEoa;
    submitters[1] = makeAddr('aux0');
    submitters[2] = makeAddr('aux1');

    Escrow escrow7702 = new Escrow(
      2 days, makeAddr('admin'), makeAddr('operator'), submitters, 1 days, settlement, 'BYOS Escrow', 'BYOS'
    );
    TrampolineFactory factory7702 = TrampolineFactory(address(escrow7702.TRAMPOLINE_FACTORY()));
    Trampoline instance = Trampoline(payable(factory7702.ensureDeployed(subSolver)));

    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    bytes32 digest = ProposalSigning.digest(factory7702.domainSeparator(), proposal, route);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(subSolverKey, digest);
    bytes memory signature = abi.encodePacked(r, s, v);

    for (uint256 i = 0; i < submitters.length; ++i) {
      sellToken.mint(address(instance), SELL_AMOUNT);
      vm.prank(settlement, submitters[i]);
      instance.execute(proposal, route, address(sellToken), address(buyToken), signature);
    }

    assertEq(buyToken.balanceOf(settlement), submitters.length * BUY_AMOUNT);
  }

  function test_execute_reverts_when_proposal_expired() public {
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.warp(proposal.validUntil + 1);

    vm.prank(settlement, submitter);
    vm.expectRevert(ITrampoline.Trampoline_ProposalExpired.selector);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);
  }

  // --- Signature verification ---

  function test_execute_reverts_on_signature_from_wrong_signer() public {
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    (, uint256 wrongKey) = makeAddrAndKey('mallory');
    bytes memory signature = _sign(wrongKey, proposal, route);

    vm.prank(settlement, submitter);
    vm.expectRevert(ITrampoline.Trampoline_InvalidSignature.selector);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);
  }

  function test_execute_reverts_when_interactions_differ_from_signed() public {
    // The fabricated-fault vector from ADR-0005: BYOS substitutes a different route
    // while presenting the sub-solver's signed amounts.
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, _swapRoute(BUY_AMOUNT));

    ITrampoline.Interaction[] memory substituted = _swapRoute(BUY_AMOUNT + 1);

    vm.prank(settlement, submitter);
    vm.expectRevert(ITrampoline.Trampoline_InvalidSignature.selector);
    trampoline.execute(proposal, substituted, address(sellToken), address(buyToken), signature);
  }

  function test_execute_reverts_when_signed_amounts_tampered() public {
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    proposal.buyAmount = BUY_AMOUNT - 10 ether;

    vm.prank(settlement, submitter);
    vm.expectRevert(ITrampoline.Trampoline_InvalidSignature.selector);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);
  }

  // --- Funding guard: floor, sweep, delta check (ADR-0003 / ADR-0008) ---

  /// @dev The funding-guard property (ADR-0003) over fuzzed amounts: execute succeeds
  /// iff the route's output covers the floor, the settlement receives the full output
  /// (surplus included), and the instance ends empty of both trade tokens.
  function testFuzz_execute_succeeds_iff_route_output_covers_floor(
    uint256 buyAmount,
    uint256 output
  ) public {
    // The router pays output from its own inventory (minted in setUp).
    buyAmount = bound(buyAmount, 0, 1_000_000 ether);
    output = bound(output, 0, 1_000_000 ether);

    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = _swapRoute(output);
    ITrampoline.Proposal memory proposal = _proposal();
    proposal.buyAmount = buyAmount;
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.prank(settlement, submitter);
    if (output >= buyAmount) {
      trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);

      assertEq(buyToken.balanceOf(settlement), output);
      assertEq(buyToken.balanceOf(address(trampoline)), 0);
      assertEq(sellToken.balanceOf(address(trampoline)), 0);
    } else {
      // Expect the delta-check error with its exact arguments, so an unrelated
      // revert (e.g. in the route) cannot make this branch pass.
      vm.expectRevert(abi.encodeWithSelector(ITrampoline.Trampoline_FloorNotMet.selector, output, buyAmount));
      trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);
    }
  }

  function test_execute_buy_order_sweeps_unconsumed_sell_token_to_settlement() public {
    // Buy-order shape (ADR-0003): the input is over-provisioned, the route consumes
    // only part of it, and the sweep returns the rest to the settlement.
    uint256 consumed = 40 ether;
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = _swapRoute(consumed, BUY_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.prank(settlement, submitter);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);

    assertEq(buyToken.balanceOf(settlement), BUY_AMOUNT);
    assertEq(sellToken.balanceOf(settlement), SELL_AMOUNT - consumed);
    assertEq(buyToken.balanceOf(address(trampoline)), 0);
    assertEq(sellToken.balanceOf(address(trampoline)), 0);
  }

  function test_execute_same_token_hook_order_sweeps_once_and_enforces_floor() public {
    // Same-token hook order (COW-1194): sellToken == buyToken, sellAmount > buyAmount,
    // and the route spends part of the input on the hook. The sweep returning the
    // unconsumed input is the delivery the delta check measures; the floor bounds
    // route consumption at sellAmount - buyAmount.
    uint256 hookBudget = SELL_AMOUNT - BUY_AMOUNT;
    address hook = makeAddr('hook');

    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({
      target: address(sellToken), value: 0, callData: abi.encodeCall(IERC20.transfer, (hook, hookBudget))
    });
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.recordLogs();
    vm.prank(settlement, submitter);
    trampoline.execute(proposal, route, address(sellToken), address(sellToken), signature);

    assertEq(sellToken.balanceOf(settlement), SELL_AMOUNT - hookBudget);
    assertEq(sellToken.balanceOf(address(trampoline)), 0);

    // The shared token sweeps exactly once: no zero-value second leg, no double send.
    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 sweeps;
    for (uint256 i = 0; i < logs.length; ++i) {
      if (
        logs[i].emitter == address(sellToken) && logs[i].topics[0] == keccak256('Transfer(address,address,uint256)')
          && logs[i].topics[1] == bytes32(uint256(uint160(address(trampoline))))
          && logs[i].topics[2] == bytes32(uint256(uint160(settlement)))
      ) sweeps++;
    }
    assertEq(sweeps, 1);

    // One token over the budget and the returned balance no longer covers the floor.
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    route[0].callData = abi.encodeCall(IERC20.transfer, (hook, hookBudget + 1));
    signature = _sign(subSolverKey, proposal, route);

    vm.prank(settlement, submitter);
    vm.expectRevert(abi.encodeWithSelector(ITrampoline.Trampoline_FloorNotMet.selector, BUY_AMOUNT - 1, BUY_AMOUNT));
    trampoline.execute(proposal, route, address(sellToken), address(sellToken), signature);
  }

  function test_execute_passes_when_route_delivers_directly_to_settlement() public {
    // The delta measures what the settlement actually received, so a route that pays
    // the settlement without the output ever touching the instance still meets the
    // floor. The untouched sell tokens come back via the sweep.
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({
      target: address(buyToken), value: 0, callData: abi.encodeCall(TestERC20.mint, (settlement, BUY_AMOUNT))
    });
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.prank(settlement, submitter);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);

    assertEq(buyToken.balanceOf(settlement), BUY_AMOUNT);
    assertEq(sellToken.balanceOf(settlement), SELL_AMOUNT);
    assertEq(buyToken.balanceOf(address(trampoline)), 0);
    assertEq(sellToken.balanceOf(address(trampoline)), 0);
  }

  // --- Reverting routes ---

  function test_execute_bubbles_interaction_revert_data() public {
    Reverter reverter = new Reverter();
    ITrampoline.Interaction[] memory route = new ITrampoline.Interaction[](1);
    route[0] =
      ITrampoline.Interaction({target: address(reverter), value: 0, callData: abi.encodeCall(Reverter.explode, ())});
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.prank(settlement, submitter);
    vm.expectRevert(abi.encodeWithSelector(Reverter.Boom.selector, 42));
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);
  }

  // --- Native ETH ---

  function test_execute_native_eth_buy_sweeps_over_delivery_to_settlement() public {
    // For BUY_ETH_ADDRESS the snapshot, sweep, and delta are the settlement's native
    // ETH balance. Route output lands as WETH in the instance and the signed route's
    // final leg unwraps it (wrap/unwrap is route responsibility, ADR-0001); the sweep
    // sends the instance's whole ETH balance, floor and surplus alike.
    uint256 surplus = 2 ether;
    MockWETH weth = new MockWETH();
    vm.deal(address(this), BUY_AMOUNT + surplus);
    weth.deposit{value: BUY_AMOUNT + surplus}();
    assertTrue(weth.transfer(address(trampoline), BUY_AMOUNT + surplus));

    ITrampoline.Interaction[] memory route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({
      target: address(weth), value: 0, callData: abi.encodeCall(MockWETH.withdraw, (BUY_AMOUNT + surplus))
    });
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.prank(settlement, submitter);
    trampoline.execute(proposal, route, address(sellToken), BUY_ETH_ADDRESS, signature);

    assertEq(settlement.balance, BUY_AMOUNT + surplus);
    assertEq(address(trampoline).balance, 0);
  }

  function test_execute_native_eth_buy_reverts_below_floor() public {
    MockWETH weth = new MockWETH();
    vm.deal(address(this), BUY_AMOUNT - 1);
    weth.deposit{value: BUY_AMOUNT - 1}();
    assertTrue(weth.transfer(address(trampoline), BUY_AMOUNT - 1));

    ITrampoline.Interaction[] memory route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({
      target: address(weth), value: 0, callData: abi.encodeCall(MockWETH.withdraw, (BUY_AMOUNT - 1))
    });
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.prank(settlement, submitter);
    vm.expectRevert(abi.encodeWithSelector(ITrampoline.Trampoline_FloorNotMet.selector, BUY_AMOUNT - 1, BUY_AMOUNT));
    trampoline.execute(proposal, route, address(sellToken), BUY_ETH_ADDRESS, signature);
  }

  function test_execute_passes_value_in_interactions() public {
    MockWETH weth = new MockWETH();
    // ETH sitting in the instance mid-route (e.g. from an ETH-paying venue);
    // the signed route wraps it and the sweep returns it as WETH.
    vm.deal(address(trampoline), BUY_AMOUNT);

    ITrampoline.Interaction[] memory route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({
      target: address(weth), value: BUY_AMOUNT, callData: abi.encodeCall(MockWETH.deposit, ())
    });
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.prank(settlement, submitter);
    trampoline.execute(proposal, route, address(sellToken), address(weth), signature);

    assertEq(weth.balanceOf(settlement), BUY_AMOUNT);
    assertEq(address(trampoline).balance, 0);
  }

  // --- Replay ---

  function test_execute_accepts_replayed_proposal_by_design() public {
    // The trampoline is deliberately stateless (no nonce mapping, ADR-0005): a live
    // proposal replayed by an authorized BYOS submitter executes again. Third-party
    // replay is blocked by the submitter gate; BYOS itself is trusted not to
    // resubmit, and validUntil bounds the window. This test pins that behavior.
    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    for (uint256 i = 0; i < 2; i++) {
      sellToken.mint(address(trampoline), SELL_AMOUNT);
      vm.prank(settlement, submitter);
      trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);
    }

    assertEq(buyToken.balanceOf(settlement), 2 * BUY_AMOUNT);
  }

  // --- Isolation between instances ---

  function test_route_cannot_call_another_instances_execute() public {
    Trampoline other = Trampoline(payable(factory.ensureDeployed(makeAddr('otherSubSolver'))));

    ITrampoline.Interaction[] memory innerRoute = new ITrampoline.Interaction[](0);
    ITrampoline.Interaction[] memory route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({
      target: address(other),
      value: 0,
      callData: abi.encodeCall(
        ITrampoline.execute, (_proposal(), innerRoute, address(sellToken), address(buyToken), '')
      )
    });
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    // The inner execute rejects the trampoline as caller; the revert bubbles up.
    vm.prank(settlement, submitter);
    vm.expectRevert(ITrampoline.Trampoline_OnlySettlement.selector);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);
  }

  function test_route_cannot_reenter_own_execute() public {
    ITrampoline.Interaction[] memory innerRoute = new ITrampoline.Interaction[](0);
    ITrampoline.Interaction[] memory route = new ITrampoline.Interaction[](1);
    route[0] = ITrampoline.Interaction({
      target: address(trampoline),
      value: 0,
      callData: abi.encodeCall(
        ITrampoline.execute, (_proposal(), innerRoute, address(sellToken), address(buyToken), '')
      )
    });
    ITrampoline.Proposal memory proposal = _proposal();
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.prank(settlement, submitter);
    vm.expectRevert(ITrampoline.Trampoline_OnlySettlement.selector);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);
  }

  function test_planted_approval_cannot_reach_other_instances_residue() public {
    address mallory = makeAddr('mallory');
    Trampoline other = Trampoline(payable(factory.ensureDeployed(makeAddr('otherSubSolver'))));
    // The other instance holds a stray balance (instances end settlements empty of
    // trade tokens under ADR-0008, but tokens can still land outside the flow).
    buyToken.mint(address(other), 7 ether);

    // Sub-solver A's route plants an unlimited approval for mallory on its own instance.
    sellToken.mint(address(trampoline), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT);
    route[0] = ITrampoline.Interaction({
      target: address(buyToken), value: 0, callData: abi.encodeCall(IERC20.approve, (mallory, type(uint256).max))
    });
    route[1] = ITrampoline.Interaction({
      target: address(sellToken), value: 0, callData: abi.encodeCall(IERC20.transfer, (makeAddr('sink'), SELL_AMOUNT))
    });
    ITrampoline.Proposal memory proposal = _proposal();
    proposal.buyAmount = 0;
    bytes memory signature = _sign(subSolverKey, proposal, route);
    vm.prank(settlement, submitter);
    trampoline.execute(proposal, route, address(sellToken), address(buyToken), signature);

    // The approval stands (approvals are not reset, ADR-0001) but instance A is
    // empty, and it grants nothing over instance B's residue.
    assertEq(buyToken.allowance(address(trampoline), mallory), type(uint256).max);
    vm.prank(mallory);
    assertTrue(buyToken.transferFrom(address(trampoline), mallory, 0));
    assertEq(buyToken.balanceOf(mallory), 0);

    vm.prank(mallory);
    vm.expectRevert();
    // forge-lint: disable-next-line(erc20-unchecked-transfer)
    buyToken.transferFrom(address(other), mallory, 1);
    assertEq(buyToken.balanceOf(address(other)), 7 ether);
  }

  // --- EIP-712 domain separation ---

  function test_signature_from_other_factory_generation_fails() public {
    // An escrow redeployment (v2) brings a new factory and a new EIP-712 domain:
    // signatures against the v1 factory must not verify on a v2 instance (ADR-0005).
    Escrow escrow2 = new Escrow(
      2 days,
      makeAddr('admin'),
      makeAddr('operator'),
      _soloSubmitters(submitter),
      1 days,
      settlement,
      'BYOS Escrow',
      'BYOS'
    );
    TrampolineFactory factory2 = TrampolineFactory(address(escrow2.TRAMPOLINE_FACTORY()));
    Trampoline instance2 = Trampoline(payable(factory2.ensureDeployed(subSolver)));
    assertTrue(address(instance2) != address(trampoline));

    sellToken.mint(address(instance2), SELL_AMOUNT);
    ITrampoline.Interaction[] memory route = _swapRoute(BUY_AMOUNT);
    ITrampoline.Proposal memory proposal = _proposal();
    // Signed against the v1 factory's domain separator (the _sign helper).
    bytes memory signature = _sign(subSolverKey, proposal, route);

    vm.prank(settlement, submitter);
    vm.expectRevert(ITrampoline.Trampoline_InvalidSignature.selector);
    instance2.execute(proposal, route, address(sellToken), address(buyToken), signature);
  }
}
