// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {OrbitalHook} from "../../src/OrbitalHook.sol";
import {TickLib} from "../../src/libraries/TickLib.sol";
import {SphereMath} from "../../src/libraries/SphereMath.sol";
import {BandLib} from "../../src/libraries/BandLib.sol";

/// @notice The liquidity every deploy script seeds, shaped like the capital
///         real stablecoin LPs actually commit.
///
/// @dev    The shape is measured, not chosen: it is how LPs in the live Uniswap
///         v3 USDC/USDT0 0.01% pool on Arbitrum One place their capital
///         (tick-by-tick liquidity, read on-chain, Sep 2026), by distance from
///         the PEG — which is what a band's bound measures — not from the
///         market price, which sat ~4 bps off it:
///
///           within  1 bp of peg  11%     10 bps  87%
///                   2 bps        23%     20 bps  97.5%
///                   5 bps        66%     50 bps  99.6%
///
///         Each ring goes to the band that covers it, trimmed a little to fund
///         a tail — a 0.99 band and a full-range backstop — that real v3 LPs
///         barely hold but a pool needs: once the bands near the peg have
///         pinned, the tail is all that is left to absorb a very large trade.
///         With a 1% backstop, a $330k trade used up the near bands and hit a
///         wall (the price of the asset sold fell to zero within the next $6k).
///
///           band     0.9999 0.9998 0.9995 0.999 0.998 0.995 0.99  full range
///           capital  11     12     41     20    9     2     2     3        (%)
///
///         An earlier ladder began at 0.999 and spread depth down to 0.95. Run
///         against real Arbitrum trades (script/realworld) it matched v3 on
///         small trades but paid up to ~150 bps less on $100k+ ones: it had
///         almost nothing where real LPs put most of their money.
///
///         A pinned band is not lost to the other assets: boundary liquidity
///         keeps trading the healthy coins among themselves (paper §4.11), so
///         concentrating near the peg costs depth only in the depegging coin.
library TierLadder {
    uint256 internal constant TIERS = 8;

    /// @dev Default real capital per asset (engine WAD value units): ~$5M TVL
    ///      across four assets.
    uint256 internal constant DEFAULT_CAPITAL_PER_ASSET = 1_250_000 ether;

    /// @dev Radius used to measure a band's real deposit per unit of radius.
    uint256 private constant PROBE_R = 1_000_000 ether;

    /// @dev Band bound of tier `t`, WAD; 0 is full range.
    function bound(uint256 t) internal pure returns (uint256) {
        return [uint256(0.9999e18), 0.9998e18, 0.9995e18, 0.999e18, 0.998e18, 0.995e18, 0.99e18, 0][t];
    }

    /// @dev Share of the capital tier `t` gets, in percent.
    function share(uint256 t) internal pure returns (uint256) {
        return [uint256(11), 12, 41, 20, 9, 2, 2, 3][t];
    }

    /// @notice Radius of every tier such that tier `t` deposits `share(t)`% of
    ///         `capitalPerAsset` of each asset into a balanced pool.
    function radii(uint8 n, uint256 capitalPerAsset) internal pure returns (uint256[TIERS] memory r) {
        for (uint256 t = 0; t < TIERS; ++t) {
            r[t] = capitalPerAsset * share(t) / 100 * 1e18 / _realPerRadius(bound(t), n);
        }
    }

    /// @notice Seed every tier into `hook`. The caller must have approved the
    ///         hook for each asset and hold enough of each.
    /// @return ticks_ The tick (band) index of each seeded tier. Every bound in
    ///         `bound` must be on the hook's band menu (`BandLib`).
    function seed(OrbitalHook hook, uint8 n, uint256 capitalPerAsset)
        internal
        returns (uint256[TIERS] memory ticks_)
    {
        uint256[] memory maxA = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) maxA[i] = type(uint256).max;

        uint256[TIERS] memory r = radii(n, capitalPerAsset);
        for (uint256 t = 0; t < TIERS; ++t) {
            uint256 b = bound(t);
            uint256[] memory amounts;
            (ticks_[t], amounts) = hook.addLiquidity(BandLib.bandOf(b), r[t], maxA, block.timestamp + 1 hours);
            console2.log("  seeded tick", ticks_[t], "r:", r[t]);
            if (b == 0) console2.log("    full range, deposit (wad/asset):", amounts[0]);
            else console2.log("    band bound (wad):", b, "deposit (wad/asset):", amounts[0]);
        }
    }

    /// @notice Plane constant of a tier of radius `r` whose band ends at
    ///         `bound_` (full range when 0).
    function plane(uint256 r, uint8 n, uint256 bound_) internal pure returns (uint256) {
        return bound_ == 0 ? TickLib.kMax(r, n) : TickLib.kFromDepegPrice(r, n, bound_);
    }

    /// @dev Real deposit per asset per unit of radius (×1e18), virtual part
    ///      excluded exactly as the hook books it (1e9 is the hook's
    ///      VIRTUAL_HAIRCUT_DIVISOR). Deposits are linear in r, so one probe
    ///      serves every radius.
    function _realPerRadius(uint256 bound_, uint8 n) private pure returns (uint256) {
        uint256 xMin = TickLib.xMin(PROBE_R, n, plane(PROBE_R, n, bound_));
        return (SphereMath.equalPricePoint(PROBE_R, n) - (xMin - xMin / 1e9)) * 1e18 / PROBE_R;
    }
}
