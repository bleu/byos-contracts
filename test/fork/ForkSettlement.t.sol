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

    // Allow-list the BYOS solver as the authenticator's manager would.
    IGPv2Authentication auth = IGPv2Authentication(SETTLEMENT.authenticator());
    vm.prank(auth.manager());
    auth.addSolver(solver);

    // Deploy factory + escrow; the sub-solver's first deposit deploys its Trampoline.
    factory = new TrampolineFactory(address(SETTLEMENT));
    Escrow escrow = new Escrow(2 days, makeAddr('admin'), makeAddr('operator'), 1 days, factory);
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

  /// @dev Route: approve router, swap sellToken -> buyToken; optionally unwrap the
  /// WETH output to native ETH (wrap/unwrap is route responsibility, ADR-0001).
  function _swapRoute(
    address sellToken,
    address buyToken,
    uint256 sellAmount,
    uint256 buyAmountOut,
    bool unwrap
  ) internal view returns (ITrampoline.Interaction[] memory route) {
    address[] memory path = new address[](2);
    path[0] = sellToken;
    path[1] = buyToken;
    route = new ITrampoline.Interaction[](unwrap ? 3 : 2);
    route[0] = ITrampoline.Interaction({
      target: sellToken, value: 0, callData: abi.encodeCall(IERC20.approve, (address(UNIV2_ROUTER), sellAmount))
    });
    route[1] = ITrampoline.Interaction({
      target: address(UNIV2_ROUTER),
      value: 0,
      callData: abi.encodeCall(
        IUniswapV2Router.swapExactTokensForTokens,
        (sellAmount, buyAmountOut, path, address(trampoline), block.timestamp + 1 hours)
      )
    });
    if (unwrap) {
      route[2] = ITrampoline.Interaction({
        target: address(WETH), value: 0, callData: abi.encodeCall(IWETH.withdraw, (buyAmountOut))
      });
    }
  }

  function _signProposal(
    uint256 sellAmount,
    uint256 buyAmount,
    ITrampoline.Interaction[] memory route
  ) internal view returns (SignedProposal memory signed) {
    signed.data = ITrampoline.Proposal({
      orderUidHash: keccak256('fork-order-uid'),
      sellAmount: sellAmount,
      buyAmount: buyAmount,
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
  /// The user's limit is set 1% under the quote so the clearing price satisfies it.
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
      callData: abi.encodeCall(ITrampoline.execute, (prop.data, prop.route, buyToken, prop.signature))
    });

    vm.prank(solver);
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

    // Quote the route output; V2 math is deterministic within the block, so the
    // trampoline receives exactly this and settles it all back (zero surplus).
    uint256 quotedOut = _quote(address(WETH), address(USDC), sellAmount);
    SignedProposal memory prop =
      _signProposal(sellAmount, quotedOut, _swapRoute(address(WETH), address(USDC), sellAmount, quotedOut, false));

    uint256 settlementWethBefore = WETH.balanceOf(address(SETTLEMENT));
    uint256 settlementUsdcBefore = USDC.balanceOf(address(SETTLEMENT));

    _settleOrder(address(WETH), address(USDC), sellAmount, quotedOut, prop);

    // User was paid exactly at clearing price; BYOS buffers are untouched.
    assertEq(USDC.balanceOf(user), quotedOut);
    assertEq(WETH.balanceOf(address(SETTLEMENT)), settlementWethBefore);
    assertEq(USDC.balanceOf(address(SETTLEMENT)), settlementUsdcBefore);
    assertEq(WETH.balanceOf(address(trampoline)), 0);
    assertEq(USDC.balanceOf(address(trampoline)), 0);
  }

  function test_fork_settle_eth_buy_order_through_trampoline() public onlyFork {
    uint256 sellAmount = 5000e6; // USDC

    deal(address(USDC), user, sellAmount);
    address vaultRelayer = SETTLEMENT.vaultRelayer();
    vm.prank(user);
    USDC.approve(vaultRelayer, sellAmount);

    uint256 quotedOut = _quote(address(USDC), address(WETH), sellAmount);
    // Swap USDC -> WETH, then unwrap: the trampoline delivers native ETH.
    SignedProposal memory prop =
      _signProposal(sellAmount, quotedOut, _swapRoute(address(USDC), address(WETH), sellAmount, quotedOut, true));

    uint256 userEthBefore = user.balance;
    uint256 settlementEthBefore = address(SETTLEMENT).balance;

    _settleOrder(address(USDC), BUY_ETH, sellAmount, quotedOut, prop);

    assertEq(user.balance - userEthBefore, quotedOut);
    assertEq(address(SETTLEMENT).balance, settlementEthBefore);
    assertEq(address(trampoline).balance, 0);
    assertEq(USDC.balanceOf(address(trampoline)), 0);
  }
}
