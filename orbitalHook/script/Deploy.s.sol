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

    // Per-LP starting mint for each mock token.
    uint256 internal constant MINT_PER_TOKEN = 10_000_000 ether;

    uint8 internal constant N_TOKENS = 4;
    string[4] internal SYMBOLS = ["sUSDA", "sUSDB", "sUSDC", "sUSDD"];

    function run() external {
        vm.startBroadcast();

        // 1) v4 PoolManager + Permit2
        address pmAddr = V4PoolManagerDeployer.deploy(msg.sender);
        IPoolManager poolManager = IPoolManager(pmAddr);
        IAllowanceTransfer permit2 = IAllowanceTransfer(Permit2Deployer.deploy());
        console2.log("PoolManager:", pmAddr);
        console2.log("Permit2:    ", address(permit2));

        // 2) Mock stables
        Currency[] memory assets = _deployTokens();

        // 3) OrbitalHook (CREATE2-mined). Deployer becomes initial admin.
        OrbitalHook hook = _deployHook(poolManager, permit2, assets, msg.sender);
        console2.log("OrbitalHook:", address(hook));
        console2.log("Admin:      ", msg.sender);

        // 4) Pair pools — N(N-1)/2 of them, all sharing the hook's engine state.
        _initializePools(poolManager, hook, assets);

        vm.stopBroadcast();
    }

    function _deployTokens() internal returns (Currency[] memory sorted) {
        MockERC20[] memory raw = new MockERC20[](N_TOKENS);
        for (uint8 i = 0; i < N_TOKENS; ++i) {
            MockERC20 token = new MockERC20(string.concat("Mock Stable ", SYMBOLS[i]), SYMBOLS[i], 18);
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
}
