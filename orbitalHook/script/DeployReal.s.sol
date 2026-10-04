// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {OrbitalDeploy} from "./lib/OrbitalDeploy.sol";
import {ArbitrumOne} from "./realworld/ArbitrumOne.sol";

/// @notice Deploy Orbital over LIVE stablecoins on Arbitrum One — or on a fork
///         of it (Tenderly Virtual TestNet, anvil). No mock tokens: the pool
///         lists the real USDC, USDT0, DAI and Paxos USDG contracts, with their
///         real decimals, blocklists and pause switches.
///
/// @dev    By default the pool holds as much USDC and USDT0 as the live
///         Uniswap v3 USDC/USDT0 0.01% pool does at this block: each asset gets
///         half of that pool's value, and USDG and DAI get the same again. A
///         trade between USDC and USDT0 therefore meets the same inventory in
///         both pools, and the other two assets serve the other five pairs.
///         Splitting the v3 pool's value over four assets instead would give
///         Orbital half the USDC/USDT0 inventory, a comparison it loses by
///         construction. `CAPITAL_PER_ASSET` (whole dollars) overrides it.
///
///         The deployer must already hold the capital; on a fork,
///         `script/realworld/fund.sh` mints it through each issuer's own path.
///
///         forge script script/DeployReal.s.sol --rpc-url $RPC --broadcast \
///             --slow --private-key $PRIVATE_KEY
contract DeployRealScript is Script {
    function run() external {
        require(block.chainid == 42161, "Arbitrum One (or a fork of it) only");

        address pm = AddressConstants.getPoolManagerAddress(block.chainid);
        address rt = AddressConstants.getV4SwapRouterAddress(block.chainid);
        require(pm.code.length > 0, "no PoolManager");
        require(rt.code.length > 0, "no V4Router");
        require(OrbitalDeploy.PERMIT2.code.length > 0, "no Permit2");

        address[] memory tokens = ArbitrumOne.stables();
        for (uint256 i = 0; i < tokens.length; ++i) require(tokens[i].code.length > 0, "token missing");

        uint256 capitalPerAsset = _capitalPerAsset();
        console2.log("capital per asset ($):", capitalPerAsset / 1e18);

        vm.startBroadcast();
        Currency[] memory assets = OrbitalDeploy.sorted(tokens);
        OrbitalHook hook = OrbitalDeploy.deployHook(IPoolManager(pm), assets, msg.sender);
        OrbitalDeploy.initPools(IPoolManager(pm), hook, assets);
        OrbitalDeploy.seed(hook, assets, capitalPerAsset);
        vm.stopBroadcast();

        OrbitalDeploy.report(hook, assets, pm, rt);
    }

    /// @dev Engine WAD value units per asset.
    function _capitalPerAsset() internal view returns (uint256) {
        uint256 dollars = vm.envOr("CAPITAL_PER_ASSET", uint256(0));
        if (dollars != 0) return dollars * 1e18;

        // The v3 pool's USDC + USDT0 inventory, as much of each here: both its
        // tokens have 6 decimals.
        address v3 = ArbitrumOne.V3_USDC_USDT0_POOL;
        uint256 held = IERC20(ArbitrumOne.USDC).balanceOf(v3) + IERC20(ArbitrumOne.USDT0).balanceOf(v3);
        console2.log("v3 USDC/USDT0 pool holds ($):", held / 1e6);
        return held * 1e12 / 2;
    }
}
