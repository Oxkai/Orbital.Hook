// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IAggregatorV3} from "../../src/fx/IAggregatorV3.sol";
import {SolvencyInvariantBase} from "../Solvency.invariant.t.sol";
import {MockAggregator} from "../utils/MockAggregator.sol";

/// @notice The solvency invariants run against the FX hook, where the raw <-> WAD
///         scales are NOT powers of ten.
///
/// @dev    Every asset is 6-decimal, so without pricing all three scales would be
///         1e12 and this run would add nothing over `SolvencyInvariantMixedDecimals`.
///         Instead two of them carry an oracle price folded into their scale, one
///         above the numeraire and one below:
///
///             index 0  EUR  1.15954500 -> scale 1.159545e12
///             index 1  USD  numeraire  -> scale 1e12
///             index 2  AUD  0.71700000 -> scale 0.717e12
///
///         so every rounding boundary in the scaling layer (swap in, swap out,
///         deposit, payout, fee collect) runs with a non-trivial multiplier. The
///         base handlers swap over key01, i.e. a priced asset against the
///         numeraire, and add/remove touch all three.
///
///         `h_moveOracle` drifts either rate up to 5% from its centre, ten times
///         the 50 bps band, so the guard rejects some swaps mid-run in both
///         directions. A rejected swap must never cost solvency either.
contract SolvencyInvariantFX is SolvencyInvariantBase {
    // Real Chainlink answers from Ethereum mainnet (2026-09-12), 8 decimals.
    int256 constant EUR_CENTER = 115_954_500;
    int256 constant AUD_CENTER = 71_700_000;
    uint256 constant FEED_UNIT = 1e8;

    MockAggregator eurFeed;
    MockAggregator audFeed;

    function _decimals() internal pure override returns (uint8[3] memory) {
        return [6, 6, 6];
    }

    function _hookSalt() internal pure override returns (uint160) {
        return 0x6666;
    }

    function _deployHook(Currency[] memory regd, address flagged) internal override {
        eurFeed = new MockAggregator(8, "EUR / USD");
        audFeed = new MockAggregator(8, "AUD / USD");
        eurFeed.setAnswer(EUR_CENTER, block.timestamp);
        audFeed.setAnswer(AUD_CENTER, block.timestamp);

        IAggregatorV3[] memory feeds = new IAggregatorV3[](3);
        feeds[0] = eurFeed;
        feeds[2] = audFeed; // feeds[1] stays zero: the numeraire

        deployCodeTo(
            "OrbitalFXHook.sol:OrbitalFXHook",
            abi.encode(
                poolManager, permit2, regd, uint24(100), address(this), feeds, uint256(25 hours), uint256(50)
            ),
            flagged
        );
    }

    function _expectedScale(uint8 i, uint8 dec) internal pure override returns (uint256) {
        uint256 unit = 10 ** uint256(18 - dec);
        if (i == 0) return (unit / FEED_UNIT) * uint256(EUR_CENTER);
        if (i == 2) return (unit / FEED_UNIT) * uint256(AUD_CENTER);
        return unit;
    }

    function _handlerSelectors() internal view override returns (bytes4[] memory sel) {
        bytes4[] memory base = super._handlerSelectors();
        sel = new bytes4[](base.length + 1);
        for (uint256 i = 0; i < base.length; ++i) sel[i] = base[i];
        sel[base.length] = this.h_moveOracle.selector;
    }

    function h_moveOracle(uint256 seed, bool moveAud) public {
        int256 centre = moveAud ? AUD_CENTER : EUR_CENTER;
        uint256 lo = uint256(centre * 95 / 100);
        uint256 hi = uint256(centre * 105 / 100);
        (moveAud ? audFeed : eurFeed).setAnswer(int256(bound(seed, lo, hi)), block.timestamp);
    }
}
