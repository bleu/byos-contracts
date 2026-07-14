// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {MessageHashUtils} from '@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol';

import {ITrampoline, PROPOSAL_TYPEHASH} from 'interfaces/ITrampoline.sol';

/// @dev Builds the EIP-712 digest a sub-solver signs over a proposal (ADR-0005),
/// reusing the contract's own PROPOSAL_TYPEHASH so tests cannot drift from it.
library ProposalSigning {
  function digest(
    bytes32 domainSeparator,
    ITrampoline.Proposal memory proposal,
    ITrampoline.Interaction[] memory interactions
  ) internal pure returns (bytes32) {
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
    return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
  }
}
