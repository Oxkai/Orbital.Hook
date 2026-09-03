// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

/// @notice Deploys a V4Quoter against this chain's canonical PoolManager.
/// @dev    hookmate's AddressConstants has no quoter getter, and Base Sepolia /
///         Arbitrum Sepolia have no canonical v4 Quoter, so the frontend needs
///         one deployed per chain to quote same-chain Orbital swaps.
///
///         forge script script/DeployQuoter.s.sol --rpc-url base_sepolia \
///             --broadcast --private-key $PRIVATE_KEY
contract DeployQuoterScript is Script {
    function run() external {
        address pm = AddressConstants.getPoolManagerAddress(block.chainid);
        require(pm.code.length > 0, "no PoolManager on this chain");

        vm.startBroadcast();
        V4Quoter quoter = new V4Quoter(IPoolManager(pm));
        vm.stopBroadcast();

        console2.log("chainId:     ", block.chainid);
        console2.log("PoolManager: ", pm);
        console2.log("V4Quoter:    ", address(quoter));
    }
}
