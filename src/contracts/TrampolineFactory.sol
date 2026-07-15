// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';

import {ITrampolineFactory} from 'interfaces/ITrampolineFactory.sol';

import {Trampoline} from 'contracts/Trampoline.sol';

contract TrampolineFactory is ITrampolineFactory, EIP712 {
  /// @inheritdoc ITrampolineFactory
  address public immutable SETTLEMENT;

  /**
   * @notice Sets the settlement contract and the EIP-712 domain (name "BYOS", version "0.1")
   * @param _settlement GPv2Settlement address for this chain
   */
  constructor(
    address _settlement
  ) EIP712('BYOS', '0.1') {
    SETTLEMENT = _settlement;
  }

  /// @inheritdoc ITrampolineFactory
  function ensureDeployed(
    address _subSolver
  ) external returns (address _instance) {
    _instance = addressOf(_subSolver);
    if (_instance.code.length == 0) {
      new Trampoline{salt: bytes32(uint256(uint160(_subSolver)))}(_subSolver, SETTLEMENT, _domainSeparatorV4());
      emit TrampolineDeployed(_subSolver, _instance);
    }
  }

  /// @inheritdoc ITrampolineFactory
  function domainSeparator() external view returns (bytes32 _domainSeparator) {
    _domainSeparator = _domainSeparatorV4();
  }

  /// @inheritdoc ITrampolineFactory
  function addressOf(
    address _subSolver
  ) public view returns (address _trampoline) {
    bytes32 _initCodeHash = keccak256(
      abi.encodePacked(type(Trampoline).creationCode, abi.encode(_subSolver, SETTLEMENT, _domainSeparatorV4()))
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
