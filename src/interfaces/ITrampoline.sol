// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

/**
 * @dev Marker address GPv2 uses for orders buying native ETH (GPv2Order.BUY_ETH_ADDRESS).
 * Settle-back sends native ETH instead of ERC-20.
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
 * and transfers exactly the promised buy amount back to the settlement contract.
 * One immutable instance per sub-solver at a deterministic CREATE2 address (ADR-0001).
 */
interface ITrampoline {
  /*///////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

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
   * @param sellAmount The sell amount the route consumes
   * @param buyAmount The buy amount settled back to the settlement contract
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
   * @notice Throws if the proposal's validUntil timestamp has passed
   */
  error Trampoline_ProposalExpired();

  /**
   * @notice Throws if the proposal signature does not recover to the sub-solver
   */
  error Trampoline_InvalidSignature();

  /**
   * @notice Throws if the native ETH settle-back transfer fails
   */
  error Trampoline_EthSettleBackFailed();

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

  /*///////////////////////////////////////////////////////////////
                               LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Executes a sub-solver's signed route and settles back exactly
   * `_proposal.buyAmount` of `_buyToken` to the settlement contract
   * @dev The transfer's own insufficient-balance revert is the funding guard (ADR-0003):
   * a route that falls short reverts the settlement. Surplus beyond buyAmount stays in
   * the instance.
   * @param _proposal The signed proposal fields
   * @param _interactions The route, hashed into the verified signature
   * @param _buyToken Token to settle back; supplied by BYOS from the order
   * @param _signature Sub-solver's EIP-712 signature over the proposal
   */
  function execute(
    Proposal calldata _proposal,
    Interaction[] calldata _interactions,
    address _buyToken,
    bytes calldata _signature
  ) external;

  /**
   * @notice Transfers the instance's full balance of `_token` to `_recipient`
   * @dev Residue is the sub-solver's property (ADR-0008). The instance is storage-free
   * and cannot enumerate what it holds; the caller identifies tokens off-chain. Use
   * BUY_ETH_ADDRESS to claim native ETH. Residue is at risk to allow-listed-solver
   * replay while any signed proposal for this instance is unexpired — claim promptly.
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
