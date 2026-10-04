// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {QuadraticSolver} from "../src/libraries/QuadraticSolver.sol";

/// @notice The tick-crossing quadratic f(p) = 2p² + b·p + c·WAD.
///
///         Expectations come from the algebra, not from the implementation: a
///         quadratic built as 2(p − r₁)(p − r₂) has roots exactly r₁ and r₂, so
///         the solver must return them to the wei; and for arbitrary
///         coefficients the returned root must bracket a true root within one
///         wei, which is what a closed form with an exact integer √ promises.
contract QuadraticSolverTest is Test {
    int256 internal constant WAD = 1e18;

    /// Coefficient bound for the arbitrary-coefficient fuzz, so the test's own
    /// evaluation of f stays inside int256.
    int256 internal constant COEF_MAX = 1e20;

    function _f(int256 p, int256 b, int256 c) internal pure returns (int256) {
        return 2 * p * p + b * p + c * WAD;
    }

    /// f = 2(p − r₁)(p − r₂) = 2p² − 2(r₁ + r₂)p + 2r₁r₂. With r = a·1e9 the
    /// constant 2r₁r₂ = 2·a₁a₂·WAD, so c = 2a₁a₂ is exact and so is every root.
    function _fromRoots(uint256 a1, uint256 a2) internal pure returns (int256 b, int256 c, uint256 r1, uint256 r2) {
        (r1, r2) = a1 <= a2 ? (a1 * 1e9, a2 * 1e9) : (a2 * 1e9, a1 * 1e9);
        b = -2 * (int256(r1) + int256(r2));
        c = 2 * int256(a1) * int256(a2);
    }

    // ─────────────────────────────────────────────────────────────
    // Exact roots
    // ─────────────────────────────────────────────────────────────

    function test_returns_smaller_root_exactly() public pure {
        (int256 b, int256 c, uint256 r1,) = _fromRoots(1_000, 10_000);
        (uint256 p, bool found) = QuadraticSolver.smallestRootAtLeast(b, c, 0);
        assertTrue(found);
        assertEq(p, r1, "not the smaller root");
    }

    /// The crossing's input is p − D on a falling trade; a root below D would
    /// mean a negative input, so the solver must skip past it.
    function test_lower_bound_skips_the_root_behind_it() public pure {
        (int256 b, int256 c, uint256 r1, uint256 r2) = _fromRoots(1_000, 10_000);
        (uint256 p, bool found) = QuadraticSolver.smallestRootAtLeast(b, c, r1 + 1);
        assertTrue(found);
        assertEq(p, r2, "did not advance to the root at or past lo");
    }

    function test_lower_bound_is_inclusive() public pure {
        (int256 b, int256 c, uint256 r1,) = _fromRoots(1_000, 10_000);
        (uint256 p, bool found) = QuadraticSolver.smallestRootAtLeast(b, c, r1);
        assertTrue(found);
        assertEq(p, r1, "a root exactly at lo must qualify");
    }

    function test_no_root_past_lo_is_reported() public pure {
        (int256 b, int256 c,, uint256 r2) = _fromRoots(1_000, 10_000);
        (, bool found) = QuadraticSolver.smallestRootAtLeast(b, c, r2 + 1);
        assertFalse(found, "reported a root that is behind lo");
    }

    /// r₁ < 0 < r₂: only r₂ is a trade.
    function test_negative_root_is_never_returned() public pure {
        int256 r1 = -1e15;
        int256 r2 = 1e14;
        // 2(p − r₁)(p − r₂) with c·WAD = 2r₁r₂ ⇒ c = 2r₁r₂ / WAD.
        int256 b = -2 * (r1 + r2);
        int256 c = (2 * r1 * r2) / WAD;
        (uint256 p, bool found) = QuadraticSolver.smallestRootAtLeast(b, c, 0);
        assertTrue(found);
        assertEq(p, uint256(r2));
    }

    function test_both_roots_negative_is_not_found() public pure {
        // 2(p + 1e15)(p + 2e15): roots −1e15 and −2e15.
        int256 b = 2 * 3e15;
        int256 c = (2 * 1e15 * 2e15) / WAD;
        (, bool found) = QuadraticSolver.smallestRootAtLeast(b, c, 0);
        assertFalse(found);
    }

    // ─────────────────────────────────────────────────────────────
    // Negative discriminant: only a grazing double root, taken at the vertex
    // ─────────────────────────────────────────────────────────────

    function test_negative_discriminant_takes_the_vertex() public pure {
        // b = −4e10, c = 1e9 ⇒ disc = 1.6e21 − 8e27 < 0; vertex −b/4 = 1e10.
        (uint256 p, bool found) = QuadraticSolver.smallestRootAtLeast(-4e10, 1e9, 0);
        assertTrue(found);
        assertEq(p, 1e10);
    }

    function test_negative_discriminant_vertex_behind_lo_is_not_found() public pure {
        (, bool found) = QuadraticSolver.smallestRootAtLeast(-4e10, 1e9, 1e10 + 1);
        assertFalse(found);
    }

    function test_negative_discriminant_negative_vertex_is_not_found() public pure {
        (, bool found) = QuadraticSolver.smallestRootAtLeast(4e10, 1e9, 0);
        assertFalse(found);
    }

    // ─────────────────────────────────────────────────────────────
    // Properties
    // ─────────────────────────────────────────────────────────────

    /// Integer roots come back exactly, and `lo` selects between them.
    function testFuzz_exact_roots_and_lower_bound(uint64 a1, uint64 a2, uint256 loRaw) public pure {
        (int256 b, int256 c, uint256 r1, uint256 r2) = _fromRoots(uint256(a1), uint256(a2));
        uint256 lo = bound(loRaw, 0, r2 + 1e9);

        (uint256 p, bool found) = QuadraticSolver.smallestRootAtLeast(b, c, lo);

        if (lo <= r1) {
            assertTrue(found);
            assertEq(p, r1, "smaller root");
        } else if (lo <= r2) {
            assertTrue(found);
            assertEq(p, r2, "larger root");
        } else {
            assertFalse(found, "no root at or past lo");
        }
    }

    /// For arbitrary coefficients with well-separated real roots, the result is
    /// within one wei of a true root: f changes sign across [p − 1, p + 1].
    function testFuzz_result_brackets_a_true_root(uint256 bRaw, uint256 cRaw) public pure {
        uint256 span = uint256(COEF_MAX) * 2;
        int256 b = int256(bRaw % (span + 1)) - COEF_MAX;
        int256 c = int256(cRaw % (span + 1)) - COEF_MAX;

        // Roots at least a few wei apart: a near-double root need not change
        // sign across the bracket, and is covered by the vertex tests.
        int256 disc = b * b - 8 * c * WAD;
        if (disc < 64) return;

        (uint256 p, bool found) = QuadraticSolver.smallestRootAtLeast(b, c, 0);
        if (!found || p == 0) return;

        int256 ip = int256(p);
        int256 lo = _f(ip - 1, b, c);
        int256 hi = _f(ip + 1, b, c);
        assertTrue((lo <= 0 && hi >= 0) || (lo >= 0 && hi <= 0), "no true root within one wei");
    }

    /// Whatever the coefficients, the solver returns rather than overflowing:
    /// there is no iteration left to run away.
    function testFuzz_never_reverts_in_bounded_range(uint256 bRaw, uint256 cRaw, uint256 lo) public pure {
        uint256 span = uint256(COEF_MAX) * 2;
        int256 b = int256(bRaw % (span + 1)) - COEF_MAX;
        int256 c = int256(cRaw % (span + 1)) - COEF_MAX;
        QuadraticSolver.smallestRootAtLeast(b, c, lo);
    }
}
