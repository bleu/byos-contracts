// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';

import {ITrampolineFactory} from 'interfaces/ITrampolineFactory.sol';

import {Trampoline} from 'contracts/Trampoline.sol';

contract TrampolineFactory is ITrampolineFactory, EIP712 {
  /// @inheritdoc ITrampolineFactory
  address public immutable SETTLEMENT;

  /// @inheritdoc ITrampolineFactory
  address public immutable ESCROW;

  /// @dev Keep CREATE2 init code and signature verification on the same deployment-time domain.
  bytes32 private immutable _DOMAIN_SEPARATOR;

  /// @dev Domain introspection must report the chain ID used by the frozen separator.
  uint256 private immutable _CHAIN_ID;

  /**
   * @notice Sets the settlement contract and the EIP-712 domain (name "BYOS", version "0.1")
   * @dev The deployer is recorded as the Escrow whose SUBMITTER_ROLE gates instance
   * execution; in production the Escrow deploys the factory from its constructor
   * @param _settlement GPv2Settlement address for this chain
   */
  constructor(
    address _settlement
  ) EIP712('BYOS', '0.1') {
    SETTLEMENT = _settlement;
    ESCROW = msg.sender;
    _DOMAIN_SEPARATOR = _domainSeparatorV4();
    _CHAIN_ID = block.chainid;
  }

  /// @inheritdoc ITrampolineFactory
  function ensureDeployed(
    address _subSolver
  ) external returns (address _instance) {
    _instance = addressOf(_subSolver);
    if (_instance.code.length == 0) {
      new Trampoline{salt: bytes32(uint256(uint160(_subSolver)))}(_subSolver, SETTLEMENT, _DOMAIN_SEPARATOR, ESCROW);
      emit TrampolineDeployed(_subSolver, _instance);
    }
  }

  /// @inheritdoc ITrampolineFactory
  function domainSeparator() external view returns (bytes32 _domainSeparator) {
    _domainSeparator = _DOMAIN_SEPARATOR;
  }

  /// @inheritdoc EIP712
  function eip712Domain()
    public
    view
    override
    returns (
      bytes1 _fields,
      string memory _name,
      string memory _version,
      uint256 _chainId,
      address _verifyingContract,
      bytes32 _salt,
      uint256[] memory _extensions
    )
  {
    (_fields, _name, _version,, _verifyingContract, _salt, _extensions) = super.eip712Domain();
    _chainId = _CHAIN_ID;
  }

  /// @inheritdoc ITrampolineFactory
  function addressOf(
    address _subSolver
  ) public view returns (address _trampoline) {
    bytes32 _initCodeHash = keccak256(
      abi.encodePacked(type(Trampoline).creationCode, abi.encode(_subSolver, SETTLEMENT, _DOMAIN_SEPARATOR, ESCROW))
    );
    _trampoline = address(
      uint160(
        uint256(
          keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(uint256(uint160(_subSolver))), _initCodeHash))
        )
      )
    );
  }
}
