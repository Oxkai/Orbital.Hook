// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {OrbitalHook} from "../../src/OrbitalHook.sol";
import {TickLib} from "../../src/libraries/TickLib.sol";
import {SphereMath} from "../../src/libraries/SphereMath.sol";

/// @notice The liquidity every deploy script seeds: six concentrated bands plus
///         a small full-range backstop, shaped by DEPTH and sized by capital.
///
/// @dev    A band's reserves below its floor (xMin) are virtual, so the depth
///         (radius) a dollar buys grows steeply as a band narrows. Giving each
///         band equal capital therefore piles almost all depth into the
///         narrowest band: a cliff at the peg that no real pool looks like.
///         Instead each tier is given a share of the DEPTH, tapering from the
///         peg outward, and the capital follows from it: narrow bands need
///         little, wide ones more. The profile is then scaled so the whole
///         ladder deposits `capitalPerAsset` of every asset.
///
///           STABLE  bands 0.999 0.997 0.995 0.99 0.98 0.95   + full range
///                   depth 100   90    80    60   40   20     + 1
///           FX      bands 0.995 0.99  0.98  0.97 0.95 0.90   + full range
///                   depth 100   90    75    60   40   20     + 1
///
///         Cumulative depth falls ~20x from the peg to the outer band, the
///         shape of a real stable pool, instead of ~3000x. The full-range tier
///         is kept small (a full-range position has no virtual part, so each
///         dollar in it buys the least depth); its boundary is reached only by
///         draining an asset, so large trades still fill rather than revert.
///         FX bands are wider: an FX pool's centre is fixed at deploy while the
///         rate drifts, and narrow bands would exit within days.
library TierLadder {
    enum Profile {
        STABLE,
        FX
    }

    uint256 internal constant TIERS = 7;

    /// @dev Default real capital per asset (engine WAD value units): ~$5M TVL
    ///      across four assets.
    uint256 internal constant DEFAULT_CAPITAL_PER_ASSET = 1_250_000 ether;

    /// @dev Radius used to measure a band's real deposit per unit of radius.
    uint256 private constant PROBE_R = 1_000_000 ether;

    /// @dev Band bound of tier `t`, WAD; 0 is full range.
    function bound(Profile p, uint256 t) internal pure returns (uint256) {
        if (p == Profile.STABLE) return [uint256(0.999e18), 0.997e18, 0.995e18, 0.99e18, 0.98e18, 0.95e18, 0][t];
        return [uint256(0.995e18), 0.99e18, 0.98e18, 0.97e18, 0.95e18, 0.9e18, 0][t];
    }

    /// @dev Relative depth (radius) tier `t` adds.
    function weight(Profile p, uint256 t) internal pure returns (uint256) {
        if (p == Profile.STABLE) return [uint256(100), 90, 80, 60, 40, 20, 1][t];
        return [uint256(100), 90, 75, 60, 40, 20, 1][t];
    }

    /// @notice Radius of every tier such that the whole ladder deposits
    ///         `capitalPerAsset` of each asset into a balanced pool.
    function radii(Profile p, uint8 n, uint256 capitalPerAsset) internal pure returns (uint256[TIERS] memory r) {
        // Real deposit per unit of weight, then the radius per unit of weight.
        uint256 perWeight;
        for (uint256 t = 0; t < TIERS; ++t) perWeight += weight(p, t) * _realPerRadius(bound(p, t), n);
        uint256 radiusPerWeight = capitalPerAsset * 1e18 / perWeight;
        for (uint256 t = 0; t < TIERS; ++t) r[t] = weight(p, t) * radiusPerWeight;
    }

    /// @notice Seed every tier into `hook`. The caller must have approved the
    ///         hook for each asset and hold enough of each.
    /// @return ticks_ The tick index of each seeded tier.
    function seed(OrbitalHook hook, uint8 n, Profile p, uint256 capitalPerAsset)
        internal
        returns (uint256[TIERS] memory ticks_)
    {
        uint256[] memory maxA = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) maxA[i] = type(uint256).max;

        uint256[TIERS] memory r = radii(p, n, capitalPerAsset);
        for (uint256 t = 0; t < TIERS; ++t) {
            uint256 b = bound(p, t);
            uint256[] memory amounts;
            (ticks_[t], amounts) = hook.addLiquidity(plane(r[t], n, b), r[t], maxA);
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
