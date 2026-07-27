// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

/**
 * @dev Marker address GPv2 uses for orders buying native ETH (GPv2Order.BUY_ETH_ADDRESS).
 * The sweep and the balance-delta check run in native ETH instead of ERC-20.
 */
address constant BUY_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

/**
 * @dev EIP-712 type hash of the signed proposal struct. The type name "ProposalData"
 * and its six fields are fixed by ADR-0005 and baked into every sub-solver signature —
 * renaming the Solidity struct (`Proposal`, which omits the derived interactionsHash
 * field) is safe, but changing this string invalidates all outstanding signatures.
 */
bytes32 constant PROPOSAL_TYPEHASH = keccak256(
  'ProposalData(bytes32 orderUidHash,uint256 sellAmount,uint256 buyAmount,bytes32 interactionsHash,uint256 validUntil,uint256 nonce)'
);

/**
 * @title BYOS Trampoline
 * @author CoW Protocol Developers
 * @notice Per-sub-solver execution sandbox. Receives the trade's sell tokens from
 * GPv2Settlement, runs the sub-solver's EIP-712-signed route in a fund-less context,
 * sweeps its full remaining balance of both trade tokens back to the settlement
 * contract, and enforces the signed buy amount as a floor on the settlement's
 * buy-token balance growth. One immutable instance per sub-solver at a deterministic
 * CREATE2 address (ADR-0001).
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
   * @param _floor The signed buyAmount the delta was checked against
   */
  event Executed(bytes32 indexed _orderUidHash, uint256 _delta, uint256 _floor);

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
   * @param buyAmount The floor: the minimum growth of the settlement's buy-token
   * balance execute enforces
   * @param validUntil Timestamp after which the proposal is no longer executable
   * @param nonce Sub-solver-chosen value distinguishing otherwise identical proposals
   */
  struct Proposal {
    bytes32 orderUidHash;
    uint256 sellAmount;
    uint256 buyAmount;
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
   * @notice Throws if the proposal signature does not recover to the sub-solver
   */
  error Trampoline_InvalidSignature();

  /**
   * @notice Throws if the settlement's buy-token balance grew by less than the
   * signed floor
   * @param _delta The measured growth of the settlement's buy-token balance
   * @param _floor The signed buyAmount required
   */
  error Trampoline_FloorNotMet(uint256 _delta, uint256 _floor);

  /**
   * @notice Throws if the native ETH sweep to the settlement fails
   */
  error Trampoline_EthSettleBackFailed();

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

  /*///////////////////////////////////////////////////////////////
                               LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Executes a sub-solver's signed route, sweeps the instance's full
   * remaining balance of both trade tokens to the settlement contract, and reverts
   * unless the settlement's buy-token balance grew by at least `_proposal.buyAmount`
   * @dev Callable only by the settlement contract, and only in a settlement submitted
   * by a BYOS submitter: tx.origin must hold the Escrow's SUBMITTER_ROLE, since a live
   * proposal's calldata is public and any allow-listed solver could otherwise replay it
   * (ADR-0005). The balance-delta check is the funding guard (ADR-0003): buyAmount is
   * the floor the sub-solver signed, measured as the growth of the settlement's
   * buy-token balance between entry and return, so routes that deliver output to the
   * settlement directly also count. Anything above the floor lands in the settlement
   * as BYOS-owned slippage (ADR-0008); the instance ends every settlement holding
   * none of the trade tokens. The tokens are BYOS-supplied call parameters taken from
   * the order, not signed proposal fields. When `_buyToken` is BUY_ETH_ADDRESS the
   * snapshot, sweep, and delta are in native ETH. Zero balances are not swept (some
   * tokens revert on zero-value transfers), and when the trade's tokens are the same
   * address (same-token hook orders) the shared token is swept once.
   * @param _proposal The signed proposal fields
   * @param _interactions The route, hashed into the verified signature
   * @param _sellToken The trade's sell token, swept back along with the buy token
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
}
