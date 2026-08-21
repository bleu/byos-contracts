// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {IGPv2Authentication} from 'interfaces/IGPv2Authentication.sol';
import {GPv2TradeData, IGPv2Settlement} from 'interfaces/IGPv2Settlement.sol';
import {BUY_ETH_ADDRESS, ITrampoline} from 'interfaces/ITrampoline.sol';

import {Escrow} from 'contracts/Escrow.sol';
import {Trampoline} from 'contracts/Trampoline.sol';
import {TrampolineFactory} from 'contracts/TrampolineFactory.sol';

import {IUniswapV2Router} from '../interfaces/IUniswapV2Router.sol';
import {IWETH} from '../interfaces/IWETH.sol';
import {ProposalSigning} from '../utils/ProposalSigning.sol';

/// @notice End-to-end integration against the real mainnet GPv2Settlement: a full
/// settle() carrying the ADR-0003 value flow (transfer-in interaction + Trampoline
/// execute). Uses a public RPC endpoint by default; override with MAINNET_RPC_URL,
/// or set it to an empty string to skip the suite (e.g. offline).
contract ForkSettlementTest is Test {
  IGPv2Settlement constant SETTLEMENT = IGPv2Settlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);
  IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
  IUniswapV2Router constant UNIV2_ROUTER = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
  address constant BUY_ETH = BUY_ETH_ADDRESS;

  bytes32 constant ORDER_TYPE_HASH = keccak256(
    'Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)'
  );
  bytes32 constant KIND_SELL = keccak256('sell');
  bytes32 constant BALANCE_ERC20 = keccak256('erc20');

  /// @dev A signed sub-solver proposal bundled with its route.
  struct SignedProposal {
    ITrampoline.Proposal data;
    ITrampoline.Interaction[] route;
    bytes signature;
  }

  string rpcUrl;
  TrampolineFactory factory;
  Trampoline trampoline;
  address solver;
  address user;
  uint256 userKey;
  address subSolver;
  uint256 subSolverKey;

  modifier onlyFork() {
    vm.skip(bytes(rpcUrl).length == 0);
    _;
  }

  string constant DEFAULT_RPC_URL = 'https://ethereum-rpc.publicnode.com';

  function setUp() public {
    rpcUrl = vm.envOr('MAINNET_RPC_URL', DEFAULT_RPC_URL);
    if (bytes(rpcUrl).length == 0) return;
    vm.createSelectFork(rpcUrl);

    solver = makeAddr('byosSolver');
    (user, userKey) = makeAddrAndKey('user');
    (subSolver, subSolverKey) = makeAddrAndKey('subSolver');

    // makeAddr-derived addresses can collide with deployed mainnet contracts
    // (e.g. EIP-7702 delegated EOAs). Strip any code so .transfer() with the
    // 2300 gas stipend succeeds when GPv2Settlement pays the user in native ETH.
    vm.etch(user, '');

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
  }

  // --- Helpers ---

  function _quote(
    address sellToken,
    address buyToken,
    uint256 sellAmount
  ) internal view returns (uint256) {
    address[] memory path = new address[](2);
    path[0] = sellToken;
    path[1] = buyToken;
    return UNIV2_ROUTER.getAmountsOut(sellAmount, path)[1];
  }

  /// @dev Route: approve router, swap sellToken -> buyToken, delivering output
  /// directly to the settlement contract.
  function _swapRoute(
    address sellToken,
    address buyToken,
    uint256 sellAmount,
    uint256 buyAmountOut
  ) internal view returns (ITrampoline.Interaction[] memory route) {
    address[] memory path = new address[](2);
    path[0] = sellToken;
    path[1] = buyToken;
    route = new ITrampoline.Interaction[](2);
    route[0] = ITrampoline.Interaction({
      target: sellToken, value: 0, callData: abi.encodeCall(IERC20.approve, (address(UNIV2_ROUTER), sellAmount))
    });
    route[1] = ITrampoline.Interaction({
      target: address(UNIV2_ROUTER),
      value: 0,
      callData: abi.encodeCall(
        IUniswapV2Router.swapExactTokensForTokens,
        (sellAmount, buyAmountOut, path, address(SETTLEMENT), block.timestamp + 1 hours)
      )
    });
  }

  function _signProposal(
    address sellToken,
    address buyToken,
    uint256 sellAmount,
    uint256 buyAmount,
    ITrampoline.Interaction[] memory route
  ) internal view returns (SignedProposal memory signed) {
    signed.data = ITrampoline.Proposal({
      orderUidHash: keccak256('fork-order-uid'),
      sellToken: sellToken,
      buyToken: buyToken,
      sellAmount: sellAmount,
      minBuyAmount: buyAmount,
      quoteBuyAmount: buyAmount,
      validUntil: block.timestamp + 1 hours,
      nonce: 0
    });
    signed.route = route;
    bytes32 digest = ProposalSigning.digest(factory.domainSeparator(), signed.data, route);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(subSolverKey, digest);
    signed.signature = abi.encodePacked(r, s, v);
  }

  function _signOrder(
    address sellToken,
    address buyToken,
    uint256 sellAmount,
    uint256 buyAmount,
    uint32 validTo
  ) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(
      abi.encode(
        ORDER_TYPE_HASH,
        sellToken,
        buyToken,
        user,
        sellAmount,
        buyAmount,
        validTo,
        bytes32(0), // appData
        uint256(0), // feeAmount
        KIND_SELL,
        false, // partiallyFillable
        BALANCE_ERC20,
        BALANCE_ERC20
      )
    );
    bytes32 digest = keccak256(abi.encodePacked('\x19\x01', SETTLEMENT.domainSeparator(), structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, digest);
    return abi.encodePacked(r, s, v);
  }

  /// @dev Builds a one-trade settlement carrying the ADR-0003 value flow (push
  /// sellAmount to the trampoline, call execute) and submits it as the solver.
  /// `buyAmount` is the clearing amount the user is paid; the user's limit is set
  /// 1% under it so the clearing price satisfies it.
  function _settleOrder(
    address sellToken,
    address buyToken,
    uint256 sellAmount,
    uint256 buyAmount,
    SignedProposal memory prop
  ) internal {
    address[] memory tokens = new address[](2);
    tokens[0] = sellToken;
    tokens[1] = buyToken;
    uint256[] memory prices = new uint256[](2);
    prices[0] = buyAmount; // sell token priced in buy units
    prices[1] = sellAmount; // buy token priced in sell units

    GPv2TradeData[] memory trades = new GPv2TradeData[](1);
    trades[0] = GPv2TradeData({
      sellTokenIndex: 0,
      buyTokenIndex: 1,
      receiver: user,
      sellAmount: sellAmount,
      buyAmount: buyAmount * 99 / 100,
      validTo: uint32(block.timestamp + 1 hours),
      appData: bytes32(0),
      feeAmount: 0,
      flags: 0, // sell, fill-or-kill, erc20 balances, EIP-712 signature
      executedAmount: sellAmount,
      signature: _signOrder(sellToken, buyToken, sellAmount, buyAmount * 99 / 100, uint32(block.timestamp + 1 hours))
    });

    ITrampoline.Interaction[][3] memory interactions;
    interactions[1] = new ITrampoline.Interaction[](2);
    interactions[1][0] = ITrampoline.Interaction({
      target: sellToken, value: 0, callData: abi.encodeCall(IERC20.transfer, (address(trampoline), sellAmount))
    });
    interactions[1][1] = ITrampoline.Interaction({
      target: address(trampoline),
      value: 0,
      callData: abi.encodeCall(ITrampoline.execute, (prop.data, prop.route, prop.signature))
    });

    // A solver submits settle() from its own EOA: msg.sender and tx.origin are both it.
    vm.prank(solver, solver);
    SETTLEMENT.settle(tokens, prices, trades, interactions);
  }

  // --- Tests ---

  function test_fork_settle_erc20_order_through_trampoline() public onlyFork {
    uint256 sellAmount = 1 ether;

    // User holds WETH and approves the vault relayer.
    vm.deal(user, 2 ether);
    vm.startPrank(user);
    WETH.deposit{value: sellAmount}();
    WETH.approve(SETTLEMENT.vaultRelayer(), sellAmount);
    vm.stopPrank();

    // The route delivers the full V2 quote; the signed floor and the clearing amount
    // sit below it, so the sweep hands the settlement more than it pays the user.
    uint256 quotedOut = _quote(address(WETH), address(USDC), sellAmount);
    uint256 clearingOut = quotedOut * 99 / 100;
    SignedProposal memory prop = _signProposal(
      address(WETH),
      address(USDC),
      sellAmount,
      clearingOut,
      _swapRoute(address(WETH), address(USDC), sellAmount, quotedOut)
    );

    uint256 settlementWethBefore = WETH.balanceOf(address(SETTLEMENT));
    uint256 settlementUsdcBefore = USDC.balanceOf(address(SETTLEMENT));

    _settleOrder(address(WETH), address(USDC), sellAmount, clearingOut, prop);

    // User was paid exactly at clearing price; the over-delivery is not an exact
    // settle-back and does not strand in the instance — it lands in the settlement
    // as BYOS-owned slippage (ADR-0008), and the instance ends empty of both tokens.
    assertEq(USDC.balanceOf(user), clearingOut);
    assertEq(WETH.balanceOf(address(SETTLEMENT)), settlementWethBefore);
    assertEq(USDC.balanceOf(address(SETTLEMENT)), settlementUsdcBefore + (quotedOut - clearingOut));
    assertEq(WETH.balanceOf(address(trampoline)), 0);
    assertEq(USDC.balanceOf(address(trampoline)), 0);
  }

  function test_fork_replayed_proposal_by_second_solver_reverts() public onlyFork {
    // COW-1151: after BYOS settles, the proposal's signature and route are public
    // calldata. A rival allow-listed solver carries the same execute in its own
    // (tradeless) settlement — the sweep leaves no residue to skim, but a replayed
    // route could still grief the instance or front-run a live proposal. The
    // submitter gate must reject it: the rival passes the protocol's solver
    // allowlist but holds no SUBMITTER_ROLE on the BYOS escrow.
    uint256 sellAmount = 1 ether;

    vm.deal(user, 2 ether);
    vm.startPrank(user);
    WETH.deposit{value: sellAmount}();
    WETH.approve(SETTLEMENT.vaultRelayer(), sellAmount);
    vm.stopPrank();

    uint256 quotedOut = _quote(address(WETH), address(USDC), sellAmount);
    SignedProposal memory prop = _signProposal(
      address(WETH),
      address(USDC),
      sellAmount,
      quotedOut,
      _swapRoute(address(WETH), address(USDC), sellAmount, quotedOut)
    );

    // BYOS settles the proposal; from here on its calldata is public.
    _settleOrder(address(WETH), address(USDC), sellAmount, quotedOut, prop);

    address rival = makeAddr('rivalSolver');
    IGPv2Authentication auth = IGPv2Authentication(SETTLEMENT.authenticator());
    vm.prank(auth.manager());
    auth.addSolver(rival);

    ITrampoline.Interaction[][3] memory interactions;
    interactions[1] = new ITrampoline.Interaction[](1);
    interactions[1][0] = ITrampoline.Interaction({
      target: address(trampoline),
      value: 0,
      callData: abi.encodeCall(ITrampoline.execute, (prop.data, prop.route, prop.signature))
    });

    vm.prank(rival, rival);
    vm.expectRevert(ITrampoline.Trampoline_UnauthorizedSubmitter.selector);
    SETTLEMENT.settle(new address[](0), new uint256[](0), new GPv2TradeData[](0), interactions);
  }

  function test_fork_settle_eth_buy_order_through_trampoline() public onlyFork {
    uint256 sellAmount = 5000e6; // USDC

    deal(address(USDC), user, sellAmount);
    address vaultRelayer = SETTLEMENT.vaultRelayer();
    vm.prank(user);
    USDC.approve(vaultRelayer, sellAmount);

    uint256 quotedOut = _quote(address(USDC), address(WETH), sellAmount);
    uint256 clearingOut = quotedOut * 99 / 100;
    // Route sends WETH to Settlement; the delta check tracks WETH growth. A
    // post-execute interaction unwraps the WETH so Settlement can pay in ETH.
    ITrampoline.Interaction[] memory route = _swapRoute(address(USDC), address(WETH), sellAmount, quotedOut);
    SignedProposal memory prop = _signProposal(address(USDC), address(WETH), sellAmount, clearingOut, route);

    uint256 userEthBefore = user.balance;
    uint256 settlementEthBefore = address(SETTLEMENT).balance;

    // Build settlement inline: needs a post-execute unwrap that _settleOrder doesn't support.
    address[] memory tokens = new address[](2);
    tokens[0] = address(USDC);
    tokens[1] = BUY_ETH;
    uint256[] memory prices = new uint256[](2);
    prices[0] = clearingOut;
    prices[1] = sellAmount;
    GPv2TradeData[] memory trades = new GPv2TradeData[](1);
    trades[0] = GPv2TradeData({
      sellTokenIndex: 0,
      buyTokenIndex: 1,
      receiver: user,
      sellAmount: sellAmount,
      buyAmount: clearingOut * 99 / 100,
      validTo: uint32(block.timestamp + 1 hours),
      appData: bytes32(0),
      feeAmount: 0,
      flags: 0,
      executedAmount: sellAmount,
      signature: _signOrder(
        address(USDC), BUY_ETH, sellAmount, clearingOut * 99 / 100, uint32(block.timestamp + 1 hours)
      )
    });

    ITrampoline.Interaction[][3] memory interactions;
    interactions[1] = new ITrampoline.Interaction[](3);
    interactions[1][0] = ITrampoline.Interaction({
      target: address(USDC), value: 0, callData: abi.encodeCall(IERC20.transfer, (address(trampoline), sellAmount))
    });
    interactions[1][1] = ITrampoline.Interaction({
      target: address(trampoline),
      value: 0,
      callData: abi.encodeCall(ITrampoline.execute, (prop.data, prop.route, prop.signature))
    });
    interactions[1][2] =
      ITrampoline.Interaction({target: address(WETH), value: 0, callData: abi.encodeCall(IWETH.withdraw, (quotedOut))});

    vm.prank(solver, solver);
    SETTLEMENT.settle(tokens, prices, trades, interactions);

    // The ETH surplus stays in the settlement; the instance ends empty.
    assertEq(user.balance - userEthBefore, clearingOut);
    assertEq(address(SETTLEMENT).balance, settlementEthBefore + (quotedOut - clearingOut));
    assertEq(address(trampoline).balance, 0);
    assertEq(USDC.balanceOf(address(trampoline)), 0);
  }
}
