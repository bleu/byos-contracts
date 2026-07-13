// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {Trampoline} from "./Trampoline.sol";

/// @title BYOS Trampoline Factory
/// @author CoW Protocol Developers
/// @notice CREATE2 deployer for per-sub-solver Trampoline instances and the EIP-712
/// domain anchor for proposal signatures (ADR-0005): signatures verify against this
/// factory's domain, so a factory redeployment cleanly invalidates old signatures.
contract TrampolineFactory is EIP712 {
    /// @notice The GPv2Settlement contract baked into every deployed instance.
    address public immutable settlement;

    event TrampolineDeployed(address indexed subSolver, address instance);

    /// @param _settlement GPv2Settlement address for this chain.
    constructor(address _settlement) EIP712("BYOS", "1") {
        settlement = _settlement;
    }

    /// @notice Deploy the Trampoline instance for a sub-solver if it does not exist yet.
    /// Idempotent and permissionless; called by Escrow.deposit on first deposit (ADR-0003).
    /// @return instance The instance address (freshly deployed or pre-existing).
    function ensureDeployed(address subSolver) external returns (address instance) {
        instance = addressOf(subSolver);
        if (instance.code.length == 0) {
            new Trampoline{salt: bytes32(uint256(uint160(subSolver)))}(subSolver, settlement, _domainSeparatorV4());
            emit TrampolineDeployed(subSolver, instance);
        }
    }

    /// @notice The EIP-712 domain separator proposal signatures are verified against.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Deterministic CREATE2 address of a sub-solver's Trampoline instance.
    function addressOf(address subSolver) public view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(Trampoline).creationCode, abi.encode(subSolver, settlement, _domainSeparatorV4()))
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), bytes32(uint256(uint160(subSolver))), initCodeHash
                        )
                    )
                )
            )
        );
    }
}
