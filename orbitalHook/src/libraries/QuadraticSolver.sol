// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SphereMath} from "./SphereMath.sol";

/// @title  QuadraticSolver
/// @notice Smallest non-negative root of  2p² + b·p + c·WAD = 0.
/// @dev    Used by the Orbital tick-crossing swap path: given the per-cross
///         coefficients (b, c), `p` is the partial-trade amount that lands
///         the pool exactly on the next tick's plane.
///
///         Algorithm:
///           1. Closed-form seed from the quadratic formula (or vertex when
///              the discriminant is negative).
///           2. Up to 30 Newton refinement steps:
///                p ← p − f(p)/f'(p),  f(p) = 2p² + b·p + c·WAD,  f'(p) = 4p + b
///              Exit when |step| < max(p / 1e6, 100) — i.e. ≤ 1 ppm relative
///              error above p ≈ 1e8, or 100 wei absolute below it.
///
///         Pure function, no state — extracted from OrbitalHook so the solver
///         can be fuzz-tested directly without deploying the full hook.
library QuadraticSolver {
    uint256 internal constant WAD = 1e18;

    /// @notice Smallest non-negative root of 2p² + b·p + c·WAD = 0.
    /// @dev    Inputs must be bounded so that intermediate products stay within
    ///         int256. The OrbitalHook caller enforces this via `SwapAmountTooLarge`.
    function solveSmallestNonNegativeRoot(int256 bCoef, int256 cCoef) internal pure returns (uint256 p) {
        int256 wad = int256(WAD);
        int256 disc = bCoef * bCoef - 8 * cCoef * wad;

        if (disc >= 0) {
            uint256 sq = SphereMath.sqrt(uint256(disc));
            int256 r1 = (-bCoef - int256(sq)) / 4;
            int256 r2 = (-bCoef + int256(sq)) / 4;
            if (r1 >= 0 && (r2 < 0 || r1 <= r2)) {
                p = uint256(r1);
            } else if (r2 >= 0) {
                p = uint256(r2);
            }
        } else {
            int256 vertex = -bCoef / 4;
            p = vertex > 0 ? uint256(vertex) : 0;
        }

        for (uint256 i = 0; i < 30; ++i) {
            int256 ip = int256(p);
            int256 fp = 2 * ip * ip + bCoef * ip + cCoef * wad;
            int256 dfp = 4 * ip + bCoef;
            if (dfp == 0) break;
            int256 step = fp / dfp;

            // Newton update: p_next = p - f(p)/f'(p). The sign of `step` already
            // encodes direction, so a positive step decreases p and vice versa.
            uint256 absStep = step < 0 ? uint256(-step) : uint256(step);
            if (step > 0) {
                p = p >= absStep ? p - absStep : 0;
            } else {
                p += absStep;
            }

            uint256 eps = p / 1_000_000;
            if (eps < 100) eps = 100;
            if (absStep < eps) break;
        }
    }
}
