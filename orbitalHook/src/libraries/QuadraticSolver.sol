// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SphereMath} from "./SphereMath.sol";

/// @title  QuadraticSolver
/// @notice Roots of the tick-crossing quadratic (paper §4.13):
///
///             f(p) = 2p² + b·p + c·WAD = 0
///
///         where `p` is the amount out, in WAD, that lands the pool exactly on
///         the crossed tick's plane. `p` and `b` are WAD-scaled amounts and `c`
///         a WAD-normalised square, so every term of `f` is in WAD².
///
/// @dev    The roots are computed in closed form, (−b ∓ √disc)/4 with
///         disc = b² − 8·c·WAD. In integer arithmetic this is already exact to
///         about a wei: the square root is the exact floor and the only other
///         rounding is the final division. There is no cancellation to repair —
///         that is a floating-point concern — so no iterative refinement is
///         needed, and none is done: a Newton pass could only add the risk of a
///         runaway step where f′ is near zero.
///
///         Inputs must keep `b²` and `8·c·WAD` inside int256. The hook bounds
///         both through `MAX_RINT`, which caps every reserve and so every
///         coefficient.
library QuadraticSolver {
    uint256 internal constant WAD = 1e18;

    /// @notice The smallest root of f that is at least `lo`.
    /// @dev    `lo` is what makes the answer a trade rather than just a root:
    ///         the amount in is `p + D` or `p − D` depending on which way the
    ///         trade moves Σx, and it cannot be negative. The caller passes 0 or
    ///         D accordingly, and the first root at or past it is the first
    ///         point on the trade's path that meets the plane.
    ///
    ///         A negative discriminant has no real root. The only way one
    ///         arises from a crossing that exists is a double root — the path
    ///         grazing the plane — that the floors in b and c pushed a hair
    ///         below zero. A double root sits at the vertex −b/4, so that is
    ///         where it is taken from.
    /// @return p     The root, WAD-scaled.
    /// @return found False when f has no real root ≥ `lo`.
    function smallestRootAtLeast(int256 b, int256 c, uint256 lo) internal pure returns (uint256 p, bool found) {
        int256 disc = b * b - 8 * c * int256(WAD);

        if (disc < 0) {
            int256 vertex = -b / 4;
            if (vertex >= 0 && uint256(vertex) >= lo) return (uint256(vertex), true);
            return (0, false);
        }

        int256 sq = int256(SphereMath.sqrt(uint256(disc)));

        // r1 ≤ r2 because f opens upward; the smaller one qualifying wins.
        int256 r1 = (-b - sq) / 4;
        if (r1 >= 0 && uint256(r1) >= lo) return (uint256(r1), true);

        int256 r2 = (-b + sq) / 4;
        if (r2 >= 0 && uint256(r2) >= lo) return (uint256(r2), true);

        return (0, false);
    }
}
