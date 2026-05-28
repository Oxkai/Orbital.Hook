// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";

/// @notice Deploys an end-to-end Orbital hook setup on local anvil:
///         1) v4 PoolManager
///         2) Four 18-decimal mock stablecoins, sorted ascending by address
///         3) OrbitalHook at a CREATE2-mined address encoding the right flag suffix
///         4) All `N(N-1)/2 = 6` pair pools registered against the hook
///
/// @dev Run with:
///         anvil &
///         forge script script/Deploy.s.sol --rpc-url http://localhost:8545 \
///             --broadcast --private-key $PRIVATE_KEY
///
///      For a default anvil instance, use the first prefunded account's key, e.g.:
///         export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract DeployScript is Script {
    // SQRT_PRICE_1_1 from v4 — both reserves equal at init.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Hook fee: 1 bp = 100 hundredths-of-bip.
    uint24 internal constant POOL_FEE = 100;

    // PoolKey.lpFee must be 0 — engine handles its own fee accounting.
    uint24 internal constant POOL_KEY_LP_FEE = 0;
    int24 internal constant POOL_KEY_TICK_SPACING = 1;

    // Per-token mint to the deployer. Must cover the ~5M/asset seed plus swap room.
    uint256 internal constant MINT_PER_TOKEN = 20_000_000 ether;

    uint8 internal constant N_TOKENS = 4;
    string[4] internal SYMBOLS = ["USDC", "USDT", "DAI", "FRAX"];
    string[4] internal NAMES = ["USD Coin", "Tether USD", "Dai Stablecoin", "Frax"];

    // Deep, tiered seed: ~$10M rInt (~$20M TVL) across four depeg-bound tiers.
    // Bounds are intentionally WIDE (0.95 .. 0.80) so they sit well above the
    // equal-price point — gentle demo swaps keep αNorm near peg and never reach
    // the tightest tier, so no tick crosses to boundary.
    //   tier r (radius)          depeg bound
    //   4,000,000                0.95
    //   3,000,000                0.90
    //   2,000,000                0.85
    //   1,000,000                0.80
    function _tierR(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 4_000_000 ether;
        if (i == 1) return 3_000_000 ether;
        if (i == 2) return 2_000_000 ether;
        return 1_000_000 ether;
    }

    function _tierDepeg(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 0.95e18;
        if (i == 1) return 0.90e18;
        if (i == 2) return 0.85e18;
        return 0.80e18;
    }

    uint256 internal constant N_TIERS = 4;

    function run() external {
        vm.startBroadcast();

        // 1) v4 PoolManager + Permit2 — reuse existing infra if present, so a
        //    redeploy only creates fresh tokens + hook + pools (and avoids a
        //    CREATE2 collision on the deterministic PoolManager address).
        address knownPM = 0x9BEACCac4e0358Cc276703dcE7341B9B9fEfd5f7; // X Layer testnet
        IPoolManager poolManager = knownPM.code.length > 0
            ? IPoolManager(knownPM)
            : IPoolManager(V4PoolManagerDeployer.deploy(msg.sender));

        address canonicalPermit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        IAllowanceTransfer permit2 = canonicalPermit2.code.length > 0
            ? IAllowanceTransfer(canonicalPermit2)
            : IAllowanceTransfer(Permit2Deployer.deploy());

        console2.log("PoolManager:", address(poolManager));
        console2.log("Permit2:    ", address(permit2));

        // 2) Mock stables
        Currency[] memory assets = _deployTokens();

        // 3) OrbitalHook (CREATE2-mined). Deployer becomes initial admin.
        OrbitalHook hook = _deployHook(poolManager, permit2, assets, msg.sender);
        console2.log("OrbitalHook:", address(hook));
        console2.log("Admin:      ", msg.sender);

        // 4) Pair pools — N(N-1)/2 of them, all sharing the hook's engine state.
        _initializePools(poolManager, hook, assets);

        // 5) Seed deep, tiered liquidity so the pool is immediately usable and tight.
        _seedTiers(hook, assets);

        vm.stopBroadcast();
    }

    function _deployTokens() internal returns (Currency[] memory sorted) {
        MockERC20[] memory raw = new MockERC20[](N_TOKENS);
        for (uint8 i = 0; i < N_TOKENS; ++i) {
            MockERC20 token = new MockERC20(NAMES[i], SYMBOLS[i], 18);
            token.mint(msg.sender, MINT_PER_TOKEN);
            raw[i] = token;
            console2.log(SYMBOLS[i], address(token));
        }
        // Sort ascending by address (OrbitalHook constructor requires this).
        for (uint8 i = 0; i < N_TOKENS; ++i) {
            for (uint8 j = uint8(i + 1); j < N_TOKENS; ++j) {
                if (address(raw[j]) < address(raw[i])) {
                    (raw[i], raw[j]) = (raw[j], raw[i]);
                }
            }
        }
        sorted = new Currency[](N_TOKENS);
        for (uint8 i = 0; i < N_TOKENS; ++i) {
            sorted[i] = Currency.wrap(address(raw[i]));
        }
    }

    function _deployHook(
        IPoolManager poolManager,
        IAllowanceTransfer permit2,
        Currency[] memory assets,
        address admin
    ) internal returns (OrbitalHook hook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, permit2, assets, POOL_FEE, admin);

        // forge-std's CREATE2_FACTORY is the canonical 0x4e59...956C proxy that
        // Foundry routes salted deployments through during scripts.
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(OrbitalHook).creationCode, constructorArgs);

        hook = new OrbitalHook{salt: salt}(poolManager, permit2, assets, POOL_FEE, admin);
        require(address(hook) == expected, "hook address mismatch");
    }

    function _initializePools(IPoolManager poolManager, OrbitalHook hook, Currency[] memory assets) internal {
        uint256 n = assets.length;
        uint256 pairCount;
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                PoolKey memory key = PoolKey({
                    currency0: assets[i],
                    currency1: assets[j],
                    fee: POOL_KEY_LP_FEE,
                    tickSpacing: POOL_KEY_TICK_SPACING,
                    hooks: IHooks(address(hook))
                });
                poolManager.initialize(key, SQRT_PRICE_1_1);
                console2.log("Pool registered (i,j):", i, j);
                pairCount++;
            }
        }
        console2.log("Pools registered:", pairCount);
    }

    function _seedTiers(OrbitalHook hook, Currency[] memory assets) internal {
        // Approve the hook to pull each asset from the deployer.
        for (uint256 i = 0; i < assets.length; ++i) {
            MockERC20(Currency.unwrap(assets[i])).approve(address(hook), type(uint256).max);
        }

        uint256[] memory maxA = new uint256[](N_TOKENS);
        for (uint256 i = 0; i < N_TOKENS; ++i) maxA[i] = type(uint256).max;

        // All tiers added while the pool is balanced (kBound stays 0), so each
        // mint's depeg-bound k is valid and deposits stay pro-rata/equal-price.
        for (uint256 t = 0; t < N_TIERS; ++t) {
            uint256 r = _tierR(t);
            uint256 k = TickLib.kFromDepegPrice(r, N_TOKENS, _tierDepeg(t));
            (uint256 tickIdx,) = hook.addLiquidity(k, r, maxA);
            console2.log("Tier seeded, tickIdx:", tickIdx);
            console2.log("  r:", r);
            console2.log("  depeg(wad):", _tierDepeg(t));
        }
    }
}
