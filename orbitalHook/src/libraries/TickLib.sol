// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./FullMath.sol";
import "./SphereMath.sol";

/// @title TickLib
/// @notice Tick geometry for the orbital AMM (paper §4.5–4.9).
///         All monetary values WAD (1e18) fixed-point unless noted.
library TickLib {
    error PriceOutOfRange();
    error KAboveValidRange();
    error NegativeDiscriminant();
    error XMinAboveBase();

    // Tick struct

    /// @dev Fee accounting is not held here: a tick's fee growth is per ASSET,
    ///      which one field cannot express, and lives in the hook's
    ///      `tickFeeGrowthInside` / `tickFeeGrowthSnapshot` mappings.
    ///      Nor is whether the tick is interior: the hook keeps that in one
    ///      bitmap for all bands, which crossing detection reads in one go.
    struct Tick {
        uint256 k; // plane constant, WAD-scaled
        uint256 r; // radius, WAD-scaled — the tick's liquidity
    }

    // Internal helper

    /// @dev WAD-scaled sqrt(n) = sqrt(n * WAD^2).
    function _sqrtN(uint256 n) private pure returns (uint256) {
        return SphereMath.sqrt(n * SphereMath.WAD * SphereMath.WAD);
    }

    // Tick range bounds

    /// @notice Minimum valid plane constant: kMin = r(sqrt(n) - 1), WAD-scaled.
    function kMin(uint256 r, uint256 n) public pure returns (uint256) {
        uint256 sqrtN = _sqrtN(n);
        return FullMath.mulDiv(r, sqrtN - SphereMath.WAD, SphereMath.WAD);
    }

    /// @notice Maximum valid plane constant: kMax = r(n-1)/sqrt(n), WAD-scaled.
    function kMax(uint256 r, uint256 n) public pure returns (uint256) {
        uint256 sqrtN = _sqrtN(n);
        return FullMath.mulDiv(r, (n - 1) * SphereMath.WAD, sqrtN);
    }

    // Depeg-price to plane constant (paper §4.8)

    /// @notice Compute k from a depeg price.
    ///         k = r*sqrt(n) - r*(p + n-1) / sqrt(n*(p^2 + n-1))
    /// @param r     Sphere radius, WAD-scaled.
    /// @param n     Number of assets (plain integer).
    /// @param pWad  Depeg spot price, WAD-scaled (e.g. 0.99e18).
    function kFromDepegPrice(
        uint256 r,
        uint256 n,
        uint256 pWad
    ) public pure returns (uint256) {
        uint256 WAD   = SphereMath.WAD;
        uint256 sqrtN = _sqrtN(n);

        // p = 1 is the formula's own limit: k_depeg(1) = r√n − r·n/n = kMin. It is
        // snapped exactly because the two independent sqrt floors below leave
        // ~100-200 wei of residual there.
        if (pWad >= WAD) return kMin(r, n);

        // p = 0 is NOT the formula's limit. k_depeg(0) = r√n − r√(n−1)/√n, which
        // is below kMax (1.134r against 1.5r at n = 4): the depeg reading only
        // spans [kMin, k_depeg(0)]. The paper places kMax outside it — a tick
        // that stays in range while every coin but one goes to zero (§4.8). So
        // p = 0 is a sentinel meaning "full range" and returns kMax; k jumps
        // there rather than approaching it. Callers wanting the widest DEPEG
        // band should pass a small positive price instead.
        if (pWad == 0)   return kMax(r, n);

        // p^2 in WAD
        uint256 pSq = FullMath.mulDiv(pWad, pWad, WAD);

        // sqrtDenom = sqrt(n*(p^2+n-1)), WAD-scaled
        uint256 sqrtDenom = SphereMath.sqrt(n * (pSq + (n - 1) * WAD) * WAD);

        uint256 numerator = pWad + (n - 1) * WAD;

        // Single-mulDiv form eliminates double-rounding from separate term1/term2:
        //   k = r*(sqrtN*sqrtDenom − numerator*WAD) / (WAD*sqrtDenom)
        //
        // Analytically: sqrtN*sqrtDenom = n*sqrt(p²+n-1)*WAD² >= (p+n-1)*WAD²
        // (follows from n²*(p²+n-1) >= (p+n-1)² by Cauchy-Schwarz for p∈[0,1], n>=2).
        uint256 lhs = sqrtN * sqrtDenom;           // ≈ n*sqrt(p²+n-1)*WAD²  ≤ ~1e37
        uint256 rhs = numerator * WAD;             // ≈ (p+n-1)*WAD²          ≤ ~1e37
        if (lhs < rhs) revert PriceOutOfRange();

        uint256 k = FullMath.mulDiv(r, lhs - rhs, WAD * sqrtDenom);

        // Clamp for residual 1-unit rounding at boundaries
        uint256 km = kMin(r, n);
        uint256 kM = kMax(r, n);
        if (k < km) k = km;
        if (k > kM) k = kM;
        return k;
    }

    // Reserve bounds (paper §4.7)

    /// @notice Minimum reserve for asset i at tick k.
    ///         xMin = (k*sqrt(n) - sqrt(k^2*n - n*((n-1)*r - k*sqrt(n))^2)) / n
    function xMin(uint256 r, uint256 n, uint256 k) public pure returns (uint256) {
        (uint256 lo, ) = _reserveBounds(r, n, k);
        return lo;
    }

    /// @notice Maximum reserve for asset i at tick k, capped at r.
    ///         xMax = (k*sqrt(n) + sqrt(k^2*n - n*((n-1)*r - k*sqrt(n))^2)) / n
    function xMax(uint256 r, uint256 n, uint256 k) public pure returns (uint256) {
        (, uint256 hi) = _reserveBounds(r, n, k);
        return hi;
    }

    /// @dev Shared discriminant computation for xMin / xMax.
    function _reserveBounds(
        uint256 r,
        uint256 n,
        uint256 k
    ) private pure returns (uint256 lo, uint256 hi) {
        uint256 WAD    = SphereMath.WAD;
        uint256 sqrtN  = _sqrtN(n);
        uint256 kSqrtN = FullMath.mulDiv(k, sqrtN, WAD);

        // A = (n-1)*r - k*sqrt(n)  (>= 0 for k in [kMin, kMax])
        uint256 A;
        {
            uint256 nMinus1R = (n - 1) * r;
            if (nMinus1R < kSqrtN) revert KAboveValidRange();
            A = nMinus1R - kSqrtN;
        }

        // sqrtDisc = sqrt(k^2*n - n*A^2), WAD-scaled
        uint256 sqrtDisc;
        {
            uint256 kSqN = n * FullMath.mulDiv(k, k, WAD);
            uint256 nASq = n * FullMath.mulDiv(A, A, WAD);
            // At k = kMin (a zero-width band) the discriminant is exactly 0, and
            // the floored products can leave it a few wei negative. Treat a
            // deficit within 1e-12 of k²n as that zero; anything larger means
            // k is genuinely out of range.
            if (kSqN < nASq) {
                if (nASq - kSqN > kSqN / 1e12) revert NegativeDiscriminant();
                nASq = kSqN;
            }
            sqrtDisc = SphereMath.sqrt((kSqN - nASq) * WAD);
        }

        // xMin = (k√n − √D)/n cancels catastrophically near kMax, where the two
        // terms agree to the last wei (at kMax, A = 0 and xMin is exactly 0,
        // but the separately floored √D can exceed k√n and underflow). Since
        // k²n − D = nA², the same quantity is A²/(k√n + √D): a sum, so it
        // cannot go negative, it is exactly 0 at kMax, and it is q at kMin.
        // The denominator is rounded up so xMin — and with it the virtual
        // reserve the pool never pays out — errs low.
        lo = A == 0 ? 0 : FullMath.mulDiv(A, A, kSqrtN + sqrtDisc + 1);

        uint256 hiRaw = (kSqrtN + sqrtDisc) / n;
        hi = hiRaw > r ? r : hiRaw;
    }

    // Capital efficiency (paper §4.9)

    /// @notice Capital efficiency = xBase / (xBase - xMin), WAD-scaled.
    ///         Returns WAD (1x) when k == kMax (full-range position).
    function capitalEfficiency(
        uint256 r,
        uint256 n,
        uint256 k
    ) public pure returns (uint256) {
        if (k == kMax(r, n)) return SphereMath.WAD;

        uint256 xBase = SphereMath.equalPricePoint(r, n);
        uint256 xLo   = xMin(r, n, k);

        if (xBase <= xLo) revert XMinAboveBase();
        return FullMath.mulDiv(xBase, SphereMath.WAD, xBase - xLo);
    }
}
