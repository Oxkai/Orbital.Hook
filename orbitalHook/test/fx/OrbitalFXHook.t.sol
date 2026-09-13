// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {OrbitalHook} from "../../src/OrbitalHook.sol";
import {OrbitalFXHook} from "../../src/fx/OrbitalFXHook.sol";
import {IAggregatorV3} from "../../src/fx/IAggregatorV3.sol";
import {TickLib} from "../../src/libraries/TickLib.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockAggregator} from "../utils/MockAggregator.sol";
import {TestnetFxFeed} from "../../script/mocks/TestnetFxFeed.sol";

/// @dev Exposes the base contract's `_setScale` so its freeze rule is tested
///      directly, independent of any subclass that happens to call it.
contract ScaleHarness is OrbitalHook {
    constructor(IPoolManager pm, IAllowanceTransfer p2, Currency[] memory a, uint24 f, address admin)
        OrbitalHook(pm, p2, a, f, admin)
    {}

    function setScale(uint8 i, uint256 s) external {
        _setScale(i, s);
    }
}

/// @notice OrbitalFXHook over a four-currency book: USDC (numeraire), EURC, GBP
///         and AUD, all 6-decimal, priced at real Chainlink answers read from
///         Ethereum mainnet. Covers construction, execution at the centre, the
///         marginal-price band guard, every oracle failure mode, LP exit with a
///         dead oracle, a rate drifting past an LP's FX band, and the base
///         contract's scale freeze.
///
/// @dev    Trade sizes are expressed as a fraction of the input asset's reserve
///         (`_frac`), so the tests hold at any pool depth rather than encoding
///         one pool's slippage.
///
///         Swap reverts surface from the PoolManager as
///         `WrappedError(hook, selector, reason, details)`, so a bare
///         `expectRevert()` cannot tell the guard from any other failure.
///         `_expectSwapRevert` unwraps `reason` and asserts the hook's own error.
contract OrbitalFXHookTest is BaseTest {
    // Real Chainlink answers from Ethereum mainnet (2026-09-12), 8 decimals.
    int256 constant EUR_PX = 115_954_500;
    int256 constant GBP_PX = 135_264_500;
    int256 constant AUD_PX = 71_700_000;
    uint8 constant FEED_DECIMALS = 8;
    /// @dev 10^(18 - 6) / 10^8: a 6-decimal token's scale per unit of answer.
    uint256 constant PER_ANSWER = 1e4;

    /// @dev Chainlink FX heartbeat (24h) plus an hour of update lag.
    uint256 constant MAX_AGE = 25 hours;
    uint256 constant BAND_BPS = 50;
    uint256 constant BPS = 10_000;
    uint256 constant WAD = 1e18;
    uint24 constant FEE = 100; // 1 bp
    uint8 constant N = 4;

    // Trade sizes, in parts-per-million of the input asset's reserve.
    uint256 constant TINY = 10; // ~0 price impact
    uint256 constant SMALL = 200; // comfortably inside the band
    /// @dev Past the band, yet small enough to stay inside the main tick, so a
    ///      guard test is not also a tick-crossing test.
    uint256 constant LARGE = 10_000;

    /// @dev A realistic block time, so "published N seconds ago" never underflows.
    uint256 constant T0 = 1_789_000_000;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    MockAggregator eurFeed;
    MockAggregator gbpFeed;
    MockAggregator audFeed;
    OrbitalFXHook hook;

    Currency[] regd; // address-sorted, as the hook requires
    IAggregatorV3[] feeds; // feed per asset, aligned with `regd`
    MockERC20[4] tok; // aligned with `regd`
    uint8 iUsd;
    uint8 iEur;
    uint8 iGbp;
    uint8 iAud;

    uint256 tickMain;
    uint256 tickBackstop;

    function setUp() public {
        vm.warp(T0);
        deployArtifactsAndLabel();

        eurFeed = _newFeed("EUR / USD", EUR_PX);
        gbpFeed = _newFeed("GBP / USD", GBP_PX);
        audFeed = _newFeed("AUD / USD", AUD_PX);

        // Four 6-decimal tokens and their roles; slot 0 is the numeraire.
        MockERC20[4] memory t =
            [deployTokenWithDecimals(6), deployTokenWithDecimals(6), deployTokenWithDecimals(6), deployTokenWithDecimals(6)];
        IAggregatorV3[4] memory role =
            [IAggregatorV3(address(0)), IAggregatorV3(eurFeed), IAggregatorV3(gbpFeed), IAggregatorV3(audFeed)];
        for (uint256 i; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (address(t[j]) < address(t[i])) {
                    (t[i], t[j]) = (t[j], t[i]);
                    (role[i], role[j]) = (role[j], role[i]);
                }
            }
        }
        for (uint8 i; i < N; ++i) {
            regd.push(Currency.wrap(address(t[i])));
            feeds.push(role[i]);
            tok[i] = t[i];
            if (address(role[i]) == address(0)) iUsd = i;
            else if (role[i] == eurFeed) iEur = i;
            else if (role[i] == gbpFeed) iGbp = i;
            else iAud = i;
        }

        hook = OrbitalFXHook(_deployFX(0x7777));
        for (uint256 i; i < N; ++i) tok[i].approve(address(hook), type(uint256).max);

        for (uint8 i; i < N; ++i) {
            for (uint8 j = i + 1; j < N; ++j) {
                poolManager.initialize(_key(i, j), Constants.SQRT_PRICE_1_1);
            }
        }

        // A concentrated ±3% FX band plus a wide backstop, mirroring the deploy
        // script's tiering: the backstop can never be crossed by normal flow,
        // so a crossing can never leave every tick at the boundary.
        (tickMain,) = hook.addLiquidity(TickLib.kFromDepegPrice(4_000_000 ether, N, 0.97e18), 4_000_000 ether, _max());
        (tickBackstop,) =
            hook.addLiquidity(TickLib.kFromDepegPrice(1_000_000 ether, N, 0.8e18), 1_000_000 ether, _max());
    }

    // ═════════════════════════════════════════════════════════════
    // Construction
    // ═════════════════════════════════════════════════════════════

    function test_centre_scales_fold_in_the_oracle_price() public view {
        // 10^(18-6) * answer / 10^8  =  answer * 1e4, exactly.
        assertEq(hook.scaleOf(iUsd), 1e12, "numeraire must keep its decimal scale");
        assertEq(hook.scaleOf(iEur), 1_159_545_000_000, "EUR scale");
        assertEq(hook.scaleOf(iGbp), 1_352_645_000_000, "GBP scale");
        assertEq(hook.scaleOf(iAud), 717_000_000_000, "AUD scale");
    }

    function test_constructor_emits_one_centre_event_per_priced_asset() public {
        address where = _flagged(0x7778);
        for (uint8 i; i < N; ++i) {
            if (address(feeds[i]) == address(0)) continue;
            (, int256 answer,, uint256 updatedAt,) = feeds[i].latestRoundData();
            vm.expectEmit(true, true, false, true, where);
            emit OrbitalFXHook.FxCenterSet(i, address(feeds[i]), uint256(answer) * PER_ANSWER, answer, updatedAt);
        }
        (bool ok,) = _tryDeployFX(where, regd, feeds, MAX_AGE, BAND_BPS);
        assertTrue(ok, "deploy failed");
    }

    function test_exposes_its_configuration() public view {
        assertEq(hook.maxPriceAge(), MAX_AGE);
        assertEq(hook.maxDeviationBps(), BAND_BPS);
        for (uint8 i; i < N; ++i) {
            assertEq(address(hook.feedOf(i)), address(feeds[i]), "feed misaligned with asset order");
        }
    }

    function test_rejects_invalid_configuration() public {
        bytes memory invalid = abi.encodeWithSelector(OrbitalFXHook.FxInvalidParams.selector);

        _assertDeployReverts(
            0x7801,
            regd,
            new IAggregatorV3[](3),
            MAX_AGE,
            BAND_BPS,
            abi.encodeWithSelector(OrbitalFXHook.FxConfigLengthMismatch.selector, 4, 3)
        );
        _assertDeployReverts(0x7802, regd, feeds, 0, BAND_BPS, invalid);
        _assertDeployReverts(0x7803, regd, feeds, MAX_AGE, 0, invalid);
        _assertDeployReverts(0x7804, regd, feeds, MAX_AGE, BPS, invalid);
    }

    function test_rejects_a_stale_price_at_deploy() public {
        uint256 old = block.timestamp - MAX_AGE - 1;
        eurFeed.setAnswer(EUR_PX, old);
        _assertDeployReverts(
            0x7811, regd, feeds, MAX_AGE, BAND_BPS, abi.encodeWithSelector(OrbitalFXHook.StalePrice.selector, iEur, old)
        );
    }

    /// @notice A feed with no rounds answers all zeros; it must read as stale,
    ///         not as a zero price or a timestamp of "infinitely fresh".
    function test_rejects_a_feed_that_never_reported_at_deploy() public {
        IAggregatorV3[] memory bad = _copyFeeds();
        bad[iGbp] = new MockAggregator(FEED_DECIMALS, "GBP / USD");
        _assertDeployReverts(
            0x7812, regd, bad, MAX_AGE, BAND_BPS, abi.encodeWithSelector(OrbitalFXHook.StalePrice.selector, iGbp, 0)
        );
    }

    /// @notice A timestamp ahead of the chain is a broken feed, not a fresh one.
    function test_rejects_a_timestamp_from_the_future_at_deploy() public {
        uint256 ahead = block.timestamp + 1;
        eurFeed.setAnswer(EUR_PX, ahead);
        _assertDeployReverts(
            0x7815, regd, feeds, MAX_AGE, BAND_BPS, abi.encodeWithSelector(OrbitalFXHook.StalePrice.selector, iEur, ahead)
        );
    }

    /// @notice A mistyped feed address must fail the deploy, not price at zero.
    function test_rejects_a_feed_address_without_code() public {
        IAggregatorV3[] memory bad = _copyFeeds();
        bad[iAud] = IAggregatorV3(makeAddr("not a feed"));
        (bool ok, bytes memory ret) = _tryDeployFX(_flagged(0x7816), regd, bad, MAX_AGE, BAND_BPS);
        assertFalse(ok, "deployed against an address with no code");
        assertEq(ret.length, 0, "expected the empty revert of a call to a codeless address");
    }

    function test_rejects_a_price_it_cannot_represent_exactly() public {
        MockERC20 usd6 = deployTokenWithDecimals(6);

        // An 18-decimal token has no headroom for an 8-decimal answer:
        // 10^(18-18) / 10^8 is fractional.
        MockERC20 eur18 = deployTokenWithDecimals(18);
        (Currency[] memory pair, uint8 i18) = _sortedPair(usd6, eur18);
        IAggregatorV3[] memory pairFeeds = new IAggregatorV3[](2);
        pairFeeds[i18] = eurFeed;
        _assertDeployReverts(
            0x7813,
            pair,
            pairFeeds,
            MAX_AGE,
            BAND_BPS,
            abi.encodeWithSelector(OrbitalFXHook.PriceNotRepresentable.selector, i18, FEED_DECIMALS)
        );

        // A 6-decimal token has 12 digits of headroom: a 13-decimal feed is one
        // too many, and an absurd one must be rejected without overflowing.
        MockERC20 eur6 = deployTokenWithDecimals(6);
        uint8 i6;
        (pair, i6) = _sortedPair(usd6, eur6);
        uint8[2] memory tooFine = [uint8(13), type(uint8).max];
        for (uint256 k; k < tooFine.length; ++k) {
            pairFeeds = new IAggregatorV3[](2);
            pairFeeds[i6] = _newFeedWithDecimals(tooFine[k], "EUR / USD", EUR_PX);
            _assertDeployReverts(
                uint160(0x7820 + k),
                pair,
                pairFeeds,
                MAX_AGE,
                BAND_BPS,
                abi.encodeWithSelector(OrbitalFXHook.PriceNotRepresentable.selector, i6, tooFine[k])
            );
        }
    }

    /// @notice The same rate from feeds of different precision must produce the
    ///         same centre: decimals are an encoding, not a price.
    function test_feed_decimals_do_not_change_the_centre() public {
        MockERC20 usd6 = deployTokenWithDecimals(6);
        MockERC20 eur6 = deployTokenWithDecimals(6);
        (Currency[] memory pair, uint8 iE) = _sortedPair(usd6, eur6);

        uint8[3] memory decs = [uint8(6), 8, 12];
        int256[3] memory answers = [int256(1_159_545), EUR_PX, 1_159_545_000_000];
        for (uint256 k; k < decs.length; ++k) {
            IAggregatorV3[] memory pairFeeds = new IAggregatorV3[](2);
            pairFeeds[iE] = _newFeedWithDecimals(decs[k], "EUR / USD", answers[k]);
            address where = _flagged(uint160(0x7830 + k));
            (bool ok,) = _tryDeployFX(where, pair, pairFeeds, MAX_AGE, BAND_BPS);
            assertTrue(ok, "deploy failed");
            assertEq(OrbitalFXHook(where).scaleOf(iE), 1_159_545_000_000, "centre depends on feed decimals");
        }
    }

    /// @notice The Arc testnet mirror plugs into the hook unchanged: the same
    ///         centre as the feed it copies, and the same staleness rule
    ///         applied to the copied timestamp.
    function test_runs_on_the_testnet_mirror_as_on_the_feed_it_copies() public {
        TestnetFxFeed mirror = new TestnetFxFeed(FEED_DECIMALS, "EUR / USD", 1, address(eurFeed), address(this));
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt,) = eurFeed.latestRoundData();
        mirror.push(roundId, answer, startedAt, updatedAt);

        IAggregatorV3[] memory mirrored = _copyFeeds();
        mirrored[iEur] = mirror;
        address where = _flagged(0x7B01);
        (bool ok,) = _tryDeployFX(where, regd, mirrored, MAX_AGE, BAND_BPS);
        assertTrue(ok, "deploy on the mirror failed");
        assertEq(OrbitalFXHook(where).scaleOf(iEur), hook.scaleOf(iEur), "mirror centre differs from the source's");

        vm.warp(T0 + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(OrbitalFXHook.StalePrice.selector, iEur, T0));
        OrbitalFXHook(where).oracleScaleOf(iEur);
    }

    function test_rejects_a_bad_price_at_deploy() public {
        int256[2] memory bad = [int256(0), -1];
        for (uint256 k; k < bad.length; ++k) {
            eurFeed.setAnswer(bad[k], block.timestamp);
            _assertDeployReverts(
                uint160(0x7814 + (k << 8)),
                regd,
                feeds,
                MAX_AGE,
                BAND_BPS,
                abi.encodeWithSelector(OrbitalFXHook.InvalidOraclePrice.selector, iEur, bad[k])
            );
        }
    }

    /// @notice The deployed basket prices two assets off ONE feed (EURC and EURe
    ///         on EUR/USD) beside two numeraires (USDC, USDT). Assets sharing a
    ///         feed must share a centre, sit exactly at the market against each
    ///         other, and trade at parity less the fee.
    function test_two_assets_sharing_a_feed_trade_at_parity() public {
        MockERC20[4] memory t =
            [deployTokenWithDecimals(6), deployTokenWithDecimals(6), deployTokenWithDecimals(6), deployTokenWithDecimals(6)];
        IAggregatorV3 none = IAggregatorV3(address(0));
        IAggregatorV3[4] memory role = [none, none, IAggregatorV3(eurFeed), IAggregatorV3(eurFeed)];
        for (uint256 i; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (address(t[j]) < address(t[i])) {
                    (t[i], t[j]) = (t[j], t[i]);
                    (role[i], role[j]) = (role[j], role[i]);
                }
            }
        }
        Currency[] memory basket = new Currency[](N);
        IAggregatorV3[] memory basketFeeds = new IAggregatorV3[](N);
        uint8[2] memory eur;
        uint8 found;
        for (uint8 i; i < N; ++i) {
            basket[i] = Currency.wrap(address(t[i]));
            basketFeeds[i] = role[i];
            if (role[i] == eurFeed) eur[found++] = i;
        }

        address where = _flagged(0x7A01);
        deployCodeTo(
            "OrbitalFXHook.sol:OrbitalFXHook",
            abi.encode(poolManager, permit2, basket, FEE, address(this), basketFeeds, MAX_AGE, BAND_BPS),
            where
        );
        OrbitalFXHook h = OrbitalFXHook(where);

        assertEq(h.scaleOf(eur[0]), h.scaleOf(eur[1]), "one feed, two centres");
        assertEq(h.scaleOf(eur[0]), 1_159_545_000_000, "EUR centre");
        for (uint8 i; i < N; ++i) if (role[i] == none) assertEq(h.scaleOf(i), 1e12, "numeraire scale");

        for (uint256 i; i < N; ++i) t[i].approve(where, type(uint256).max);
        PoolKey memory k = PoolKey({currency0: basket[eur[0]], currency1: basket[eur[1]], fee: 0, tickSpacing: 1, hooks: IHooks(where)});
        poolManager.initialize(k, Constants.SQRT_PRICE_1_1);
        h.addLiquidity(TickLib.kFromDepegPrice(1_000_000 ether, N, 0.97e18), 1_000_000 ether, _max());

        assertApproxEqRel(h.priceDeviation(eur[0], eur[1]), WAD, 1e9, "EUR stables off parity with each other");

        uint256 amtIn = 10e6;
        uint256 before = t[eur[1]].balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(amtIn, 0, true, k, "", address(this), block.timestamp);
        uint256 out = t[eur[1]].balanceOf(address(this)) - before;
        assertLe(out, amtIn, "same-currency swap paid a premium");
        assertApproxEqRel(out, amtIn, 2e14, "same-currency swap not at parity less the fee");
    }

    // ═════════════════════════════════════════════════════════════
    // Execution at the centre
    // ═════════════════════════════════════════════════════════════

    function test_pool_prices_every_pair_at_the_oracle_rate_at_the_centre() public view {
        for (uint8 i; i < N; ++i) {
            for (uint8 j; j < N; ++j) {
                if (i == j) continue;
                assertApproxEqRel(hook.priceDeviation(i, j), WAD, 1e9, "pool off the oracle at the centre");
            }
        }
    }

    /// @notice A trade too small to move the price clears at the oracle rate
    ///         less the 1 bp fee, for every pair including cross-currency ones.
    function test_small_trades_clear_at_the_oracle_rate_less_the_fee() public {
        uint8[2][6] memory pairs =
            [[iEur, iUsd], [iUsd, iGbp], [iAud, iUsd], [iEur, iGbp], [iGbp, iAud], [iAud, iEur]];
        for (uint256 p; p < pairs.length; ++p) {
            (uint8 a, uint8 b) = (pairs[p][0], pairs[p][1]);
            uint256 amtIn = _frac(a, TINY);
            uint256 vIn = _usdWad(a, amtIn);
            uint256 vOut = _usdWad(b, _swap(a, b, amtIn));
            assertLe(vOut, vIn, "paid out more value than it took in at the centre");
            assertGe(vOut * BPS, vIn * (BPS - 2), "cleared more than fee + 1 bp from the oracle");
        }
    }

    /// @notice At the centre the pool can never be made to hand out value, and
    ///         any trade the guard admits leaves the pool within the band.
    function testFuzz_trades_at_the_centre_conserve_value_and_stay_in_band(uint256 amtSeed, uint8 aSeed, uint8 bSeed)
        public
    {
        uint8 a = aSeed % N;
        uint8 b = bSeed % N;
        vm.assume(a != b);
        uint256 amtIn = bound(amtSeed, _frac(a, 1), _frac(a, SMALL));
        uint256 out = _swap(a, b, amtIn);
        assertLe(_usdWad(b, out), _usdWad(a, amtIn), "trade extracted value from LPs at the centre");
        assertLe(hook.priceDeviation(a, b) * BPS, WAD * (BPS + BAND_BPS), "an admitted trade left the band");
    }

    // ═════════════════════════════════════════════════════════════
    // Band guard
    // ═════════════════════════════════════════════════════════════

    function test_priceDeviation_follows_the_oracle() public {
        int256 moved = EUR_PX * 101 / 100; // EUR +1%
        _setPrice(iEur, moved);
        // The pool still prices EUR at the centre, so relative to the market it
        // is cheap by exactly the move.
        assertApproxEqRel(hook.priceDeviation(iUsd, iEur), WAD * uint256(EUR_PX) / uint256(moved), 1e9);
    }

    function test_a_trade_cannot_push_the_pool_past_the_market() public {
        _expectSwapRevert(iUsd, iEur, _frac(iUsd, LARGE), OrbitalFXHook.FxPriceBeyondBand.selector);
        // The same direction in a size the band allows goes through.
        _swap(iUsd, iEur, _frac(iUsd, SMALL));
        assertLe(hook.priceDeviation(iUsd, iEur) * BPS, WAD * (BPS + BAND_BPS), "left the band");
    }

    /// @notice REGRESSION. After the market moves, arbitrage toward it pays the
    ///         arbitrageur more than the band against the oracle. That is the
    ///         trade a per-trade value check rejected, freezing the pool in one
    ///         direction; the marginal-price guard must let it through.
    function test_arbitrage_after_a_rate_move_is_never_blocked() public {
        _setPrice(iEur, EUR_PX * 1015 / 1000); // EUR +1.5%, three bands
        uint256 amtIn = _frac(iUsd, SMALL);
        uint256 vIn = _usdWad(iUsd, amtIn);
        uint256 before = hook.priceDeviation(iUsd, iEur);

        uint256 vOut = _usdWad(iEur, _swap(iUsd, iEur, amtIn));

        assertGt(vOut * BPS, vIn * (BPS + BAND_BPS), "fixture: arb should out-earn the band vs the oracle");
        assertGt(hook.priceDeviation(iUsd, iEur), before, "arb did not move the pool toward the market");
    }

    function test_buying_an_asset_the_pool_already_overprices_is_blocked() public {
        _setPrice(iEur, EUR_PX * 985 / 1000); // EUR -1.5%: the pool now overprices it
        _expectSwapRevert(iUsd, iEur, _frac(iUsd, TINY), OrbitalFXHook.FxPriceBeyondBand.selector);
        // Selling it into the pool moves toward the market and clears.
        _swap(iEur, iUsd, _frac(iEur, SMALL));
    }

    /// @notice REGRESSION. A large trade followed by its reversal is ordinary
    ///         flow; the reversal recovers slippage and must never be blocked.
    function test_mean_reversion_after_a_large_trade_is_never_blocked() public {
        uint256 eurOut = _swap(iUsd, iEur, _frac(iUsd, 2 * SMALL));
        _swap(iEur, iUsd, eurOut);
        _swap(iEur, iGbp, _frac(iEur, SMALL));
    }

    function test_band_guards_cross_currency_trades() public {
        _setPrice(iGbp, GBP_PX * 985 / 1000); // GBP -1.5%: overpriced in the pool
        _expectSwapRevert(iEur, iGbp, _frac(iEur, TINY), OrbitalFXHook.FxPriceBeyondBand.selector);
    }

    /// @notice A rate drifting past an LP's FX band retires that LP's tick, and
    ///         the pool keeps tracking the market on the remaining liquidity.
    /// @dev    EUR falls 4%, past the main tick's 3% band. Sellers of EUR move
    ///         the pool toward the market (the guard admits them) until the
    ///         guard stops the pool just past it. The main tick must end up on
    ///         the boundary, putting the torus term live, and the pool's
    ///         marginal price must still match what a tiny trade actually pays.
    function test_market_drifting_past_an_fx_band_retires_that_tick() public {
        _setPrice(iEur, EUR_PX * 96 / 100);

        uint256 ppm = 5_000;
        for (uint256 k; k < 400 && ppm >= 10; ++k) {
            (PoolKey memory key_, bool zeroForOne) = _route(iEur, iUsd);
            try swapRouter.swapExactTokensForTokens(
                _frac(iEur, ppm), 0, zeroForOne, key_, "", address(this), block.timestamp
            ) {} catch {
                ppm /= 2;
            }
        }

        (,, bool mainInterior,,) = hook.ticks(tickMain);
        (,, bool backstopInterior,,) = hook.ticks(tickBackstop);
        (,,, uint256 kBound,) = hook.slot0();
        assertFalse(mainInterior, "tick past its FX band is still quoting");
        assertTrue(backstopInterior, "backstop crossed too");
        assertGt(kBound, 0, "no boundary liquidity booked");

        uint256 dev = hook.priceDeviation(iEur, iUsd);
        assertGe(dev, WAD, "sellers stopped short of the market");
        assertLe(dev * BPS, WAD * (BPS + BAND_BPS), "guard let the pool past the band");

        // On the torus: a tiny purchase of EUR (toward the market) must pay the
        // pool's marginal price plus the fee.
        uint256 marginal = hook.priceDeviation(iUsd, iEur);
        uint256 amtIn = _frac(iUsd, TINY);
        uint256 vIn = _usdWad(iUsd, amtIn);
        uint256 vOut = _usdWad(iEur, _swap(iUsd, iEur, amtIn));
        assertApproxEqRel(vIn * WAD / vOut, marginal, 2e14, "marginal price != execution on the torus");
    }

    // ═════════════════════════════════════════════════════════════
    // Oracle failures fail closed
    // ═════════════════════════════════════════════════════════════

    /// @notice `maxPriceAge` is inclusive: an answer exactly that old still
    ///         trades, one second more halts the pool.
    function test_staleness_boundary_is_exact() public {
        // Every feed was last updated in setUp, at T0. (A constant, not a cached
        // `block.timestamp`: under via-IR a timestamp read may be re-evaluated
        // after `vm.warp`.)
        vm.warp(T0 + MAX_AGE);
        _swap(iUsd, iEur, _frac(iUsd, SMALL));

        vm.warp(T0 + MAX_AGE + 1);
        assertEq(
            _swapRevertReason(iUsd, iEur, _frac(iUsd, TINY)),
            abi.encodeWithSelector(OrbitalFXHook.StalePrice.selector, iEur, T0)
        );
    }

    /// @notice A swap reads only the two feeds it trades between: a dead GBP
    ///         feed must not halt USD <-> EUR.
    function test_a_dead_feed_halts_only_its_own_pairs() public {
        vm.warp(T0 + MAX_AGE + 1);
        _setPrice(iEur, EUR_PX); // EUR refreshed; GBP and AUD now stale
        _swap(iUsd, iEur, _frac(iUsd, SMALL));
        _expectSwapRevert(iUsd, iGbp, _frac(iUsd, TINY), OrbitalFXHook.StalePrice.selector);
        _expectSwapRevert(iEur, iAud, _frac(iEur, TINY), OrbitalFXHook.StalePrice.selector);
    }

    function test_non_positive_price_halts_swaps() public {
        int256[2] memory bad = [int256(0), -1];
        for (uint256 k; k < bad.length; ++k) {
            _setPrice(iEur, bad[k]);
            assertEq(
                _swapRevertReason(iUsd, iEur, _frac(iUsd, TINY)),
                abi.encodeWithSelector(OrbitalFXHook.InvalidOraclePrice.selector, iEur, bad[k])
            );
        }
    }

    function test_a_timestamp_from_the_future_halts_swaps() public {
        uint256 ahead = block.timestamp + 1 hours;
        eurFeed.setAnswer(EUR_PX, ahead);
        assertEq(
            _swapRevertReason(iUsd, iEur, _frac(iUsd, TINY)),
            abi.encodeWithSelector(OrbitalFXHook.StalePrice.selector, iEur, ahead)
        );
    }

    /// @notice Removing liquidity and collecting fees never read the oracle, so
    ///         LPs can always leave, even with every feed dead.
    function test_lps_can_exit_while_the_oracle_is_dead() public {
        _swap(iUsd, iEur, _frac(iUsd, SMALL));
        _swap(iGbp, iAud, _frac(iGbp, SMALL));
        vm.warp(T0 + MAX_AGE + 1);

        uint256[] memory fees = hook.collect(tickMain);
        bool anyFee;
        for (uint8 i; i < N; ++i) if (fees[i] > 0) anyFee = true;
        assertTrue(anyFee, "no fees collected");

        hook.removeLiquidity(tickMain, hook.balanceOf(address(this), tickMain), new uint256[](N));
        hook.removeLiquidity(tickBackstop, hook.balanceOf(address(this), tickBackstop), new uint256[](N));
        (,, uint256 rInt,,) = hook.slot0();
        assertEq(rInt, 0, "liquidity stuck behind a dead oracle");
    }

    // ═════════════════════════════════════════════════════════════
    // Views
    // ═════════════════════════════════════════════════════════════

    function test_oracleScaleOf_tracks_the_market_while_the_centre_holds() public {
        _setPrice(iEur, 120_000_000);
        assertEq(hook.oracleScaleOf(iEur), 1_200_000_000_000, "live scale");
        assertEq(hook.scaleOf(iEur), 1_159_545_000_000, "centre moved");
        assertEq(hook.oracleScaleOf(iUsd), 1e12, "numeraire must not read an oracle");
    }

    function test_oracle_views_revert_on_a_stale_price() public {
        vm.warp(T0 + MAX_AGE + 1);
        bytes memory stale = abi.encodeWithSelector(OrbitalFXHook.StalePrice.selector, iEur, T0);
        vm.expectRevert(stale);
        hook.oracleScaleOf(iEur);
        vm.expectRevert(stale);
        hook.priceDeviation(iUsd, iEur);
    }

    // ═════════════════════════════════════════════════════════════
    // Base contract: scale freeze
    // ═════════════════════════════════════════════════════════════

    function test_scale_is_settable_only_before_the_first_mint() public {
        MockERC20 a = deployTokenWithDecimals(6);
        MockERC20 b = deployTokenWithDecimals(6);
        (Currency[] memory pair,) = _sortedPair(a, b);
        address where = _flagged(0x7901);
        deployCodeTo(
            "OrbitalFXHook.t.sol:ScaleHarness", abi.encode(poolManager, permit2, pair, FEE, address(this)), where
        );
        ScaleHarness h = ScaleHarness(where);

        vm.expectRevert(abi.encodeWithSelector(OrbitalHook.ZeroScale.selector, uint8(0)));
        h.setScale(0, 0);

        h.setScale(0, 2e12);
        assertEq(h.scaleOf(0), 2e12, "pre-mint scale change not applied");

        a.approve(where, type(uint256).max);
        b.approve(where, type(uint256).max);
        uint256 r = 1_000 ether;
        uint256[] memory maxA = new uint256[](2);
        maxA[0] = type(uint256).max;
        maxA[1] = type(uint256).max;
        (uint256 tick,) = h.addLiquidity((TickLib.kMin(r, 2) + TickLib.kMax(r, 2)) / 2, r, maxA);

        vm.expectRevert(OrbitalHook.ScaleFrozen.selector);
        h.setScale(0, 1e12);

        // Still frozen after every LP leaves: WAD history outlives the liquidity.
        h.removeLiquidity(tick, h.balanceOf(address(this), tick), new uint256[](2));
        vm.expectRevert(OrbitalHook.ScaleFrozen.selector);
        h.setScale(0, 1e12);
    }

    // ═════════════════════════════════════════════════════════════
    // Lifecycle
    // ═════════════════════════════════════════════════════════════

    function test_full_lifecycle_across_four_currencies() public {
        _swap(iUsd, iEur, _frac(iUsd, SMALL));
        _swap(iEur, iGbp, _frac(iEur, SMALL));
        _swap(iGbp, iAud, _frac(iGbp, SMALL));
        _swap(iAud, iUsd, _frac(iAud, SMALL));

        uint256[] memory fees = hook.collect(tickMain);
        uint256 feeAssets;
        for (uint8 i; i < N; ++i) if (fees[i] > 0) ++feeAssets;
        assertEq(feeAssets, N, "every input asset should have earned fees");

        uint256[] memory got =
            hook.removeLiquidity(tickMain, hook.balanceOf(address(this), tickMain), new uint256[](N));
        for (uint8 i; i < N; ++i) assertGt(got[i], 0, "burn returned nothing for an asset");
        hook.removeLiquidity(tickBackstop, hook.balanceOf(address(this), tickBackstop), new uint256[](N));

        (,, uint256 rInt,,) = hook.slot0();
        assertEq(rInt, 0, "interior radius not fully unwound");
    }

    // ═════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════

    function _flagged(uint160 salt) internal pure returns (address) {
        return address(HOOK_FLAGS ^ (salt << 144));
    }

    function _deployFX(uint160 salt) internal returns (address where) {
        where = _flagged(salt);
        deployCodeTo(
            "OrbitalFXHook.sol:OrbitalFXHook",
            abi.encode(poolManager, permit2, regd, FEE, address(this), feeds, MAX_AGE, BAND_BPS),
            where
        );
    }

    /// @dev `deployCodeTo`, but returning the constructor's revert data instead
    ///      of replacing it with a generic message.
    function _tryDeployFX(
        address where,
        Currency[] memory assets_,
        IAggregatorV3[] memory feeds_,
        uint256 age,
        uint256 band
    ) internal returns (bool ok, bytes memory ret) {
        bytes memory args = abi.encode(poolManager, permit2, assets_, FEE, address(this), feeds_, age, band);
        vm.etch(where, abi.encodePacked(vm.getCode("OrbitalFXHook.sol:OrbitalFXHook"), args));
        (ok, ret) = where.call("");
        if (ok) vm.etch(where, ret);
    }

    function _assertDeployReverts(
        uint160 salt,
        Currency[] memory assets_,
        IAggregatorV3[] memory feeds_,
        uint256 age,
        uint256 band,
        bytes memory expected
    ) internal {
        (bool ok, bytes memory ret) = _tryDeployFX(_flagged(salt), assets_, feeds_, age, band);
        assertFalse(ok, "deploy should have reverted");
        assertEq(ret, expected, "wrong constructor revert");
    }

    function _key(uint8 a, uint8 b) internal view returns (PoolKey memory) {
        return PoolKey({currency0: regd[a], currency1: regd[b], fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
    }

    function _route(uint8 inI, uint8 outI) internal view returns (PoolKey memory k, bool zeroForOne) {
        zeroForOne = inI < outI;
        k = zeroForOne ? _key(inI, outI) : _key(outI, inI);
    }

    /// @dev `ppm` parts-per-million of asset `i`'s current reserve, in raw units.
    function _frac(uint8 i, uint256 ppm) internal view returns (uint256) {
        return hook.reserves(i) / hook.scaleOf(i) * ppm / 1e6;
    }

    function _swap(uint8 inI, uint8 outI, uint256 amtIn) internal returns (uint256 out) {
        (PoolKey memory k, bool zeroForOne) = _route(inI, outI);
        uint256 before = tok[outI].balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(amtIn, 0, zeroForOne, k, "", address(this), block.timestamp);
        out = tok[outI].balanceOf(address(this)) - before;
    }

    /// @dev Asserts the swap reverts inside the hook with error `inner`.
    function _expectSwapRevert(uint8 inI, uint8 outI, uint256 amtIn, bytes4 inner) internal {
        assertEq(bytes4(_swapRevertReason(inI, outI, amtIn)), inner, "wrong hook error");
    }

    /// @dev Runs a swap that must revert inside the hook and returns the hook's
    ///      own revert data, unwrapped from the PoolManager's `WrappedError`.
    function _swapRevertReason(uint8 inI, uint8 outI, uint256 amtIn) internal returns (bytes memory reason) {
        (PoolKey memory k, bool zeroForOne) = _route(inI, outI);
        try swapRouter.swapExactTokensForTokens(amtIn, 0, zeroForOne, k, "", address(this), block.timestamp) {
            revert("swap should have reverted");
        } catch (bytes memory err) {
            assertEq(bytes4(err), CustomRevert.WrappedError.selector, "not a wrapped hook revert");
            address target;
            (target,, reason,) = this.decodeWrapped(err);
            assertEq(target, address(hook), "revert did not come from the hook");
        }
    }

    function decodeWrapped(bytes calldata err) external pure returns (address, bytes4, bytes memory, bytes memory) {
        return abi.decode(err[4:], (address, bytes4, bytes, bytes));
    }

    function _newFeed(string memory label, int256 answer) internal returns (MockAggregator) {
        return _newFeedWithDecimals(FEED_DECIMALS, label, answer);
    }

    function _newFeedWithDecimals(uint8 decimals, string memory label, int256 answer)
        internal
        returns (MockAggregator feed)
    {
        feed = new MockAggregator(decimals, label);
        feed.setAnswer(answer, vm.getBlockTimestamp());
    }

    /// @dev Publishes a new answer for asset `i`'s feed, timestamped now.
    function _setPrice(uint8 i, int256 answer) internal {
        MockAggregator(address(feeds[i])).setAnswer(answer, vm.getBlockTimestamp());
    }

    /// @dev WAD value of `raw` units of asset `i` at the feed price, computed
    ///      independently of the hook.
    function _usdWad(uint8 i, uint256 raw) internal view returns (uint256) {
        if (address(feeds[i]) == address(0)) return raw * 1e12;
        (, int256 answer,,,) = feeds[i].latestRoundData();
        return raw * PER_ANSWER * uint256(answer);
    }

    function _max() internal pure returns (uint256[] memory m) {
        m = new uint256[](N);
        for (uint256 i; i < N; ++i) m[i] = type(uint256).max;
    }

    function _copyFeeds() internal view returns (IAggregatorV3[] memory out) {
        out = new IAggregatorV3[](feeds.length);
        for (uint256 i; i < feeds.length; ++i) out[i] = feeds[i];
    }

    /// @dev Two tokens sorted by address; also returns where `b` landed.
    function _sortedPair(MockERC20 a, MockERC20 b) internal pure returns (Currency[] memory pair, uint8 bIndex) {
        pair = new Currency[](2);
        if (address(a) < address(b)) {
            (pair[0], pair[1], bIndex) = (Currency.wrap(address(a)), Currency.wrap(address(b)), 1);
        } else {
            (pair[0], pair[1], bIndex) = (Currency.wrap(address(b)), Currency.wrap(address(a)), 0);
        }
    }
}
