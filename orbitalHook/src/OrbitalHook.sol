// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {SoulboundShares} from "./SoulboundShares.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {FullMath} from "./libraries/FullMath.sol";
import {SphereMath} from "./libraries/SphereMath.sol";
import {TorusMath} from "./libraries/TorusMath.sol";
import {TickLib} from "./libraries/TickLib.sol";
import {PositionLib} from "./libraries/PositionLib.sol";
import {QuadraticSolver} from "./libraries/QuadraticSolver.sol";
import {BandLib} from "./libraries/BandLib.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Uniswap v4 hook implementing the Orbital N-asset stableswap (Paradigm 2025).
/// @dev Single engine state shared across all N(N-1)/2 pair-pools that share this hook.
///      Token custody lives in the v4 PoolManager via ERC-6909 claim tokens; this hook
///      tracks the abstract reserve vector and routes settlement through `unlockCallback`.
///      The engine works entirely in WAD (1e18). Tokens with fewer than 18 decimals
///      (e.g. 6-decimal USDC/USDT) are supported via a per-asset scale factor
///      `10^(18-decimals)` applied only at the token-transfer boundaries — raw amounts
///      are scaled up to WAD on the way in and down to raw on the way out, rounding in
///      the pool's favour. The engine, ticks, and all public WAD quantities are
///      untouched. Tokens with MORE than 18 decimals are rejected at deploy.
///
///      LIQUIDITY lives in a fixed menu of depeg bands (`BandLib`): one tick per
///      band, shared by every position opened in it, the way Uniswap v3
///      positions share initialised ticks on a spacing. The tick id and the
///      ERC-6909 share id are both the band index.
///
///      TOKEN ASSUMPTIONS (enforced on-chain at the deposit boundary):
///      registered assets MUST be standard ERC-20s (≤ 18 decimals) with no
///      fee-on-transfer and no rebasing. Rather than trusting that, every deposit
///      measures the PoolManager's real balance delta and reverts with
///      `TokenTransferShortfall` if less arrived than was requested — so a
///      fee-on-transfer or negatively-rebasing token fails closed with a named
///      error instead of leaving claim tokens unbacked. Deposit is the only path
///      where a short transfer could threaten solvency: swaps move ERC-6909 claim
///      tokens inside the PoolManager and never touch the ERC-20, while burn and
///      collect transfer OUT (a transfer fee there is borne by the withdrawing LP,
///      not the pool). Native ETH is unsupported (the constructor's `decimals()`
///      probe reverts for `address(0)`).
///
///      READ-ONLY REENTRANCY: every state-changing path holds a transient lock
///      (`nonReentrant`), so nothing can re-enter it. Public getters such as
///      `reserves` are not locked, and during a mint they briefly show reserves
///      credited ahead of the tokens arriving. An integrator reading this hook's
///      state as a price inside another protocol should check `isLocked()`.
contract OrbitalHook is BaseHook, IUnlockCallback, SoulboundShares, Ownable2Step, Pausable {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    uint256 internal constant WAD = 1e18;


    // ─────────────────────────────────────────────────────────────
    // Asset registry (immutable after construction)
    // ─────────────────────────────────────────────────────────────

    uint8 internal constant MIN_ASSETS = 2;
    /// @notice Upper bound on assets per pool. Raised from 5 to 10; the cap is a
    ///         gas/safety guard (per-asset settlement and fee-accrual loops and
    ///         the segmenting solver scale with N) rather than a math limit.
    uint8 public constant MAX_ASSETS = 10;

    uint8 public immutable N;
    /// @notice Pool fee in hundredths of a bip (e.g. 100 = 1bp).
    uint24 public immutable fee;

    /// @notice Minimum pool fee, in hundredths of a bip (10 = 0.1bp = 10 ppm).
    /// @dev    Rules out zero- and near-zero-fee pools at deploy, which LPs would
    ///         be providing for free.
    ///
    ///         This is not what protects the pool from the invariant's 1 ppm
    ///         tolerance, and is not sized against it: that tolerance is
    ///         relative to rInt², the size of the whole pool, so it does not
    ///         compare to a fee on one trade. The pool is protected because a
    ///         trader never chooses the output — `solveSwapBounded` returns the
    ///         largest output at which the invariant is still ≤ 0, so the
    ///         rounding lands on the pool's side and the tolerance is only a
    ///         backstop against the solver itself.
    uint24 public constant MIN_FEE = 10;

    /// @dev Cached √N·WAD (= sqrt(N·WAD²)). N is immutable, so this geometric
    ///      constant is computed once at deploy instead of being re-derived via
    ///      an integer sqrt on every call. Threaded through `TorusState.sqrtN`.
    uint256 internal immutable sqrtN;

    Currency[] private _assets;
    mapping(Currency => uint8) private _assetIndexPlusOne;
    /// @dev Per-asset multiplier converting raw token units to WAD. Defaults to
    ///      `10^(18-decimals)`: 1 for 18-decimal tokens, 1e12 for 6-decimal
    ///      (USDC/USDT). A subclass may replace it before the first mint via
    ///      `_setScale` to price assets in a common numeraire. Applied only at
    ///      the token-transfer boundaries; the engine stays in WAD.
    mapping(uint8 => uint256) private _scale;

    // ─────────────────────────────────────────────────────────────
    // Bands
    // ─────────────────────────────────────────────────────────────

    /// @dev A literal because Solidity will not size an array by another
    ///      contract's constant; the constructor checks it against `BandLib`.
    uint8 internal constant NUM_BANDS = 31;

    /// @notice Each band's normalised plane constant kNorm = k/r, WAD. The
    ///         engine compares THIS to αNorm (paper §4.13). Ascending in the
    ///         band index. Fixed at deploy: a band's boundary never moves.
    uint256[NUM_BANDS] public bandKNorm;

    // ─────────────────────────────────────────────────────────────
    // Engine state
    // ─────────────────────────────────────────────────────────────

    struct Slot0 {
        uint256 sumX;
        uint256 sumXSq;
        uint256 rInt;
        uint256 kBound;
        uint256 sBound;
    }

    Slot0 public slot0;

    mapping(uint8 => uint256) public reserves; // virtual x⃗, WAD

    /// @notice Per-asset VIRTUAL reserve of the whole pool, WAD: Σ over live
    ///         ticks of `tickVirtual`. The tokens actually held for asset i are
    ///         `reserves[i] − virtualReserve`.
    /// @dev    CONCENTRATED LIQUIDITY (paper §4.7, §4.9). Inside a tick's band no
    ///         reserve of that tick can fall below `xMin(r, n, k)`: its cap is
    ///         bounded by the plane α = k, and xMin is the smallest coordinate on
    ///         it. That part of the tick's reserves is never paid out, so the LP
    ///         never deposits it. The engine still runs on the full (virtual)
    ///         reserves, which is what gives a concentrated tick its depth; only
    ///         the token boundaries (mint, burn, swap payout) see the real part.
    ///         Every path that pays out checks `reserves[i] ≥ virtualReserve`.
    uint256 public virtualReserve;
    /// @notice A tick's per-asset virtual reserve, WAD (see `virtualReserve`).
    mapping(uint256 => uint256) public tickVirtual;
    /// @notice Radius summed over every live tick, interior and pinned. Bounded
    ///         by `MAX_RINT`; swaps and crossings never change it.
    uint256 private _radiusTotal;

    mapping(uint8 => uint256) public feesAccrued; // WAD (scaled to raw on collect)
    mapping(uint8 => uint256) public feeGrowthGlobal; // WAD per unit interior rInt
    /// @dev The part of a fee too small to raise `feeGrowthGlobal` by a whole
    ///      unit, in WAD·WAD; carried into the next credit so no fee is lost to
    ///      the division. Always below the rInt it was divided by.
    mapping(uint8 => uint256) private _feeGrowthCarry;

    /// @dev One tick per band; live while `r > 0`. Read with `ticks`.
    TickLib.Tick[NUM_BANDS] private _ticks;

    /// @dev The live bands, one bit per band: bit b of `_interiorBands` is set
    ///      iff band b holds liquidity and is interior, of `_pinnedBands` iff it
    ///      holds liquidity and is pinned. They are the only record of which
    ///      side of its plane a band is on. Crossing detection needs only the
    ///      extreme live band on one side, which these give in one read (both
    ///      share a slot); scanning every band for it cost up to one cold read
    ///      per band on every swap.
    uint128 private _interiorBands;
    uint128 private _pinnedBands;

    mapping(bytes32 => PositionLib.Position) public positions;
    mapping(bytes32 => mapping(uint8 => uint256)) private _feeGrowthInsideLast;
    /// @dev Per-tick, per-asset range-fee accounting (Uniswap-v3 style). A tick
    ///      only earns fees while INTERIOR; `tickFeeGrowthInside` is the cumulative
    ///      growth frozen across boundary spells, and `tickFeeGrowthSnapshot` is
    ///      `feeGrowthGlobal` captured at the tick's last interior entry. Together
    ///      they ensure a boundary (depegged) tick accrues nothing, so the sum of
    ///      all positions' owed fees never exceeds `feesAccrued`.
    mapping(uint256 => mapping(uint8 => uint256)) private tickFeeGrowthInside;
    mapping(uint256 => mapping(uint8 => uint256)) private tickFeeGrowthSnapshot;
    mapping(bytes32 => mapping(uint8 => uint256)) private _tokensOwed;

    /// @notice Payouts the hook could not deliver, per recipient and asset, in
    ///         the token's raw units (see `_payOrDefer`), redeemable with
    ///         `claimOwed`. Backed by PoolManager claim tokens the hook keeps
    ///         aside, outside `reserves` and `feesAccrued`, so no swap can
    ///         spend them.
    mapping(address => mapping(uint8 => uint256)) public owed;
    /// @notice `owed` summed over recipients, per asset (raw units).
    mapping(uint8 => uint256) public totalOwed;

    /// @dev Set on the first mint and never cleared: WAD figures (fee buckets,
    ///      accumulators) outlive the liquidity that produced them, so the
    ///      raw↔WAD scale is frozen from then on. See `_setScale`.
    bool private _liquidityEverAdded;

    /// @dev Transient slot of the reentrancy lock:
    ///      keccak256("orbital.hook.reentrancy") − 1.
    bytes32 private constant _LOCK_SLOT = 0xf3f89d1c8c7a97389c2659d41b771d48eea1d3f69546571f3693868f79b2aaa1;

    // ─────────────────────────────────────────────────────────────
    // Errors and events
    // ─────────────────────────────────────────────────────────────

    error InvalidAssetCount(uint256 n);
    error PoolKeyFeeMustBeZero(uint24 fee);
    error AssetsNotSortedOrUnique();
    error AssetNotRegistered(Currency asset);
    error NativeLiquidityDisabled();
    error ZeroRWad();
    error InvalidBand(uint256 band);
    error BandsNotOrdered();
    /// @notice No interior liquidity to join: every remaining tick is pinned.
    ///         A mint waits for them to recover or leave.
    error MintBlockedByBoundaryTicks();
    error SlippageExceeded(uint8 asset, uint256 requested, uint256 maxAllowed);
    error DeadlinePassed();
    error Reentered();
    error InvariantBroken();
    error InvalidAction();
    error NotEnoughLiquidity();
    error ZeroSwapInput();
    error ZeroSwapOutput();
    error TooManyCrossings();
    /// @notice The trade would move the last interior tick to its boundary: it
    ///         is larger than the pool's liquidity can fill in this direction.
    error SwapExceedsLiquidity();
    /// @notice The trade would sell the input asset past the point where the
    ///         pool prices it at zero (see `TorusMath.pricedPositive`).
    error SwapBeyondZeroPrice();
    error CrossingPartialExceedsOutputReserve();
    error NothingOwed();
    error FeeBucketShort();
    error SharesAreSoulbound();
    error AssetDecimalsTooHigh(Currency asset, uint8 decimals);
    error SwapAmountTooLarge(uint256 amountIn);
    error SwapAmountTooSmall(uint256 amountIn);
    error RadiusCapExceeded();
    error FeeTooLow(uint24 fee);
    error TokenTransferShortfall(Currency asset, uint256 requested, uint256 received);
    error ScaleFrozen();
    error ZeroScale(uint8 asset);
    /// @notice The pool has already moved past the band's plane, so a position
    ///         there would start outside its own range.
    error TickOutsideItsBand();
    /// @notice A payout would take an asset's reserve below the pool's virtual
    ///         reserve, i.e. pay out tokens the pool does not hold.
    error InsufficientRealReserves(uint8 asset);
    /// @notice Boundary liquidity with ‖w‖ = 0: a state the geometry rules out.
    error InvalidBoundaryState();

    event Mint(address indexed recipient, uint256 indexed tickIdx, uint256 kWad, uint256 rWad, uint256[] amounts);
    event Burn(address indexed owner, uint256 indexed tickIdx, uint256 rWad, uint256[] amounts);
    event Collect(address indexed owner, uint256 indexed tickIdx, uint256[] fees);
    /// @param sender The caller of `poolManager.swap` (router or EOA), NOT the
    ///        PoolManager. `assetIn`/`assetOut` are indices into this hook's
    ///        asset array; `amountIn`/`amountOut` are in each token's RAW units,
    ///        so a consumer must scale by that asset's own decimals.
    event Swap(address indexed sender, uint8 assetIn, uint8 assetOut, uint256 amountIn, uint256 amountOut);
    event TickCrossed(uint256 indexed tickIdx, bool nowInterior);
    /// @notice `amount` (raw) of `asset` could not be transferred to `to` — the
    ///         token paused, or `to` or the PoolManager frozen by its issuer —
    ///         and is held for them in `owed`.
    event PayoutDeferred(address indexed to, uint8 indexed asset, uint256 amount);
    event OwedClaimed(address indexed to, uint8 indexed asset, uint256 amount);

    // ─────────────────────────────────────────────────────────────
    // Unlock-callback action codes
    // ─────────────────────────────────────────────────────────────

    enum Action {
        MINT,
        BURN,
        COLLECT,
        CLAIM_OWED
    }

    struct MintData {
        address recipient;
        uint256 band;
        uint256 rWad;
        uint256[] maxAmounts;
    }

    struct BurnData {
        address owner;
        uint256 band;
        uint256 rWad;
        uint256[] minAmounts;
    }

    struct CollectData {
        address owner;
        uint256 band;
    }

    // ─────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(
        IPoolManager _poolManager,
        Currency[] memory assets_,
        uint24 fee_,
        address admin_
    ) BaseHook(_poolManager) Ownable(admin_) {

        uint256 len = assets_.length;
        if (len < MIN_ASSETS || len > MAX_ASSETS) revert InvalidAssetCount(len);
        N = uint8(len);
        if (fee_ < MIN_FEE) revert FeeTooLow(fee_);
        fee = fee_;
        sqrtN = SphereMath.sqrt(uint256(len) * WAD * WAD);

        Currency prev = Currency.wrap(address(0));
        for (uint256 i = 0; i < len; ++i) {
            Currency c = assets_[i];
            if (i > 0 && Currency.unwrap(c) <= Currency.unwrap(prev)) revert AssetsNotSortedOrUnique();
            // The engine is WAD-scaled. Tokens with ≤ 18 decimals are supported
            // via a per-asset scale factor applied at the transfer boundaries;
            // > 18 decimals would need to scale *down* (precision loss), so reject.
            uint8 dec = IERC20Decimals(Currency.unwrap(c)).decimals();
            if (dec > 18) revert AssetDecimalsTooHigh(c, dec);
            _scale[uint8(i)] = 10 ** uint256(18 - dec);
            _assets.push(c);
            _assetIndexPlusOne[c] = uint8(i + 1);
            prev = c;
        }

        // Each band's kNorm is its plane for a unit radius (paper §4.8):
        // kFromDepegPrice(r, n, p) is proportional to r, so at r = WAD it IS
        // k/r in WAD. The planes must ascend with the band index — detection
        // relies on it to stop at the first live tick either way.
        if (BandLib.COUNT != NUM_BANDS) revert BandsNotOrdered();
        uint256 prevKNorm;
        for (uint256 b = 0; b < NUM_BANDS; ++b) {
            uint256 p = BandLib.depegPriceWad(b);
            uint256 kn = TickLib.kFromDepegPrice(WAD, len, p);
            if (b > 0 && kn <= prevKNorm) revert BandsNotOrdered();
            bandKNorm[b] = kn;
            prevKNorm = kn;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Reentrancy lock (transient)
    // ─────────────────────────────────────────────────────────────

    /// @dev Held across every path that changes engine state: the swap and the
    ///      mint / burn / collect callbacks. The PoolManager's own lock already
    ///      stops a second `unlock`, but not a swap on this pool from inside
    ///      one — a registered token with a transfer hook could otherwise swap
    ///      against a mint that is half booked.
    modifier nonReentrant() {
        bool held;
        assembly ("memory-safe") {
            held := tload(_LOCK_SLOT)
        }
        if (held) revert Reentered();
        assembly ("memory-safe") {
            tstore(_LOCK_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(_LOCK_SLOT, 0)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Admin (Ownable2Step + Pausable)
    //
    // pause() blocks new mints AND swap intake. It deliberately does NOT
    // block removeLiquidity or collect — LPs must always be able to exit
    // and claim accrued fees, even during an emergency.
    // ─────────────────────────────────────────────────────────────

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────

    function assetAt(uint8 i) external view returns (Currency) {
        return _assets[i];
    }

    function isRegistered(Currency c) public view returns (bool) {
        return _assetIndexPlusOne[c] != 0;
    }

    function indexOf(Currency c) public view returns (uint8) {
        uint8 idx = _assetIndexPlusOne[c];
        if (idx == 0) revert AssetNotRegistered(c);
        return idx - 1;
    }

    /// @notice Number of tick slots, one per band. A slot is live while its
    ///         `r > 0`.
    /// @notice Band `band`'s tick: plane constant, radius, and whether it is
    ///         interior (false for a band with no liquidity).
    function ticks(uint256 band) external view returns (uint256 k, uint256 r, bool isInterior) {
        TickLib.Tick storage t = _ticks[band];
        return (t.k, t.r, _isInterior(band));
    }

    function _isInterior(uint256 band) internal view returns (bool) {
        return (_interiorBands >> band) & 1 == 1;
    }

    function numTicks() external pure returns (uint256) {
        return NUM_BANDS;
    }

    // ─────────────────────────────────────────────────────────────
    // Hook permissions
    // ─────────────────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────────
    // Hook callbacks
    // ─────────────────────────────────────────────────────────────

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (!isRegistered(key.currency0)) revert AssetNotRegistered(key.currency0);
        if (!isRegistered(key.currency1)) revert AssetNotRegistered(key.currency1);
        // The engine charges its own fee (`fee`) and consumes the whole input
        // in `beforeSwap`, so the PoolManager's curve never runs and a PoolKey
        // LP fee would never be charged. Accepting one would let a pool
        // advertise a fee it does not take, and a dynamic-fee flag would promise
        // fee updates this hook never makes. Pin it to zero.
        if (key.fee != 0) revert PoolKeyFeeMustBeZero(key.fee);
        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert NativeLiquidityDisabled();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert NativeLiquidityDisabled();
    }

    function _beforeSwap(address swapper, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        whenNotPaused
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (slot0.rInt == 0) revert NotEnoughLiquidity();

        // v4 states one side of the trade and leaves the other to the curve:
        // `amountSpecified` is negative for an exact-input swap (the trader
        // fixes what they pay) and positive for an exact-output one (they fix
        // what they receive). The engine serves both — `_solveWithCrossings`
        // walks the same segments either way — so routers and quoters that
        // quote by output work against the pool like any other v4 pool.
        bool exactOut = params.amountSpecified > 0;
        uint256 specifiedRaw = exactOut ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);
        if (specifiedRaw == 0) revert ZeroSwapInput();
        // Cap at the BeforeSwapDelta int128 range so the cast at return doesn't
        // silently wrap and emit a negative-looking delta.
        if (specifiedRaw > uint256(uint128(type(int128).max))) revert SwapAmountTooLarge(specifiedRaw);

        (Currency cIn, Currency cOut) = params.zeroForOne
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);
        uint8 assetIn = indexOf(cIn);
        uint8 assetOut = indexOf(cOut);

        // The engine works in WAD; `specifiedRaw` is in its token's raw units.
        // `netInWad` is what reaches the curve, `feeAmount` what the LPs keep.
        uint256 netInWad;
        uint256 outWad;
        uint256 feeAmount;
        {
            SwapState memory state;
            state.torus = _buildTorusState();
            state.exactOut = exactOut;
            // A swap moves, and reads, only the two reserves it trades; the
            // rest enter the engine through `sumX`/`sumXSq` alone. Loading all
            // N would cost a cold storage read for every idle asset.
            uint256[] memory res = new uint256[](N);
            res[assetIn] = reserves[assetIn];
            res[assetOut] = reserves[assetOut];

            if (exactOut) {
                outWad = _toWad(assetOut, specifiedRaw);
                // No pool can pay out more than its whole radius, and the
                // solver squares the amount: past MAX_RINT it would overflow
                // inside FullMath with an unnamed revert. Refuse it by name.
                if (outWad > MAX_RINT) revert SwapAmountTooLarge(specifiedRaw);
                state.remaining = outWad;
                // The walk returns the net input the output costs, and bills
                // each segment its own fee on the way (`_creditSegmentFee`).
                netInWad = _solveWithCrossings(state, res, assetIn, assetOut);
                feeAmount = state.feeCharged;
            } else {
                uint256 grossIn = _toWad(assetIn, specifiedRaw);
                if (grossIn > MAX_RINT) revert SwapAmountTooLarge(specifiedRaw);
                feeAmount = FullMath.mulDiv(grossIn, fee, 1_000_000);
                // A trade so small its fee floors to 0 would trade for free. It
                // is dust either way, so refuse it rather than carve out a
                // zero-fee path.
                if (feeAmount == 0) revert SwapAmountTooSmall(specifiedRaw);
                netInWad = grossIn - feeAmount;
                state.remaining = netInWad;
                state.feeRemaining = feeAmount;
                outWad = _solveWithCrossings(state, res, assetIn, assetOut);
            }
        }

        if (outWad == 0) revert ZeroSwapOutput();
        if (netInWad == 0) revert ZeroSwapInput();
        if (feeAmount == 0) revert SwapAmountTooSmall(specifiedRaw);
        // The exact-output path learns the input only by solving for it, so its
        // size is bounded here rather than before the walk.
        uint256 grossInWad = netInWad + feeAmount;
        if (grossInWad > MAX_RINT) revert SwapAmountTooLarge(specifiedRaw);
        feesAccrued[assetIn] += feeAmount;

        // Commit final sumX/sumXSq + reserves[in/out] (all WAD).
        // sumX/sumXSq deltas telescope over partials so a single update with
        // (netInWad, outWad) and pre-trade xi/xj gives the correct totals.
        _updateReserves(assetIn, assetOut, netInWad, outWad);
        // The payout comes out of real tokens: never below the virtual floor.
        if (reserves[assetOut] < virtualReserve) revert InsufficientRealReserves(assetOut);

        {
            TorusMath.TorusState memory end = _buildTorusState();
            (bool ok,) = TorusMath.checkInvariant(end);
            if (!ok) revert InvariantBroken();
            // The input's price falls monotonically as input is added, so a
            // positive price at the end holds along the whole trade. Past zero
            // the curve pays less for more input: the trader would do better
            // selling less, and no quote there is a real price.
            if (!TorusMath.pricedPositive(end, reserves[assetIn])) revert SwapBeyondZeroPrice();
        }

        // Back to raw units. The side the trader specified is paid or received
        // exactly as asked; the side the curve set rounds the pool's way — the
        // output down, so the pool never owes more than it holds, and the input
        // up, so it is never short of what the curve charged.
        uint256 amountInRaw = exactOut ? _toRawUp(assetIn, grossInWad) : specifiedRaw;
        uint256 amountOutRaw = exactOut ? specifiedRaw : _toRawDown(assetOut, outWad);
        if (amountOutRaw == 0) revert ZeroSwapOutput();
        if (amountInRaw > uint256(uint128(type(int128).max))) revert SwapAmountTooLarge(amountInRaw);
        if (amountOutRaw > uint256(uint128(type(int128).max))) revert SwapAmountTooLarge(amountOutRaw);

        _validateSwap(assetIn, assetOut, amountInRaw, amountOutRaw);

        // `swapper` is the address that called `poolManager.swap` (the router, or
        // an EOA going direct). `msg.sender` here is always the PoolManager,
        // since it is the PoolManager that calls the hook — emitting that made
        // every swap in the UI attributed to the PoolManager's own address.
        emit Swap(swapper, assetIn, assetOut, amountInRaw, amountOutRaw);

        cIn.take(poolManager, address(this), amountInRaw, true);
        cOut.settle(poolManager, address(this), amountOutRaw, true);

        // The delta is quoted against the side v4 calls "specified". For an
        // exact-input swap that is the input the hook takes (positive) and the
        // output it gives (negative); for an exact-output swap the two swap
        // places, since the output is what the trader specified.
        return (
            this.beforeSwap.selector,
            exactOut
                ? toBeforeSwapDelta(-int128(uint128(amountOutRaw)), int128(uint128(amountInRaw)))
                : toBeforeSwapDelta(int128(uint128(amountInRaw)), -int128(uint128(amountOutRaw))),
            0
        );
    }

    /// @dev Extension point for subclasses that must accept or reject a trade on
    ///      its final terms. Called exactly once per swap with
    ///      `(assetIn, assetOut, amountInRaw, amountOutRaw)` in each token's raw
    ///      units, after the engine has solved and booked the trade and before
    ///      any tokens move. Reverting rejects the swap atomically, since the
    ///      engine state written so far is rolled back with it. No-op here.
    function _validateSwap(uint8, uint8, uint256, uint256) internal view virtual {}

    // ─────────────────────────────────────────────────────────────
    // Tick-crossing solver (paper §4.13)
    // ─────────────────────────────────────────────────────────────

    struct SwapState {
        TorusMath.TorusState torus;
        /// @dev Still to trade on the side the swap specified: net input for an
        ///      exact-input swap, output for an exact-output one.
        uint256 remaining;
        /// @dev Exact input only: the fee not yet credited to a segment.
        uint256 feeRemaining;
        /// @dev Exact output only: the fee charged over the segments so far.
        uint256 feeCharged;
        /// @dev True when `remaining` counts output rather than input.
        bool exactOut;
    }

    struct XoverCoeffs {
        int256 bCoef;
        int256 cCoef;
        bool dPositive;
        uint256 D;
    }

    /// @dev Cap on crossing events per swap. Each band crosses at most once per
    ///      event however many positions share it, so a swap needing more than
    ///      this is one moving through more distinct bands than that — a router
    ///      splits it, and each part persists. The cap bounds worst-case gas.
    uint256 internal constant MAX_CROSSINGS = 20;

    /// @dev Cap on the total radius (and therefore on reserve magnitude). The
    ///      tick-crossing coefficients scale with RESERVE magnitude (`bCoef ≈
    ///      2·xi`, `cCoef ≈ sumXSq`) and are squared inside `QuadraticSolver`;
    ///      unbounded reserves could push them past int256 and revert the
    ///      crossing path. Every reserve is bounded by the radius of the ticks
    ///      holding it, so capping `_radiusTotal` caps them for the pool's life.
    ///      1e34 WAD ≈ 1e16 18-decimal tokens — far above any real pool, with
    ///      >1e6× int256 margin.
    uint256 internal constant MAX_RINT = 1e34;

    /// @dev A tick's virtual reserve is its xMin less 1e-9 of it. xMin is exact
    ///      geometry, but reserves carry wei-level rounding from the solver and
    ///      from pro-rata burns; this margin, immaterial to capital efficiency,
    ///      keeps every tick's real part strictly positive through it.
    uint256 internal constant VIRTUAL_HAIRCUT_DIVISOR = 1e9;

    function _solveWithCrossings(SwapState memory state, uint256[] memory res, uint8 assetIn, uint8 assetOut)
        internal
        returns (uint256 total)
    {
        for (uint256 iter = 0; iter < MAX_CROSSINGS; ++iter) {
            if (state.remaining == 0) break;

            uint256 alphaNormOld = _alphaNormOf(state.torus, state.torus.sumX);

            // The solvers mutate torus.sumX/sumXSq. Save and restore around the
            // call so crossing-detection and coefficient math see the pre-swap
            // state. Whichever side the swap specified, a segment is the pair
            // (candidateIn, candidateOut) the current ticks would trade.
            uint256 savedSumX = state.torus.sumX;
            uint256 savedSumXSq = state.torus.sumXSq;

            uint256 candidateIn;
            uint256 candidateOut;
            bool found;
            if (state.exactOut) {
                candidateOut = state.remaining;
                (candidateIn, found) =
                    TorusMath.solveSwapInputBounded(state.torus, assetIn, assetOut, candidateOut, res);
            } else {
                candidateIn = state.remaining;
                (candidateOut, found) =
                    TorusMath.solveSwapBounded(state.torus, assetIn, assetOut, candidateIn, res);
            }

            state.torus.sumX = savedSumX;
            state.torus.sumXSq = savedSumXSq;

            // Nothing in this configuration restores the invariant: the trade
            // would drain the output asset, or the input alone overshoots the
            // surface. Both are a trade the current ticks cannot absorb, so
            // αNorm is still rising and the next event on the path is the next
            // interior tick reaching its boundary.
            uint256 alphaNormNew = type(uint256).max;
            if (found) {
                TorusMath.TorusState memory end =
                    TorusMath.applyTrade(state.torus, res[assetIn], res[assetOut], candidateIn, candidateOut);
                alphaNormNew = _alphaNormOf(end, end.sumX);

                // Comparing αNorm at the two ends of the trade misses a crossing
                // when αNorm is not monotone along it, and on the way back to
                // peg it is not. The invariant only fixes (‖w‖ − s_bound)², but
                // the paper's geometry fixes the sign: interior and boundary
                // liquidity point the same way (§4.11, w_int ∥ w_bound), so
                // ‖w_int‖ = ‖w‖ − s_bound ≥ 0. A trade back toward balance
                // shrinks ‖w‖; at ‖w‖ = s_bound, ‖w_int‖ = 0 and αNorm bottoms
                // out at kMin/r — below every boundary tick's plane — then rises
                // again on the unphysical sheet ‖w‖ < s_bound. An end state on
                // that sheet therefore means the path passed αNorm's minimum and
                // every boundary tick came back on the way: treat it as falling
                // to that minimum.
                if (end.sBound != 0 && TorusMath.wNormOf(end) < end.sBound) alphaNormNew = 0;
            }

            (bool crossed, uint256 band) = _detectCrossing(alphaNormOld, alphaNormNew);

            if (!crossed) {
                if (!found) revert SwapExceedsLiquidity();
                _creditSegmentFee(state, assetIn, candidateIn);
                total += state.exactOut ? candidateIn : candidateOut;
                state.remaining = 0;
                break;
            }

            TickLib.Tick storage t = _ticks[band];
            bool rising = _isInterior(band);

            // Moving the last interior tick to its boundary would leave
            // rInt = 0: every tick on the boundary, where no swap can run (not
            // even the reverse trade that would recover them). That state is
            // terminal for trading, so a trade reaching it is refused instead.
            if (rising && t.r >= state.torus.rInt) revert SwapExceedsLiquidity();

            // A tick whose plane the pool already sits on (or, by rounding, a
            // unit past) needs no trade to reach it: it is flipped where it is.
            // Only a plane strictly ahead calls for a partial trade.
            uint256 kNorm = bandKNorm[band];
            if (rising ? kNorm > alphaNormOld : kNorm < alphaNormOld) {
                (uint256 partialIn, uint256 partialOut, bool reached) =
                    _tradeToXover(state, res, assetIn, assetOut, band);
                if (!reached) {
                    // Detection saw the plane crossed from the solved end state,
                    // yet the partial to reach it needs at least all the input
                    // left: the plane sits within rounding of the trade's end.
                    // Finish the trade on the current ticks, then flip the tick
                    // at the end state, where by the paper's rule (interior iff
                    // kNorm > αNorm) it is now on the far side of its plane.
                    if (!found) revert SwapExceedsLiquidity();
                    _creditSegmentFee(state, assetIn, candidateIn);
                    _applyPartial(state, res, assetIn, assetOut, candidateIn, candidateOut);
                    total += state.exactOut ? candidateIn : candidateOut;
                    state.remaining = 0;
                    _crossTick(band, state);
                    _crossTicksOnPlane(state, rising);
                    break;
                }
                _creditSegmentFee(state, assetIn, partialIn);
                total += state.exactOut ? partialIn : partialOut;
                state.remaining -= state.exactOut ? partialOut : partialIn;
                _applyPartial(state, res, assetIn, assetOut, partialIn, partialOut);
            }

            _crossTick(band, state);
            _crossTicksOnPlane(state, rising);

            if (iter == MAX_CROSSINGS - 1 && state.remaining > 0) revert TooManyCrossings();
        }
    }

    /// @dev Credit one segment's share of the swap's fee to the ticks interior
    ///      for that segment.
    ///
    ///      The fee is split in proportion to each segment's input, so a tick
    ///      earns only on the part of the trade it provided liquidity for.
    ///      Crediting the whole fee at the start instead, against the interior
    ///      radius before any crossing, paid a tick for volume it never saw: a
    ///      very tight band holds a large radius for little capital, would cross
    ///      out a sliver into a large trade, and still take its radius's share
    ///      of that trade's entire fee — at the other LPs' expense.
    ///      An exact-input swap knows the whole fee before it starts, so each
    ///      segment takes its share of what is left and the last segment
    ///      (`segIn == remaining`) takes the remainder, leaving none to
    ///      rounding. An exact-output swap learns its input only by solving, so
    ///      each segment is instead grossed up from its own net input,
    ///      f = segIn·fee/(1e6 − fee) rounded up, and the trade's fee is their
    ///      sum. Both charge the same rate on the same volume.
    function _creditSegmentFee(SwapState memory state, uint8 asset, uint256 segIn) internal {
        uint256 f;
        if (state.exactOut) {
            f = FullMath.mulDivRoundingUp(segIn, fee, 1_000_000 - fee);
            state.feeCharged += f;
        } else {
            f = segIn >= state.remaining
                ? state.feeRemaining
                : FullMath.mulDiv(state.feeRemaining, segIn, state.remaining);
            state.feeRemaining -= f;
        }
        if (f == 0) return;

        // growth = f·WAD / rInt, with the remainder carried to the next credit
        // so the division loses nothing over time.
        uint256 rInt = state.torus.rInt;
        uint256 num = f * WAD + _feeGrowthCarry[asset];
        uint256 g = num / rInt;
        _feeGrowthCarry[asset] = num - g * rInt;
        feeGrowthGlobal[asset] += g;
    }

    /// @dev Cross, as part of the same event, every other tick the pool now
    ///      sits on the plane of (paper §4.13: interior ticks share one
    ///      normalised point, so it meets every kNorm at or behind it together).
    ///
    ///      With one tick per band, only a tick a rounding unit behind the point
    ///      — left by an earlier crossing's floors — can be caught here, so this
    ///      normally does nothing. Bands ascend in kNorm, so each direction stops
    ///      at the first live tick of the right kind beyond the point.
    function _crossTicksOnPlane(SwapState memory state, bool rising) internal {
        uint256 alphaNorm = _alphaNormOf(state.torus, state.torus.sumX);
        // Walk the live bands on the moving side, nearest plane first (kNorm
        // ascends with the band index). Each band flips at most once, so a
        // snapshot of the mask is enough.
        if (rising) {
            for (uint256 m = _interiorBands; m != 0; m &= m - 1) {
                uint256 b = _lowestBand(m);
                if (bandKNorm[b] > alphaNorm) break;
                // Same terminal-state guard as the primary crossing.
                if (_ticks[b].r >= state.torus.rInt) revert SwapExceedsLiquidity();
                _crossTick(b, state);
            }
        } else {
            for (uint256 m = _pinnedBands; m != 0;) {
                uint256 b = _highestBand(m);
                if (bandKNorm[b] < alphaNorm) break;
                _crossTick(b, state);
                m ^= 1 << b;
            }
        }
    }

    /// @dev The tick the trade crosses first, if any (paper §4.13).
    ///
    ///      The paper's condition for a trade crossing nothing is
    ///      k_bound^max ≤ αNorm_new ≤ k_int^min: every boundary tick at or below
    ///      the new point, every interior tick at or above it. Rising, the
    ///      offender is the interior tick with the smallest kNorm (k_int^min), if
    ///      that is below αNorm_new; falling, the boundary tick with the largest
    ///      kNorm (k_bound^max), if that is above it.
    ///
    ///      That is judged against the extreme tick, not only ticks between the
    ///      old and new point. The two agree only if the state already meets the
    ///      condition exactly, and it need not: a crossing lands the pool on the
    ///      crossed plane, but αNorm is recomputed with floors, so a tick can be
    ///      left a unit behind it. Scanning only forward of αNorm_old would skip
    ///      that tick on every later trade, leaving it interior while the pool
    ///      moves past its plane — trading below its own x_min, on reserves other
    ///      ticks back. Bands ascend in kNorm, so the extreme tick is the first
    ///      live tick of the right kind from the matching end.
    function _detectCrossing(uint256 alphaNormOld, uint256 alphaNormNew)
        internal
        view
        returns (bool crossed, uint256 band)
    {
        if (alphaNormNew == alphaNormOld) return (false, 0);

        if (alphaNormNew > alphaNormOld) {
            uint256 m = _interiorBands;
            if (m == 0) return (false, 0);
            band = _lowestBand(m);
            return (bandKNorm[band] < alphaNormNew, band);
        }
        uint256 p = _pinnedBands;
        if (p == 0) return (false, 0);
        band = _highestBand(p);
        return (bandKNorm[band] > alphaNormNew, band);
    }

    /// @dev Index of the lowest / highest set bit of a non-zero band mask. A
    ///      mask has at most NUM_BANDS bits, so a short loop does it; that is
    ///      smaller than a general 256-bit search and costs far less than the
    ///      storage reads it replaces.
    function _lowestBand(uint256 m) private pure returns (uint256 b) {
        while ((m >> b) & 1 == 0) ++b;
    }

    function _highestBand(uint256 m) private pure returns (uint256 b) {
        b = NUM_BANDS - 1;
        while (m >> b == 0) --b;
    }

    /// @dev Compute (b, c) and the gap D for the partial-trade quadratic that
    ///      lands the pool on the plane of `band` (paper §4.13). Coefficients
    ///      are int256, in the WAD scale `QuadraticSolver` documents.
    function _xoverCoeffs(
        TorusMath.TorusState memory ts,
        uint256[] memory res,
        uint8 assetIn,
        uint8 assetOut,
        uint256 band
    ) internal view returns (XoverCoeffs memory q) {
        uint256 sqrtNc = ts.sqrtN; // cached √N·WAD (immutable `sqrtN` threaded via TorusState)

        uint256 alphaIntTarget = FullMath.mulDiv(bandKNorm[band], ts.rInt, WAD);
        uint256 targetSumX = FullMath.mulDiv(alphaIntTarget + ts.kBound, sqrtNc, WAD);

        q.dPositive = targetSumX >= ts.sumX;
        q.D = q.dPositive ? targetSumX - ts.sumX : ts.sumX - targetSumX;

        uint256 targetSumXSq;
        {
            uint256 rIntSqrtN = FullMath.mulDiv(ts.rInt, sqrtNc, WAD);
            uint256 t1Abs = alphaIntTarget >= rIntSqrtN ? alphaIntTarget - rIntSqrtN : rIntSqrtN - alphaIntTarget;
            uint256 rIntSq = FullMath.mulDiv(ts.rInt, ts.rInt, WAD);
            uint256 t1AbsSq = FullMath.mulDiv(t1Abs, t1Abs, WAD);
            uint256 CC = rIntSq >= t1AbsSq ? rIntSq - t1AbsSq : 0;
            uint256 wNormTarget = ts.sBound + SphereMath.sqrt(CC * WAD);
            uint256 wNormTargetSq = FullMath.mulDiv(wNormTarget, wNormTarget, WAD);
            targetSumXSq = wNormTargetSq + FullMath.mulDiv(targetSumX, targetSumX, ts.n * WAD);
        }

        // The trade moves Σx by exactly D (paper §4.13: d_j = √n(α − α_cross) + d_i),
        // so with p out, the amount in is p + σD where σ = +1 when Σx must rise
        // and −1 when it must fall. Of the reserves only xᵢ and xⱼ change, so
        //
        //   Σx²' = Σx² + (xᵢ + p + σD)² − xᵢ² + (xⱼ − p)² − xⱼ²
        //        = Σx² + 2p² + 2(xᵢ + σD − xⱼ)·p + σ·2xᵢD + D²
        //
        // and requiring Σx²' = targetSumXSq gives 2p² + b·p + c·WAD = 0 with
        //
        //   b = 2(xᵢ + σD − xⱼ),   c = Σx² + σ·2xᵢD + D² − targetSumXSq
        //
        // in WAD-normalised squares. Both are taken signed and exact: clamping
        // xᵢ − D at zero when σ = −1, as this once did, is a different polynomial
        // whenever xᵢ < D — which is the recovery case, buying back a depegged
        // coin with an input the depeg drained.
        uint256 xi = res[assetIn];
        uint256 xj = res[assetOut];
        int256 twoXiD = int256(FullMath.mulDiv(2 * xi, q.D, WAD));
        int256 signedD = q.dPositive ? int256(q.D) : -int256(q.D);

        q.bCoef = 2 * (int256(xi) + signedD - int256(xj));
        q.cCoef = int256(ts.sumXSq) + (q.dPositive ? twoXiD : -twoXiD) + int256(FullMath.mulDiv(q.D, q.D, WAD))
            - int256(targetSumXSq);
    }

    /// @dev The partial (in, out) that moves the pool exactly onto the crossed
    ///      tick's plane, or `reached = false` when the plane lies beyond what the
    ///      remaining input can reach.
    ///
    ///      `in = out + σD` cannot be negative, so the root must be at least D
    ///      when Σx falls (σ = −1) and at least 0 when it rises. Asking the solver
    ///      for the smallest root at or past that bound picks the first point on
    ///      the trade's path that meets the plane; taking the smallest
    ///      NON-NEGATIVE root instead would, on a falling trade, land behind the
    ///      state and read as a negative input.
    function _tradeToXover(
        SwapState memory state,
        uint256[] memory res,
        uint8 assetIn,
        uint8 assetOut,
        uint256 band
    ) internal view returns (uint256 partialIn, uint256 partialOut, bool reached) {
        XoverCoeffs memory q = _xoverCoeffs(state.torus, res, assetIn, assetOut, band);

        (partialOut, reached) = QuadraticSolver.smallestRootAtLeast(q.bCoef, q.cCoef, q.dPositive ? 0 : q.D);
        if (!reached) return (0, 0, false);

        partialIn = q.dPositive ? partialOut + q.D : partialOut - q.D;
        // The plane is only ahead of the trade's end if reaching it costs less
        // than the swap has left on the side it specified.
        if (state.exactOut ? partialOut >= state.remaining : partialIn >= state.remaining) {
            return (0, 0, false);
        }

        if (partialOut >= res[assetOut]) revert CrossingPartialExceedsOutputReserve();
    }

    /// @dev Flip a tick interior↔boundary and update both `state.torus` and `slot0`.
    function _crossTick(uint256 band, SwapState memory state) internal {
        TickLib.Tick storage t = _ticks[band];
        uint256 s = TorusMath.computeS(t.r, t.k, N);
        bool wasInterior = _isInterior(band);

        if (wasInterior) {
            state.torus.rInt -= t.r;
            state.torus.kBound += t.k;
            state.torus.sBound += s;
            // Going interior → boundary: freeze fee accrual by banking the growth
            // earned since the last entry; the tick earns nothing while out.
            for (uint8 i = 0; i < N; ++i) {
                tickFeeGrowthInside[band][i] += feeGrowthGlobal[i] - tickFeeGrowthSnapshot[band][i];
            }
        } else {
            state.torus.rInt += t.r;
            state.torus.kBound -= t.k;
            state.torus.sBound -= s;
            // Boundary → interior recovery: resume accrual from the current global.
            for (uint8 i = 0; i < N; ++i) {
                tickFeeGrowthSnapshot[band][i] = feeGrowthGlobal[i];
            }
        }

        // Commit the updated torus aggregates — identical in both branches.
        slot0.rInt = state.torus.rInt;
        slot0.kBound = state.torus.kBound;
        slot0.sBound = state.torus.sBound;

        uint128 bit = uint128(1 << band);
        if (wasInterior) {
            _interiorBands &= ~bit;
            _pinnedBands |= bit;
        } else {
            _pinnedBands &= ~bit;
            _interiorBands |= bit;
        }

        (bool ok,) = TorusMath.checkInvariant(state.torus);
        if (!ok) revert InvariantBroken();

        emit TickCrossed(band, !wasInterior);
    }

    /// @dev Apply a settled partial swap to the in-memory torus + reserve copy.
    ///      `slot0.sumX/sumXSq` and storage `reserves` are committed in one
    ///      go later via `_updateReserves` — the per-asset xi/xj telescoping
    ///      makes that equivalent to summing per-partial deltas.
    function _applyPartial(
        SwapState memory state,
        uint256[] memory res,
        uint8 assetIn,
        uint8 assetOut,
        uint256 partialIn,
        uint256 partialOut
    ) internal pure {
        uint256 xi = res[assetIn];
        uint256 xj = res[assetOut];

        res[assetIn] = xi + partialIn;
        res[assetOut] = xj - partialOut;

        state.torus.sumX = state.torus.sumX + partialIn - partialOut;
        // Add before subtracting, as in `_updateReserves`.
        state.torus.sumXSq = state.torus.sumXSq + FullMath.mulDiv(2 * xi, partialIn, WAD)
            + FullMath.mulDiv(partialIn, partialIn, WAD) + FullMath.mulDiv(partialOut, partialOut, WAD)
            - FullMath.mulDiv(2 * xj, partialOut, WAD);
    }

    function _alphaNormOf(TorusMath.TorusState memory ts, uint256 sumX) internal pure returns (uint256) {
        uint256 sqrtNc = ts.sqrtN; // cached √N·WAD (immutable `sqrtN` threaded via TorusState)
        uint256 alphaTot = FullMath.mulDiv(sumX, WAD, sqrtNc);
        uint256 alphaInt = alphaTot >= ts.kBound ? alphaTot - ts.kBound : 0;
        return ts.rInt > 0 ? FullMath.mulDiv(alphaInt, WAD, ts.rInt) : type(uint256).max;
    }

    function _updateReserves(uint8 assetIn, uint8 assetOut, uint256 amountIn, uint256 amountOut) internal {
        uint256 xiOld = reserves[assetIn];
        uint256 xjOld = reserves[assetOut];

        slot0.sumX = slot0.sumX + amountIn - amountOut;

        uint256 addIn =
            FullMath.mulDiv(2 * xiOld, amountIn, WAD) + FullMath.mulDiv(amountIn, amountIn, WAD);
        uint256 twoXjAmountOut = FullMath.mulDiv(2 * xjOld, amountOut, WAD);
        uint256 amountOutSq = FullMath.mulDiv(amountOut, amountOut, WAD);

        // Add before subtracting: Σx² − 2·xⱼ·out + out² ≥ 0, but the running
        // value can dip below zero if the subtraction comes first.
        slot0.sumXSq = slot0.sumXSq + addIn + amountOutSq - twoXjAmountOut;

        reserves[assetIn] += amountIn;
        reserves[assetOut] -= amountOut;
    }

    // ─────────────────────────────────────────────────────────────
    // Public LP entry points (direct-to-hook)
    // ─────────────────────────────────────────────────────────────

    /// @notice Add `rWad` of radius to band `band`. Pulls each asset from the
    ///         caller via direct ERC-20 approval (caller must approve this hook
    ///         to spend each asset).
    /// @param  deadline Latest block timestamp the mint may execute at.
    /// @return tickIdx  The band's tick — also the ERC-6909 share id.
    function addLiquidity(uint256 band, uint256 rWad, uint256[] calldata maxAmounts, uint256 deadline)
        external
        whenNotPaused
        returns (uint256 tickIdx, uint256[] memory amounts)
    {
        return _addLiquidity(band, rWad, maxAmounts, deadline);
    }

    function _addLiquidity(
        uint256 band,
        uint256 rWad,
        uint256[] calldata maxAmounts,
        uint256 deadline
    ) internal returns (uint256 tickIdx, uint256[] memory amounts) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (band >= NUM_BANDS) revert InvalidBand(band);
        if (rWad == 0) revert ZeroRWad();
        if (maxAmounts.length != N) revert InvalidAssetCount(maxAmounts.length);

        bytes memory ret = poolManager.unlock(
            abi.encode(
                Action.MINT,
                abi.encode(
                    MintData({
                        recipient: msg.sender,
                        band: band,
                        rWad: rWad,
                        maxAmounts: maxAmounts
                    })
                )
            )
        );
        (tickIdx, amounts) = abi.decode(ret, (uint256, uint256[]));
    }

    /// @notice Remove `rWad` of the caller's liquidity from band `band`. Pays
    ///         each asset out to the caller, floored by `minAmounts[i]`. Works
    ///         whether the band is interior or pinned by a depeg.
    function removeLiquidity(uint256 band, uint256 rWad, uint256[] calldata minAmounts, uint256 deadline)
        external
        returns (uint256[] memory amounts)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (band >= NUM_BANDS) revert InvalidBand(band);
        if (rWad == 0) revert ZeroRWad();
        if (minAmounts.length != N) revert InvalidAssetCount(minAmounts.length);
        if (balanceOf[msg.sender][band] < rWad) revert NotEnoughLiquidity();

        bytes memory ret = poolManager.unlock(
            abi.encode(
                Action.BURN,
                abi.encode(BurnData({owner: msg.sender, band: band, rWad: rWad, minAmounts: minAmounts}))
            )
        );
        amounts = abi.decode(ret, (uint256[]));
    }

    /// @notice Claim accrued fees on band `band` for the caller's position.
    function collect(uint256 band) external returns (uint256[] memory fees) {
        if (band >= NUM_BANDS) revert InvalidBand(band);
        bytes memory ret = poolManager.unlock(
            abi.encode(Action.COLLECT, abi.encode(CollectData({owner: msg.sender, band: band})))
        );
        fees = abi.decode(ret, (uint256[]));
    }

    /// @notice Pay the caller what an earlier withdrawal or fee collection
    ///         could not deliver of `asset` (see `PayoutDeferred`). Reverts,
    ///         keeping the claim, while the token still cannot be transferred.
    ///         An asset index nobody is owed (including an invalid one)
    ///         reverts with `NothingOwed`.
    function claimOwed(uint8 asset) external returns (uint256 amount) {
        bytes memory ret = poolManager.unlock(abi.encode(Action.CLAIM_OWED, abi.encode(msg.sender, asset)));
        amount = abi.decode(ret, (uint256));
    }

    // ─────────────────────────────────────────────────────────────
    // Unlock callback dispatch
    // ─────────────────────────────────────────────────────────────

    function unlockCallback(bytes calldata raw) external onlyPoolManager nonReentrant returns (bytes memory) {
        (Action action, bytes memory payload) = abi.decode(raw, (Action, bytes));

        if (action == Action.MINT) {
            MintData memory m = abi.decode(payload, (MintData));
            uint256[] memory amounts = _executeMint(m);
            return abi.encode(m.band, amounts);
        }
        if (action == Action.BURN) {
            BurnData memory b = abi.decode(payload, (BurnData));
            uint256[] memory amounts = _executeBurn(b);
            return abi.encode(amounts);
        }
        if (action == Action.COLLECT) {
            CollectData memory cdata = abi.decode(payload, (CollectData));
            uint256[] memory fees = _executeCollect(cdata);
            return abi.encode(fees);
        }
        if (action == Action.CLAIM_OWED) {
            (address to, uint8 asset) = abi.decode(payload, (address, uint8));
            return abi.encode(_executeClaimOwed(to, asset));
        }
        revert InvalidAction();
    }

    // ─────────────────────────────────────────────────────────────
    // Soulbound ERC-6909
    //
    // Position bookkeeping (fees, contributed r) is keyed by the minter.
    // Moving the share without that bookkeeping would leave the new holder
    // unable to burn or collect, so the share cannot move — and approvals,
    // which exist only to move it, are refused rather than accepted as no-ops.
    // ─────────────────────────────────────────────────────────────

    function transfer(address, uint256, uint256) public pure returns (bool) {
        revert SharesAreSoulbound();
    }

    function transferFrom(address, address, uint256, uint256) public pure returns (bool) {
        revert SharesAreSoulbound();
    }

    function approve(address, uint256, uint256) public pure returns (bool) {
        revert SharesAreSoulbound();
    }

    function setOperator(address, bool) public pure returns (bool) {
        revert SharesAreSoulbound();
    }

    // ─────────────────────────────────────────────────────────────
    // MINT
    // ─────────────────────────────────────────────────────────────

    function _executeMint(MintData memory m) internal returns (uint256[] memory amounts) {
        // The tick's share of the (virtual) reserves, and the part of it the LP
        // actually deposits: the share less the tick's virtual reserve.
        uint256[] memory share;
        uint256 kWad;
        uint256 virt;
        (amounts, share, kWad, virt) = _depositAmounts(m.band, m.rWad);

        // Slippage check.
        for (uint8 i = 0; i < N; ++i) {
            if (amounts[i] > m.maxAmounts[i]) revert SlippageExceeded(i, amounts[i], m.maxAmounts[i]);
        }

        // Join the band's tick (bringing it to life if it has none), then book
        // the full virtual share into the interior.
        _joinBand(m.band, m.rWad);
        tickVirtual[m.band] += virt;
        virtualReserve += virt;
        _applyMintToTorus(share, m.rWad);
        _liquidityEverAdded = true;

        // Bound total radius so the crossing-path solver coefficients stay
        // within int256 (see MAX_RINT).
        _radiusTotal += m.rWad;
        if (_radiusTotal > MAX_RINT) revert RadiusCapExceeded();

        // Position bookkeeping. An existing position in the band banks its fees
        // at the old size first; a new one starts its checkpoint at the tick's
        // current growth — after `_joinBand`, which resets a reborn tick's.
        bytes32 pKey = PositionLib.positionKey(m.recipient, m.band);
        PositionLib.Position storage pos = positions[pKey];
        if (pos.r != 0) {
            _updatePositionFees(pKey, pos.r, m.band);
        } else {
            for (uint8 i = 0; i < N; ++i) {
                _feeGrowthInsideLast[pKey][i] = _tickInsideGrowth(m.band, i);
            }
        }
        pos.r += m.rWad;

        // Pull tokens to PoolManager (direct ERC-20 OR via Permit2), then
        // convert the resulting +amt delta into ERC-6909 claim tokens held by
        // the hook so net delta on each currency is zero by unlock end.
        for (uint8 i = 0; i < N; ++i) {
            uint256 amtWad = amounts[i];
            if (amtWad == 0) continue;
            Currency c = _assets[i];
            // Convert the WAD deposit to the token's raw units, rounding UP so the
            // pool is never under-funded against the WAD credited to reserves.
            uint256 amt = _toRawUp(i, amtWad);

            // Measure the PoolManager's real balance delta across the transfer.
            // `reserves` was already credited the full WAD amount by
            // `_applyMintToTorus`, and `poolManager.mint` below claims the full
            // `amt`, so anything less than `amt` actually arriving would leave the
            // engine believing in tokens the pool does not hold. v4's own
            // accounting would revert with `CurrencyNotSettled`, but only as a
            // side effect; this makes the failure explicit and named.
            address token = Currency.unwrap(c);
            uint256 pmBefore = IERC20Decimals(token).balanceOf(address(poolManager));

            // CurrencySettler.settle uses SafeERC20 under the hood, so a
            // non-bool-returning token such as USDT settles correctly.
            c.settle(poolManager, m.recipient, amt, false);

            uint256 received = IERC20Decimals(token).balanceOf(address(poolManager)) - pmBefore;
            if (received < amt) revert TokenTransferShortfall(c, amt, received);

            poolManager.mint(address(this), c.toId(), amt);
        }

        // Invariant guard.
        (bool ok,) = TorusMath.checkInvariant(_buildTorusState());
        if (!ok) revert InvariantBroken();

        // Mint LP shares (share id = band).
        _mint(m.recipient, m.band, m.rWad);

        emit Mint(m.recipient, m.band, kWad, m.rWad, amounts);
    }

    /// @notice Tokens (WAD per asset) a mint of radius `rWad` in band `band`
    ///         would take right now. Reverts where the mint itself would.
    function depositAmounts(uint256 band, uint256 rWad) external view returns (uint256[] memory amounts) {
        if (band >= NUM_BANDS) revert InvalidBand(band);
        (amounts,,,) = _depositAmounts(band, rWad);
    }

    /// @dev What a mint of `rWad` into `band` books and takes: its share of the
    ///      virtual reserves, the plane constant it adds, its virtual reserve,
    ///      and the real deposit (share − virtual, per asset).
    ///
    ///      New liquidity always joins the interior. By the paper's consolidation
    ///      (§4.10, case 1) every interior tick holds the same normalised point,
    ///      x_a = (r_a / r_int)·x_int, so the new tick's share is (rWad / rInt) of
    ///      the interior reserves: the total less what the pinned ticks hold
    ///      (§4.11). Scaling the interior sphere by (rInt + rWad) / rInt keeps
    ///      the torus invariant, so this is exact during a depeg as well as at
    ///      peg — where the pinned part is zero and it reduces to pro rata.
    function _depositAmounts(uint256 band, uint256 rWad)
        internal
        view
        returns (uint256[] memory amounts, uint256[] memory share, uint256 kWad, uint256 virt)
    {
        uint256 kNorm = bandKNorm[band];
        kWad = FullMath.mulDiv(kNorm, rWad, WAD);
        share = new uint256[](N);

        Slot0 memory s0 = slot0;
        if (s0.rInt == 0) {
            // No interior point to join. With nothing pinned either, the pool is
            // empty and the first tick opens at the equal price point (§4.3).
            if (s0.kBound != 0) revert MintBlockedByBoundaryTicks();
            uint256 q = SphereMath.equalPricePoint(rWad, N);
            for (uint8 i = 0; i < N; ++i) share[i] = q;
        } else {
            TorusMath.TorusState memory ts = _buildTorusState();
            // The new tick starts at the interior point, which must be inside
            // its band: αNorm ≤ kNorm, judged exactly as detection judges it.
            // A band pinned right at its plane is on the far side too.
            if (_alphaNormOf(ts, ts.sumX) > kNorm) revert TickOutsideItsBand();
            if ((_pinnedBands >> band) & 1 == 1) revert TickOutsideItsBand();

            uint256[] memory res = _currentReserves();
            uint256[] memory xBound = _pinnedPart(ts, res, s0.kBound, s0.sBound, true);
            for (uint8 i = 0; i < N; ++i) {
                uint256 xInt = res[i] > xBound[i] ? res[i] - xBound[i] : 0;
                share[i] = FullMath.mulDiv(xInt, rWad, s0.rInt);
            }
        }

        uint256 xMin = TickLib.xMin(rWad, N, kWad);
        virt = xMin - xMin / VIRTUAL_HAIRCUT_DIVISOR;

        amounts = new uint256[](N);
        for (uint8 i = 0; i < N; ++i) {
            // Inside the band every coordinate is ≥ xMin > virt.
            if (share[i] < virt) revert TickOutsideItsBand();
            amounts[i] = share[i] - virt;
        }
    }

    /// @dev Reserves held by pinned liquidity of plane constant `kPart` and
    ///      boundary radius `sPart`, per asset (paper §4.11).
    ///
    ///      A pinned tick sits on its plane, α = k, so it holds k/√n of every
    ///      coin along v; and its orthogonal part has length s and points along
    ///      w — every pinned and interior tick shares that direction (§4.11,
    ///      w_int ∥ w_bound). So coordinate i is k/√n + s·wᵢ/‖w‖, with
    ///      wᵢ = xᵢ − Σx/n. `roundUp` picks the direction the whole coordinate
    ///      rounds in, which is the caller's safe side.
    function _pinnedPart(
        TorusMath.TorusState memory ts,
        uint256[] memory res,
        uint256 kPart,
        uint256 sPart,
        bool roundUp
    ) internal pure returns (uint256[] memory x) {
        uint256 n = ts.n;
        x = new uint256[](n);
        if (kPart == 0 && sPart == 0) return x;

        uint256 base = roundUp
            ? FullMath.mulDivRoundingUp(kPart, WAD, ts.sqrtN)
            : FullMath.mulDiv(kPart, WAD, ts.sqrtN);
        uint256 wNorm = TorusMath.wNormOf(ts);
        if (sPart != 0 && wNorm == 0) revert InvalidBoundaryState();
        uint256 mean = ts.sumX / n;

        for (uint256 i = 0; i < n; ++i) {
            if (sPart == 0) {
                x[i] = base;
                continue;
            }
            bool below = res[i] < mean;
            uint256 dev = below ? mean - res[i] : res[i] - mean;
            // Rounding the subtracted term the other way rounds the coordinate
            // the way asked.
            uint256 term = roundUp != below
                ? FullMath.mulDivRoundingUp(sPart, dev, wNorm)
                : FullMath.mulDiv(sPart, dev, wNorm);
            x[i] = below ? (base > term ? base - term : 0) : base + term;
        }
    }

    /// @dev Add `rWad` to band `band`'s tick, bringing it to life (interior,
    ///      with a fresh fee history) if it had none. Its plane constant is the
    ///      band's kNorm times the new radius, so merging positions can never
    ///      move the band's boundary.
    function _joinBand(uint256 band, uint256 rWad) internal {
        TickLib.Tick storage t = _ticks[band];
        if (t.r == 0) {
            _interiorBands |= uint128(1 << band);
            for (uint8 i = 0; i < N; ++i) {
                tickFeeGrowthSnapshot[band][i] = feeGrowthGlobal[i];
                tickFeeGrowthInside[band][i] = 0;
            }
        }
        t.r += rWad;
        t.k = FullMath.mulDiv(bandKNorm[band], t.r, WAD);
    }

    function _applyMintToTorus(uint256[] memory amounts, uint256 rWad) internal {
        // Accumulate sumX/sumXSq in memory and commit once at the end — one
        // SSTORE per slot0 field instead of N per asset.
        uint256 totalAdded;
        uint256 sumXSqAdded;
        for (uint8 i = 0; i < N; ++i) {
            uint256 xi = reserves[i];
            uint256 amt = amounts[i];
            totalAdded += amt;
            sumXSqAdded += FullMath.mulDiv(2 * xi, amt, WAD) + FullMath.mulDiv(amt, amt, WAD);
            reserves[i] = xi + amt;
        }
        slot0.sumX += totalAdded;
        slot0.sumXSq += sumXSqAdded;
        slot0.rInt += rWad;
    }

    // ─────────────────────────────────────────────────────────────
    // Engine helpers
    // ─────────────────────────────────────────────────────────────

    function _buildTorusState() internal view returns (TorusMath.TorusState memory) {
        Slot0 memory s = slot0;
        return TorusMath.TorusState({rInt: s.rInt, kBound: s.kBound, sBound: s.sBound, sumX: s.sumX, sumXSq: s.sumXSq, n: N, sqrtN: sqrtN});
    }

    function _currentReserves() internal view returns (uint256[] memory out) {
        out = new uint256[](N);
        for (uint8 i = 0; i < N; ++i) {
            out[i] = reserves[i];
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Decimal scaling — raw token units <-> WAD. The engine is WAD;
    // these are applied only where real tokens cross the PoolManager.
    // ─────────────────────────────────────────────────────────────

    /// @notice Per-asset raw -> WAD multiplier. `10^(18-decimals)` by default
    ///         (1 for 18-decimal tokens); a numeraire-priced subclass folds the
    ///         asset's price into it, so `raw * scaleOf(i)` is always the WAD
    ///         value the engine books.
    function scaleOf(uint8 i) public view returns (uint256) {
        return _scale[i];
    }

    /// @dev Replace an asset's raw -> WAD multiplier. Only legal before the
    ///      pool has EVER held liquidity.
    ///
    ///      Reserves, tick radii and fee accumulators are all stored in WAD. The
    ///      scale is the only link between those WAD figures and the raw tokens
    ///      the PoolManager actually holds, so changing it on a pool with any
    ///      history would silently re-denominate stored WAD against unchanged
    ///      balances and break solvency. `_liquidityEverAdded` is set on the
    ///      first mint and never cleared, since fee buckets outlive a full exit.
    function _setScale(uint8 i, uint256 s) internal {
        if (_liquidityEverAdded) revert ScaleFrozen();
        if (s == 0) revert ZeroScale(i);
        _scale[i] = s;
    }

    /// @dev Raw token amount -> WAD (exact; scale is an integer multiplier).
    function _toWad(uint8 i, uint256 raw) internal view returns (uint256) {
        return raw * _scale[i];
    }

    /// @dev WAD -> raw, rounding DOWN. Used for pay-outs so the pool never
    ///      sends more than it holds (rounding favours the pool).
    function _toRawDown(uint8 i, uint256 wad) internal view returns (uint256) {
        return wad / _scale[i];
    }

    /// @dev WAD -> raw, rounding UP. Used for deposits so the pool is never
    ///      under-funded against the WAD credited to reserves.
    function _toRawUp(uint8 i, uint256 wad) internal view returns (uint256) {
        uint256 s = _scale[i];
        return (wad + s - 1) / s;
    }

    // ─────────────────────────────────────────────────────────────
    // Fee accounting
    // ─────────────────────────────────────────────────────────────

    /// @dev Cumulative fee growth credited to `band`'s tick for asset `i`,
    ///      counting only the time it has been INTERIOR. For an interior tick
    ///      this is the frozen total plus the live growth since its last entry;
    ///      for a boundary tick it's just the frozen total. `feeGrowthGlobal`
    ///      only increases and the snapshot is set to it on entry, so the
    ///      subtraction never underflows.
    function _tickInsideGrowth(uint256 band, uint8 i) internal view returns (uint256) {
        uint256 g = tickFeeGrowthInside[band][i];
        if (_isInterior(band)) {
            g += feeGrowthGlobal[i] - tickFeeGrowthSnapshot[band][i];
        }
        return g;
    }

    function _updatePositionFees(bytes32 pKey, uint256 posR, uint256 band) internal {
        for (uint8 i = 0; i < N; ++i) {
            uint256 inside = _tickInsideGrowth(band, i);
            uint256 last = _feeGrowthInsideLast[pKey][i];
            if (inside != last) {
                if (posR > 0) {
                    _tokensOwed[pKey][i] += FullMath.mulDiv(posR, inside - last, WAD);
                }
                _feeGrowthInsideLast[pKey][i] = inside;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // BURN
    // ─────────────────────────────────────────────────────────────

    /// @dev A burn pays out the burning part of its tick's actual holding,
    ///      which the paper fixes whether the tick is interior or pinned
    ///      (§4.10–4.11), so an LP can leave during a depeg as well as at peg.
    function _executeBurn(BurnData memory b) internal returns (uint256[] memory amounts) {
        bytes32 pKey = PositionLib.positionKey(b.owner, b.band);
        PositionLib.Position storage pos = positions[pKey];
        if (pos.r < b.rWad) revert NotEnoughLiquidity();

        // Settle fees against the OLD position size before modifying it.
        _updatePositionFees(pKey, pos.r, b.band);

        TickLib.Tick storage t = _ticks[b.band];
        uint256 tickR = t.r;
        uint256 kNew = FullMath.mulDiv(bandKNorm[b.band], tickR - b.rWad, WAD);

        uint256[] memory share;
        {
            TorusMath.TorusState memory ts = _buildTorusState();
            uint256[] memory res = _currentReserves();
            if (_isInterior(b.band)) {
                // §4.10, case 1: an interior tick holds (r / rInt) of the
                // interior reserves — the total less the pinned part. Burning
                // it scales the interior sphere down, which keeps the torus
                // invariant with rInt reduced to match.
                uint256[] memory xBound = _pinnedPart(ts, res, ts.kBound, ts.sBound, true);
                share = new uint256[](N);
                for (uint8 i = 0; i < N; ++i) {
                    uint256 xInt = res[i] > xBound[i] ? res[i] - xBound[i] : 0;
                    share[i] = FullMath.mulDiv(xInt, b.rWad, ts.rInt);
                }
                slot0.rInt = ts.rInt - b.rWad;
            } else {
                // §4.11: a pinned tick holds k/√n of every coin plus s along ŵ.
                // The burning part is the drop in its k and s, and removing it
                // leaves αInt and ‖w‖ − sBound unchanged, so the invariant too.
                uint256 sOld = TorusMath.computeS(tickR, t.k, N);
                uint256 sNew = TorusMath.computeS(tickR - b.rWad, kNew, N);
                uint256 kPart = t.k - kNew;
                uint256 sPart = sOld > sNew ? sOld - sNew : 0;
                share = _pinnedPart(ts, res, kPart, sPart, false);
                slot0.kBound = ts.kBound - kPart;
                slot0.sBound = ts.sBound - sPart;
            }
        }

        // The burned share carries its pro-rata part of the tick's virtual
        // reserve, which stays unpaid; the LP receives the real remainder, and
        // `reserves − virtualReserve` falls by exactly what is paid.
        //
        // The virtual that REMAINS on the tick is floored, so the burned part
        // rounds up. A tick's virtual must never exceed its proportional share
        // of the reserves: rounded the other way, a near-total burn leaves a
        // dust tick whose ≥ 1 wei of virtual outweighs the sub-wei reserves
        // behind it, and the pool's reserves dip below the virtual floor. A
        // full burn always pays: every coordinate of a tick — interior inside
        // its cap, or pinned on its circle — is at least its x_min.
        uint256 virtOut =
            tickVirtual[b.band] - FullMath.mulDiv(tickVirtual[b.band], tickR - b.rWad, tickR);
        amounts = new uint256[](N);
        for (uint8 i = 0; i < N; ++i) {
            if (share[i] < virtOut) revert InsufficientRealReserves(i);
            amounts[i] = share[i] - virtOut;
        }

        // Slippage check.
        for (uint8 i = 0; i < N; ++i) {
            if (amounts[i] < b.minAmounts[i]) revert SlippageExceeded(i, amounts[i], b.minAmounts[i]);
        }

        // Update sumX, sumXSq, reserves.
        {
            uint256 totalRemoved;
            uint256 totalSqRemoved;
            for (uint8 i = 0; i < N; ++i) {
                uint256 xOld = reserves[i];
                uint256 amt = share[i];
                totalRemoved += amt;
                // Δ(x²) = 2·x·amt − amt²
                totalSqRemoved += FullMath.mulDiv(2 * xOld, amt, WAD) - FullMath.mulDiv(amt, amt, WAD);
                reserves[i] = xOld - amt;
            }
            slot0.sumX -= totalRemoved;
            // Saturating to absorb ≤ N wei of mulDiv rounding dust against mint.
            slot0.sumXSq = slot0.sumXSq > totalSqRemoved ? slot0.sumXSq - totalSqRemoved : 0;
        }

        // The band's plane constant follows its radius; kNorm never moves.
        t.r = tickR - b.rWad;
        t.k = kNew;
        if (t.r == 0) {
            uint128 bit = uint128(1 << b.band);
            _interiorBands &= ~bit;
            _pinnedBands &= ~bit;
        }
        tickVirtual[b.band] -= virtOut;
        virtualReserve -= virtOut;
        _radiusTotal -= b.rWad;
        pos.r -= b.rWad;

        // The payout must come out of tokens the pool actually holds, as
        // `_beforeSwap` requires of a swap payout.
        //
        // In exact arithmetic this cannot fail: the share paid is the burning
        // tick's own holding, and every remaining tick still covers its own
        // virtual floor. What can fail is the wei-level rounding around that,
        // which the 1e-9 haircut on `virt` is there to absorb; this makes that
        // margin checked rather than assumed.
        for (uint8 i = 0; i < N; ++i) {
            if (reserves[i] < virtualReserve) revert InsufficientRealReserves(i);
        }

        if (pos.r == 0) {
            // Its fees were banked into `_tokensOwed` above and stay collectable.
            delete positions[pKey];
        }

        // Burn the LP's ERC-6909 share.
        _burn(b.owner, b.band, b.rWad);

        // Engine state is now final — validate the invariant and emit BEFORE any
        // token movement (checks-effects-interactions). The payout loop below only
        // transfers tokens; it does not touch reserves/slot0. With no interior
        // liquidity left there is no sphere to check.
        if (slot0.rInt > 0) {
            (bool ok,) = TorusMath.checkInvariant(_buildTorusState());
            if (!ok) revert InvariantBroken();
        }
        emit Burn(b.owner, b.band, b.rWad, amounts);

        // Interactions: pay owner each asset as raw ERC-20. WAD -> raw rounds
        // DOWN so the pool never pays out more than it holds.
        for (uint8 i = 0; i < N; ++i) {
            uint256 amtWad = amounts[i];
            if (amtWad == 0) continue;
            _payOrDefer(i, b.owner, _toRawDown(i, amtWad));
        }
    }

    // ─────────────────────────────────────────────────────────────
    // COLLECT
    // ─────────────────────────────────────────────────────────────

    function _executeCollect(CollectData memory cdata) internal returns (uint256[] memory fees) {
        bytes32 pKey = PositionLib.positionKey(cdata.owner, cdata.band);
        PositionLib.Position storage pos = positions[pKey];

        _updatePositionFees(pKey, pos.r, cdata.band);

        fees = new uint256[](N);
        uint256[] memory payRaw = new uint256[](N);
        bool any;

        // Effects: settle all fee accounting first (checks-effects-interactions),
        // recording the raw amount to pay per asset.
        for (uint8 i = 0; i < N; ++i) {
            uint256 due = _tokensOwed[pKey][i];
            if (due == 0) continue;
            if (feesAccrued[i] < due) revert FeeBucketShort();

            // WAD -> raw, rounding down (pool's favour). Any sub-raw-unit
            // remainder stays in _tokensOwed so it is paid once it grows past one
            // raw unit, rather than being silently wiped.
            uint256 dueRaw = _toRawDown(i, due);
            if (dueRaw == 0) continue;
            uint256 paidWad = dueRaw * _scale[i];

            _tokensOwed[pKey][i] = due - paidWad;
            feesAccrued[i] -= paidWad;
            fees[i] = paidWad;
            payRaw[i] = dueRaw;
            any = true;
        }

        if (!any) revert NothingOwed();
        emit Collect(cdata.owner, cdata.band, fees);

        // Interactions: pay out only after all state is settled.
        for (uint8 i = 0; i < N; ++i) {
            _payOrDefer(i, cdata.owner, payRaw[i]);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // PAYOUT
    // ─────────────────────────────────────────────────────────────

    /// @dev Pay `amt` (raw) of asset `i` to `to`, or hold it for them.
    ///
    ///      Stablecoins can stop moving: an issuer can pause its token, or
    ///      freeze the recipient or the PoolManager itself. Paying every asset
    ///      in one all-or-nothing loop would then revert every withdrawal and
    ///      fee collection in the pool — including everyone's healthy coins —
    ///      for as long as any one token stays frozen. So each asset is paid on
    ///      its own: the PoolManager transfers it out and the hook burns the
    ///      matching claim tokens; if the transfer reverts, both are rolled
    ///      back with it, and the hook keeps those claim tokens as `owed` to
    ///      `to` instead. The other assets are paid as usual.
    ///
    ///      Only the recipient's own payout can be deferred, and only into a
    ///      claim they can redeem (`claimOwed`), so forcing a failure (say, by
    ///      giving the call too little gas) harms no one but the caller.
    function _payOrDefer(uint8 i, address to, uint256 amt) internal {
        if (amt == 0) return;
        Currency c = _assets[i];
        try poolManager.take(c, to, amt) {
            c.settle(poolManager, address(this), amt, true);
        } catch {
            owed[to][i] += amt;
            totalOwed[i] += amt;
            emit PayoutDeferred(to, i, amt);
        }
    }

    /// @dev Pay `to` everything owed of asset `i`. Unlike `_payOrDefer` this
    ///      does not catch a failed transfer: the claim stays until the token
    ///      moves again.
    function _executeClaimOwed(address to, uint8 i) internal returns (uint256 amt) {
        amt = owed[to][i];
        if (amt == 0) revert NothingOwed();
        owed[to][i] = 0;
        totalOwed[i] -= amt;
        emit OwedClaimed(to, i, amt);
        Currency c = _assets[i];
        c.take(poolManager, to, amt, false);
        c.settle(poolManager, address(this), amt, true);
    }
}
