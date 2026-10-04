// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {BandLib} from "../src/libraries/BandLib.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {FreezableToken} from "./utils/FreezableToken.sol";

/// @notice An issuer's emergency controls must not lock the whole pool.
///
///         Every stablecoin Orbital lists on Arbitrum can be stopped by its
///         issuer: paused outright, or with one address frozen. A withdrawal
///         pays out every asset, so if one token cannot move, an all-or-nothing
///         payout reverts every withdrawal and fee collection in the pool, for
///         everyone, until the issuer relents. These tests pin the fix: the
///         healthy assets are paid, the stuck one is held for the recipient
///         (`owed`), and `claimOwed` pays it once the token moves again.
contract IssuerFreezeTest is BaseTest {
    OrbitalHook hook;
    FreezableToken frz; // 6 decimals, like USDC, USDT0 and USDG
    MockERC20 a;
    MockERC20 b;
    Currency[] regd;
    uint8 fi; // the freezable token's asset index

    uint8 constant N = 3;
    uint256 constant MID = 19; // the 0.95 band
    uint256 constant R = 100_000 ether;
    address lpB = address(0xB0B);
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    function setUp() public {
        deployArtifactsAndLabel();
        a = deployToken();
        b = deployToken();
        frz = new FreezableToken(6);
        frz.mint(address(this), 10_000_000e6);
        frz.approve(address(swapRouter), type(uint256).max);

        address[3] memory t = [address(a), address(b), address(frz)];
        for (uint256 i = 0; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (t[j] < t[i]) (t[i], t[j]) = (t[j], t[i]);
            }
        }
        for (uint256 i = 0; i < N; ++i) regd.push(Currency.wrap(t[i]));

        address flagged = address(HOOK_FLAGS ^ (0x5151 << 144));
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, regd, uint24(100), address(this)), flagged
        );
        hook = OrbitalHook(flagged);
        fi = hook.indexOf(Currency.wrap(address(frz)));

        for (uint256 i = 0; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) poolManager.initialize(_key(uint8(i), uint8(j)), Constants.SQRT_PRICE_1_1);
        }

        // Two LPs in the same band: this contract and lpB.
        a.approve(address(hook), type(uint256).max);
        b.approve(address(hook), type(uint256).max);
        frz.approve(address(hook), type(uint256).max);
        hook.addLiquidity(MID, R, _max(), block.timestamp);

        a.transfer(lpB, 1_000_000 ether);
        b.transfer(lpB, 1_000_000 ether);
        frz.transfer(lpB, 1_000_000e6);
        vm.startPrank(lpB);
        a.approve(address(hook), type(uint256).max);
        b.approve(address(hook), type(uint256).max);
        frz.approve(address(hook), type(uint256).max);
        hook.addLiquidity(MID, R, _max(), block.timestamp);
        vm.stopPrank();
    }

    /// @notice A paused token: the withdrawal still pays every other asset,
    ///         and the paused one is held for the LP — not lost, not stuck.
    function test_paused_token_does_not_block_withdrawal() public {
        frz.pause(true);

        uint256[3] memory before = _balances(address(this));
        uint256[] memory amounts = hook.removeLiquidity(MID, R / 2, new uint256[](N), block.timestamp);

        uint256 expectFrz = amounts[fi] / hook.scaleOf(fi);
        assertGt(expectFrz, 0, "the burn should owe some of the paused token");
        for (uint8 i = 0; i < N; ++i) {
            uint256 got = _balanceOf(i, address(this)) - before[i];
            if (i == fi) assertEq(got, 0, "a paused token moved");
            else assertEq(got, amounts[i] / hook.scaleOf(i), "a healthy asset was not paid");
        }
        assertEq(hook.owed(address(this), fi), expectFrz, "the paused payout was not held for the LP");
        assertEq(hook.totalOwed(fi), expectFrz, "totalOwed");

        // While the token stays paused, the claim reverts and stands.
        vm.expectRevert();
        hook.claimOwed(fi);
        assertEq(hook.owed(address(this), fi), expectFrz, "a failed claim changed the claim");

        // Once it moves again, the claim pays exactly what was held.
        frz.pause(false);
        uint256 frzBefore = frz.balanceOf(address(this));
        assertEq(hook.claimOwed(fi), expectFrz, "claimOwed return");
        assertEq(frz.balanceOf(address(this)) - frzBefore, expectFrz, "claimOwed paid other than what was owed");
        assertEq(hook.owed(address(this), fi), 0, "claim not cleared");
        assertEq(hook.totalOwed(fi), 0, "totalOwed not cleared");

        vm.expectRevert(OrbitalHook.NothingOwed.selector);
        hook.claimOwed(fi);
    }

    /// @notice An issuer freezing one LP's address affects that LP alone:
    ///         their payout of that token is held; everyone else is paid in full.
    function test_frozen_lp_defers_only_its_own_payout() public {
        frz.freeze(lpB, true);

        vm.prank(lpB);
        hook.removeLiquidity(MID, R, new uint256[](N), block.timestamp);
        assertGt(hook.owed(lpB, fi), 0, "the frozen LP's payout was not held");

        uint256 frzBefore = frz.balanceOf(address(this));
        uint256[] memory amounts = hook.removeLiquidity(MID, R, new uint256[](N), block.timestamp);
        assertEq(frz.balanceOf(address(this)) - frzBefore, amounts[fi] / hook.scaleOf(fi), "an unfrozen LP was not paid");
        assertEq(hook.owed(address(this), fi), 0, "an unfrozen LP was deferred");
    }

    /// @notice The issuer freezing the PoolManager itself (the address every
    ///         v4 pool's tokens sit in) stops that token everywhere, but LPs can
    ///         still leave with the rest, and pairs without it keep trading.
    function test_frozen_pool_manager_still_lets_lps_exit() public {
        frz.freeze(address(poolManager), true);

        hook.removeLiquidity(MID, R / 4, new uint256[](N), block.timestamp);
        assertGt(hook.owed(address(this), fi), 0, "payout not held");

        (uint8 x, uint8 y) = fi == 0 ? (1, 2) : fi == 1 ? (0, 2) : (0, 1);
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, _key(x, y), "", address(this), block.timestamp);

        (uint8 lo, uint8 hi) = fi < x ? (fi, x) : (x, fi);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(1 ether, 0, fi == lo, _key(lo, hi), "", address(this), block.timestamp);
    }

    /// @notice Fee collection holds a frozen token's fees the same way.
    function test_collect_defers_a_paused_fee() public {
        (uint8 lo, uint8 hi) = fi == 0 ? (0, 1) : (0, fi);
        // Sell the freezable token in, so fees accrue in it.
        swapRouter.swapExactTokensForTokens(1_000e6, 0, fi == lo, _key(lo, hi), "", address(this), block.timestamp);

        frz.pause(true);
        hook.collect(MID);
        uint256 held = hook.owed(address(this), fi);
        assertGt(held, 0, "the paused fee was not held");

        frz.pause(false);
        assertEq(hook.claimOwed(fi), held, "claimOwed");
    }

    /// @notice What is held back stays the recipient's: once the token moves
    ///         again, swaps draining it cannot reach the held payout.
    function test_held_payout_is_not_swappable() public {
        frz.pause(true);
        hook.removeLiquidity(MID, R, new uint256[](N), block.timestamp);
        uint256 held = hook.owed(address(this), fi);
        frz.pause(false);

        // Buy out as much of the freezable token as the pool will sell.
        (uint8 other, bool zeroForOne) = fi == 0 ? (uint8(1), false) : (uint8(0), true);
        (uint8 lo, uint8 hi) = fi < other ? (fi, other) : (other, fi);
        for (uint256 k = 0; k < 8; ++k) {
            try swapRouter.swapExactTokensForTokens(
                20_000 ether, 0, zeroForOne, _key(lo, hi), "", address(this), block.timestamp
            ) {} catch {
                break;
            }
        }

        uint256 before = frz.balanceOf(address(this));
        assertEq(hook.claimOwed(fi), held, "claimOwed");
        assertEq(frz.balanceOf(address(this)) - before, held, "the held payout was spent by swaps");
    }

    // ── helpers ──

    function _key(uint8 i, uint8 j) internal view returns (PoolKey memory) {
        return PoolKey({currency0: regd[i], currency1: regd[j], fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
    }

    function _max() internal pure returns (uint256[] memory m) {
        m = new uint256[](N);
        for (uint256 i = 0; i < N; ++i) m[i] = type(uint256).max;
    }

    function _balanceOf(uint8 i, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(regd[i])).balanceOf(who);
    }

    function _balances(address who) internal view returns (uint256[3] memory out) {
        for (uint8 i = 0; i < N; ++i) out[i] = _balanceOf(i, who);
    }
}
