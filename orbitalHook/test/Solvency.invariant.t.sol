// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";
import {BaseTest} from "./utils/BaseTest.sol";

interface IERC6909Balance {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

/// @notice Stateful invariant: the hook must always stay SOLVENT. For every asset,
///         the real claim-token balance the hook holds in the PoolManager must cover
///         everything it owes — the tracked reserves plus accrued fees. A random
///         sequence of add/swap/remove/collect (including depeg crossings) must never
///         create phantom value or let the pool owe more than it holds.
contract SolvencyInvariant is BaseTest {
    OrbitalHook hook;
    Currency[3] assets;
    PoolKey key01;
    uint256[] heldTicks;

    uint8 constant N = 3;
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    function setUp() public {
        deployArtifactsAndLabel();

        // Three 18-decimal tokens, sorted ascending by address.
        MockERC20[3] memory t = [deployToken(), deployToken(), deployToken()];
        for (uint256 i = 0; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (address(t[j]) < address(t[i])) (t[i], t[j]) = (t[j], t[i]);
            }
        }
        Currency[] memory regd = new Currency[](N);
        for (uint256 i = 0; i < N; ++i) {
            assets[i] = Currency.wrap(address(t[i]));
            regd[i] = assets[i];
        }

        address flagged = address(HOOK_FLAGS);
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook",
            abi.encode(poolManager, permit2, regd, uint24(100), address(this)),
            flagged
        );
        hook = OrbitalHook(flagged);

        for (uint256 i = 0; i < N; ++i) {
            t[i].approve(address(hook), type(uint256).max);
        }

        // Initialize the (asset0, asset1) pool so the handler can swap against it.
        key01 = PoolKey({
            currency0: assets[0],
            currency1: assets[1],
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(flagged)
        });
        poolManager.initialize(key01, Constants.SQRT_PRICE_1_1);

        // Seed a wide base position so swaps have depth from the start.
        uint256 r0 = 1_000_000 ether;
        uint256 k0 = (TickLib.kMin(r0, N) + TickLib.kMax(r0, N)) / 2;
        (uint256 tick0,) = hook.addLiquidity(k0, r0, _maxAmounts());
        heldTicks.push(tick0);

        // Restrict the fuzzer to the four handler entry points.
        bytes4[] memory sel = new bytes4[](4);
        sel[0] = this.h_add.selector;
        sel[1] = this.h_swap.selector;
        sel[2] = this.h_remove.selector;
        sel[3] = this.h_collect.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    // ── Handlers (reverts are swallowed: invalid random inputs just no-op) ──

    function h_add(uint256 rSeed, uint256 kSeed) public {
        uint256 r = bound(rSeed, 1 ether, 100_000 ether);
        uint256 k = bound(kSeed, TickLib.kMin(r, N), TickLib.kMax(r, N));
        try hook.addLiquidity(k, r, _maxAmounts()) returns (uint256 tickIdx, uint256[] memory) {
            _track(tickIdx);
        } catch {}
    }

    function h_swap(uint256 amtSeed, uint256 dirSeed) public {
        bool zeroForOne = dirSeed % 2 == 0;
        uint8 inIdx = zeroForOne ? 0 : 1;
        uint256 res = hook.reserves(inIdx);
        if (res < 2 ether) return;
        uint256 amt = bound(amtSeed, 1 ether, res / 2);
        try swapRouter.swapExactTokensForTokens(amt, 0, zeroForOne, key01, "", address(this), block.timestamp) {} catch {}
    }

    function h_remove(uint256 tickSeed, uint256 rSeed) public {
        if (heldTicks.length == 0) return;
        uint256 tick = heldTicks[tickSeed % heldTicks.length];
        uint256 bal = hook.balanceOf(address(this), tick);
        if (bal == 0) return;
        uint256 r = bound(rSeed, 1, bal);
        try hook.removeLiquidity(tick, r, new uint256[](N)) {} catch {}
    }

    function h_collect(uint256 tickSeed) public {
        if (heldTicks.length == 0) return;
        uint256 tick = heldTicks[tickSeed % heldTicks.length];
        // NothingOwed is fine, but FeeBucketShort would mean total owed fees
        // exceeded the bucket — the exact symptom of fee over-attribution (#1).
        try hook.collect(tick) {}
        catch (bytes memory reason) {
            if (reason.length >= 4) {
                assertTrue(bytes4(reason) != OrbitalHook.FeeBucketShort.selector, "FeeBucketShort: fee over-attribution");
            }
        }
    }

    // ── The invariant ──

    function invariant_pool_is_solvent() public view {
        for (uint8 i = 0; i < N; ++i) {
            uint256 id = uint256(uint160(Currency.unwrap(assets[i])));
            uint256 claim = IERC6909Balance(address(poolManager)).balanceOf(address(hook), id);
            uint256 owed = hook.reserves(i) + hook.feesAccrued(i);
            // scale == 1 here (18-decimal tokens), so claim and owed are both WAD.
            assertGe(claim, owed, "pool owes more than it holds");
        }
    }

    // ── helpers ──

    function _maxAmounts() internal pure returns (uint256[] memory m) {
        m = new uint256[](N);
        for (uint256 i = 0; i < N; ++i) m[i] = type(uint256).max;
    }

    function _track(uint256 t) internal {
        for (uint256 i = 0; i < heldTicks.length; ++i) {
            if (heldTicks[i] == t) return;
        }
        heldTicks.push(t);
    }
}
