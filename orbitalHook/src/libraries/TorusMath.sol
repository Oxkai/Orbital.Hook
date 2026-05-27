// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./FullMath.sol";
import "./SphereMath.sol";

/// @title TorusMath
/// @notice Global torus invariant for the orbital AMM (paper §4.11–4.13).
///         All monetary values WAD (1e18) fixed-point unless noted.
library TorusMath {
    uint256 internal constant WAD = SphereMath.WAD;

    // State struct

    struct TorusState {
        uint256 rInt;    // consolidated interior radius, WAD-scaled
        uint256 kBound;  // Σk of all boundary ticks, WAD-scaled
        uint256 sBound;  // Σs of all boundary ticks, WAD-scaled
        uint256 sumX;    // Σxᵢ total reserves, WAD-scaled
        uint256 sumXSq;  // Σ(xᵢ²/WAD) total reserves, WAD-scaled
        uint256 n;       // number of assets (plain integer)
    }

    // Helpers

    /// @notice Boundary-circle radius for a tick:
    ///         s = sqrt(r² − (k − r√n)²), WAD-scaled.
    function computeS(uint256 r, uint256 k, uint256 n) internal pure returns (uint256) {
        uint256 sqrtN  = SphereMath.sqrt(n * WAD * WAD);
        uint256 rSqrtN = FullMath.mulDiv(r, sqrtN, WAD);
        // (k − r√n)² — same whether k > r√n or k < r√n
        uint256 diff   = k >= rSqrtN ? k - rSqrtN : rSqrtN - k;
        uint256 rSq    = FullMath.mulDiv(r, r, WAD);
        uint256 diffSq = FullMath.mulDiv(diff, diff, WAD);
        require(rSq >= diffSq, "TorusMath: k out of range");
        return SphereMath.sqrt((rSq - diffSq) * WAD);
    }

    /// @notice Normalised alpha: alphaInt / rInt, WAD-scaled.
    ///         Returns type(uint256).max when rInt = 0.
    function alphaNorm(uint256 alphaInt, uint256 rInt) internal pure returns (uint256) {
        if (rInt == 0) return type(uint256).max;
        return FullMath.mulDiv(alphaInt, WAD, rInt);
    }

    // LHS of torus invariant (paper §4.11)

    /// @notice Compute LHS = (alphaInt − rInt√n)² + (wNorm − sBound)², WAD-scaled.
    function torusLHS(TorusState memory s) internal pure returns (uint256) {
        uint256 sqrtN = SphereMath.sqrt(s.n * WAD * WAD);

        // alphaTot = Σxᵢ / √n
        uint256 alphaTot = FullMath.mulDiv(s.sumX, WAD, sqrtN);

        // alphaInt = alphaTot − kBound
        require(alphaTot >= s.kBound, "TorusMath: alphaTot < kBound");
        uint256 alphaInt = alphaTot - s.kBound;

        // rInt√n
        uint256 rIntSqrtN = FullMath.mulDiv(s.rInt, sqrtN, WAD);

        // term1 = |alphaInt − rInt√n|
        uint256 term1 = alphaInt >= rIntSqrtN
            ? alphaInt - rIntSqrtN
            : rIntSqrtN - alphaInt;

        // wNormSq = sumXSq − sumX² / (n·WAD)
        // Safe because sumXSq is accumulated incrementally.
        // Saturating subtraction: for a perfectly balanced pool, integer rounding
        // can make sumXSqMean > sumXSq by 1; treat that as wNormSq = 0.
        uint256 sumXSqMean = FullMath.mulDiv(s.sumX, s.sumX, s.n * WAD);
        uint256 wNormSq = s.sumXSq > sumXSqMean ? s.sumXSq - sumXSqMean : 0;

        // wNorm = sqrt(wNormSq), WAD-scaled
        uint256 wNorm = SphereMath.sqrt(wNormSq * WAD);

        // term2 = |wNorm − sBound|
        uint256 term2 = wNorm >= s.sBound
            ? wNorm - s.sBound
            : s.sBound - wNorm;

        // LHS = term1² + term2²  (WAD-normalised)
        return FullMath.mulDiv(term1, term1, WAD) + FullMath.mulDiv(term2, term2, WAD);
    }

    // Invariant check

    /// @notice Check torus invariant: LHS ≈ rInt².
    /// @return ok           true when relative drift < 1e-6 (1e12 in WAD units)
    /// @return relativeDrift |lhs − rhs| / rhs in WAD (type(uint256).max if rhs=0)
    function checkInvariant(TorusState memory s)
        internal
        pure
        returns (bool ok, uint256 relativeDrift)
    {
        uint256 lhs = torusLHS(s);
        uint256 rhs = FullMath.mulDiv(s.rInt, s.rInt, WAD);

        if (rhs == 0) {
            // All ticks on boundary: invariant holds iff lhs is also 0.
            ok            = lhs == 0;
            relativeDrift = type(uint256).max;
            return (ok, relativeDrift);
        }

        uint256 drift = lhs > rhs ? lhs - rhs : rhs - lhs;
        relativeDrift = FullMath.mulDiv(drift, WAD, rhs);
        ok = relativeDrift < 1e12; // 1e-6 × WAD
    }

    // Swap solver — Newton's method (paper §4.13)

    /// @notice Solve for amountOut such that the torus invariant holds after swap.
    /// @param s         Current torus state (will be mutated for input side).
    /// @param assetIn   Index of the asset being sold.
    /// @param assetOut  Index of the asset being bought.
    /// @param amountIn  Amount of assetIn, WAD-scaled.
    /// @param reserves  Per-asset reserve array, each WAD-scaled.
    /// @return amountOut Amount of assetOut to send, WAD-scaled.
    function solveSwap(
        TorusState memory s,
        uint256 assetIn,
        uint256 assetOut,
        uint256 amountIn,
        uint256[] memory reserves
    ) internal pure returns (uint256 amountOut) {
        require(assetIn != assetOut, "TorusMath: same asset");
        require(assetIn  < s.n && assetOut < s.n, "TorusMath: asset out of range");
        require(amountIn > 0, "TorusMath: zero amountIn");

        uint256 xjOld = reserves[assetOut];
        require(xjOld > 0, "TorusMath: empty output reserve");

        {
            uint256 xiOld = reserves[assetIn];
            s.sumX = s.sumX + amountIn;
            // sumXSq increases by (xi+amount)² - xi² = 2*xi*amount + amount²
            uint256 twoXiAmount = FullMath.mulDiv(2 * xiOld, amountIn, WAD);
            uint256 amountInSq  = FullMath.mulDiv(amountIn, amountIn, WAD);
            s.sumXSq = s.sumXSq + twoXiAmount + amountInSq;
        }

        uint256 rhs = FullMath.mulDiv(s.rInt, s.rInt, WAD);

        amountOut = FullMath.mulDiv(amountIn, 999, 1000);
        if (amountOut >= xjOld) amountOut = xjOld - 1;

        for (uint256 i; i < 15; ++i) {
            int256 f0 = int256(torusLHS(_applyOutput(s, xjOld, amountOut))) - int256(rhs);
            if (f0 == 0) break;

            // Relative eps — scales with amountOut magnitude (~1 ppm)
            uint256 eps = amountOut / 1_000_000;
            if (eps < 100) eps = 100;

            uint256 bumpOut = amountOut + eps < xjOld ? amountOut + eps : amountOut;
            int256 df;
            if (bumpOut != amountOut) {
                int256 f1 = int256(torusLHS(_applyOutput(s, xjOld, bumpOut))) - int256(rhs);
                df = (f1 - f0) / int256(eps);
            }
            if (df == 0) break;

            int256  step    = -(f0 / df);
            uint256 absStep = step < 0 ? uint256(-step) : uint256(step);

            if (step < 0) {
                amountOut = absStep >= amountOut ? 0 : amountOut - absStep;
            } else {
                amountOut += absStep;
                if (amountOut >= xjOld) amountOut = xjOld - 1;
            }

            if (absStep < 2) break;
        }
    }

    /// @dev Apply output-side reserve change to a copy of state.
    ///      NOTE: memory-struct assignment in Solidity aliases the reference,
    ///      so each field must be copied explicitly to avoid mutating `s`.
    function _applyOutput(
        TorusState memory s,
        uint256 xjOld,
        uint256 amount
    ) private pure returns (TorusState memory t) {
        require(xjOld >= amount, "insufficient reserve");
        t.rInt   = s.rInt;
        t.kBound = s.kBound;
        t.sBound = s.sBound;
        t.n      = s.n;
        t.sumX   = s.sumX - amount;
        // sumXSq decreases by xj² - (xj-amount)² = 2*xj*amount - amount²
        uint256 twoXjAmount = FullMath.mulDiv(2 * xjOld, amount, WAD);
        uint256 amountSq    = FullMath.mulDiv(amount, amount, WAD);
        t.sumXSq = s.sumXSq - twoXjAmount + amountSq;
    }
}
