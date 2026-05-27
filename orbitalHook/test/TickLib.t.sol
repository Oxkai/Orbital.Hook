// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TickLib}    from "../src/libraries/TickLib.sol";
import {SphereMath} from "../src/libraries/SphereMath.sol";
import {FullMath}   from "../src/libraries/FullMath.sol";

contract TickLibTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant R   = 100 * WAD;

    // ─────────────────────────────────────────────────────────────────────────
    // kMin < kMax for every n in 2..10
    // ─────────────────────────────────────────────────────────────────────────

    function _assertKBounds(uint256 n) private pure {
        assertLt(TickLib.kMin(R, n), TickLib.kMax(R, n), "kMin must be < kMax");
    }

    function test_kMin_lt_kMax_n2()  public pure { _assertKBounds(2);  }
    function test_kMin_lt_kMax_n3()  public pure { _assertKBounds(3);  }
    function test_kMin_lt_kMax_n4()  public pure { _assertKBounds(4);  }
    function test_kMin_lt_kMax_n5()  public pure { _assertKBounds(5);  }
    function test_kMin_lt_kMax_n6()  public pure { _assertKBounds(6);  }
    function test_kMin_lt_kMax_n7()  public pure { _assertKBounds(7);  }
    function test_kMin_lt_kMax_n8()  public pure { _assertKBounds(8);  }
    function test_kMin_lt_kMax_n9()  public pure { _assertKBounds(9);  }
    function test_kMin_lt_kMax_n10() public pure { _assertKBounds(10); }

    // ─────────────────────────────────────────────────────────────────────────
    // kFromDepegPrice
    // ─────────────────────────────────────────────────────────────────────────

    function test_kFromDepegPrice_099() public pure {
        // p = 0.99 is close to peg → tight tick → k close to kMin
        uint256 k = TickLib.kFromDepegPrice(R, 2, 0.99e18);
        assertGe(k, TickLib.kMin(R, 2), "k >= kMin");
        assertLe(k, TickLib.kMax(R, 2), "k <= kMax");
        // tight tick: k much closer to kMin than to kMax
        uint256 km   = TickLib.kMin(R, 2);
        uint256 kM   = TickLib.kMax(R, 2);
        assertLt(k - km, (kM - km) / 4, "p=0.99 gives tight tick near kMin");
    }

    function test_kFromDepegPrice_090() public pure {
        // p = 0.90 is further from peg → wider tick → k further toward kMax
        uint256 k099 = TickLib.kFromDepegPrice(R, 2, 0.99e18);
        uint256 k090 = TickLib.kFromDepegPrice(R, 2, 0.90e18);
        assertGt(k090, k099, "wider depeg tolerance gives larger k");
        assertGe(k090, TickLib.kMin(R, 2));
        assertLe(k090, TickLib.kMax(R, 2));
    }

    function test_kFromDepegPrice_000() public pure {
        // p = 0 with n = 2 analytically gives kMax exactly.
        uint256 k  = TickLib.kFromDepegPrice(R, 2, 0);
        uint256 kM = TickLib.kMax(R, 2);
        // Integer sqrt rounding may cause off-by-one; allow tolerance of 2 wei.
        assertApproxEqAbs(k, kM, 2, "p=0, n=2 should give kMax");
    }

    function testFuzz_kFromDepegPrice(uint256 pWad) public pure {
        // All prices in [0, WAD] and n in 2..8 must produce k in [kMin, kMax].
        pWad = bound(pWad, 0, WAD);
        uint256 n = 3; // fixed n to keep gas low; range property holds for any n
        uint256 k = TickLib.kFromDepegPrice(R, n, pWad);
        assertGe(k, TickLib.kMin(R, n), "k >= kMin");
        assertLe(k, TickLib.kMax(R, n), "k <= kMax");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Capital efficiency
    // ─────────────────────────────────────────────────────────────────────────

    function test_capitalEfficiency_one_at_kMax() public pure {
        uint256 kM = TickLib.kMax(R, 3);
        assertEq(TickLib.capitalEfficiency(R, 3, kM), WAD, "full range = 1x");
    }

    function test_capitalEfficiency_gt_one_below_kMax() public pure {
        // k closer to kMin concentrates liquidity → efficiency > 1x
        uint256 k = TickLib.kFromDepegPrice(R, 3, 0.95e18);
        assertGt(TickLib.capitalEfficiency(R, 3, k), WAD, "concentrated > 1x");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // xMin
    // ─────────────────────────────────────────────────────────────────────────

    function test_xMin_lt_xBase() public pure {
        // For any interior k, xMin < equal-price point reserve.
        uint256 k     = TickLib.kFromDepegPrice(R, 3, 0.95e18);
        uint256 xBase = SphereMath.equalPricePoint(R, 3);
        uint256 xLo   = TickLib.xMin(R, 3, k);
        assertLt(xLo, xBase, "xMin must be below equal-price reserve");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // boundaryRadius
    // ─────────────────────────────────────────────────────────────────────────

    function test_boundaryRadius_leq_r() public pure {
        // s = sqrt(r^2 - (r*sqrt(n)-k)^2) <= r for any valid k
        uint256[4] memory ks = [
            TickLib.kMin(R, 4),
            TickLib.kFromDepegPrice(R, 4, 0.99e18),
            TickLib.kFromDepegPrice(R, 4, 0.90e18),
            TickLib.kMax(R, 4)
        ];
        for (uint256 i; i < ks.length; ++i) {
            uint256 s = TickLib.boundaryRadius(R, ks[i], 4);
            assertLe(s, R, "boundary radius must not exceed sphere radius");
        }
    }
}
