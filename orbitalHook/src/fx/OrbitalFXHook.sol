// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {OrbitalHook, IERC20Decimals} from "../OrbitalHook.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {TorusMath} from "../libraries/TorusMath.sol";
import {IAggregatorV3} from "./IAggregatorV3.sol";

/// @title OrbitalFXHook
/// @notice Orbital across currencies: one shared book for stablecoins of
///         different denominations (e.g. USDC, EURC), priced by Chainlink-style
///         `AggregatorV3` feeds.
///
/// @dev PRICING. The Orbital curve assumes every asset trades at parity: the
///      equal-reserve point is the fair price. Different currencies are not at
///      parity, so this hook restores it in VALUE space instead of changing the
///      curve. Each asset's raw -> WAD scale is multiplied by its price in a
///      common quote currency, read from its feed once at construction:
///
///          scale(EURC) = 10^(18 - 6) * 1.15954500   // 1 EURC books as $1.159545
///          scale(USDC) = 10^(18 - 6)                // numeraire, exactly $1
///
///      In WAD the assets are then at parity, so the sphere math, ticks, solver
///      and fee accounting run unchanged. The centre is fixed for the pool's
///      lifetime: reserves and tick radii are stored in WAD, so re-pricing a
///      live pool would re-denominate them against unchanged token balances,
///      and the base contract refuses any scale change once liquidity has ever
///      existed (`_setScale`).
///
///      TRACKING THE MARKET. Rates drift away from the centre, and the pool
///      follows them the way any AMM does: through arbitrage along the curve.
///      A tick's depeg bound acts as the LP's FX band. A 0.97 tick provides
///      liquidity while its asset stays within about 3% of the centre, and
///      exits to the boundary beyond that, exactly like an out-of-range
///      concentrated position.
///
///      THE ORACLE GUARD. After every swap the pool's MARGINAL price for the
///      asset just bought is compared with the live feed rate. If the trade
///      left the pool pricing that asset more than `maxDeviationBps` above the
///      market, it reverts. Buying an asset only ever raises its pool price, so
///      the rule rejects exactly the trades that push the pool past the market:
///      manipulation, fat fingers, one-sided overshoot. Trades that move the
///      pool TOWARD the market (arbitrage after a rate move, mean reversion
///      after a large trade) are never blocked, so the pool can always
///      re-converge.
///
///      Why marginal price and not per-trade value: valuing each trade at the
///      oracle treats slippage returning to a mean-reverting trader as LP
///      loss, and once the market drifts one band from the fixed centre every
///      purchase of the appreciated asset looks like extraction. That freezes
///      the pool in one direction permanently. The marginal price describes
///      the pool's state, which is what the band is meant to bound.
///
///      ORACLE FAILURES fail closed: a non-positive answer, or an `updatedAt`
///      that is unset, in the future, or older than `maxPriceAge`, reverts the
///      swap. Liquidity removal and fee collection never read the oracle, so
///      LPs can always exit.
///
///      FEEDS. Every feed must quote the same currency (USD for Chainlink's
///      `XXX / USD` feeds), and a numeraire asset, one worth exactly 1 in that
///      currency, takes `address(0)`. Any `AggregatorV3` source works:
///      Chainlink directly, or another oracle behind a Chainlink-compatible
///      adapter. Feed decimals are cached at construction, the convention of
///      production Chainlink integrations (e.g. Compound III); a feed proxy
///      that later changed its decimals must not be pointed at this pool.
///
///      REPRESENTATION. `scale = 10^(18 - tokenDecimals) * answer / 10^feedDecimals`
///      must be an exact integer, which holds when
///      `18 - tokenDecimals >= feedDecimals` (a 6-decimal token on an 8-decimal
///      FX feed: 12 >= 8). Assets without that headroom are rejected at deploy
///      with `PriceNotRepresentable` rather than silently rounded.
contract OrbitalFXHook is OrbitalHook {
    uint256 internal constant BPS = 10_000;

    /// @notice Max age, in seconds, of a feed answer accepted by a swap.
    /// @dev    Size it to the feeds' heartbeat plus a margin for update lag
    ///         (Chainlink FX: 24h heartbeat). Too tight and the pool halts
    ///         between heartbeats; too loose and it prices off old rates.
    uint256 public immutable maxPriceAge;
    /// @notice Max amount, in bps, by which a swap may leave the pool pricing the
    ///         asset it bought above the oracle rate.
    uint256 public immutable maxDeviationBps;

    /// @dev Feed per asset; `address(0)` marks a numeraire asset, valued at
    ///      exactly 1 in the feeds' quote currency.
    IAggregatorV3[] private _feeds;
    /// @dev `10^feedDecimals` per asset (1 for a numeraire asset).
    uint256[] private _feedUnit;
    /// @dev `10^(18 - tokenDecimals)` per asset: the scale before pricing.
    uint256[] private _unitScale;

    event FxCenterSet(uint8 indexed asset, address indexed feed, uint256 scale, int256 answer, uint256 updatedAt);

    error FxConfigLengthMismatch(uint256 assets, uint256 feeds);
    error FxInvalidParams();
    error PriceNotRepresentable(uint8 asset, uint8 feedDecimals);
    error InvalidOraclePrice(uint8 asset, int256 answer);
    error StalePrice(uint8 asset, uint256 updatedAt);
    error FxPriceBeyondBand(uint8 assetIn, uint8 assetOut, uint256 deviationWad);

    /// @param feeds_ One `AggregatorV3` feed per asset, in the same
    ///        (address-sorted) order as `assets_`; `address(0)` for a numeraire
    ///        asset. All feeds must quote the same currency.
    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        Currency[] memory assets_,
        uint24 fee_,
        address admin_,
        IAggregatorV3[] memory feeds_,
        uint256 maxPriceAge_,
        uint256 maxDeviationBps_
    ) OrbitalHook(_poolManager, _permit2, assets_, fee_, admin_) {
        if (feeds_.length != assets_.length) revert FxConfigLengthMismatch(assets_.length, feeds_.length);
        if (maxPriceAge_ == 0 || maxDeviationBps_ == 0 || maxDeviationBps_ >= BPS) revert FxInvalidParams();

        maxPriceAge = maxPriceAge_;
        maxDeviationBps = maxDeviationBps_;

        for (uint256 j = 0; j < assets_.length; ++j) {
            uint8 i = uint8(j);
            IAggregatorV3 feed = feeds_[j];
            // The base constructor already rejected token decimals > 18.
            uint256 unit = 10 ** uint256(18 - IERC20Decimals(Currency.unwrap(assets_[j])).decimals());
            _unitScale.push(unit);
            _feeds.push(feed);

            // A numeraire asset keeps its plain decimal scale.
            if (address(feed) == address(0)) {
                _feedUnit.push(1);
                continue;
            }

            // Exact representation: `unit / 10^feedDecimals` must be a whole
            // number. The check also bounds the exponent (feedDecimals <= 18).
            uint8 feedDecimals = feed.decimals();
            if (feedDecimals > 18 || unit % 10 ** uint256(feedDecimals) != 0) {
                revert PriceNotRepresentable(i, feedDecimals);
            }
            uint256 feedUnit = 10 ** uint256(feedDecimals);
            _feedUnit.push(feedUnit);

            // Immutables are passed explicitly: they cannot be read from inside
            // an internal function during construction.
            (uint256 answer, uint256 updatedAt) = _readFeed(i, feed, maxPriceAge_);
            uint256 s = (unit / feedUnit) * answer;
            _setScale(i, s);
            emit FxCenterSet(i, address(feed), s, int256(answer), updatedAt);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────

    /// @notice Price feed for asset `i`; `address(0)` if it is a numeraire asset.
    function feedOf(uint8 i) external view returns (IAggregatorV3) {
        return _feeds[i];
    }

    /// @notice Asset `i`'s raw -> WAD scale at the LIVE oracle price. Compare
    ///         with `scaleOf(i)`, the fixed centre, to see how far the market
    ///         has moved from it. Reverts if the price fails any oracle check.
    function oracleScaleOf(uint8 i) external view returns (uint256) {
        return _oracleScale(i);
    }

    /// @notice How the pool currently prices asset `j` in units of asset `i`,
    ///         relative to the oracle, WAD-scaled: 1e18 is exactly at market,
    ///         above means the pool charges more for `j` than the market does.
    ///         Reverts if either price fails an oracle check.
    function priceDeviation(uint8 i, uint8 j) external view returns (uint256) {
        return _deviation(i, j);
    }

    // ─────────────────────────────────────────────────────────────
    // Swap guard
    // ─────────────────────────────────────────────────────────────

    /// @dev Runs with the trade already booked, so the reserves are post-trade.
    ///      Buying `assetOut` only ever raises its pool price; rejecting the
    ///      state where that price sits more than the band above market blocks
    ///      pushes past the market and nothing else.
    function _validateSwap(uint8 assetIn, uint8 assetOut, uint256, uint256) internal view override {
        uint256 deviation = _deviation(assetIn, assetOut);
        if (deviation * BPS > WAD * (BPS + maxDeviationBps)) {
            revert FxPriceBeyondBand(assetIn, assetOut, deviation);
        }
    }

    /// @dev Pool price of `j` in units of `i`, divided by the market's.
    ///
    ///          pool   (raw i per raw j) = marginalPrice * scale(j) / scale(i)
    ///          market (raw i per raw j) = oracleScale(j) / oracleScale(i)
    ///
    ///      The centre scales convert the engine's WAD price back to raw
    ///      tokens; the oracle scales price those raw tokens at market.
    function _deviation(uint8 i, uint8 j) internal view returns (uint256) {
        uint256 poolWad = TorusMath.marginalPrice(_buildTorusState(), reserves[i], reserves[j]);
        uint256 poolRaw = FullMath.mulDiv(poolWad, scaleOf(j), scaleOf(i));
        return FullMath.mulDiv(poolRaw, _oracleScale(i), _oracleScale(j));
    }

    // ─────────────────────────────────────────────────────────────
    // Pricing
    // ─────────────────────────────────────────────────────────────

    /// @dev Raw -> WAD value multiplier for asset `i` at the live oracle price.
    ///      Exact: the constructor proved `_unitScale[i]` divisible by
    ///      `_feedUnit[i]`.
    function _oracleScale(uint8 i) internal view returns (uint256) {
        IAggregatorV3 feed = _feeds[i];
        if (address(feed) == address(0)) return _unitScale[i];
        (uint256 answer,) = _readFeed(i, feed, maxPriceAge);
        return (_unitScale[i] / _feedUnit[i]) * answer;
    }

    /// @dev Latest answer from `feed`, after the standard Chainlink checks: an
    ///      `updatedAt` that is set, not in the future, and at most `maxAge`
    ///      old, then a positive answer. Time is checked first so a feed with
    ///      no rounds (all zeros) reports as stale rather than as a zero price.
    ///      `answeredInRound` is deprecated upstream and deliberately not checked.
    function _readFeed(uint8 i, IAggregatorV3 feed, uint256 maxAge)
        internal
        view
        returns (uint256 answer, uint256 updatedAt)
    {
        (, int256 raw,, uint256 at,) = feed.latestRoundData();
        if (at == 0 || at > block.timestamp || block.timestamp - at > maxAge) revert StalePrice(i, at);
        if (raw <= 0) revert InvalidOraclePrice(i, raw);
        return (uint256(raw), at);
    }
}
