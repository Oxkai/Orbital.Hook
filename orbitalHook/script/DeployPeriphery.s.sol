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
///         forge script script/DeployPeriphery.s.sol --rpc-url <xlayer> \
///             --broadcast --slow --private-key $PRIVATE_KEY
contract DeployPeripheryScript is Script {
    // From the X Layer testnet Deploy.s.sol run.
    address internal constant POOL_MANAGER = 0x9BEACCac4e0358Cc276703dcE7341B9B9fEfd5f7;
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
