// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {TorusMath} from "../src/libraries/TorusMath.sol";
import {SphereMath} from "../src/libraries/SphereMath.sol";
import {FullMath} from "../src/libraries/FullMath.sol";

/// @notice Pure-math benchmark of the Orbital curve to find the real levers for
///         near-peg slippage / IL. Uses the same libraries the hook calls, so a
///         single all-interior tick (kBound=0, sBound=0) == sphere of radius rInt.
///
///         Run: forge test --match-path test/Benchmark.t.sol -vv
contract BenchmarkTest is Test {
    uint256 constant WAD = 1e18;

    // Build a balanced all-interior torus state of radius R with n assets.
    function _balanced(uint256 R, uint256 n)
        internal
        pure
        returns (TorusMath.TorusState memory s, uint256[] memory res)
    {
        uint256 perAsset = SphereMath.equalPricePoint(R, n);
        res = new uint256[](n);
        uint256 sumX;
        uint256 sumXSq;
        for (uint256 i; i < n; ++i) {
            res[i] = perAsset;
            sumX += perAsset;
            sumXSq += FullMath.mulDiv(perAsset, perAsset, WAD);
        }
        s = TorusMath.TorusState({rInt: R, kBound: 0, sBound: 0, sumX: sumX, sumXSq: sumXSq, n: n});
    }

    function _quote(uint256 R, uint256 n, uint256 amountIn) internal pure returns (uint256) {
        (TorusMath.TorusState memory s, uint256[] memory res) = _balanced(R, n);
        return TorusMath.solveSwap(s, 0, 1, amountIn, res);
    }

    // bps of slippage vs a perfect 1:1 (pre-fee; the hook fee is separate).
    function _slipBps(uint256 amountIn, uint256 amountOut) internal pure returns (uint256) {
        if (amountOut >= amountIn) return 0;
        return (amountIn - amountOut) * 10_000 / amountIn;
    }

    // ─────────────────────────────────────────────────────────────
    // 1. Slippage vs depth (n = 4, fixed 1000-token swap)
    // ─────────────────────────────────────────────────────────────

    function test_slippage_vs_depth() public pure {
        console2.log("=== slippage vs depth (n=4, swap 1000) ===");
        uint256 amtIn = 1_000 ether;
        uint256[5] memory depths = [uint256(100_000 ether), 500_000 ether, 2_000_000 ether, 10_000_000 ether, 50_000_000 ether];
        for (uint256 i; i < depths.length; ++i) {
            uint256 out = _quote(depths[i], 4, amtIn);
            console2.log("  rInt(k):", depths[i] / 1e21);
            console2.log("    out:", out, "slip(bps):", _slipBps(amtIn, out));
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 2. Slippage vs swap size as % of depth (n=4, rInt=1M)
    // ─────────────────────────────────────────────────────────────

    function test_slippage_vs_swapsize() public pure {
        console2.log("=== slippage vs swap size (n=4, rInt=1,000,000) ===");
        uint256 R = 1_000_000 ether;
        uint256[5] memory amts = [uint256(100 ether), 1_000 ether, 10_000 ether, 50_000 ether, 100_000 ether];
        for (uint256 i; i < amts.length; ++i) {
            uint256 out = _quote(R, 4, amts[i]);
            console2.log("  in:", amts[i] / 1e18);
            console2.log("    out:", out, "slip(bps):", _slipBps(amts[i], out));
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 3. Slippage vs n (fixed per-asset depth, fixed swap)
    // ─────────────────────────────────────────────────────────────

    function test_slippage_vs_n() public pure {
        console2.log("=== slippage vs n (rInt scaled so per-asset depth fixed, swap 1000) ===");
        uint256 amtIn = 1_000 ether;
        // Keep per-asset reserve ~constant: perAsset = R(1-1/sqrt(n)). Pick R so perAsset ~= 250k.
        for (uint256 n = 2; n <= 5; ++n) {
            // Solve R from perAsset target: R = target / (1 - 1/sqrt(n)).
            uint256 sqrtN = SphereMath.sqrt(n * WAD * WAD);
            uint256 oneMinus = WAD - FullMath.mulDiv(WAD, WAD, sqrtN); // (1 - 1/sqrt(n)) in WAD
            uint256 R = FullMath.mulDiv(250_000 ether, WAD, oneMinus);
            uint256 out = _quote(R, n, amtIn);
            console2.log("  n:", n);
            console2.log("    out:", out, "slip(bps):", _slipBps(amtIn, out));
        }
    }
}
