// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./FullMath.sol";
import "./SphereMath.sol";

/// @title TickLib
/// @notice Tick geometry for the orbital AMM (paper §4.5–4.9).
///         All monetary values WAD (1e18) fixed-point unless noted.
library TickLib {
    // Tick struct

    struct Tick {
        uint256 k;                // plane constant, WAD-scaled
        uint256 r;                // radius contribution, WAD-scaled
        bool    isInterior;       // true when current price is inside this tick
        uint256 feeGrowthInside;  // accumulated fee growth inside the tick
        uint128 liquidityGross;   // total liquidity (r) in integer units
    }

    // Internal helper

    /// @dev WAD-scaled sqrt(n) = sqrt(n * WAD^2).
    function _sqrtN(uint256 n) private pure returns (uint256) {
        return SphereMath.sqrt(n * SphereMath.WAD * SphereMath.WAD);
    }

    // Tick range bounds

    /// @notice Minimum valid plane constant: kMin = r(sqrt(n) - 1), WAD-scaled.
    function kMin(uint256 r, uint256 n) internal pure returns (uint256) {
        uint256 sqrtN = _sqrtN(n);
        return FullMath.mulDiv(r, sqrtN - SphereMath.WAD, SphereMath.WAD);
    }

    /// @notice Maximum valid plane constant: kMax = r(n-1)/sqrt(n), WAD-scaled.
    function kMax(uint256 r, uint256 n) internal pure returns (uint256) {
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
    ) internal pure returns (uint256) {
        uint256 WAD   = SphereMath.WAD;
        uint256 sqrtN = _sqrtN(n);

        // Boundary special cases: formula converges to kMin/kMax at p=1/p=0,
        // but two independent sqrt floors produce ~100-200 wei residual error.
        // Snap to exact bounds — these are semantically correct degenerate limits.
        if (pWad >= WAD) return kMin(r, n);
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
        require(lhs >= rhs, "TickLib: price out of range");

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
    function xMin(uint256 r, uint256 n, uint256 k) internal pure returns (uint256) {
        (uint256 lo, ) = _reserveBounds(r, n, k);
        return lo;
    }

    /// @notice Maximum reserve for asset i at tick k, capped at r.
    ///         xMax = (k*sqrt(n) + sqrt(k^2*n - n*((n-1)*r - k*sqrt(n))^2)) / n
    function xMax(uint256 r, uint256 n, uint256 k) internal pure returns (uint256) {
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
            require(nMinus1R >= kSqrtN, "TickLib: k above valid range");
            A = nMinus1R - kSqrtN;
        }

        // sqrtDisc = sqrt(k^2*n - n*A^2), WAD-scaled
        uint256 sqrtDisc;
        {
            uint256 kSqN = n * FullMath.mulDiv(k, k, WAD);
            uint256 nASq = n * FullMath.mulDiv(A, A, WAD);
            require(kSqN >= nASq, "TickLib: negative discriminant");
            sqrtDisc = SphereMath.sqrt((kSqN - nASq) * WAD);
        }

        lo = (kSqrtN - sqrtDisc) / n;

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
    ) internal pure returns (uint256) {
        if (k == kMax(r, n)) return SphereMath.WAD;

        uint256 xBase = SphereMath.equalPricePoint(r, n);
        uint256 xLo   = xMin(r, n, k);

        require(xBase > xLo, "TickLib: xMin >= xBase");
        return FullMath.mulDiv(xBase, SphereMath.WAD, xBase - xLo);
    }

    // Boundary radius (paper §4.6)

    /// @notice Radius of the boundary circle at plane constant k.
    ///         s = sqrt(r^2 - (r*sqrt(n) - k)^2), WAD-scaled.
    /// @dev    k < r*sqrt(n) always holds in the valid range.
    function boundaryRadius(
        uint256 r,
        uint256 k,
        uint256 n
    ) internal pure returns (uint256) {
        uint256 WAD    = SphereMath.WAD;
        uint256 sqrtN  = _sqrtN(n);
        uint256 rSqrtN = FullMath.mulDiv(r, sqrtN, WAD);

        require(k >= kMin(r, n) && k <= kMax(r, n), "TickLib: k out of range");

        // k < r*sqrt(n) in valid range so diff >= 0
        uint256 diff   = rSqrtN - k;
        uint256 rSq    = FullMath.mulDiv(r, r, WAD);
        uint256 diffSq = FullMath.mulDiv(diff, diff, WAD);
        require(rSq >= diffSq, "TickLib: geometry error");
        uint256 inner  = rSq - diffSq;
        return SphereMath.sqrt(inner * WAD);
    }
}
