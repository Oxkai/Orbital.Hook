// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SphereMath} from "../src/libraries/SphereMath.sol";
import {FullMath} from "../src/libraries/FullMath.sol";

/// @notice Safety properties of the shared math primitives: they must return a
///         verdict over the whole domain the pool can reach, not panic on it.
contract MathSafetyTest is Test {
    uint256 constant WAD = 1e18;

    /// @dev A perfectly balanced pool: every reserve at the equal-price point,
    ///      which is exactly on the sphere.
    function _balanced(uint256 r, uint256 n)
        internal
        pure
        returns (uint256 sumX, uint256 sumXSq)
    {
        uint256 x = SphereMath.equalPricePoint(r, n);
        sumX = x * n;
        sumXSq = FullMath.mulDiv(x, x, WAD) * n;
    }

    /// @notice The invariant check must report `true` for a balanced pool at any
    ///         supported asset count.
    ///
    ///         `Σx` at the balanced point is `r(n − √n)`, which exceeds `n·r/2`
    ///         for every n > 4 (and equals it at n = 4). The check computes
    ///         `n·r² − 2r·Σx + Σx²` left to right, so that subtraction runs
    ///         negative on exactly the state a stablecoin pool sits at when
    ///         every asset is at peg — the most ordinary state there is.
    function test_checkSphereInvariant_holds_when_balanced() public pure {
        uint256 r = 1_000_000 ether;
        for (uint256 n = 2; n <= 10; ++n) {
            (uint256 sumX, uint256 sumXSq) = _balanced(r, n);
            assertTrue(
                SphereMath.checkSphereInvariant(sumX, sumXSq, r, n),
                "balanced pool reported off-sphere"
            );
        }
    }

    /// @notice A state genuinely off the sphere must be reported as such rather
    ///         than reverting: the caller's job is to decide what to do about it.
    function test_checkSphereInvariant_rejects_off_sphere_state() public pure {
        uint256 r = 1_000_000 ether;
        for (uint256 n = 2; n <= 10; ++n) {
            (uint256 sumX, uint256 sumXSq) = _balanced(r, n);
            // Inflate Σx² well past the 1 ppm tolerance while leaving Σx alone.
            assertFalse(
                SphereMath.checkSphereInvariant(sumX, sumXSq + sumXSq / 100, r, n),
                "off-sphere state reported as valid"
            );
        }
    }
}
