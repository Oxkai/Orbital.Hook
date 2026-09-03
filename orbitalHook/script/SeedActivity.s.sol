// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";

/// @notice Generates realistic activity on a live Orbital deployment: swap waves,
///         a mid-run re-seed at a fresh depeg bound, then more swaps.
///
/// @dev SELF-DESCRIBING. Earlier versions pinned the hook, router and all four
///      token addresses as constants, which silently rotted the moment anything
///      was redeployed. This reads the asset set off the hook (`N`, `assetAt`) and
///      each token's own `decimals()`, so it stays correct across redeploys and
///      across chains with different decimal mixes. Only the hook and router come
///      from the environment.
///
///      Required env: ORBITAL_HOOK, V4_ROUTER
///
///      forge script script/SeedActivity.s.sol --rpc-url base_sepolia \
///          --broadcast --slow --private-key $PRIVATE_KEY
contract SeedActivityScript is Script {
    OrbitalHook hook;
    IUniswapV4Router04 router;
    uint8 n;
    address[] toks;
    uint8[] decs;

    function run() external {
        hook = OrbitalHook(vm.envAddress("ORBITAL_HOOK"));
        router = IUniswapV4Router04(payable(vm.envAddress("V4_ROUTER")));

        n = hook.N();
        for (uint8 i = 0; i < n; ++i) {
            address t = Currency.unwrap(hook.assetAt(i));
            toks.push(t);
            decs.push(IERC20(t).decimals());
        }

        vm.startBroadcast();

        for (uint8 i = 0; i < n; ++i) {
            IERC20(toks[i]).approve(address(router), type(uint256).max);
            IERC20(toks[i]).approve(address(hook), type(uint256).max);
        }

        console2.log("--- T0: initial state ---");
        _logState();

        // T1 - small, roughly balanced swaps. Sized in each token's own units so a
        // 6-decimal asset is not accidentally traded 1e12x too large.
        _swap(0, 1, 12_000);
        _swap(1, 0, 9_000);
        _swap(2, 3, 10_000);
        _swap(3, 2, 8_000);
        _swap(0, 2, 7_000);
        _swap(1, 3, 6_000);
        console2.log("--- T1: after first swap wave ---");
        _logState();

        // T2 - add a tick at a fresh depeg bound. Valid only while the pool is
        // all-interior (kBound == 0), which the gentle wave above preserves.
        _seedTier(2_000_000 ether, 0.88e18);
        console2.log("--- T2: re-seeded at depeg 0.88 ---");
        _logState();

        // T3 - second wave.
        _swap(2, 0, 8_000);
        _swap(3, 1, 7_000);
        _swap(0, 3, 6_000);
        _swap(1, 2, 9_000);
        _swap(2, 1, 7_000);

        vm.stopBroadcast();

        console2.log("--- final state ---");
        _logState();
    }

    /// @param whole Amount in WHOLE tokens; scaled into the input token's decimals.
    function _swap(uint8 i, uint8 j, uint256 whole) internal {
        if (i >= n || j >= n) return;
        address tin = toks[i];
        address tout = toks[j];
        uint256 amountIn = whole * (10 ** uint256(decs[i]));

        (address c0, address c1) = tin < tout ? (tin, tout) : (tout, tin);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        // Generous deadline: each broadcast tx lands in its own block, so a
        // tight one passes in simulation and then reverts on-chain.
        router.swapExactTokensForTokens(
            amountIn, 0, tin == c0, key, "", msg.sender, block.timestamp + 1 hours
        );
    }

    function _seedTier(uint256 rWad, uint256 depegWad) internal {
        uint256 k = TickLib.kFromDepegPrice(rWad, n, depegWad);
        uint256[] memory maxA = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) maxA[i] = type(uint256).max;
        hook.addLiquidity(k, rWad, maxA);
    }

    function _logState() internal view {
        (uint256 sumX,, uint256 rInt, uint256 kBound,) = hook.slot0();
        console2.log("  numTicks:", hook.numTicks(), "rInt:", rInt);
        console2.log("  sumX(TVL wad):", sumX, "kBound:", kBound);
        for (uint8 i = 0; i < n; ++i) {
            console2.log("  reserve(wad)", i, hook.reserves(i));
        }
    }
}
