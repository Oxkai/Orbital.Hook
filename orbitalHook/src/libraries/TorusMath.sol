// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./FullMath.sol";
import "./SphereMath.sol";

/// @title TorusMath
/// @notice Global torus invariant for the orbital AMM (paper §4.11–4.13).
///         All monetary values WAD (1e18) fixed-point unless noted.
library TorusMath {
    uint256 internal constant WAD = SphereMath.WAD;

    /// @notice k is outside [r√n − r, r√n + r]: no boundary circle exists.
    error BoundaryRadiusUndefined();
    /// @notice Σx/√n fell below kBound: the state is outside the torus domain.
    error AlphaBelowKBound();
    /// @notice A zero or sign-split gradient: the state is off the manifold.
    error DegenerateGradient();
    /// @notice No output within the current tick configuration restores the
    ///         invariant (see `solveSwapBounded`).
    error NoSolutionInConfiguration();
    error InvalidSwapAssets();
    error ZeroAmountIn();
    error EmptyOutputReserve();
    error OutputExceedsReserve();

    // State struct

    struct TorusState {
        uint256 rInt;    // consolidated interior radius, WAD-scaled
        uint256 kBound;  // Σk of all boundary ticks, WAD-scaled
        uint256 sBound;  // Σs of all boundary ticks, WAD-scaled
        uint256 sumX;    // Σxᵢ total reserves, WAD-scaled
        uint256 sumXSq;  // Σ(xᵢ²/WAD) total reserves, WAD-scaled
        uint256 n;       // number of assets (plain integer)
        uint256 sqrtN;   // cached √n·WAD (= sqrt(n·WAD²)); set by the caller so
                         // the Newton solver doesn't recompute it every iteration
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
        if (rSq < diffSq) revert BoundaryRadiusUndefined();
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
        (, uint256 t1, uint256 wNorm) = _terms(s);
        // term2 = |wNorm − sBound|
        uint256 t2 = wNorm >= s.sBound ? wNorm - s.sBound : s.sBound - wNorm;
        // LHS = term1² + term2²  (WAD-normalised)
        return FullMath.mulDiv(t1, t1, WAD) + FullMath.mulDiv(t2, t2, WAD);
    }

    /// @dev The two quantities every torus expression is built from:
    ///      term1 = alphaInt − rInt√n (as sign + magnitude) and ‖w‖, the norm of
    ///      the reserves' component orthogonal to (1,…,1). Shared by the
    ///      invariant, its gradient and the swap solver so all three agree to
    ///      the wei.
    function _terms(TorusState memory s) private pure returns (bool t1Neg, uint256 t1, uint256 wNorm) {
        uint256 sqrtN = s.sqrtN; // cached √n·WAD; avoids recomputing sqrt(n·WAD²) per call

        // alphaTot = Σxᵢ / √n
        uint256 alphaTot = FullMath.mulDiv(s.sumX, WAD, sqrtN);

        // alphaInt = alphaTot − kBound
        if (alphaTot < s.kBound) revert AlphaBelowKBound();
        uint256 alphaInt = alphaTot - s.kBound;

        // term1 = alphaInt − rInt√n
        uint256 rIntSqrtN = FullMath.mulDiv(s.rInt, sqrtN, WAD);
        t1Neg = alphaInt < rIntSqrtN;
        t1 = t1Neg ? rIntSqrtN - alphaInt : alphaInt - rIntSqrtN;

        // wNormSq = sumXSq − sumX² / (n·WAD)
        // Safe because sumXSq is accumulated incrementally.
        // Saturating subtraction: for a perfectly balanced pool, integer rounding
        // can make sumXSqMean > sumXSq by 1; treat that as wNormSq = 0.
        uint256 sumXSqMean = FullMath.mulDiv(s.sumX, s.sumX, s.n * WAD);
        uint256 wNormSq = s.sumXSq > sumXSqMean ? s.sumXSq - sumXSqMean : 0;

        // wNorm = sqrt(wNormSq), WAD-scaled
        wNorm = SphereMath.sqrt(wNormSq * WAD);
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

    // Marginal price (gradient of the torus invariant)

    /// @notice Marginal price of asset j in units of asset i, WAD-scaled: how
    ///         much of i the pool asks per unit of j for an infinitesimal trade
    ///         at the current state.
    /// @dev    Along the invariant surface F = 0, a trade taking dxᵢ in and
    ///         paying dxⱼ out satisfies Fᵢ·dxᵢ + Fⱼ·dxⱼ = 0, so the rate is the
    ///         gradient ratio Fⱼ / Fᵢ. With
    ///
    ///             F  = (αInt − rInt√n)² + (‖w‖ − sBound)² − rInt²
    ///             wₖ = xₖ − Σx/n       (the part of x orthogonal to (1,…,1))
    ///
    ///         each partial is, up to a common factor of 2,
    ///
    ///             Fₖ = (αInt − rInt√n)/√n + (‖w‖ − sBound)·wₖ/‖w‖
    ///
    ///         With no boundary ticks (kBound = sBound = 0) this collapses to
    ///         Fₖ = xₖ − rInt, i.e. `SphereMath.spotPrice`.
    ///
    /// @param xi Current reserve of asset i, WAD-scaled.
    /// @param xj Current reserve of asset j, WAD-scaled.
    function marginalPrice(TorusState memory s, uint256 xi, uint256 xj) internal pure returns (uint256) {
        (bool t1Neg, uint256 t1, uint256 wNorm) = _terms(s);
        (bool okI, bool negI, uint256 gi) = _gradient(s, t1Neg, t1, wNorm, xi);
        (bool okJ, bool negJ, uint256 gj) = _gradient(s, t1Neg, t1, wNorm, xj);
        // Inside the pool's operating region both partials share a sign (every
        // reserve sits on the same side of the centre); a zero or sign-split
        // gradient means the state is off the manifold, not a price.
        if (!(okI && okJ && gi != 0 && negI == negJ)) revert DegenerateGradient();
        return FullMath.mulDiv(gj, WAD, gi);
    }

    /// @dev Fₖ as (isNegative, magnitude), WAD-scaled, given the state's
    ///      `_terms`. `ok` is false when the state has boundary liquidity but
    ///      ‖w‖ = 0, where the gradient is undefined. Magnitudes go through
    ///      FullMath so the library stays overflow-safe independent of any
    ///      reserve cap a caller enforces.
    function _gradient(TorusState memory s, bool t1Neg, uint256 t1Abs, uint256 wNorm, uint256 xk)
        private
        pure
        returns (bool ok, bool neg, uint256 mag)
    {
        // term1 contribution = (αInt − rInt√n) / √n
        uint256 g1 = FullMath.mulDiv(t1Abs, WAD, s.sqrtN);

        // term2 contribution = (‖w‖ − sBound) · wₖ / ‖w‖
        uint256 mean = s.sumX / s.n;
        bool wNeg = xk < mean;
        uint256 wAbs = wNeg ? mean - xk : xk - mean;
        bool g2Neg;
        uint256 g2;
        if (s.sBound == 0) {
            // With no boundary liquidity the ‖w‖ factors cancel and the term is
            // exactly wₖ. Taking it directly also matters numerically: for a
            // near-balanced pool ‖w‖² falls below WAD resolution and rounds to
            // zero while wₖ is still nonzero.
            (g2Neg, g2) = (wNeg, wAbs);
        } else {
            // On the manifold the boundary circles contribute sBound along w,
            // so ‖w‖ ≥ sBound > 0; a zero here is an invalid state, not a price.
            if (wNorm == 0) return (false, false, 0);
            bool baseNeg = wNorm < s.sBound;
            g2 = FullMath.mulDiv(baseNeg ? s.sBound - wNorm : wNorm - s.sBound, wAbs, wNorm);
            g2Neg = baseNeg != wNeg;
        }

        // term1 + term2, as a signed magnitude.
        ok = true;
        if (t1Neg == g2Neg) return (ok, t1Neg, g1 + g2);
        (neg, mag) = g1 >= g2 ? (t1Neg, g1 - g2) : (g2Neg, g2 - g1);
    }

    // Swap solver — safeguarded Newton (paper §4.13)

    /// @dev Enough iterations for pure bisection to resolve any output the
    ///      reserve cap allows (log₂ of 1e34 ≈ 113) with margin; Newton steps
    ///      normally finish in a handful.
    uint256 private constant MAX_SOLVER_ITERATIONS = 128;

    /// @dev An input below rInt / DUST_DIVISOR (1e-9 of the interior radius)
    ///      cannot move the state past rounding; if it leaves the residual
    ///      non-negative it is absorbed with nothing paid out.
    uint256 private constant DUST_DIVISOR = 1e9;

    /// @notice Solve for amountOut such that the torus invariant holds after swap.
    ///         Reverts if no output within the current tick configuration can
    ///         restore the invariant; see `solveSwapBounded` for the variant
    ///         that reports that instead.
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
        bool found;
        (amountOut, found) = solveSwapBounded(s, assetIn, assetOut, amountIn, reserves);
        if (!found) revert NoSolutionInConfiguration();
    }

    /// @notice Output for a swap within the CURRENT tick configuration, or a
    ///         report that none exists.
    /// @dev    With the input applied, the invariant residual
    ///
    ///             F(out) = LHS(state − out·eⱼ) − rInt²
    ///
    ///         is negative at out = 0 (input moves the state inside the
    ///         surface) and the answer is its first root. F is only defined
    ///         while αInt ≥ 0 and out < xⱼ, and it is convex, so an unguarded
    ///         Newton step from below the root overshoots, and from a flat
    ///         region can jump straight out of that domain. This solver keeps a
    ///         sign bracket [lo, hi] inside the domain at all times: it takes
    ///         the analytic Newton step (dF/dout = −2·Fⱼ/WAD) when that lands
    ///         strictly inside the bracket and shrinks it fast enough, and
    ///         bisects otherwise. It stops when the bracket is 1 wei wide and
    ///         returns `lo`, where F ≤ 0: the pool never pays more than the
    ///         invariant allows.
    /// @return amountOut The solved output (WAD). When `found` is false, 0.
    /// @return found     False when no output in the domain restores the
    ///                   invariant: even the largest leaves F < 0 (the trade
    ///                   would drain asset j), or the input alone already
    ///                   leaves F ≥ 0 and is more than dust. Either way the
    ///                   trade must cross a tick, or exceeds the pool, first.
    function solveSwapBounded(
        TorusState memory s,
        uint256 assetIn,
        uint256 assetOut,
        uint256 amountIn,
        uint256[] memory reserves
    ) internal pure returns (uint256 amountOut, bool found) {
        if (assetIn == assetOut || assetIn >= s.n || assetOut >= s.n) revert InvalidSwapAssets();
        if (amountIn == 0) revert ZeroAmountIn();

        uint256 xjOld = reserves[assetOut];
        if (xjOld == 0) revert EmptyOutputReserve();

        {
            uint256 xiOld = reserves[assetIn];
            s.sumX = s.sumX + amountIn;
            // sumXSq increases by (xi+amount)² - xi² = 2*xi*amount + amount²
            uint256 twoXiAmount = FullMath.mulDiv(2 * xiOld, amountIn, WAD);
            uint256 amountInSq  = FullMath.mulDiv(amountIn, amountIn, WAD);
            s.sumXSq = s.sumXSq + twoXiAmount + amountInSq;
        }

        int256 rhs = int256(FullMath.mulDiv(s.rInt, s.rInt, WAD));

        // Domain: out ≤ xⱼ − 1, and αTot(Σx − out) ≥ kBound. Rounding the
        // floor of Σx up makes `_terms`' floor-divided αTot provably ≥ kBound.
        uint256 hi = xjOld - 1;
        {
            uint256 minSumX = FullMath.mulDivRoundingUp(s.kBound, s.sqrtN, WAD);
            if (s.sumX <= minSumX) return (0, false);
            uint256 outMax = s.sumX - minSumX;
            if (outMax < hi) hi = outMax;
        }

        // The input alone leaves the state on or outside the surface. For dust
        // that is rounding, and nothing is owed. For anything larger it means
        // no output in this configuration can take the trade: report it rather
        // than returning 0, which would let the input be absorbed for nothing.
        (int256 fLo,,,) = _residual(s, xjOld, 0, rhs);
        if (fLo >= 0) return (0, amountIn <= s.rInt / DUST_DIVISOR);

        (int256 fHi,,,) = _residual(s, xjOld, hi, rhs);
        if (fHi == 0) return (hi, true);
        if (fHi < 0) return (0, false);

        // Invariant from here on: F(lo) < 0 < F(hi). `dx` is the last step
        // taken and `dxOld` the one before it (Numerical Recipes' rtsafe): a
        // Newton step is taken only if it lands strictly inside the bracket
        // and is at most half of `dxOld`, which guarantees the bracket at
        // least halves every two iterations whatever F looks like.
        uint256 lo = 0;
        uint256 dx = hi;
        uint256 dxOld = hi;
        // Near parity the output is close to the input, which puts the first
        // evaluation next to the root for ordinary trades.
        uint256 x = FullMath.mulDiv(amountIn, 999, 1000);
        if (x == 0 || x >= hi) x = hi / 2;

        for (uint256 i; i < MAX_SOLVER_ITERATIONS; ++i) {
            (int256 f, bool gOk, bool gNeg, uint256 g) = _residual(s, xjOld, x, rhs);
            if (f == 0) return (x, true);
            if (f < 0) lo = x;
            else hi = x;
            if (hi - lo <= 1) break;

            // Newton: x' = x − F/F′ with F′ = −2·Fⱼ/WAD, i.e. x' = x + F·WAD/(2·Fⱼ).
            // The step moves up exactly when F and Fⱼ share a sign.
            uint256 next;
            uint256 stepMag;
            bool useNewton = gOk && g != 0;
            if (useNewton) {
                stepMag = FullMath.mulDiv(uint256(f < 0 ? -f : f), WAD, 2 * g);
                if (stepMag == 0) {
                    // Converged below wei resolution: probe the neighbour on the
                    // far side of the root to close the bracket.
                    (next, stepMag) = (f < 0 ? x + 1 : x - 1, 1);
                } else if ((f < 0) == gNeg) {
                    next = stepMag < hi - x ? x + stepMag : hi;
                } else {
                    next = stepMag < x - lo ? x - stepMag : lo;
                }
                useNewton = next > lo && next < hi && stepMag <= dxOld / 2;
            }
            dxOld = dx;
            if (useNewton) {
                (x, dx) = (next, stepMag);
            } else {
                dx = (hi - lo) / 2;
                x = lo + dx;
            }
        }
        return (lo, true);
    }

    /// @dev F(out) and ∂F/∂xⱼ (as `_gradient` returns it) at the state with
    ///      `out` removed from asset j. Caller guarantees `out` is in the domain.
    function _residual(TorusState memory s, uint256 xjOld, uint256 out, int256 rhs)
        private
        pure
        returns (int256 f, bool gOk, bool gNeg, uint256 g)
    {
        TorusState memory t = _applyOutput(s, xjOld, out);
        (bool t1Neg, uint256 t1, uint256 wNorm) = _terms(t);
        uint256 t2 = wNorm >= t.sBound ? wNorm - t.sBound : t.sBound - wNorm;
        f = int256(FullMath.mulDiv(t1, t1, WAD) + FullMath.mulDiv(t2, t2, WAD)) - rhs;
        (gOk, gNeg, g) = _gradient(t, t1Neg, t1, wNorm, xjOld - out);
    }

    /// @dev Apply output-side reserve change to a copy of state.
    ///      NOTE: memory-struct assignment in Solidity aliases the reference,
    ///      so each field must be copied explicitly to avoid mutating `s`.
    function _applyOutput(
        TorusState memory s,
        uint256 xjOld,
        uint256 amount
    ) private pure returns (TorusState memory t) {
        if (xjOld < amount) revert OutputExceedsReserve();
        t.rInt   = s.rInt;
        t.kBound = s.kBound;
        t.sBound = s.sBound;
        t.n      = s.n;
        t.sqrtN  = s.sqrtN;
        t.sumX   = s.sumX - amount;
        // sumXSq decreases by xj² - (xj-amount)² = 2*xj*amount - amount²
        uint256 twoXjAmount = FullMath.mulDiv(2 * xjOld, amount, WAD);
        uint256 amountSq    = FullMath.mulDiv(amount, amount, WAD);
        // Σx² − 2·xⱼ·amount + amount² = (Σ over k≠j of xₖ²) + (xⱼ − amount)² ≥ 0,
        // so add before subtracting; near amount = xⱼ the other order dips
        // below zero. Floor rounding of the two products can still leave the
        // exact value a wei short, which saturates to 0.
        uint256 plus = s.sumXSq + amountSq;
        t.sumXSq = plus > twoXjAmount ? plus - twoXjAmount : 0;
    }
}
