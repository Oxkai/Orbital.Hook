// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice Large and tier-crossing swaps against realistic tick ladders.
///
/// @dev    REGRESSIONS covered:
///         1. The Newton solver stepped outside the torus domain after a tick
///            crossing (`TorusMath.AlphaBelowKBound`), so any trade of ~5% of
///            a reserve reverted.
///         2. A trade could move the LAST interior tick to its boundary,
///            leaving rInt = 0: no swap can run there, not even the reverse
///            trade, and mint and burn are blocked, locking every LP. Only
///            rounding stopped it; it is now refused as `SwapExceedsLiquidity`.
contract SolverRobustnessTest is BaseTest {
    uint8 constant N = 4;
    uint24 constant FEE = 100;
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    Currency[] regd;
    MockERC20[4] tok;
    OrbitalHook hook;

    function setUp() public {
        deployArtifactsAndLabel();
        MockERC20[4] memory t =
            [deployTokenWithDecimals(18), deployTokenWithDecimals(18), deployTokenWithDecimals(18), deployTokenWithDecimals(18)];
        for (uint256 i; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (address(t[j]) < address(t[i])) (t[i], t[j]) = (t[j], t[i]);
            }
        }
        for (uint256 i; i < N; ++i) {
            regd.push(Currency.wrap(address(t[i])));
            tok[i] = t[i];
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Concentrated ladder (every tier a band): trades past it are refused
    // ═════════════════════════════════════════════════════════════

    /// @dev The ladder the deploy scripts used before the full-range backstop.
    function _bandLadder() internal {
        _pool(0x5151);
        _seed([uint256(5_000_000 ether), 4_000_000 ether, 2_000_000 ether, 1_000_000 ether], [uint256(0.97e18), 0.93e18, 0.88e18, 0.80e18]);
    }

    function test_a_trade_through_several_tiers_settles_and_reverses() public {
        _bandLadder();
        (uint256 rInt0,,) = _radii();

        // ~3% of a reserve moves the pool through the first tiers.
        uint256 out = _swap(0, 1, hook.reserves(0) * 3 / 100);
        (uint256 rIntAfter, uint256 kBoundAfter,) = _radii();
        assertLt(rIntAfter, rInt0, "fixture: no tier crossed");
        assertGt(kBoundAfter, 0, "fixture: no boundary liquidity");

        // The reverse trade walks the same tiers back to interior.
        _swap(1, 0, out);
        (uint256 rIntBack, uint256 kBoundBack,) = _radii();
        assertEq(rIntBack, rInt0, "tiers did not recover");
        assertEq(kBoundBack, 0, "boundary liquidity left behind");
    }

    /// @notice REGRESSION (2): past the last tier the trade is refused with a
    ///         named error and the pool remains fully usable afterwards.
    function test_a_trade_past_every_tier_is_refused_and_the_pool_stays_live() public {
        _bandLadder();
        uint256[3] memory pct = [uint256(5), 20, 60];
        for (uint256 k; k < pct.length; ++k) {
            _expectSwapRevert(0, 1, hook.reserves(0) * pct[k] / 100, OrbitalHook.SwapExceedsLiquidity.selector);
        }
        _assertLive();
    }

    /// @notice Whatever the size, pair and direction, a trade either fills or
    ///         is refused with `SwapExceedsLiquidity`, and the pool is never
    ///         left without interior liquidity.
    function testFuzz_every_trade_fills_or_is_refused_cleanly(uint256 bpsSeed, uint8 aSeed, uint8 bSeed) public {
        _bandLadder();
        uint8 a = aSeed % N;
        uint8 b = bSeed % N;
        vm.assume(a != b);
        uint256 amt = hook.reserves(a) * bound(bpsSeed, 1, 8_000) / 10_000;

        (PoolKey memory k, bool zeroForOne) = _route(a, b);
        try swapRouter.swapExactTokensForTokens(amt, 0, zeroForOne, k, "", address(this), block.timestamp) {}
        catch (bytes memory err) {
            assertEq(_innerSelector(err), OrbitalHook.SwapExceedsLiquidity.selector, "unexpected swap failure");
        }
        _assertLive();
    }

    // ═════════════════════════════════════════════════════════════
    // Full-range backstop: large trades fill
    // ═════════════════════════════════════════════════════════════

    /// @notice With the last tier full range (k = kMax), its boundary is only
    ///         reached by draining an asset, so large trades fill at a price
    ///         that worsens smoothly with size instead of being refused.
    function test_a_full_range_backstop_fills_large_trades() public {
        _pool(0x5252);
        _seed([uint256(4_000_000 ether), 3_000_000 ether, 2_000_000 ether, 3_000_000 ether], [uint256(0.97e18), 0.93e18, 0.88e18, 0]);

        uint256 reserve = hook.reserves(0);
        uint256[5] memory pct = [uint256(1), 5, 12, 20, 35];
        uint256 lastOut;
        uint256 lastRate = type(uint256).max;
        for (uint256 k; k < pct.length; ++k) {
            uint256 snap = vm.snapshotState();
            uint256 amt = reserve * pct[k] / 100;
            uint256 out = _swap(0, 1, amt);
            uint256 rate = out * 1e18 / amt;
            assertGt(out, lastOut, "a larger trade paid out less");
            assertLt(rate, lastRate, "a larger trade got a better rate");
            (lastOut, lastRate) = (out, rate);
            _assertLive();
            vm.revertToState(snap);
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════

    function _pool(uint160 salt) internal {
        address where = address(HOOK_FLAGS ^ (salt << 144));
        deployCodeTo("OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, permit2, regd, FEE, address(this)), where);
        hook = OrbitalHook(where);
        for (uint256 i; i < N; ++i) {
            tok[i].mint(address(this), 100_000_000 ether);
            tok[i].approve(where, type(uint256).max);
        }
        for (uint8 i; i < N; ++i) {
            for (uint8 j = i + 1; j < N; ++j) poolManager.initialize(_key(i, j), Constants.SQRT_PRICE_1_1);
        }
    }

    /// @dev `p == 0` seeds a full-range position (k = kMax).
    function _seed(uint256[4] memory r, uint256[4] memory p) internal {
        uint256[] memory maxA = new uint256[](N);
        for (uint256 i; i < N; ++i) maxA[i] = type(uint256).max;
        for (uint256 k; k < 4; ++k) {
            uint256 kk = p[k] == 0 ? TickLib.kMax(r[k], N) : TickLib.kFromDepegPrice(r[k], N, p[k]);
            hook.addLiquidity(kk, r[k], maxA);
        }
    }

    function _radii() internal view returns (uint256 rInt, uint256 kBound, uint256 sBound) {
        (,, rInt, kBound, sBound) = hook.slot0();
    }

    /// @dev The pool still has interior liquidity and trades both ways.
    function _assertLive() internal {
        (uint256 rInt,,) = _radii();
        assertGt(rInt, 0, "pool left with no interior liquidity");
        _swap(1, 0, 1_000 ether);
        _swap(0, 1, 1_000 ether);
    }

    function _key(uint8 a, uint8 b) internal view returns (PoolKey memory) {
        return PoolKey({currency0: regd[a], currency1: regd[b], fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
    }

    function _route(uint8 inI, uint8 outI) internal view returns (PoolKey memory k, bool zeroForOne) {
        zeroForOne = inI < outI;
        k = zeroForOne ? _key(inI, outI) : _key(outI, inI);
    }

    function _swap(uint8 inI, uint8 outI, uint256 amt) internal returns (uint256 out) {
        (PoolKey memory k, bool zeroForOne) = _route(inI, outI);
        uint256 before = tok[outI].balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(amt, 0, zeroForOne, k, "", address(this), block.timestamp);
        out = tok[outI].balanceOf(address(this)) - before;
    }

    function _expectSwapRevert(uint8 inI, uint8 outI, uint256 amt, bytes4 inner) internal {
        (PoolKey memory k, bool zeroForOne) = _route(inI, outI);
        try swapRouter.swapExactTokensForTokens(amt, 0, zeroForOne, k, "", address(this), block.timestamp) {
            revert("swap should have reverted");
        } catch (bytes memory err) {
            assertEq(_innerSelector(err), inner, "wrong hook error");
        }
    }

    /// @dev The hook's own error selector, unwrapped from the PoolManager's
    ///      `WrappedError(target, selector, reason, details)`.
    function _innerSelector(bytes memory err) internal view returns (bytes4) {
        assertEq(bytes4(err), CustomRevert.WrappedError.selector, "not a wrapped hook revert");
        (,, bytes memory reason,) = this.decodeWrapped(err);
        return bytes4(reason);
    }

    function decodeWrapped(bytes calldata err) external pure returns (address, bytes4, bytes memory, bytes memory) {
        return abi.decode(err[4:], (address, bytes4, bytes, bytes));
    }
}
