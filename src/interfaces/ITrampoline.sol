// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

/**
 * @dev Marker address GPv2 uses for orders buying native ETH (GPv2Order.BUY_ETH_ADDRESS).
 * The balance-delta check and claim functions handle native ETH instead of ERC-20.
 */
address constant BUY_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

/**
 * @dev EIP-712 type hash of the signed proposal struct. The type name "ProposalData"
 * and its seven fields are fixed by ADR-0005 and baked into every sub-solver signature —
 * renaming the Solidity struct (`Proposal`, which omits the derived interactionsHash
 * field) is safe, but changing this string invalidates all outstanding signatures.
 */
bytes32 constant PROPOSAL_TYPEHASH = keccak256(
  'ProposalData(bytes32 orderUidHash,uint256 sellAmount,uint256 minBuyAmount,uint256 quoteBuyAmount,bytes32 interactionsHash,uint256 validUntil,uint256 nonce)'
);

/**
 * @title BYOS Trampoline
 * @author CoW Protocol Developers
 * @notice Per-sub-solver execution sandbox. Receives the trade's sell tokens from
 * GPv2Settlement, runs the sub-solver's EIP-712-signed route, and enforces the
 * signed buy amount as a floor on the settlement's buy-token balance growth. Routes
 * are expected to deliver buy-token output directly to the settlement. Tokens
 * remaining on the instance after execution (unconsumed sell tokens, intermediate
 * dust) are reclaimable by the sub-solver via `claimToken`/`claimTokens`. One
 * immutable instance per sub-solver at a deterministic CREATE2 address (ADR-0001).
 */
interface ITrampoline {
  /*///////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice A signed route executed and the settlement's buy-token balance growth
   * covered the floor (ADR-0003)
   * @param _orderUidHash Hash of the CoW order UID the proposal settles
   * @param _delta The measured growth of the settlement's buy-token balance
   * @param _floor The signed minBuyAmount the delta was checked against
   * @param _ceiling The signed quoteBuyAmount used as the clearing-price commitment
   */
  event Executed(bytes32 indexed _orderUidHash, uint256 _delta, uint256 _floor, uint256 _ceiling);

  /**
   * @notice The sub-solver has claimed residue from its instance (ADR-0008)
   * @param _token The claimed token (BUY_ETH_ADDRESS for native ETH)
   * @param _amount The full balance transferred out
   * @param _recipient The address that received the claimed balance
   */
  event ResidueClaimed(address indexed _token, uint256 _amount, address indexed _recipient);

  /*///////////////////////////////////////////////////////////////
                              STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice One call of the sub-solver's route, mirroring GPv2Interaction.Data
   * @param target The address the call is made to
   * @param value The native token value sent with the call
   * @param callData The calldata of the call
   */
  struct Interaction {
    address target;
    uint256 value;
    bytes callData;
  }

  /**
   * @notice The signed proposal fields (ADR-0005), minus interactionsHash which is
   * recomputed on-chain from the interactions actually being executed
   * @param orderUidHash Hash of the CoW order UID the proposal settles
   * @param sellAmount The sell amount pushed into the instance for the route
   * @param minBuyAmount The floor: the minimum growth of the settlement's buy-token
   * balance execute enforces. The delta check reverts when actual growth is below this.
   * @param quoteBuyAmount The ceiling: the clearing-price commitment. When minBuyAmount
   * equals quoteBuyAmount the sub-solver bears no slippage risk. When minBuyAmount is
   * lower, the gap between quoteBuyAmount and the actual delivery is charged against
   * the sub-solver's escrow (and over-delivery above quoteBuyAmount is credited back).
   * @param validUntil Timestamp after which the proposal is no longer executable
   * @param nonce Sub-solver-chosen value distinguishing otherwise identical proposals
   */
  struct Proposal {
    bytes32 orderUidHash;
    uint256 sellAmount;
    uint256 minBuyAmount;
    uint256 quoteBuyAmount;
    uint256 validUntil;
    uint256 nonce;
  }

  /*///////////////////////////////////////////////////////////////
                              ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Throws if execute was called by someone else than the settlement contract
   */
  error Trampoline_OnlySettlement();

  /**
   * @notice Throws if the settlement was not submitted by an authorized BYOS submitter
   * (tx.origin lacks the Escrow's SUBMITTER_ROLE)
   */
  error Trampoline_UnauthorizedSubmitter();

  /**
   * @notice Throws if the proposal's validUntil timestamp has passed
   */
  error Trampoline_ProposalExpired();

  /**
   * @notice Throws if the proposal's nonce has already been used
   */
  error Trampoline_NonceAlreadyUsed();

  /**
   * @notice Throws if the proposal signature does not recover to the sub-solver
   */
  error Trampoline_InvalidSignature();

  /**
   * @notice Throws if the settlement's buy-token balance grew by less than the
   * signed floor
   * @param _delta The measured growth of the settlement's buy-token balance
   * @param _floor The signed minBuyAmount required
   */
  error Trampoline_FloorNotMet(uint256 _delta, uint256 _floor);

  /**
   * @notice Throws if claim was called by someone else than the sub-solver
   */
  error Trampoline_OnlySubSolver();

  /**
   * @notice Throws if the native ETH claim transfer fails
   */
  error Trampoline_EthClaimFailed();

  /*///////////////////////////////////////////////////////////////
                             VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the sub-solver whose signed proposals this instance executes
   * @return _subSolver The sub-solver address
   */
  // solhint-disable-next-line func-name-mixedcase
  function SUB_SOLVER() external view returns (address _subSolver);

  /**
   * @notice Returns the GPv2Settlement contract — the only address allowed to call execute
   * @return _settlement The settlement contract address
   */
  // solhint-disable-next-line func-name-mixedcase
  function SETTLEMENT() external view returns (address _settlement);

  /**
   * @notice Returns the EIP-712 domain separator of the deploying factory (ADR-0005)
   * @return _domainSeparator The domain separator proposal signatures are verified against
   */
  // solhint-disable-next-line func-name-mixedcase
  function DOMAIN_SEPARATOR() external view returns (bytes32 _domainSeparator);

  /**
   * @notice Returns the Escrow acting as submitter registry: execute requires tx.origin
   * to hold its SUBMITTER_ROLE
   * @return _escrow The Escrow address
   */
  // solhint-disable-next-line func-name-mixedcase
  function ESCROW() external view returns (address _escrow);

  /**
   * @notice Returns whether a nonce has already been consumed by a prior execution
   * @param _nonce The nonce value to check
   * @return _used True if the nonce has been consumed
   */
  function noncesUsed(
    uint256 _nonce
  ) external view returns (bool _used);

  /*///////////////////////////////////////////////////////////////
                               LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Executes a sub-solver's signed route and reverts unless the settlement's
   * buy-token balance grew by at least `_proposal.minBuyAmount`
   * @dev Callable only by the settlement contract, and only in a settlement submitted
   * by a BYOS submitter: tx.origin must hold the Escrow's SUBMITTER_ROLE, since a live
   * proposal's calldata is public and any allow-listed solver could otherwise replay it
   * (ADR-0005). The balance-delta check is the funding guard (ADR-0003): minBuyAmount
   * is the floor the sub-solver signed, measured as the growth of the settlement's
   * buy-token balance between entry and return. quoteBuyAmount is the clearing-price
   * commitment; the gap between quoteBuyAmount and the actual delivery is settled
   * off-chain against the sub-solver's escrow. Routes are expected to deliver
   * buy-token output directly to the settlement. Tokens remaining on the instance
   * after execution (unconsumed sell tokens, intermediate dust) are reclaimable by
   * the sub-solver via `claimToken`/`claimTokens`. The tokens are BYOS-supplied call
   * parameters taken from the order, not signed proposal fields. When `_buyToken` is
   * BUY_ETH_ADDRESS the snapshot and delta are in native ETH.
   * @param _proposal The signed proposal fields
   * @param _interactions The route, hashed into the verified signature
   * @param _sellToken The trade's sell token (unused in execute, retained for interface compatibility)
   * @param _buyToken The trade's buy token; BUY_ETH_ADDRESS for native ETH
   * @param _signature Sub-solver's EIP-712 signature over the proposal
   */
  function execute(
    Proposal calldata _proposal,
    Interaction[] calldata _interactions,
    address _sellToken,
    address _buyToken,
    bytes calldata _signature
  ) external;

  /**
   * @notice Transfers the instance's full balance of `_token` to `_recipient`
   * @dev Residue is the sub-solver's property (ADR-0008). The instance is storage-free
   * and cannot enumerate what it holds; the caller identifies tokens off-chain. Use
   * BUY_ETH_ADDRESS to claim native ETH. Unclaimed residue is exposed to route-planted
   * approvals and to replay by BYOS submitters while any signed proposal for this
   * instance is unexpired — claim promptly.
   * @param _token The token to claim; BUY_ETH_ADDRESS for native ETH
   * @param _recipient The address receiving the claimed balance
   */
  function claimToken(
    address _token,
    address _recipient
  ) external;

  /**
   * @notice Transfers the instance's full balance of each listed token to `_recipient`
   * @dev Batch form of claimToken; same semantics per token
   * @param _tokens The tokens to claim; full balance each, BUY_ETH_ADDRESS for native ETH
   * @param _recipient The address receiving the claimed balances
   */
  function claimTokens(
    address[] calldata _tokens,
    address _recipient
  ) external;
}
