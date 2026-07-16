// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

import {ITrampoline, PROPOSAL_TYPEHASH} from 'interfaces/ITrampoline.sol';

import {TrampolineFactory} from 'contracts/TrampolineFactory.sol';

import {ProposalSigning} from 'test/utils/ProposalSigning.sol';

/**
 * @notice Generates the EIP-712 test vectors consumed by off-chain proposal
 * signers (the `subsolver` crate in bleu/byos-service). Signing code there is
 * required to verify against these contract-derived values instead of
 * re-deriving the schema locally (byos-service ADR-0001).
 *
 * Running `forge test --match-contract Eip712Vectors` rewrites
 * `test/vectors/proposal-eip712.json`; the file is deterministic, so a
 * rewrite only produces a diff when the signing schema itself changed —
 * which is exactly when downstream signers must be updated.
 */
contract Eip712Vectors is Test {
  /// @dev Mainnet GPv2Settlement; an arbitrary but stable constructor input.
  address internal constant _SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
  uint256 internal constant _SUB_SOLVER_KEY = 0xA11CE;

  struct Inputs {
    bytes orderUid;
    uint256 sellAmount;
    uint256 buyAmount;
    uint256 validUntil;
    uint256 nonce;
    ITrampoline.Interaction[] interactions;
  }

  TrampolineFactory internal _factory;
  address internal _subSolver;

  function setUp() public {
    _factory = new TrampolineFactory(_SETTLEMENT);
    _subSolver = vm.addr(_SUB_SOLVER_KEY);
  }

  function test_generateVectors() public {
    Inputs[] memory _cases = new Inputs[](3);

    // Vector 1: empty route. Isolates domain + typehash from interaction encoding.
    _cases[0] = Inputs({
      orderUid: bytes.concat(bytes28(0), bytes20(_subSolver), bytes8(0)),
      sellAmount: 1e18,
      buyAmount: 5e6,
      validUntil: 1_750_000_000,
      nonce: 0,
      interactions: new ITrampoline.Interaction[](0)
    });

    // Vector 2: single zero-value interaction. Isolates the encoding of one struct.
    _cases[1] = Inputs({
      orderUid: bytes.concat(bytes28(uint224(1)), bytes20(_subSolver), bytes8(uint64(7))),
      sellAmount: 123_456_789,
      buyAmount: 987_654_321,
      validUntil: 1_750_000_060,
      nonce: 1,
      interactions: new ITrampoline.Interaction[](1)
    });
    _cases[1].interactions[0] =
      ITrampoline.Interaction({target: 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D, value: 0, callData: hex'abcdef'});

    // Vector 3: two interactions, nonzero value, empty calldata, extreme field
    // values. Exercises the dynamic-array offsets in abi.encode(_interactions).
    _cases[2] = Inputs({
      orderUid: bytes.concat(bytes28(type(uint224).max), bytes20(_subSolver), bytes8(type(uint64).max)),
      sellAmount: type(uint256).max,
      buyAmount: 1,
      validUntil: type(uint32).max,
      nonce: type(uint256).max,
      interactions: new ITrampoline.Interaction[](2)
    });
    _cases[2].interactions[0] =
      ITrampoline.Interaction({target: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, value: 1 ether, callData: hex''});
    _cases[2].interactions[1] = ITrampoline.Interaction({
      target: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
      value: 0,
      callData: hex'a9059cbb0000000000000000000000009008d19f58aabd9ed0d60971565aa8510560ab410000000000000000000000000000000000000000000000000000000005f5e100'
    });

    string memory _vectors = '[';
    for (uint256 _i = 0; _i < _cases.length; ++_i) {
      _vectors = string.concat(_vectors, _i == 0 ? '' : ',', _vector(_cases[_i]));
    }
    _vectors = string.concat(_vectors, ']');

    string memory _json = '{"domain":{"name":"BYOS","version":"0.1"';
    _json = string.concat(_json, ',"chainId":', vm.toString(block.chainid));
    _json = string.concat(_json, ',"verifyingContract":"', vm.toString(address(_factory)), '"');
    _json = string.concat(_json, ',"domainSeparator":"', vm.toString(_factory.domainSeparator()), '"}');
    _json = string.concat(_json, ',"proposalTypehash":"', vm.toString(PROPOSAL_TYPEHASH), '"');
    _json = string.concat(_json, ',"subSolver":{"address":"', vm.toString(_subSolver), '"');
    _json = string.concat(_json, ',"privateKey":"', vm.toString(bytes32(_SUB_SOLVER_KEY)), '"}');
    _json = string.concat(_json, ',"vectors":', _vectors, '}');

    vm.writeJson(_json, 'test/vectors/proposal-eip712.json');
  }

  /// @dev Builds one vector: signs the proposal exactly as Trampoline.execute
  /// verifies it, asserts the signature recovers, and serializes inputs + derived hashes.
  function _vector(
    Inputs memory _inputs
  ) internal view returns (string memory _json) {
    ITrampoline.Proposal memory _proposal = ITrampoline.Proposal({
      orderUidHash: keccak256(_inputs.orderUid),
      sellAmount: _inputs.sellAmount,
      buyAmount: _inputs.buyAmount,
      validUntil: _inputs.validUntil,
      nonce: _inputs.nonce
    });

    bytes32 _digest = ProposalSigning.digest(_factory.domainSeparator(), _proposal, _inputs.interactions);
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_SUB_SOLVER_KEY, _digest);
    bytes memory _signature = abi.encodePacked(_r, _s, _v);
    assert(ECDSA.recover(_digest, _signature) == _subSolver);

    _json = string.concat('{"orderUid":"', vm.toString(_inputs.orderUid), '"');
    _json = string.concat(_json, ',"sellAmount":"', vm.toString(_inputs.sellAmount), '"');
    _json = string.concat(_json, ',"buyAmount":"', vm.toString(_inputs.buyAmount), '"');
    _json = string.concat(_json, ',"validUntil":', vm.toString(_inputs.validUntil));
    _json = string.concat(_json, ',"nonce":"', vm.toString(_inputs.nonce), '"');
    _json = string.concat(_json, ',"interactions":', _interactionsJson(_inputs.interactions));
    _json = string.concat(_json, ',"orderUidHash":"', vm.toString(_proposal.orderUidHash), '"');
    _json = string.concat(_json, ',"interactionsHash":"', vm.toString(keccak256(abi.encode(_inputs.interactions))), '"');
    _json = string.concat(_json, ',"structHash":"', vm.toString(_structHash(_proposal, _inputs.interactions)), '"');
    _json = string.concat(_json, ',"digest":"', vm.toString(_digest), '"');
    _json = string.concat(_json, ',"signature":"', vm.toString(_signature), '"}');
  }

  function _structHash(
    ITrampoline.Proposal memory _proposal,
    ITrampoline.Interaction[] memory _interactions
  ) internal pure returns (bytes32 _hash) {
    _hash = keccak256(
      abi.encode(
        PROPOSAL_TYPEHASH,
        _proposal.orderUidHash,
        _proposal.sellAmount,
        _proposal.buyAmount,
        keccak256(abi.encode(_interactions)),
        _proposal.validUntil,
        _proposal.nonce
      )
    );
  }

  function _interactionsJson(
    ITrampoline.Interaction[] memory _interactions
  ) internal pure returns (string memory _json) {
    _json = '[';
    for (uint256 _i = 0; _i < _interactions.length; ++_i) {
      _json = string.concat(_json, _i == 0 ? '' : ',', '{"target":"', vm.toString(_interactions[_i].target), '"');
      _json = string.concat(_json, ',"value":"', vm.toString(_interactions[_i].value), '"');
      _json = string.concat(_json, ',"callData":"', vm.toString(_interactions[_i].callData), '"}');
    }
    _json = string.concat(_json, ']');
  }
}
