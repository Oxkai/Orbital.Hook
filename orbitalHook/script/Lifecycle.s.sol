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

/// @notice Full LP lifecycle against a live deployment: add at a fresh tick ->
///         swap wave -> collect -> partial burn -> full burn -> verify the freed
///         tick slot is recycled -> add again -> burn.
///
/// @dev Self-describing for the same reason as SeedActivity: it reads the asset
///      set and decimals off the hook rather than pinning addresses that go stale
///      on the next redeploy.
///
///      Required env: ORBITAL_HOOK, V4_ROUTER
contract LifecycleScript is Script {
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

        console2.log("==== START ====");
        _logState();
        uint256 ticksAtStart = hook.numTicks();

        console2.log(">>> STEP 1: add at a fresh depeg bound (0.92)");
        uint256 tick1 = _addTier(500_000 ether, 0.92e18);
        console2.log("    tickIdx:", tick1, "LP bal:", hook.balanceOf(msg.sender, tick1));

        console2.log(">>> STEP 2: swap wave to accrue fees on every asset");
        _swap(0, 1, 5_000);
        _swap(2, 3, 4_000);
        _swap(1, 0, 6_000);
        _swap(3, 2, 3_000);
        _logState();

        console2.log(">>> STEP 3: collect");
        try hook.collect(tick1) returns (uint256[] memory fees) {
            for (uint8 i = 0; i < n; ++i) console2.log("    fee(wad) asset", i, fees[i]);
        } catch {
            console2.log("    (nothing owed yet)");
        }

        console2.log(">>> STEP 4: partial burn (50%)");
        _burn(tick1, hook.balanceOf(msg.sender, tick1) / 2);
        console2.log("    remaining:", hook.balanceOf(msg.sender, tick1));

        console2.log(">>> STEP 5: full burn");
        _burn(tick1, hook.balanceOf(msg.sender, tick1));
        console2.log("    remaining:", hook.balanceOf(msg.sender, tick1));

        console2.log(">>> STEP 6: add at 0.83 - should recycle the freed slot");
        uint256 before = hook.numTicks();
        uint256 tick2 = _addTier(300_000 ether, 0.83e18);
        console2.log("    numTicks before/after:", before, hook.numTicks());
        require(hook.numTicks() == before, "free-list should recycle, not grow the array");

        console2.log(">>> STEP 7: clean up");
        _burn(tick2, hook.balanceOf(msg.sender, tick2));

        vm.stopBroadcast();

        _logState();
        console2.log("==== END ====  ticks start/end:", ticksAtStart, hook.numTicks());
    }

    function _swap(uint8 i, uint8 j, uint256 whole) internal {
        if (i >= n || j >= n) return;
        address tin = toks[i];
        address tout = toks[j];
        (address c0, address c1) = tin < tout ? (tin, tout) : (tout, tin);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        router.swapExactTokensForTokens(
            whole * (10 ** uint256(decs[i])), 0, tin == c0, key, "", msg.sender, block.timestamp + 1 hours
        );
    }

    function _addTier(uint256 rWad, uint256 depegWad) internal returns (uint256 tickIdx) {
        uint256 k = TickLib.kFromDepegPrice(rWad, n, depegWad);
        uint256[] memory maxA = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) maxA[i] = type(uint256).max;
        (tickIdx,) = hook.addLiquidity(k, rWad, maxA);
    }

    function _burn(uint256 tickIdx, uint256 rWad) internal {
        if (rWad == 0) return;
        hook.removeLiquidity(tickIdx, rWad, new uint256[](n));
    }

    function _logState() internal view {
        (uint256 sumX,, uint256 rInt, uint256 kBound,) = hook.slot0();
        console2.log("    numTicks:", hook.numTicks(), "rInt:", rInt);
        console2.log("    sumX(TVL wad):", sumX, "kBound:", kBound);
    }
}
