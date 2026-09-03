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

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Multi-LP activity against a LIVE deployment.
///
/// @dev    `SimulateMultiLP.s.sol` proves the same flows but only on anvil: it
///         relies on anvil's pre-unlocked accounts, so a live pool ends up with a
///         single LP (the deployer) and the Positions page has nothing
///         interesting in it. This script derives three LP accounts plus a
///         swapper deterministically, funds them a little gas from the deployer,
///         lets them self-mint the mock stables, and has each LP take a DIFFERENT
///         tick so the pool genuinely has several independent positions.
///
///         Self-describing: the asset set and decimals are read off the hook, so
///         it survives redeploys and differing decimal mixes per chain.
///
///         Required env: ORBITAL_HOOK, V4_ROUTER
///         Optional env: GAS_PER_ACTOR (wei, default 0.004 ether)
contract SimulateMultiLPLiveScript is Script {
    OrbitalHook hook;
    IUniswapV4Router04 router;
    uint8 n;
    address[] toks;
    uint8[] decs;

    // Deterministic throwaway actors. Derived, not hardcoded, so this file
    // carries no key material and the addresses follow from the label alone.
    uint256 constant PK_ALICE = uint256(keccak256("orbital.live.lp.alice"));
    uint256 constant PK_BOB = uint256(keccak256("orbital.live.lp.bob"));
    uint256 constant PK_CAROL = uint256(keccak256("orbital.live.lp.carol"));
    uint256 constant PK_SWAPPER = uint256(keccak256("orbital.live.swapper"));

    function run() external {
        hook = OrbitalHook(vm.envAddress("ORBITAL_HOOK"));
        router = IUniswapV4Router04(payable(vm.envAddress("V4_ROUTER")));
        uint256 gasPerActor = vm.envOr("GAS_PER_ACTOR", uint256(0.004 ether));

        n = hook.N();
        for (uint8 i = 0; i < n; ++i) {
            address t = Currency.unwrap(hook.assetAt(i));
            toks.push(t);
            decs.push(IERC20(t).decimals());
        }

        address alice = vm.addr(PK_ALICE);
        address bob = vm.addr(PK_BOB);
        address carol = vm.addr(PK_CAROL);
        address swapper = vm.addr(PK_SWAPPER);

        console2.log("=== actors ===");
        console2.log("  alice  ", alice);
        console2.log("  bob    ", bob);
        console2.log("  carol  ", carol);
        console2.log("  swapper", swapper);
        _logState("initial");

        // ── fund gas ──
        vm.startBroadcast();
        _fund(alice, gasPerActor);
        _fund(bob, gasPerActor);
        _fund(carol, gasPerActor);
        _fund(swapper, gasPerActor);
        vm.stopBroadcast();

        // ── three LPs, three DIFFERENT ticks ──
        uint256 tAlice = _lpJoin(PK_ALICE, 600_000 ether, 0.96e18, "alice");
        uint256 tBob = _lpJoin(PK_BOB, 400_000 ether, 0.91e18, "bob");
        uint256 tCarol = _lpJoin(PK_CAROL, 250_000 ether, 0.86e18, "carol");
        _logState("after three LPs joined");

        // ── swap wave (fees accrue to every interior tick, pro-rata by radius) ──
        _swapAs(PK_SWAPPER, 0, 1, 25_000);
        _swapAs(PK_SWAPPER, 1, 2, 18_000);
        _swapAs(PK_SWAPPER, 2, 3, 12_000);
        _swapAs(PK_SWAPPER, 3, 0, 9_000);
        _swapAs(PK_SWAPPER, 0, 2, 15_000);
        _logState("after swap wave");

        // ── each LP collects their own share ──
        _collect(PK_ALICE, tAlice, "alice");
        _collect(PK_BOB, tBob, "bob");
        _collect(PK_CAROL, tCarol, "carol");

        // ── partial exits, leaving live positions behind ──
        _burnHalf(PK_ALICE, tAlice, "alice");
        _burnHalf(PK_BOB, tBob, "bob");
        _logState("final");

        console2.log("=== positions left live ===");
        console2.log("  alice @tick", tAlice, hook.balanceOf(alice, tAlice));
        console2.log("  bob   @tick", tBob, hook.balanceOf(bob, tBob));
        console2.log("  carol @tick", tCarol, hook.balanceOf(carol, tCarol));
    }

    // ─────────────────────────────────────────────────────────────

    function _fund(address to, uint256 amount) internal {
        if (to.balance >= amount) return;
        (bool ok,) = to.call{value: amount - to.balance}("");
        require(ok, "gas funding failed");
    }

    /// @dev Self-mint the mocks, approve, then take a tick at `depeg`.
    function _lpJoin(uint256 pk, uint256 rWad, uint256 depeg, string memory who)
        internal
        returns (uint256 tickIdx)
    {
        address me = vm.addr(pk);
        vm.startBroadcast(pk);
        for (uint8 i = 0; i < n; ++i) {
            // Pro-rata deposits scale with the pool, so mint generously.
            IMintable(toks[i]).mint(me, 5_000_000 * (10 ** uint256(decs[i])));
            IERC20(toks[i]).approve(address(hook), type(uint256).max);
        }
        uint256 k = TickLib.kFromDepegPrice(rWad, n, depeg);
        uint256[] memory maxA = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) maxA[i] = type(uint256).max;
        (tickIdx,) = hook.addLiquidity(k, rWad, maxA);
        vm.stopBroadcast();
        console2.log(string.concat("  ", who, " joined tick"), tickIdx, "r:", rWad);
    }

    function _swapAs(uint256 pk, uint8 i, uint8 j, uint256 whole) internal {
        if (i >= n || j >= n) return;
        address me = vm.addr(pk);
        address tin = toks[i];
        address tout = toks[j];
        uint256 amountIn = whole * (10 ** uint256(decs[i]));

        vm.startBroadcast(pk);
        IMintable(tin).mint(me, amountIn);
        IERC20(tin).approve(address(router), type(uint256).max);
        (address c0, address c1) = tin < tout ? (tin, tout) : (tout, tin);
        router.swapExactTokensForTokens(
            amountIn,
            0,
            tin == c0,
            PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: 0,
                tickSpacing: 1,
                hooks: IHooks(address(hook))
            }),
            "",
            me,
            block.timestamp + 1 hours
        );
        vm.stopBroadcast();
    }

    function _collect(uint256 pk, uint256 tickIdx, string memory who) internal {
        vm.startBroadcast(pk);
        try hook.collect(tickIdx) returns (uint256[] memory fees) {
            uint256 total;
            for (uint8 i = 0; i < n; ++i) total += fees[i];
            console2.log(string.concat("  ", who, " collected (summed wad):"), total);
        } catch {
            console2.log(string.concat("  ", who, " had nothing to collect"));
        }
        vm.stopBroadcast();
    }

    function _burnHalf(uint256 pk, uint256 tickIdx, string memory who) internal {
        address me = vm.addr(pk);
        uint256 bal = hook.balanceOf(me, tickIdx);
        if (bal == 0) return;
        vm.startBroadcast(pk);
        hook.removeLiquidity(tickIdx, bal / 2, new uint256[](n));
        vm.stopBroadcast();
        console2.log(string.concat("  ", who, " burned half, left:"), hook.balanceOf(me, tickIdx));
    }

    function _logState(string memory tag) internal view {
        (uint256 sumX,, uint256 rInt, uint256 kBound,) = hook.slot0();
        console2.log(string.concat("--- ", tag, " ---"));
        console2.log("  numTicks:", hook.numTicks(), "rInt:", rInt);
        console2.log("  sumX(TVL wad):", sumX, "kBound:", kBound);
    }
}
