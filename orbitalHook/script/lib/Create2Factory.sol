// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice A minimal CREATE2 deployer, for chains that do not carry the
///         canonical deterministic deployer at 0x4e59b4...
///
///         The hook's address has to encode its Uniswap v4 permission flags in
///         its low bits, which means mining a salt against a known deployer. On
///         a chain with no deterministic deployer there is nothing to mine
///         against, so we bring our own: `HookMiner.find` is pointed at this
///         contract and `deploy` reproduces the same address formula,
///         keccak256(0xff ++ this ++ salt ++ keccak256(initCode)).
contract Create2Factory {
    error DeployFailed();

    function deploy(bytes32 salt, bytes memory initCode) external payable returns (address addr) {
        assembly ("memory-safe") {
            addr := create2(callvalue(), add(initCode, 0x20), mload(initCode), salt)
        }
        if (addr == address(0)) revert DeployFailed();
    }
}
