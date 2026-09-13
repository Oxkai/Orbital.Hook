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
import {SphereMath} from "../src/libraries/SphereMath.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice Concentrated liquidity: a tick's reserves below its band's floor
///         (xMin) are virtual, so the LP deposits only the part above it and a
///         concentrated position is correspondingly deeper per unit of capital.
contract VirtualLiquidityTest is BaseTest {
    uint8 constant N = 4;
    uint24 constant FEE = 100;
    uint256 constant WAD = 1e18;
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
            t[i].mint(address(this), 1e12 ether);
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Deposits
    // ═════════════════════════════════════════════════════════════

    /// @notice A band's real deposit is its equal-price reserve divided by the
    ///         paper's capital efficiency, x / (x − xMin) (to the 1e-9 haircut).
    function test_a_band_deposits_its_share_over_its_capital_efficiency() public {
        _pool(0x7101);
        uint256 r = 1_000_000 ether;
        uint256 k = TickLib.kFromDepegPrice(r, N, 0.99e18);
        (, uint256[] memory amounts) = hook.addLiquidity(k, r, _max());

        uint256 q = SphereMath.equalPricePoint(r, N);
        uint256 efficiency = TickLib.capitalEfficiency(r, N, k);
        assertGt(efficiency, 10 * WAD, "fixture: a 0.99 band should be >10x efficient");
        for (uint256 i; i < N; ++i) {
            assertApproxEqRel(amounts[i], q * WAD / efficiency, 1e-6 ether, "deposit != share / efficiency");
        }
        assertApproxEqRel(hook.virtualReserve(), TickLib.xMin(r, N, k), 1e-8 ether, "virtual != xMin");
    }

    /// @notice A full-range position has xMin = 0: nothing is virtual and it
    ///         deposits its whole share, exactly as before.
    function test_full_range_has_no_virtual_part() public {
        _pool(0x7102);
        uint256 r = 1_000_000 ether;
        (, uint256[] memory amounts) = hook.addLiquidity(TickLib.kMax(r, N), r, _max());
        uint256 q = SphereMath.equalPricePoint(r, N);
        assertLe(hook.virtualReserve(), q / 1e12, "full range carries virtual reserve");
        for (uint256 i; i < N; ++i) assertApproxEqRel(amounts[i], q, 1e-12 ether);
    }

    // ═════════════════════════════════════════════════════════════
    // Depth per unit of capital
    // ═════════════════════════════════════════════════════════════

    /// @notice The point of it all: with the SAME real capital, a pool of
    ///         concentrated bands quotes a trade far closer to parity than a
    ///         full-range pool.
    function test_the_same_capital_concentrated_is_far_deeper() public {
        // Full range: 1M radius deposits q(1M) per asset.
        _pool(0x7103);
        hook.addLiquidity(TickLib.kMax(1_000_000 ether, N), 1_000_000 ether, _max());
        uint256 capital = _capitalPerAsset();
        uint256 slipFull = _slippageBps(capital / 200); // 0.5% of the capital per asset

        // Concentrated: a 0.995 band sized to deposit the same capital.
        _pool(0x7104);
        uint256 r = _radiusForCapital(capital, 0.995e18);
        hook.addLiquidity(TickLib.kFromDepegPrice(r, N, 0.995e18), r, _max());
        assertApproxEqRel(_capitalPerAsset(), capital, 1e-6 ether, "fixture: capital differs");
        uint256 slipBand = _slippageBps(capital / 200);

        assertLt(slipBand * 10, slipFull, "concentration did not buy >10x depth");
    }

    // ═════════════════════════════════════════════════════════════
    // Withdrawals
    // ═════════════════════════════════════════════════════════════

    /// @notice Mint then burn with no trades in between returns the deposit,
    ///         less at most rounding dust in the pool's favour.
    function test_mint_then_burn_returns_the_deposit() public {
        _pool(0x7105);
        uint256 r = 500_000 ether;
        uint256 k = TickLib.kFromDepegPrice(r, N, 0.98e18);
        uint256[4] memory before = _balances();
        (uint256 t,) = hook.addLiquidity(k, r, _max());
        hook.removeLiquidity(t, r, new uint256[](N));
        for (uint256 i; i < N; ++i) {
            uint256 afterBal = tok[i].balanceOf(address(this));
            assertLe(afterBal, before[i], "burn paid out more than was deposited");
            assertApproxEqAbs(afterBal, before[i], 4, "burn lost more than dust");
        }
        assertEq(hook.virtualReserve(), 0, "virtual left behind");
    }

    /// @notice REGRESSION: a partial burn used to shrink r but keep k, silently
    ///         widening the band (burning half doubled kNorm). The band must be
    ///         the one the LP chose, whatever is burned.
    function test_a_partial_burn_keeps_the_band() public {
        _pool(0x7106);
        uint256 r = 800_000 ether;
        uint256 k = TickLib.kFromDepegPrice(r, N, 0.97e18);
        (uint256 t,) = hook.addLiquidity(k, r, _max());
        uint256 kNormBefore = k * WAD / r;

        hook.removeLiquidity(t, r / 2, new uint256[](N));
        (uint256 kAfter, uint256 rAfter,,,) = hook.ticks(t);
        assertEq(rAfter, r - r / 2);
        assertApproxEqRel(kAfter * WAD / rAfter, kNormBefore, 1e-12 ether, "partial burn moved the band");
        assertApproxEqRel(hook.tickVirtual(t), TickLib.xMin(rAfter, N, kAfter), 1e-8 ether, "virtual not scaled");
    }

    // ═════════════════════════════════════════════════════════════
    // A position starts inside its band
    // ═════════════════════════════════════════════════════════════

    /// @notice Once the pool has moved past a band, a new position in that band
    ///         would start outside it, with a negative real deposit for the
    ///         scarce asset. It is refused.
    function test_a_band_the_pool_has_already_left_cannot_be_minted() public {
        _pool(0x7107);
        hook.addLiquidity(TickLib.kMax(1_000_000 ether, N), 1_000_000 ether, _max());
        // 10k of a 500k reserve moves the price ~4%: past a 0.999 band, well
        // inside a 0.9 one.
        _swap(0, 1, 10_000 ether);

        uint256 r = 100_000 ether;
        uint256 k = TickLib.kFromDepegPrice(r, N, 0.999e18);
        vm.expectRevert(OrbitalHook.TickOutsideItsBand.selector);
        hook.addLiquidity(k, r, _max());

        // A band wide enough to contain the current position is accepted.
        hook.addLiquidity(TickLib.kFromDepegPrice(r, N, 0.9e18), r, _max());
    }

    // ═════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════

    function _pool(uint160 salt) internal {
        address where = address(HOOK_FLAGS ^ (salt << 144));
        deployCodeTo("OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, permit2, regd, FEE, address(this)), where);
        hook = OrbitalHook(where);
        for (uint256 i; i < N; ++i) tok[i].approve(where, type(uint256).max);
        for (uint8 i; i < N; ++i) {
            for (uint8 j = i + 1; j < N; ++j) poolManager.initialize(_key(i, j), Constants.SQRT_PRICE_1_1);
        }
    }

    function _max() internal pure returns (uint256[] memory m) {
        m = new uint256[](N);
        for (uint256 i; i < N; ++i) m[i] = type(uint256).max;
    }

    /// @dev Real tokens per asset the pool holds (asset 0; the pool is balanced).
    function _capitalPerAsset() internal view returns (uint256) {
        return hook.reserves(0) - hook.virtualReserve();
    }

    /// @dev Radius at which a band at `p` deposits `capital` per asset.
    function _radiusForCapital(uint256 capital, uint256 p) internal pure returns (uint256) {
        uint256 probe = 1_000_000 ether;
        uint256 perProbe = SphereMath.equalPricePoint(probe, N) - TickLib.xMin(probe, N, TickLib.kFromDepegPrice(probe, N, p));
        return probe * capital / perProbe;
    }

    /// @dev Shortfall from parity of swapping `amt` of asset 0 for asset 1, bps
    ///      (fee included), without keeping the trade.
    function _slippageBps(uint256 amt) internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        uint256 out = _swap(0, 1, amt);
        vm.revertToState(snap);
        return (amt - out) * 10_000 / amt;
    }

    function _swap(uint8 inI, uint8 outI, uint256 amt) internal returns (uint256 out) {
        bool zeroForOne = inI < outI;
        PoolKey memory k = zeroForOne ? _key(inI, outI) : _key(outI, inI);
        uint256 before = tok[outI].balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(amt, 0, zeroForOne, k, "", address(this), block.timestamp);
        out = tok[outI].balanceOf(address(this)) - before;
    }

    function _balances() internal view returns (uint256[4] memory b) {
        for (uint256 i; i < N; ++i) b[i] = tok[i].balanceOf(address(this));
    }

    function _key(uint8 a, uint8 b) internal view returns (PoolKey memory) {
        return PoolKey({currency0: regd[a], currency1: regd[b], fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
    }
}
