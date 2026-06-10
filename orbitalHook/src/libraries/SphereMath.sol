// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./FullMath.sol";

/// @title SphereMath
/// @notice Pure math library for orbital AMM sphere geometry (paper §4.1 & §4.2).
///         All monetary values use WAD (1e18) fixed-point unless noted otherwise.
///         Squared monetary values use WAD-normalised form: mulDiv(a, b, WAD).
library SphereMath {
    uint256 internal constant WAD  = 1e18;
    uint256 internal constant WAD2 = 1e36;

    // Integer square root

    /// @notice Integer square root — returns floor(√x).
    /// @dev Bit-shift-seeded Newton (Solmate/Solady `FixedPointMathLib.sqrt`).
    ///      Returns the exact same floor(√x) as a Babylonian loop, but with a
    ///      good power-of-two seed it needs a fixed 7 iterations instead of an
    ///      unbounded `while`, which is materially cheaper for the large
    ///      operands (~1e36) this curve feeds it on every swap.
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            z := 1
            let y := x

            // Seed: smallest power of two ≥ √x.
            if iszero(lt(y, 0x100000000000000000000000000000000)) { y := shr(128, y) z := shl(64, z) }
            if iszero(lt(y, 0x10000000000000000)) { y := shr(64, y) z := shl(32, z) }
            if iszero(lt(y, 0x100000000)) { y := shr(32, y) z := shl(16, z) }
            if iszero(lt(y, 0x10000)) { y := shr(16, y) z := shl(8, z) }
            if iszero(lt(y, 0x100)) { y := shr(8, y) z := shl(4, z) }
            if iszero(lt(y, 0x10)) { y := shr(4, y) z := shl(2, z) }
            if iszero(lt(y, 0x8)) { z := shl(1, z) }

            // Seven Newton iterations converge for any uint256.
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))

            // Floor correction: if x+1 is a perfect square the iteration can
            // land one high, so round down to floor(√x).
            let zRoundDown := div(x, z)
            if lt(zRoundDown, z) { z := zRoundDown }
        }
    }

    // Sphere geometry helpers

    /// @notice Equal-price point: q = r · (1 − 1/√n), WAD-scaled.
    /// @param r  Sphere radius, WAD-scaled.
    /// @param n  Number of assets (plain integer, not WAD).
    function equalPricePoint(uint256 r, uint256 n) internal pure returns (uint256) {
        // sqrt(n) expressed in WAD: sqrt(n · WAD²) = floor(√n) · WAD (approx)
        uint256 sqrtN = sqrt(n * WAD * WAD);
        // r / √n  (WAD-scaled):  r · WAD / (sqrtN)  =  r / √n
        uint256 rOverSqrtN = FullMath.mulDiv(r, WAD, sqrtN);
        return r - rOverSqrtN;
    }

    /// @notice Alpha coefficient: α = Σxᵢ / √n, WAD-scaled.
    /// @param sumX  Σxᵢ, WAD-scaled.
    /// @param n     Number of assets (plain integer).
    function computeAlpha(uint256 sumX, uint256 n) internal pure returns (uint256) {
        uint256 sqrtN = sqrt(n * WAD * WAD);
        return FullMath.mulDiv(sumX, WAD, sqrtN);
    }

    /// @notice Weighted norm squared: w² = Σ(xᵢ − mean)², WAD-normalised.
    /// @dev    Cancellation-safe: computes mean first, squares deviations individually.
    ///         Each squared term is normalised by WAD so the result is WAD-scaled.
    ///         Do NOT use Σxᵢ² − (Σxᵢ)²/n — that suffers catastrophic cancellation.
    /// @param reserves  Array of per-asset reserves, each WAD-scaled.
    /// @param n         Number of assets (must equal reserves.length).
    function computeWNormSq(uint256[] memory reserves, uint256 n)
        internal
        pure
        returns (uint256 wNormSq)
    {
        require(reserves.length == n, "SphereMath: length mismatch");

        // Pass 1: accumulate Σxᵢ to find mean.
        uint256 sumX;
        for (uint256 i; i < n; ++i) {
            sumX += reserves[i];
        }
        uint256 mean = sumX / n;

        // Pass 2: Σ|xᵢ − mean|² / WAD  (absolute diff avoids underflow).
        for (uint256 i; i < n; ++i) {
            uint256 diff = reserves[i] > mean
                ? reserves[i] - mean
                : mean - reserves[i];
            wNormSq += FullMath.mulDiv(diff, diff, WAD);
        }
    }

    /// @notice Marginal spot price of asset j in terms of asset i.
    ///         price = (r − xⱼ) / (r − xᵢ), WAD-scaled.
    /// @param r   Sphere radius, WAD-scaled.
    /// @param xi  Reserve of the input asset, WAD-scaled.
    /// @param xj  Reserve of the output asset, WAD-scaled.
    function spotPrice(uint256 r, uint256 xi, uint256 xj)
        internal
        pure
        returns (uint256)
    {
        require(r > xj && r > xi, "SphereMath: reserve exceeds radius");
        return FullMath.mulDiv(r - xj, WAD, r - xi);
    }

    // Invariant check

    /// @notice Verifies the sphere invariant: ||r⃗ − x⃗||² ≈ r²
    ///         Expands to: n·r² − 2r·Σxᵢ + Σxᵢ² ≈ r²
    ///         Passes when relative drift < 1 ppm (|lhs − rhs| · 1e6 < rhs).
    /// @param sumX    Σxᵢ, WAD-scaled.
    /// @param sumXSq  Σ(xᵢ²/WAD) = Σ mulDiv(xᵢ, xᵢ, WAD), WAD-scaled.
    /// @param r       Sphere radius, WAD-scaled.
    /// @param n       Number of assets (plain integer).
    function checkSphereInvariant(
        uint256 sumX,
        uint256 sumXSq,
        uint256 r,
        uint256 n
    ) internal pure returns (bool) {
        // rhs = r²  (WAD-normalised)
        uint256 rSq = FullMath.mulDiv(r, r, WAD);

        // lhs = n·r² − 2r·Σxᵢ + Σxᵢ²  (all WAD-normalised)
        uint256 nRSq        = n * rSq;                           // safe for small n
        uint256 twoRSumX    = 2 * FullMath.mulDiv(r, sumX, WAD);
        uint256 lhs         = nRSq - twoRSumX + sumXSq;

        // |lhs − rhs| · 1e6 < rhs  →  relative drift < 1 ppm
        uint256 drift = lhs > rSq ? lhs - rSq : rSq - lhs;
        return drift * 1_000_000 < rSq;
    }
}
