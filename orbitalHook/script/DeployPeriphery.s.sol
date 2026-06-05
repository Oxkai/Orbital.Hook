// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";

/// @notice Deploys the v4 periphery the frontend needs (swap router + quoter)
///         against an already-deployed PoolManager. Run after Deploy.s.sol.
///
/// @dev Set POOL_MANAGER + PERMIT2 below to the addresses from the Deploy run.
///         forge script script/DeployPeriphery.s.sol --rpc-url <unichain-sepolia> \
///             --broadcast --slow --private-key $PRIVATE_KEY
contract DeployPeripheryScript is Script {
    // Canonical Uniswap v4 PoolManager on Unichain Sepolia.
    // Source: https://developers.uniswap.org/contracts/v4/deployments
    //
    // Unichain Sepolia has canonical PoolManager + UniversalRouter + Quoter,
    // but NO separate v4 SwapRouter. Our SwapWidget and SeedActivity use the
    // v4-specific Router ABI, so run this script to deploy a lightweight one
    // pointed at the canonical PoolManager — keeps the frontend code intact.
    address internal constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        vm.startBroadcast();

        address router = V4RouterDeployer.deploy(POOL_MANAGER, PERMIT2);
        V4Quoter quoter = new V4Quoter(IPoolManager(POOL_MANAGER));

        vm.stopBroadcast();

        console2.log("V4SwapRouter:", router);
        console2.log("V4Quoter:    ", address(quoter));
    }
}
