// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test, console} from 'forge-std/Test.sol';

import {IGPv2Authentication} from 'interfaces/IGPv2Authentication.sol';
import {GPv2TradeData, IGPv2Settlement} from 'interfaces/IGPv2Settlement.sol';
import {BUY_ETH_ADDRESS, ITrampoline} from 'interfaces/ITrampoline.sol';

import {Escrow} from 'contracts/Escrow.sol';
import {Trampoline} from 'contracts/Trampoline.sol';
import {TrampolineFactory} from 'contracts/TrampolineFactory.sol';

import {IUniswapV2Router} from '../interfaces/IUniswapV2Router.sol';
import {IWETH} from '../interfaces/IWETH.sol';
import {ProposalSigning} from '../utils/ProposalSigning.sol';

/// @notice Gas benchmark comparing two settlement paths against the same
/// Uniswap V2 swap on a mainnet fork:
///   A. Direct — Settlement executes the swap itself (no trampoline)
///   C. Trampoline (output → Settlement) — route sends output directly to
///      Settlement; unconsumed input stays on instance as reclaimable residue
contract GasBenchmark is Test {
  IGPv2Settlement constant SETTLEMENT = IGPv2Settlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);
  IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
  IUniswapV2Router constant UNIV2_ROUTER = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

  bytes32 constant ORDER_TYPE_HASH = keccak256(
    'Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)'
  );
  bytes32 constant KIND_SELL = keccak256('sell');
  bytes32 constant KIND_BUY = keccak256('buy');
  bytes32 constant BALANCE_ERC20 = keccak256('erc20');

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

    IGPv2Authentication auth = IGPv2Authentication(SETTLEMENT.authenticator());
    vm.prank(auth.manager());
    auth.addSolver(solver);

    address[] memory submitters = new address[](1);
    submitters[0] = solver;
    Escrow escrow = new Escrow(
      2 days, makeAddr('admin'), makeAddr('operator'), submitters, 1 days, address(SETTLEMENT), 'BYOS Escrow', 'BYOS'
    );
    factory = TrampolineFactory(address(escrow.TRAMPOLINE_FACTORY()));
    escrow.deposit{value: 1 ether}(subSolver);
    trampoline = Trampoline(payable(factory.addressOf(subSolver)));

    // Pre-warm the trampoline's approval slots for a fair comparison:
    // the mainnet Settlement already has max approvals for the Uniswap V2
    // router from previous settlements, so without this the trampoline
    // pays a one-time cold zero→nonzero SSTORE that inflates the overhead.
    vm.startPrank(address(trampoline));
    WETH.approve(address(UNIV2_ROUTER), type(uint256).max);
    USDC.approve(address(UNIV2_ROUTER), type(uint256).max);
    vm.stopPrank();
  }

  // ───── Shared helpers ─────

  function _quote(
    address _sellToken,
    address _buyToken,
    uint256 _sellAmount
  ) internal view returns (uint256) {
    address[] memory path = new address[](2);
    path[0] = _sellToken;
    path[1] = _buyToken;
    return UNIV2_ROUTER.getAmountsOut(_sellAmount, path)[1];
  }

  function _quoteIn(
    address _sellToken,
    address _buyToken,
    uint256 _buyAmount
  ) internal view returns (uint256) {
    address[] memory path = new address[](2);
    path[0] = _sellToken;
    path[1] = _buyToken;
    return UNIV2_ROUTER.getAmountsIn(_buyAmount, path)[0];
  }

  function _signOrder(
    address _sellToken,
    address _buyToken,
    uint256 _sellAmount,
    uint256 _buyAmount,
    uint32 _validTo
  ) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(
      abi.encode(
        ORDER_TYPE_HASH,
        _sellToken,
        _buyToken,
        user,
        _sellAmount,
        _buyAmount,
        _validTo,
        bytes32(0),
        uint256(0),
        KIND_SELL,
        false,
        BALANCE_ERC20,
        BALANCE_ERC20
      )
    );
    bytes32 digest = keccak256(abi.encodePacked('\x19\x01', SETTLEMENT.domainSeparator(), structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, digest);
    return abi.encodePacked(r, s, v);
  }

  function _fundUserWeth(
    uint256 _sellAmount
  ) internal {
    vm.deal(user, _sellAmount + 1 ether);
    vm.startPrank(user);
    WETH.deposit{value: _sellAmount}();
    WETH.approve(SETTLEMENT.vaultRelayer(), _sellAmount);
    vm.stopPrank();
  }

  function _fundUserUsdc(
    uint256 _sellAmount
  ) internal {
    deal(address(USDC), user, _sellAmount);
    vm.startPrank(user);
    USDC.approve(SETTLEMENT.vaultRelayer(), _sellAmount);
    vm.stopPrank();
  }

  function _buildTrade(
    address _sellToken,
    address _buyToken,
    uint256 _sellAmount,
    uint256 _buyAmount
  ) internal view returns (address[] memory tokens_, uint256[] memory prices_, GPv2TradeData[] memory trades_) {
    tokens_ = new address[](2);
    tokens_[0] = _sellToken;
    tokens_[1] = _buyToken;

    prices_ = new uint256[](2);
    prices_[0] = _buyAmount;
    prices_[1] = _sellAmount;

    uint32 validTo = uint32(block.timestamp + 1 hours);
    trades_ = new GPv2TradeData[](1);
    trades_[0] = GPv2TradeData({
      sellTokenIndex: 0,
      buyTokenIndex: 1,
      receiver: user,
      sellAmount: _sellAmount,
      buyAmount: _buyAmount * 99 / 100,
      validTo: validTo,
      appData: bytes32(0),
      feeAmount: 0,
      flags: 0,
      executedAmount: _sellAmount,
      signature: _signOrder(_sellToken, _buyToken, _sellAmount, _buyAmount * 99 / 100, validTo)
    });
  }

  function _signProposal(
    uint256 _sellAmount,
    uint256 _buyAmount,
    ITrampoline.Interaction[] memory _route,
    bytes32 _orderUidHash
  ) internal view returns (ITrampoline.Proposal memory proposal_, bytes memory sig_) {
    proposal_ = ITrampoline.Proposal({
      orderUidHash: _orderUidHash,
      sellAmount: _sellAmount,
      minBuyAmount: _buyAmount,
      quotedBuyAmount: _buyAmount,
      validUntil: block.timestamp + 1 hours,
      nonce: 0
    });
    bytes32 digest = ProposalSigning.digest(factory.domainSeparator(), proposal_, _route);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(subSolverKey, digest);
    sig_ = abi.encodePacked(r, s, v);
  }

  /// @dev Builds a 2-interaction swap route (approve + swap) via Uniswap V2.
  function _swapRoute(
    address _sellToken,
    address _buyToken,
    uint256 _sellAmount,
    uint256 _minOut,
    address _recipient
  ) internal view returns (ITrampoline.Interaction[] memory route_) {
    address[] memory path = new address[](2);
    path[0] = _sellToken;
    path[1] = _buyToken;

    route_ = new ITrampoline.Interaction[](2);
    route_[0] = ITrampoline.Interaction({
      target: _sellToken, value: 0, callData: abi.encodeCall(IERC20.approve, (address(UNIV2_ROUTER), _sellAmount))
    });
    route_[1] = ITrampoline.Interaction({
      target: address(UNIV2_ROUTER),
      value: 0,
      callData: abi.encodeCall(
        IUniswapV2Router.swapExactTokensForTokens, (_sellAmount, _minOut, path, _recipient, block.timestamp + 1 hours)
      )
    });
  }

  /// @dev Builds a 3-interaction swap route (approve + swap + WETH unwrap).
  function _swapRouteWithUnwrap(
    address _sellToken,
    uint256 _sellAmount,
    uint256 _minOut,
    address _recipient
  ) internal view returns (ITrampoline.Interaction[] memory route_) {
    address[] memory path = new address[](2);
    path[0] = _sellToken;
    path[1] = address(WETH);

    route_ = new ITrampoline.Interaction[](3);
    route_[0] = ITrampoline.Interaction({
      target: _sellToken, value: 0, callData: abi.encodeCall(IERC20.approve, (address(UNIV2_ROUTER), _sellAmount))
    });
    route_[1] = ITrampoline.Interaction({
      target: address(UNIV2_ROUTER),
      value: 0,
      callData: abi.encodeCall(
        IUniswapV2Router.swapExactTokensForTokens, (_sellAmount, _minOut, path, _recipient, block.timestamp + 1 hours)
      )
    });
    route_[2] =
      ITrampoline.Interaction({target: address(WETH), value: 0, callData: abi.encodeCall(IWETH.withdraw, (_minOut))});
  }

  // ───── Path A: Direct settlement ─────

  function _settleDirectly(
    address _sellToken,
    address _buyToken,
    uint256 _sellAmount,
    uint256 _quotedOut
  ) internal {
    (address[] memory tokens, uint256[] memory prices, GPv2TradeData[] memory trades) =
      _buildTrade(_sellToken, _buyToken, _sellAmount, _quotedOut);

    ITrampoline.Interaction[] memory route =
      _swapRoute(_sellToken, _buyToken, _sellAmount, _quotedOut, address(SETTLEMENT));

    ITrampoline.Interaction[][3] memory interactions;
    interactions[1] = route;

    vm.prank(solver, solver);
    SETTLEMENT.settle(tokens, prices, trades, interactions);
  }

  function _settleDirectlyEth(
    uint256 _sellAmount,
    uint256 _quotedWeth
  ) internal {
    (address[] memory tokens, uint256[] memory prices, GPv2TradeData[] memory trades) =
      _buildTrade(address(USDC), BUY_ETH_ADDRESS, _sellAmount, _quotedWeth);

    ITrampoline.Interaction[] memory route =
      _swapRouteWithUnwrap(address(USDC), _sellAmount, _quotedWeth, address(SETTLEMENT));

    ITrampoline.Interaction[][3] memory interactions;
    interactions[1] = route;

    vm.prank(solver, solver);
    SETTLEMENT.settle(tokens, prices, trades, interactions);
  }

  // ───── Path C: Trampoline, route output → Settlement ─────

  function _settleViaTrampolineToSettlement(
    address _sellToken,
    address _buyToken,
    uint256 _sellAmount,
    uint256 _quotedOut
  ) internal {
    (address[] memory tokens, uint256[] memory prices, GPv2TradeData[] memory trades) =
      _buildTrade(_sellToken, _buyToken, _sellAmount, _quotedOut);

    ITrampoline.Interaction[] memory route =
      _swapRoute(_sellToken, _buyToken, _sellAmount, _quotedOut, address(SETTLEMENT));

    (ITrampoline.Proposal memory proposal, bytes memory sig) =
      _signProposal(_sellAmount, _quotedOut, route, keccak256('bench-settle'));

    ITrampoline.Interaction[][3] memory interactions;
    interactions[1] = new ITrampoline.Interaction[](2);
    interactions[1][0] = ITrampoline.Interaction({
      target: _sellToken, value: 0, callData: abi.encodeCall(IERC20.transfer, (address(trampoline), _sellAmount))
    });
    interactions[1][1] = ITrampoline.Interaction({
      target: address(trampoline),
      value: 0,
      callData: abi.encodeCall(ITrampoline.execute, (proposal, route, _sellToken, _buyToken, sig))
    });

    vm.prank(solver, solver);
    SETTLEMENT.settle(tokens, prices, trades, interactions);
  }

  function _settleViaTrampolineToSettlementEth(
    uint256 _sellAmount,
    uint256 _quotedWeth
  ) internal {
    (address[] memory tokens, uint256[] memory prices, GPv2TradeData[] memory trades) =
      _buildTrade(address(USDC), BUY_ETH_ADDRESS, _sellAmount, _quotedWeth);

    // Route sends WETH to Settlement (no unwrap inside the route).
    ITrampoline.Interaction[] memory route =
      _swapRoute(address(USDC), address(WETH), _sellAmount, _quotedWeth, address(SETTLEMENT));

    // Delta check tracks WETH growth on Settlement.
    (ITrampoline.Proposal memory proposal, bytes memory sig) =
      _signProposal(_sellAmount, _quotedWeth, route, keccak256('bench-settle-eth'));

    // Settlement unwraps the WETH after execute returns.
    ITrampoline.Interaction[][3] memory interactions;
    interactions[1] = new ITrampoline.Interaction[](3);
    interactions[1][0] = ITrampoline.Interaction({
      target: address(USDC), value: 0, callData: abi.encodeCall(IERC20.transfer, (address(trampoline), _sellAmount))
    });
    interactions[1][1] = ITrampoline.Interaction({
      target: address(trampoline),
      value: 0,
      callData: abi.encodeCall(ITrampoline.execute, (proposal, route, address(USDC), address(WETH), sig))
    });
    interactions[1][2] = ITrampoline.Interaction({
      target: address(WETH), value: 0, callData: abi.encodeCall(IWETH.withdraw, (_quotedWeth))
    });

    vm.prank(solver, solver);
    SETTLEMENT.settle(tokens, prices, trades, interactions);
  }

  // ───── Buy order helpers ─────

  function _signBuyOrder(
    address _sellToken,
    address _buyToken,
    uint256 _sellAmount,
    uint256 _buyAmount,
    uint32 _validTo
  ) internal view returns (bytes memory) {
    bytes32 structHash = keccak256(
      abi.encode(
        ORDER_TYPE_HASH,
        _sellToken,
        _buyToken,
        user,
        _sellAmount,
        _buyAmount,
        _validTo,
        bytes32(0),
        uint256(0),
        KIND_BUY,
        false,
        BALANCE_ERC20,
        BALANCE_ERC20
      )
    );
    bytes32 digest = keccak256(abi.encodePacked('\x19\x01', SETTLEMENT.domainSeparator(), structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, digest);
    return abi.encodePacked(r, s, v);
  }

  function _buildBuyTrade(
    address _sellToken,
    address _buyToken,
    uint256 _maxSellAmount,
    uint256 _exactBuyAmount,
    uint256 _actualSellAmount
  ) internal view returns (address[] memory tokens_, uint256[] memory prices_, GPv2TradeData[] memory trades_) {
    tokens_ = new address[](2);
    tokens_[0] = _sellToken;
    tokens_[1] = _buyToken;

    prices_ = new uint256[](2);
    prices_[0] = _exactBuyAmount;
    prices_[1] = _actualSellAmount;

    uint32 validTo = uint32(block.timestamp + 1 hours);
    trades_ = new GPv2TradeData[](1);
    trades_[0] = GPv2TradeData({
      sellTokenIndex: 0,
      buyTokenIndex: 1,
      receiver: user,
      sellAmount: _maxSellAmount,
      buyAmount: _exactBuyAmount,
      validTo: validTo,
      appData: bytes32(0),
      feeAmount: 0,
      flags: 1, // buy order
      executedAmount: _exactBuyAmount,
      signature: _signBuyOrder(_sellToken, _buyToken, _maxSellAmount, _exactBuyAmount, validTo)
    });
  }

  /// @dev Builds a 2-interaction route for exact-output swap via Uniswap V2.
  function _swapRouteExactOutput(
    address _sellToken,
    address _buyToken,
    uint256 _amountInMax,
    uint256 _exactOut,
    address _recipient
  ) internal view returns (ITrampoline.Interaction[] memory route_) {
    address[] memory path = new address[](2);
    path[0] = _sellToken;
    path[1] = _buyToken;

    route_ = new ITrampoline.Interaction[](2);
    route_[0] = ITrampoline.Interaction({
      target: _sellToken, value: 0, callData: abi.encodeCall(IERC20.approve, (address(UNIV2_ROUTER), _amountInMax))
    });
    route_[1] = ITrampoline.Interaction({
      target: address(UNIV2_ROUTER),
      value: 0,
      callData: abi.encodeCall(
        IUniswapV2Router.swapTokensForExactTokens,
        (_exactOut, _amountInMax, path, _recipient, block.timestamp + 1 hours)
      )
    });
  }

  function _settleDirectlyBuyOrder(
    address _sellToken,
    address _buyToken,
    uint256 _maxSellAmount,
    uint256 _exactBuyAmount,
    uint256 _quotedIn
  ) internal {
    (address[] memory tokens, uint256[] memory prices, GPv2TradeData[] memory trades) =
      _buildBuyTrade(_sellToken, _buyToken, _maxSellAmount, _exactBuyAmount, _quotedIn);

    ITrampoline.Interaction[] memory route =
      _swapRouteExactOutput(_sellToken, _buyToken, _maxSellAmount, _exactBuyAmount, address(SETTLEMENT));

    ITrampoline.Interaction[][3] memory interactions;
    interactions[1] = route;

    vm.prank(solver, solver);
    SETTLEMENT.settle(tokens, prices, trades, interactions);
  }

  function _settleViaTrampolineBuyOrder(
    address _sellToken,
    address _buyToken,
    uint256 _maxSellAmount,
    uint256 _exactBuyAmount,
    uint256 _quotedIn
  ) internal {
    (address[] memory tokens, uint256[] memory prices, GPv2TradeData[] memory trades) =
      _buildBuyTrade(_sellToken, _buyToken, _maxSellAmount, _exactBuyAmount, _quotedIn);

    ITrampoline.Interaction[] memory route =
      _swapRouteExactOutput(_sellToken, _buyToken, _maxSellAmount, _exactBuyAmount, address(SETTLEMENT));

    (ITrampoline.Proposal memory proposal, bytes memory sig) =
      _signProposal(_maxSellAmount, _exactBuyAmount, route, keccak256('bench-buy'));

    ITrampoline.Interaction[][3] memory interactions;
    interactions[1] = new ITrampoline.Interaction[](2);
    interactions[1][0] = ITrampoline.Interaction({
      target: _sellToken, value: 0, callData: abi.encodeCall(IERC20.transfer, (address(trampoline), _maxSellAmount))
    });
    interactions[1][1] = ITrampoline.Interaction({
      target: address(trampoline),
      value: 0,
      callData: abi.encodeCall(ITrampoline.execute, (proposal, route, _sellToken, _buyToken, sig))
    });

    vm.prank(solver, solver);
    SETTLEMENT.settle(tokens, prices, trades, interactions);
  }

  // ───── Benchmarks ─────

  function test_gas_benchmark_weth_to_usdc() public onlyFork {
    uint256 sellAmount = 1 ether;
    uint256 quotedOut = _quote(address(WETH), address(USDC), sellAmount);

    _fundUserWeth(sellAmount);
    uint256 snap = vm.snapshotState();

    // A: Direct
    vm.startSnapshotGas('A');
    _settleDirectly(address(WETH), address(USDC), sellAmount, quotedOut);
    uint256 gasA = vm.stopSnapshotGas('A');
    assertTrue(vm.revertToState(snap));

    // C: Trampoline, output → Settlement
    vm.startSnapshotGas('C');
    _settleViaTrampolineToSettlement(address(WETH), address(USDC), sellAmount, quotedOut);
    uint256 gasC = vm.stopSnapshotGas('C');

    console.log('');
    console.log('=== Gas Benchmark: WETH -> USDC (Uniswap V2, 1 ETH) ===');
    console.log('A  Direct (no trampoline):             %d gas', gasA);
    console.log(
      'C  Trampoline (output -> settlement):   %d gas  (+%d / +%d%%)', gasC, gasC - gasA, ((gasC - gasA) * 100) / gasA
    );
    console.log('');
  }

  function test_gas_benchmark_usdc_to_eth() public onlyFork {
    uint256 sellAmount = 5000e6;
    uint256 quotedWeth = _quote(address(USDC), address(WETH), sellAmount);

    _fundUserUsdc(sellAmount);
    uint256 snap = vm.snapshotState();

    // A: Direct
    vm.startSnapshotGas('A-eth');
    _settleDirectlyEth(sellAmount, quotedWeth);
    uint256 gasA = vm.stopSnapshotGas('A-eth');
    assertTrue(vm.revertToState(snap));

    // C: Trampoline, output → Settlement
    vm.startSnapshotGas('C-eth');
    _settleViaTrampolineToSettlementEth(sellAmount, quotedWeth);
    uint256 gasC = vm.stopSnapshotGas('C-eth');

    console.log('');
    console.log('=== Gas Benchmark: USDC -> ETH (Uniswap V2, 5000 USDC) ===');
    console.log('A  Direct (no trampoline):             %d gas', gasA);
    console.log(
      'C  Trampoline (output -> settlement):   %d gas  (+%d / +%d%%)', gasC, gasC - gasA, ((gasC - gasA) * 100) / gasA
    );
    console.log('');
  }

  function test_gas_benchmark_buy_order_usdc_to_weth() public onlyFork {
    // Buy order: user wants exactly 1 WETH, pays at most quotedIn + 1% of USDC.
    // The route uses swapTokensForExactTokens; the router pulls only quotedIn,
    // leaving 1% of USDC as residue on the instance (reclaimable by the sub-solver).
    uint256 desiredWeth = 1 ether;
    uint256 quotedIn = _quoteIn(address(USDC), address(WETH), desiredWeth);
    uint256 maxSellAmount = quotedIn * 101 / 100;

    _fundUserUsdc(maxSellAmount);
    uint256 snap = vm.snapshotState();

    // A: Direct buy order
    vm.startSnapshotGas('A-buy');
    _settleDirectlyBuyOrder(address(USDC), address(WETH), maxSellAmount, desiredWeth, quotedIn);
    uint256 gasA = vm.stopSnapshotGas('A-buy');
    assertTrue(vm.revertToState(snap));

    // C: Trampoline buy order (residue stays on instance)
    vm.startSnapshotGas('C-buy');
    _settleViaTrampolineBuyOrder(address(USDC), address(WETH), maxSellAmount, desiredWeth, quotedIn);
    uint256 gasC = vm.stopSnapshotGas('C-buy');

    console.log('');
    console.log('=== Gas Benchmark: Buy order USDC -> WETH (Uniswap V2, 1 ETH) ===');
    console.log('A  Direct (no trampoline):             %d gas', gasA);
    console.log(
      'C  Trampoline (residue on instance):    %d gas  (+%d / +%d%%)', gasC, gasC - gasA, ((gasC - gasA) * 100) / gasA
    );
    console.log('   Sell-token residue on instance:      %d USDC', maxSellAmount - quotedIn);
    console.log('');
  }
}
