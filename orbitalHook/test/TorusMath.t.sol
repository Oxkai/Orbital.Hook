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
}
