// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @dev Marker address GPv2 uses for orders buying native ETH (GPv2Order.BUY_ETH_ADDRESS).
/// Settle-back sends native ETH instead of ERC-20.
address constant BUY_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

/// @dev EIP-712 type hash of the signed proposal struct (ADR-0005).
bytes32 constant PROPOSAL_TYPEHASH = keccak256(
    "ProposalData(bytes32 orderUidHash,uint256 sellAmount,uint256 buyAmount,bytes32 interactionsHash,uint256 validUntil,uint256 nonce)"
);

/// @title BYOS Trampoline
/// @author CoW Protocol Developers
/// @notice Per-sub-solver execution sandbox. Receives the trade's sell tokens from
/// GPv2Settlement, runs the sub-solver's EIP-712-signed route in a fund-less context,
/// and transfers exactly the promised buy amount back to the settlement contract.
/// One immutable instance per sub-solver at a deterministic CREATE2 address (ADR-0001).
contract Trampoline {
    using SafeERC20 for IERC20;

    /// @notice One call of the sub-solver's route, mirroring GPv2Interaction.Data.
    struct Interaction {
        address target;
        uint256 value;
        bytes callData;
    }

    /// @notice The signed proposal fields (ADR-0005), minus interactionsHash which is
    /// recomputed on-chain from the interactions actually being executed.
    struct Proposal {
        bytes32 orderUidHash;
        uint256 sellAmount;
        uint256 buyAmount;
        uint256 validUntil;
        uint256 nonce;
    }

    /// @notice The sub-solver whose signed proposals this instance executes.
    address public immutable subSolver;
    /// @notice The GPv2Settlement contract — the only address allowed to call execute.
    address public immutable settlement;
    /// @notice EIP-712 domain separator of the deploying factory (ADR-0005).
    bytes32 public immutable domainSeparator;

    error OnlySettlement();
    error ProposalExpired();
    error InvalidSignature();
    error EthSettleBackFailed();

    /// @param _subSolver Sub-solver address; proposal signatures must recover to it.
    /// @param _settlement GPv2Settlement address.
    /// @param _domainSeparator The factory's EIP-712 domain separator.
    constructor(address _subSolver, address _settlement, bytes32 _domainSeparator) {
        subSolver = _subSolver;
        settlement = _settlement;
        domainSeparator = _domainSeparator;
    }

    /// @notice Execute a sub-solver's signed route and settle back exactly
    /// `proposal.buyAmount` of `buyToken` to the settlement contract. The transfer's own
    /// insufficient-balance revert is the funding guard (ADR-0003): a route that falls
    /// short reverts the settlement. Surplus beyond buyAmount stays in the instance.
    /// @param proposal The signed proposal fields.
    /// @param interactions The route, hashed into the verified signature.
    /// @param buyToken Token to settle back; supplied by BYOS from the order.
    /// @param signature Sub-solver's EIP-712 signature over the proposal.
    function execute(
        Proposal calldata proposal,
        Interaction[] calldata interactions,
        address buyToken,
        bytes calldata signature
    ) external {
        if (msg.sender != settlement) revert OnlySettlement();
        if (block.timestamp > proposal.validUntil) revert ProposalExpired();

        bytes32 structHash = keccak256(
            abi.encode(
                PROPOSAL_TYPEHASH,
                proposal.orderUidHash,
                proposal.sellAmount,
                proposal.buyAmount,
                keccak256(abi.encode(interactions)),
                proposal.validUntil,
                proposal.nonce
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        if (ECDSA.recover(digest, signature) != subSolver) revert InvalidSignature();

        for (uint256 i = 0; i < interactions.length; i++) {
            Interaction calldata interaction = interactions[i];
            (bool success, bytes memory returnData) =
                interaction.target.call{value: interaction.value}(interaction.callData);
            if (!success) {
                // Bubble the interaction's revert data so route failures are
                // attributable from the settlement trace.
                assembly ("memory-safe") {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }

        if (buyToken == BUY_ETH_ADDRESS) {
            (bool success,) = settlement.call{value: proposal.buyAmount}("");
            if (!success) revert EthSettleBackFailed();
        } else {
            IERC20(buyToken).safeTransfer(settlement, proposal.buyAmount);
        }
    }

    /// @notice Accept native ETH mid-route (e.g. a WETH unwrap or an ETH-paying venue).
    receive() external payable {}
}
