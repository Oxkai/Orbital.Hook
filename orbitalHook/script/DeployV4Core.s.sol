// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";
import {OrbitalDeploy} from "./lib/OrbitalDeploy.sol";

/// @notice Stands up Uniswap v4 on a chain that has no canonical deployment.
/// @dev    Most chains Orbital runs on carry a canonical PoolManager, which
///         `DeployTestnet.s.sol` resolves by chainId through hookmate's
///         `AddressConstants`. HyperEVM carries none, so the hook has nothing to
///         attach to until one exists.
///
///         Both contracts come from hookmate's prebuilt artifacts rather than
///         from source: v4-core pins `pragma solidity =0.8.26` and this repo
///         builds on 0.8.30, so the sources cannot compile side by side here.
///         The artifacts are the same bytecode Uniswap deploys canonically.
///
///         Permit2 is assumed already present at its deterministic address; it
///         is on every chain this has been pointed at so far, and the router
///         constructor takes it.
///
///         forge script script/DeployV4Core.s.sol --rpc-url <rpc> \
///             --broadcast --slow --private-key $PRIVATE_KEY
///
///         Feed the two printed addresses back in as V4_POOL_MANAGER and
///         V4_ROUTER when running DeployTestnet.s.sol.
contract DeployV4CoreScript is Script {
    function run() external {
        address permit2 = OrbitalDeploy.PERMIT2;
        require(permit2.code.length > 0, "no Permit2 on this chain");

        vm.startBroadcast();
        address pm = V4PoolManagerDeployer.deploy(msg.sender);
        address router = V4RouterDeployer.deploy(pm, permit2);
        vm.stopBroadcast();

        require(pm.code.length > 0, "PoolManager deploy produced no code");
        require(router.code.length > 0, "router deploy produced no code");

        console2.log("chainId:     ", block.chainid);
        console2.log("PoolManager: ", pm);
        console2.log("V4Router:    ", router);
        console2.log("");
        console2.log("export V4_POOL_MANAGER=%s", pm);
        console2.log("export V4_ROUTER=%s", router);
    }
}
