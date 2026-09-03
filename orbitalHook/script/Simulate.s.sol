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

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";
import {SphereMath} from "../src/libraries/SphereMath.sol";

/// @notice End-to-end protocol simulation:
///         deploy → addLiquidity → swap(s) → collect → removeLiquidity.
///         Logs state after each phase so the lifecycle is auditable from the console.
///
/// @dev Run against a fresh anvil:
///         anvil &
///         forge script script/Simulate.s.sol --rpc-url http://localhost:8545 \
///             --broadcast --private-key $PRIVATE_KEY -vv
contract SimulateScript is Script {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant POOL_FEE = 100; // 1 bp
    uint8 internal constant N_TOKENS = 4;
    uint256 internal constant MINT_PER_TOKEN = 10_000_000 ether;
    uint256 internal constant SEED_R = 100_000 ether;
    uint256 internal constant SWAP_AMOUNT = 100 ether;
    uint256 internal constant BURN_R = 50_000 ether;

    string[4] internal SYMBOLS = ["sUSDA", "sUSDB", "sUSDC", "sUSDD"];

    function run() external {
        vm.startBroadcast();

        // ---------- 1. Infra ----------
        IPermit2 permit2 = IPermit2(Permit2Deployer.deploy());
        IPoolManager poolManager = IPoolManager(V4PoolManagerDeployer.deploy(msg.sender));
        IUniswapV4Router04 swapRouter =
            IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(poolManager), address(permit2))));

        console2.log("== Infra deployed ==");
        console2.log("Permit2:    ", address(permit2));
        console2.log("PoolManager:", address(poolManager));
        console2.log("SwapRouter: ", address(swapRouter));

        // ---------- 2. Tokens ----------
        Currency[] memory assets = _deployAndApproveTokens(permit2, swapRouter);

        // ---------- 3. Hook ----------
        OrbitalHook hook = _deployHook(poolManager, permit2, assets);
        console2.log("OrbitalHook:", address(hook));

        // Approve hook for direct LP deposits (addLiquidity pulls via transferFrom).
        for (uint256 i = 0; i < assets.length; ++i) {
            MockERC20(Currency.unwrap(assets[i])).approve(address(hook), type(uint256).max);
        }

        // ---------- 4. Pools ----------
        PoolKey[6] memory keys = _initializePools(poolManager, hook, assets);

        _logHeader("STATE BEFORE LIQUIDITY");
        _logEngine(hook);

        // ---------- 5. Add Liquidity ----------
        uint256 kWad = (TickLib.kMin(SEED_R, N_TOKENS) + TickLib.kMax(SEED_R, N_TOKENS)) / 2;
        uint256[] memory maxA = new uint256[](N_TOKENS);
        for (uint256 i = 0; i < N_TOKENS; ++i) maxA[i] = type(uint256).max;

        (uint256 tickIdx, uint256[] memory amounts) = hook.addLiquidity(kWad, SEED_R, maxA);
        _logHeader("STATE AFTER addLiquidity");
        console2.log("  tickIdx :", tickIdx);
        console2.log("  rWad    :", SEED_R);
        console2.log("  kWad    :", kWad);
        for (uint256 i = 0; i < N_TOKENS; ++i) {
            console2.log(string.concat("  pulled[", SYMBOLS[i], "]:"), amounts[i]);
        }
        console2.log("  shares balance:", hook.balanceOf(msg.sender, tickIdx));
        _logEngine(hook);

        // ---------- 6. Swaps ----------
        // (a) c0 -> c1 on the first pair
        _logHeader("SWAP sUSDA -> sUSDB via pair (0,1)");
        _doSwap(swapRouter, keys[0], true, assets[0], assets[1]);
        _logEngine(hook);

        // (b) c1 -> c2 on a different pair-view — exercises shared state
        _logHeader("SWAP sUSDB -> sUSDC via pair (1,2)");
        _doSwap(swapRouter, _pairKey(assets[1], assets[2], hook), true, assets[1], assets[2]);
        _logEngine(hook);

        // (c) Reverse: c2 -> c1
        _logHeader("SWAP sUSDC -> sUSDB via pair (1,2)");
        _doSwap(swapRouter, _pairKey(assets[1], assets[2], hook), false, assets[2], assets[1]);
        _logEngine(hook);

        // ---------- 7. Collect ----------
        _logHeader("COLLECT FEES");
        uint256[] memory fees = hook.collect(tickIdx);
        for (uint256 i = 0; i < N_TOKENS; ++i) {
            console2.log(string.concat("  fees[", SYMBOLS[i], "]:"), fees[i]);
        }
        _logEngine(hook);

        // ---------- 8. Remove Liquidity (partial) ----------
        _logHeader("REMOVE LIQUIDITY (half)");
        uint256[] memory minA = new uint256[](N_TOKENS);
        uint256[] memory returned = hook.removeLiquidity(tickIdx, BURN_R, minA);
        for (uint256 i = 0; i < N_TOKENS; ++i) {
            console2.log(string.concat("  returned[", SYMBOLS[i], "]:"), returned[i]);
        }
        console2.log("  shares balance:", hook.balanceOf(msg.sender, tickIdx));
        _logEngine(hook);

        vm.stopBroadcast();
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

    function _deployAndApproveTokens(IPermit2 permit2, IUniswapV4Router04 swapRouter)
        internal
        returns (Currency[] memory sorted)
    {
        MockERC20[] memory raw = new MockERC20[](N_TOKENS);
        for (uint8 i = 0; i < N_TOKENS; ++i) {
            MockERC20 t = new MockERC20(string.concat("Mock Stable ", SYMBOLS[i]), SYMBOLS[i], 18);
            t.mint(msg.sender, MINT_PER_TOKEN);
            raw[i] = t;
        }
        // sort ascending
        for (uint8 i = 0; i < N_TOKENS; ++i) {
            for (uint8 j = uint8(i + 1); j < N_TOKENS; ++j) {
                if (address(raw[j]) < address(raw[i])) (raw[i], raw[j]) = (raw[j], raw[i]);
            }
        }
        sorted = new Currency[](N_TOKENS);
        for (uint8 i = 0; i < N_TOKENS; ++i) {
            // After sorting we don't know which original symbol mapped to which slot,
            // so re-label by position for the run.
            SYMBOLS[i] = SYMBOLS[i]; // placeholder, kept for clarity in logs
            sorted[i] = Currency.wrap(address(raw[i]));

            // Approve both paths the v4 router may use:
            //  - direct ERC-20 allowance (hookmate's router pulls inputs this way)
            //  - permit2 allowance (for any code that prefers the permit2 surface)
            raw[i].approve(address(permit2), type(uint256).max);
            raw[i].approve(address(swapRouter), type(uint256).max);
            permit2.approve(address(raw[i]), address(swapRouter), type(uint160).max, type(uint48).max);
        }
    }

    function _deployHook(IPoolManager poolManager, IPermit2 permit2, Currency[] memory assets)
        internal
        returns (OrbitalHook hook)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory ctorArgs = abi.encode(poolManager, permit2, assets, POOL_FEE, msg.sender);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(OrbitalHook).creationCode, ctorArgs);
        hook = new OrbitalHook{salt: salt}(poolManager, permit2, assets, POOL_FEE, msg.sender);
        require(address(hook) == expected, "hook addr mismatch");
    }

    function _initializePools(IPoolManager poolManager, OrbitalHook hook, Currency[] memory assets)
        internal
        returns (PoolKey[6] memory keys)
    {
        uint256 idx;
        for (uint256 i = 0; i < N_TOKENS; ++i) {
            for (uint256 j = i + 1; j < N_TOKENS; ++j) {
                keys[idx] = PoolKey({
                    currency0: assets[i],
                    currency1: assets[j],
                    fee: 0,
                    tickSpacing: 1,
                    hooks: IHooks(address(hook))
                });
                poolManager.initialize(keys[idx], SQRT_PRICE_1_1);
                ++idx;
            }
        }
    }

    function _pairKey(Currency a, Currency b, OrbitalHook hook) internal pure returns (PoolKey memory) {
        (Currency lo, Currency hi) =
            Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return
            PoolKey({currency0: lo, currency1: hi, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
    }

    function _doSwap(IUniswapV4Router04 swapRouter, PoolKey memory key, bool zeroForOne, Currency cIn, Currency cOut)
        internal
    {
        uint256 balInBefore = MockERC20(Currency.unwrap(cIn)).balanceOf(msg.sender);
        uint256 balOutBefore = MockERC20(Currency.unwrap(cOut)).balanceOf(msg.sender);
        swapRouter.swapExactTokensForTokens(SWAP_AMOUNT, 0, zeroForOne, key, "", msg.sender, block.timestamp + 1 hours);
        uint256 paid = balInBefore - MockERC20(Currency.unwrap(cIn)).balanceOf(msg.sender);
        uint256 got = MockERC20(Currency.unwrap(cOut)).balanceOf(msg.sender) - balOutBefore;
        console2.log("  paid in :", paid);
        console2.log("  got out :", got);
    }

    function _logHeader(string memory tag) internal pure {
        console2.log("");
        console2.log("==", tag, "==");
    }

    function _logEngine(OrbitalHook hook) internal view {
        (uint256 sumX, uint256 sumXSq, uint256 rInt, uint256 kBound, uint256 sBound) = hook.slot0();
        console2.log("  rInt    :", rInt);
        console2.log("  sumX    :", sumX);
        console2.log("  sumXSq  :", sumXSq);
        console2.log("  kBound  :", kBound);
        console2.log("  sBound  :", sBound);
        for (uint8 i = 0; i < N_TOKENS; ++i) {
            console2.log(
                string.concat("  reserves[", SYMBOLS[i], "]:"),
                hook.reserves(i),
                "fees:",
                hook.feesAccrued(i)
            );
        }
    }
}
