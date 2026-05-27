// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {SphereMath} from "../src/libraries/SphereMath.sol";

contract SphereMathHarness {
    function spotPrice(uint256 r, uint256 xi, uint256 xj) external pure returns (uint256) {
        return SphereMath.spotPrice(r, xi, xj);
    }
    function computeWNormSq(uint256[] calldata reserves, uint256 n) external pure returns (uint256) {
        return SphereMath.computeWNormSq(reserves, n);
    }
}

contract SphereMathTest is Test {
    SphereMathHarness harness = new SphereMathHarness();
    uint256 constant WAD = 1e18;

    // ─────────────────────────────────────────────────────────────────────────
    // sqrt
    // ─────────────────────────────────────────────────────────────────────────

    function test_sqrt_zero() public pure {
        assertEq(SphereMath.sqrt(0), 0);
    }

    function test_sqrt_perfect_squares() public pure {
        assertEq(SphereMath.sqrt(4),   2);
        assertEq(SphereMath.sqrt(9),   3);
        assertEq(SphereMath.sqrt(16),  4);
        // sqrt(1e18) = 1e9 exactly
        assertEq(SphereMath.sqrt(1e18), 1e9);
    }

    function test_sqrt_floor() public pure {
        // floor property: sqrt(x)² ≤ x < (sqrt(x)+1)²
        uint256[6] memory cases = [
            uint256(2), 3, 5, 7, 1e18 + 1, type(uint128).max
        ];
        for (uint256 i; i < cases.length; ++i) {
            uint256 x = cases[i];
            uint256 z = SphereMath.sqrt(x);
            assertLe(z * z, x, "z^2 <= x");
            // (z+1)^2 > x  —  use unchecked to avoid overflow on very large z
            unchecked {
                assertTrue((z + 1) * (z + 1) > x || z + 1 == 0, "(z+1)^2 > x");
            }
        }
    }

    function fuzz_sqrt(uint256 x) public pure {
        uint256 z = SphereMath.sqrt(x);
        assertLe(z * z, x, "z^2 <= x");
        if (z < type(uint128).max) {
            unchecked {
                assertTrue((z + 1) * (z + 1) > x, "(z+1)^2 > x");
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // equalPricePoint
    // ─────────────────────────────────────────────────────────────────────────

    // q = r(1 − 1/√n).  We verify by comparing to an independent calculation.

    function test_equalPricePoint_n2() public pure {
        uint256 r = 100 * WAD;
        // √2 ≈ 1.41421356... → q = r(1 - 1/√2) ≈ r · 0.29289...
        uint256 q = SphereMath.equalPricePoint(r, 2);
        // 1/√2 = WAD / sqrt(2·WAD²) = WAD / sqrt(2e36)
        uint256 sqrtN = SphereMath.sqrt(2 * WAD * WAD);
        uint256 expected = r - (r * WAD / sqrtN);
        assertApproxEqAbs(q, expected, 1, "n=2");
    }

    function test_equalPricePoint_n3() public pure {
        uint256 r = 100 * WAD;
        uint256 q = SphereMath.equalPricePoint(r, 3);
        uint256 sqrtN = SphereMath.sqrt(3 * WAD * WAD);
        uint256 expected = r - (r * WAD / sqrtN);
        assertApproxEqAbs(q, expected, 1, "n=3");
    }

    function test_equalPricePoint_n4() public pure {
        uint256 r = 100 * WAD;
        // √4 = 2 exactly → q = r(1 - 1/2) = r/2
        uint256 q = SphereMath.equalPricePoint(r, 4);
        assertApproxEqAbs(q, r / 2, 1, "n=4 should be r/2");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // spotPrice
    // ─────────────────────────────────────────────────────────────────────────

    function test_spotPrice_at_equal_price_is_one() public pure {
        uint256 r  = 100 * WAD;
        uint256 xi = 50  * WAD;
        uint256 xj = 50  * WAD;
        // (r - xj) / (r - xi) = 50/50 = 1.0 WAD
        assertEq(SphereMath.spotPrice(r, xi, xj), WAD);
    }

    function test_spotPrice_directional() public pure {
        uint256 r  = 100 * WAD;
        // Add to xi (increase reserve i) → r - xi shrinks → price i rises (asset i gets cheaper)
        uint256 xiSmall = 30 * WAD;
        uint256 xiBig   = 60 * WAD;
        uint256 xj      = 50 * WAD;
        uint256 priceSmall = SphereMath.spotPrice(r, xiSmall, xj);
        uint256 priceBig   = SphereMath.spotPrice(r, xiBig,   xj);
        // Larger xi → denominator (r-xi) is smaller → price ratio is larger
        assertGt(priceBig, priceSmall, "larger xi means higher price ratio");
    }

    function test_spotPrice_reverts_when_xj_ge_r() public {
        vm.expectRevert("SphereMath: reserve exceeds radius");
        harness.spotPrice(100 * WAD, 50 * WAD, 100 * WAD);
    }

    function test_spotPrice_reverts_when_xi_ge_r() public {
        vm.expectRevert("SphereMath: reserve exceeds radius");
        harness.spotPrice(100 * WAD, 100 * WAD, 50 * WAD);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // computeWNormSq
    // ─────────────────────────────────────────────────────────────────────────

    function test_wNormSq_zero_at_equal_price() public pure {
        // All reserves equal → all deviations from mean are 0.
        uint256[] memory reserves = new uint256[](3);
        reserves[0] = 50 * WAD;
        reserves[1] = 50 * WAD;
        reserves[2] = 50 * WAD;
        assertEq(SphereMath.computeWNormSq(reserves, 3), 0);
    }

    function test_wNormSq_nonzero_after_imbalance() public pure {
        uint256[] memory reserves = new uint256[](3);
        reserves[0] = 60 * WAD;
        reserves[1] = 50 * WAD;
        reserves[2] = 40 * WAD;
        uint256 w2 = SphereMath.computeWNormSq(reserves, 3);
        assertGt(w2, 0, "imbalanced pool has non-zero w norm sq");
        // mean = 50, deviations = [10, 0, 10], squared = [100, 0, 100] WAD-normalised
        // Σ = 200 WAD-normalised = 200e18
        uint256 expected = 200 * WAD;
        assertApproxEqAbs(w2, expected, WAD / 1e6, "sum of squared deviations");
    }

    function test_wNormSq_reverts_on_length_mismatch() public {
        uint256[] memory reserves = new uint256[](2);
        reserves[0] = 50 * WAD;
        reserves[1] = 50 * WAD;
        vm.expectRevert("SphereMath: length mismatch");
        harness.computeWNormSq(reserves, 3);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // checkSphereInvariant
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev At the equal-price point all xᵢ = q, so:
    ///      sumX  = n·q
    ///      sumXSq = n · (q²/WAD)
    ///      The invariant should pass because the point sits exactly on the sphere.
    function test_sphereInvariant_holds_at_equalPrice() public pure {
        uint256 n = 4;
        uint256 r = 100 * WAD;
        uint256 q = SphereMath.equalPricePoint(r, n);

        uint256 sumX   = n * q;
        // each xᵢ² / WAD
        uint256 xiSq   = q * q / WAD;
        uint256 sumXSq = n * xiSq;

        bool ok = SphereMath.checkSphereInvariant(sumX, sumXSq, r, n);
        assertTrue(ok, "invariant must hold at equal-price point");
    }

    function test_sphereInvariant_fails_on_bad_state() public pure {
        // Completely wrong values — invariant should not hold
        uint256 r     = 100 * WAD;
        uint256 sumX  = 10  * WAD;   // way off
        uint256 sumXSq = 1  * WAD;
        bool ok = SphereMath.checkSphereInvariant(sumX, sumXSq, r, 4);
        assertFalse(ok, "bad state must fail invariant");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // computeAlpha
    // ─────────────────────────────────────────────────────────────────────────

    function test_computeAlpha_n4() public pure {
        // n=4, √4=2 → alpha = sumX / 2
        uint256 sumX = 200 * WAD;
        uint256 alpha = SphereMath.computeAlpha(sumX, 4);
        assertApproxEqAbs(alpha, 100 * WAD, 1, "alpha = sumX/2 for n=4");
    }

    function test_computeAlpha_scales_with_sumX() public pure {
        uint256 alpha1 = SphereMath.computeAlpha(100 * WAD, 4);
        uint256 alpha2 = SphereMath.computeAlpha(200 * WAD, 4);
        assertApproxEqAbs(alpha2, 2 * alpha1, 2, "alpha scales linearly with sumX");
    }
}
