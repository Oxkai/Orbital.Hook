// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title BandLib
/// @notice The fixed menu of depeg bands a position can be opened in.
///
/// @dev    A band is a tick boundary (paper §4.5) named by the depeg price at
///         which it pins (§4.8). Positions in the same band share one tick,
///         the way Uniswap v3 positions share initialised ticks on a spacing.
///
///         Why a fixed menu rather than any k: with k free, every position is a
///         distinct tick, and ticks are a shared, bounded resource — the swap
///         path scans them, and each distinct boundary the price passes costs a
///         crossing. A free choice let anyone take every slot with dust (and
///         stack crossings to stall trades) for almost nothing. A menu bounds
///         the number of distinct ticks by construction, so neither can be done
///         at any price, and merging same-band positions cannot drift a band's
///         boundary because the band's k/r is fixed here rather than carried by
///         each position.
///
///         Tightest first, so the planes' kNorm ascend with the index; the last
///         band is full range (price 0 → kMax, see `TickLib.kFromDepegPrice`).
library BandLib {
    uint8 internal constant COUNT = 31;

    error UnknownBand(uint256 depegPriceWad);

    /// @notice The band's depeg threshold in basis points of the peg; 0 is
    ///         full range.
    function depegBps(uint256 band) internal pure returns (uint256) {
        uint16[COUNT] memory menu = [
            uint16(9999), 9998, 9995, 9990, 9985, 9980, 9975, 9970, 9960, 9950,
            9940, 9925, 9900, 9875, 9850, 9800, 9750, 9700, 9600, 9500,
            9400, 9200, 9000, 8800, 8500, 8000, 7500, 7000, 6000, 5000,
            0
        ];
        return menu[band];
    }

    /// @notice The band's depeg threshold as a WAD price.
    function depegPriceWad(uint256 band) internal pure returns (uint256) {
        return depegBps(band) * 1e14;
    }

    /// @notice The band whose threshold is exactly `depegPriceWad`.
    function bandOf(uint256 depegPriceWad_) internal pure returns (uint8) {
        for (uint8 b = 0; b < COUNT; ++b) {
            if (depegPriceWad(b) == depegPriceWad_) return b;
        }
        revert UnknownBand(depegPriceWad_);
    }
}
