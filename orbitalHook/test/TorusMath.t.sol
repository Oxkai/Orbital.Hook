// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TorusMath}  from "../src/libraries/TorusMath.sol";
import {SphereMath} from "../src/libraries/SphereMath.sol";
import {FullMath}   from "../src/libraries/FullMath.sol";

contract TorusMathTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant R   = 100 * WAD;

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Build a balanced 2-asset torus state with rInt = R, no boundary ticks.
    ///      At this state the invariant holds exactly: LHS = rInt² (see notes below).
    function _balancedState() private pure returns (
        TorusMath.TorusState memory s,
        uint256[] memory reserves
    ) {
        uint256 n = 2;
        uint256 q = SphereMath.equalPricePoint(R, n); // r(1 - 1/sqrt(n))

        // rInt = R satisfies (alphaInt - rInt*sqrt(n))^2 + 0 = rInt^2
        // because alphaInt = q*sqrt(2) = (R - R/sqrt(2))*sqrt(2) = R*sqrt(2) - R
        // and rIntSqrtN = R*sqrt(2), so term1 = R. LHS = R^2/WAD = rhs.
        s.rInt   = R;
        s.kBound = 0;
        s.sBound = 0;
        s.n      = n;
        s.sumX   = n * q;
        s.sumXSq = n * FullMath.mulDiv(q, q, WAD);
        s.sqrtN  = SphereMath.sqrt(n * WAD * WAD);

        reserves = new uint256[](n);
        reserves[0] = q;
        reserves[1] = q;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // computeS
    // ─────────────────────────────────────────────────────────────────────────

    function test_computeS_leq_r() public pure {
        // s^2 = r^2 - (k - r*sqrt(n))^2 <= r^2 always
        uint256 n = 3;
        uint256 k = FullMath.mulDiv(R, 12e17, WAD); // some valid k
        uint256 s = TorusMath.computeS(R, k, n);
        assertLe(s, R, "boundary circle radius must not exceed sphere radius");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // alphaNorm
    // ─────────────────────────────────────────────────────────────────────────

    function test_alphaNorm_one_at_equal_price() public pure {
        // alphaNorm(alphaInt, rInt) = WAD when alphaInt == rInt
        uint256 val = 42 * WAD;
        assertEq(TorusMath.alphaNorm(val, val), WAD);
    }

    function test_alphaNorm_max_when_rInt_zero() public pure {
        assertEq(TorusMath.alphaNorm(99 * WAD, 0), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // torusLHS at equal price
    // ─────────────────────────────────────────────────────────────────────────

    function test_torusLHS_at_equal_price_equals_rIntSq() public pure {
        (TorusMath.TorusState memory s, ) = _balancedState();
        uint256 lhs = TorusMath.torusLHS(s);
        uint256 rhs = FullMath.mulDiv(s.rInt, s.rInt, WAD);
        // Allow integer-sqrt rounding slack (drift ~1e-18 of value)
        assertApproxEqAbs(lhs, rhs, 1e5, "LHS must equal rInt^2 at equal-price point");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // checkInvariant
    // ─────────────────────────────────────────────────────────────────────────

    function test_checkInvariant_valid_state_returns_true() public pure {
        (TorusMath.TorusState memory s, ) = _balancedState();
        (bool ok, uint256 drift) = TorusMath.checkInvariant(s);
        assertTrue(ok, "balanced state must pass invariant");
        assertLt(drift, 1e12, "drift must be below 1e-6 threshold");
    }

    function test_checkInvariant_corrupted_state_returns_false() public pure {
        (TorusMath.TorusState memory s, ) = _balancedState();
        // Corrupt sumX by halving it — destroys the invariant
        s.sumX = s.sumX / 2;
        (bool ok, ) = TorusMath.checkInvariant(s);
        assertFalse(ok, "corrupted state must fail invariant");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // solveSwap
    // ─────────────────────────────────────────────────────────────────────────

    function test_solveSwap_output_positive() public pure {
        (TorusMath.TorusState memory s, uint256[] memory reserves) = _balancedState();
        uint256 amountIn = 1 * WAD;
        uint256 amountOut = TorusMath.solveSwap(s, 0, 1, amountIn, reserves);
        assertGt(amountOut, 0, "swap must produce positive output");
    }

    function test_solveSwap_invariant_holds_after() public pure {
        (TorusMath.TorusState memory s, uint256[] memory reserves) = _balancedState();

        uint256 xjOld    = reserves[1];
        uint256 amountIn = 1 * WAD;

        // solveSwap mutates s (applies input side internally)
        uint256 amountOut = TorusMath.solveSwap(s, 0, 1, amountIn, reserves);

        assertGt(amountOut, 0,     "amountOut must be positive");
        assertLt(amountOut, xjOld, "amountOut must be less than reserve");

        // Apply output side using delta form
        uint256 twoXjAmount = FullMath.mulDiv(2 * xjOld, amountOut, WAD);
        uint256 amountOutSq = FullMath.mulDiv(amountOut, amountOut, WAD);
        s.sumX   -= amountOut;
        s.sumXSq  = s.sumXSq - twoXjAmount + amountOutSq;

        (bool ok, uint256 drift) = TorusMath.checkInvariant(s);
        assertTrue(ok, string.concat("invariant failed, drift=", vm.toString(drift)));
    }

    function test_solveSwap_symmetry() public pure {
        (TorusMath.TorusState memory s0, uint256[] memory res0) = _balancedState();

        uint256 amountIn = 2 * WAD;

        // Forward: 0 -> 1
        uint256 amountOut01 = TorusMath.solveSwap(s0, 0, 1, amountIn, res0);

        // Build state after forward swap
        uint256 q = res0[0];
        uint256[] memory res1 = new uint256[](2);
        res1[0] = q + amountIn;
        res1[1] = q - amountOut01;

        (TorusMath.TorusState memory s1, ) = _balancedState();
        // Update s1 to reflect post-swap reserves
        s1.sumX   = res1[0] + res1[1];
        s1.sumXSq = FullMath.mulDiv(res1[0], res1[0], WAD)
                  + FullMath.mulDiv(res1[1], res1[1], WAD);

        // Reverse: 1 -> 0 using amountOut01 as the new amountIn
        uint256 amountOut10 = TorusMath.solveSwap(s1, 1, 0, amountOut01, res1);

        // Due to finite Newton precision and pool asymmetry, result should be
        // close to the original amountIn. Tolerance: 1e14 (0.01%).
        assertApproxEqAbs(amountOut10, amountIn, 1e14, "reverse swap should approximately restore");
    }

    function testFuzz_solveSwap_invariant(uint256 amountIn) public pure {
        (TorusMath.TorusState memory s, uint256[] memory reserves) = _balancedState();

        // BOUND FIRST — before any arithmetic touches amountIn
        amountIn = bound(amountIn, s.rInt / 10_000, s.rInt / 20);
        // Bound to realistic swap size: 0.01% to 5% of pool
        amountIn = bound(amountIn, s.rInt / 10_000, s.rInt / 20);

        uint256 xiOld = reserves[0];
        uint256 xjOld = reserves[1];

        // Apply input side first
        uint256 twoXiAmount = FullMath.mulDiv(2 * xiOld, amountIn, WAD);
        uint256 amountInSq  = FullMath.mulDiv(amountIn,  amountIn,  WAD);
        s.sumX   += amountIn;
        s.sumXSq += twoXiAmount + amountInSq;

        // Solve for output
        uint256 amountOut = TorusMath.solveSwap(s, 0, 1, amountIn, reserves);

        // Validate output
        assertGt(amountOut, 0,    "amountOut must be positive");
        assertLt(amountOut, xjOld, "amountOut must be less than reserve");

        // Apply output side
        uint256 twoXjAmount = FullMath.mulDiv(2 * xjOld, amountOut, WAD);
        uint256 amountOutSq = FullMath.mulDiv(amountOut, amountOut, WAD);
        s.sumX   -= amountOut;
        s.sumXSq  = s.sumXSq - twoXjAmount + amountOutSq;

        // Check invariant
        (bool ok, uint256 drift) = TorusMath.checkInvariant(s);
        assertTrue(ok, "invariant must hold after swap");

        // Log drift for visibility during development
        assertLt(drift, 2e16, "absolute drift must be below 2e16");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // marginalPrice
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A 3-asset state ON the torus manifold with a boundary tick
    ///      (kBound, sBound > 0), built from the invariant directly:
    ///        pick  αInt − rInt√n = −0.9·rInt,
    ///        then  ‖w‖ − sBound  = √(rInt² − (0.9·rInt)²),
    ///        and   x = mean·(1,1,1) + ‖w‖·(1,−1,0)/√2.
    ///      Assets 0 and 1 sit on opposite sides of the mean and asset 2 on it,
    ///      so every pair has a distinct, non-unit price.
    function _torusWithBoundary() private pure returns (TorusMath.TorusState memory s, uint256[] memory x) {
        uint256 n = 3;
        s.n = n;
        s.sqrtN = SphereMath.sqrt(n * WAD * WAD);
        s.rInt = R;
        s.kBound = 45 * WAD;
        s.sBound = TorusMath.computeS(50 * WAD, s.kBound, n);

        uint256 t1 = FullMath.mulDiv(R, 9, 10);
        uint256 alphaInt = FullMath.mulDiv(R, s.sqrtN, WAD) - t1;
        uint256 t2 = SphereMath.sqrt((FullMath.mulDiv(R, R, WAD) - FullMath.mulDiv(t1, t1, WAD)) * WAD);
        uint256 wNorm = s.sBound + t2;

        uint256 mean = FullMath.mulDiv(alphaInt + s.kBound, s.sqrtN, WAD) / n;
        uint256 c = FullMath.mulDiv(wNorm, WAD, SphereMath.sqrt(2 * WAD * WAD));

        x = new uint256[](n);
        x[0] = mean + c;
        x[1] = mean - c;
        x[2] = mean;
        s.sumX = x[0] + x[1] + x[2];
        s.sumXSq = FullMath.mulDiv(x[0], x[0], WAD) + FullMath.mulDiv(x[1], x[1], WAD) + FullMath.mulDiv(x[2], x[2], WAD);
    }

    /// @dev `solveSwap` mutates its state argument; hand it a field-wise copy.
    function _copy(TorusMath.TorusState memory s) private pure returns (TorusMath.TorusState memory t) {
        t.rInt = s.rInt;
        t.kBound = s.kBound;
        t.sBound = s.sBound;
        t.sumX = s.sumX;
        t.sumXSq = s.sumXSq;
        t.n = s.n;
        t.sqrtN = s.sqrtN;
    }

    function test_marginalPrice_is_one_at_equal_price() public pure {
        (TorusMath.TorusState memory s, uint256[] memory x) = _balancedState();
        assertEq(TorusMath.marginalPrice(s, x[0], x[1]), WAD);
    }

    /// @notice With no boundary ticks the torus gradient collapses to the
    ///         sphere's, so the price must equal `SphereMath.spotPrice` for any
    ///         reserves inside the sphere.
    function testFuzz_marginalPrice_equals_sphere_spotPrice_without_boundary(uint256[4] memory seeds) public pure {
        uint256 n = 4;
        uint256[] memory x = new uint256[](n);
        TorusMath.TorusState memory s;
        for (uint256 i; i < n; ++i) {
            x[i] = bound(seeds[i], 1 * WAD, 90 * WAD);
            s.sumX += x[i];
            s.sumXSq += FullMath.mulDiv(x[i], x[i], WAD);
        }
        s.rInt = R;
        s.n = n;
        s.sqrtN = SphereMath.sqrt(n * WAD * WAD);

        assertApproxEqRel(
            TorusMath.marginalPrice(s, x[0], x[1]), SphereMath.spotPrice(R, x[0], x[1]), 1e6, "sphere reduction"
        );
    }

    function test_marginalPrice_is_reciprocal_on_a_torus() public pure {
        (TorusMath.TorusState memory s, uint256[] memory x) = _torusWithBoundary();
        uint256 p01 = TorusMath.marginalPrice(s, x[0], x[1]);
        uint256 p10 = TorusMath.marginalPrice(s, x[1], x[0]);
        assertApproxEqRel(FullMath.mulDiv(p01, p10, WAD), WAD, 1e6, "P(i,j) * P(j,i) != 1");
    }

    /// @notice The analytic gradient must agree with what the engine's own
    ///         Newton solver actually charges for a tiny trade, on a state with
    ///         a boundary tick, where the torus term is live.
    function test_marginalPrice_matches_the_solver_on_a_torus_with_boundary() public pure {
        (TorusMath.TorusState memory s, uint256[] memory x) = _torusWithBoundary();
        assertGt(s.kBound, 0);
        assertGt(s.sBound, 0);
        (bool onManifold,) = TorusMath.checkInvariant(s);
        assertTrue(onManifold, "fixture is off the manifold");

        uint256[2][4] memory pairs = [[uint256(0), 1], [uint256(1), 0], [uint256(0), 2], [uint256(2), 1]];
        for (uint256 p; p < pairs.length; ++p) {
            (uint256 i, uint256 j) = (pairs[p][0], pairs[p][1]);
            uint256 dx = R / 1e7;
            uint256 dy = TorusMath.solveSwap(_copy(s), i, j, dx, x);
            // A finite trade pays slightly above the marginal price (curvature
            // ~ dx/R = 1e-7), well inside the 1e-6 tolerance.
            assertApproxEqRel(
                FullMath.mulDiv(dx, WAD, dy), TorusMath.marginalPrice(s, x[i], x[j]), 1e12, "gradient != solver"
            );
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // solveSwapBounded: safeguarded Newton
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Invariant residual LHS − rInt² after `amountIn` of asset 0 in and
    ///      `out` of asset 1 out, applied in the same order and with the same
    ///      rounding as the solver.
    function _residualAfter(uint256 amountIn, uint256 out) private pure returns (int256) {
        (TorusMath.TorusState memory s, uint256[] memory x) = _balancedState();
        s.sumX = s.sumX + amountIn - out;
        s.sumXSq = s.sumXSq + FullMath.mulDiv(2 * x[0], amountIn, WAD) + FullMath.mulDiv(amountIn, amountIn, WAD)
            - FullMath.mulDiv(2 * x[1], out, WAD) + FullMath.mulDiv(out, out, WAD);
        return int256(TorusMath.torusLHS(s)) - int256(FullMath.mulDiv(s.rInt, s.rInt, WAD));
    }

    /// @notice The output is the pool-favourable end of a 1-wei bracket around
    ///         the root: the invariant is not exceeded, and one more wei would.
    function testFuzz_solveSwapBounded_returns_the_tight_pool_favourable_root(uint256 amountIn) public pure {
        // Up to ~70.7·WAD of asset 0 can enter a 2-asset sphere of radius 100
        // before asset 1 is drained.
        amountIn = bound(amountIn, 1e12, 70 * WAD);
        (TorusMath.TorusState memory s, uint256[] memory x) = _balancedState();
        (uint256 out, bool found) = TorusMath.solveSwapBounded(s, 0, 1, amountIn, x);

        assertTrue(found, "solvable trade reported unsolvable");
        assertGt(out, 0, "no output for a real trade");
        int256 f = _residualAfter(amountIn, out);
        assertLe(f, 0, "pool paid more than the invariant allows");
        if (f != 0) assertGt(_residualAfter(amountIn, out + 1), 0, "output not tight to the root");
    }

    /// @notice A trade the sphere cannot absorb at any output is reported, not
    ///         answered with an output of 0 that would swallow the input. On a
    ///         2-asset sphere of radius 100 centred at (100, 100), x₀ can reach
    ///         2r = 200 at most, so more than ~170.7 of input is unabsorbable.
    function testFuzz_solveSwapBounded_reports_trades_beyond_the_pool(uint256 amountIn) public pure {
        amountIn = bound(amountIn, 175 * WAD, 1e9 * WAD);
        (TorusMath.TorusState memory s, uint256[] memory x) = _balancedState();
        (uint256 out, bool found) = TorusMath.solveSwapBounded(s, 0, 1, amountIn, x);
        assertFalse(found, "an impossible trade was solved");
        assertEq(out, 0);
    }

    /// @notice `solveSwap` keeps its all-or-nothing contract for callers that
    ///         have no crossing logic to fall back on.
    function test_solveSwap_reverts_when_no_solution_exists() public {
        (TorusMath.TorusState memory s, uint256[] memory x) = _balancedState();
        vm.expectRevert(TorusMath.NoSolutionInConfiguration.selector);
        this.solveExternal(s, 1000 * WAD, x);
    }

    function solveExternal(TorusMath.TorusState memory s, uint256 amountIn, uint256[] memory x)
        external
        pure
        returns (uint256)
    {
        return TorusMath.solveSwap(s, 0, 1, amountIn, x);
    }
}
