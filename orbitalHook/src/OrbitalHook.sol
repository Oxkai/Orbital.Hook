// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {ERC6909} from "@uniswap/v4-core/src/ERC6909.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {FullMath} from "./libraries/FullMath.sol";
import {SphereMath} from "./libraries/SphereMath.sol";
import {TorusMath} from "./libraries/TorusMath.sol";
import {TickLib} from "./libraries/TickLib.sol";
import {PositionLib} from "./libraries/PositionLib.sol";
import {QuadraticSolver} from "./libraries/QuadraticSolver.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
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
///      TOKEN ASSUMPTIONS (enforced loosely / by convention, not fully on-chain):
///      registered assets MUST be standard ERC-20s (≤ 18 decimals) with no
///      fee-on-transfer and no rebasing. The hook assumes the PoolManager receives
///      exactly the requested amount; a fee-on-transfer or rebasing token would leave
///      claim tokens unbacked. Native ETH is unsupported (the constructor's
///      `decimals()` probe reverts for `address(0)`).
contract OrbitalHook is BaseHook, IUnlockCallback, ERC6909, Ownable2Step, Pausable {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;

    /// @notice Permit2 singleton, used by the optional permit2-based LP path.
    IAllowanceTransfer public immutable permit2;

    // ─────────────────────────────────────────────────────────────
    // Asset registry (immutable after construction)
    // ─────────────────────────────────────────────────────────────

    uint8 public constant MIN_ASSETS = 2;
    /// @notice Upper bound on assets per pool. Raised from 5 to 10; the cap is a
    ///         gas/safety guard (per-asset settlement and fee-accrual loops and
    ///         the segmenting solver scale with N) rather than a math limit.
    uint8 public constant MAX_ASSETS = 10;

    uint8 public immutable N;
    /// @notice Pool fee in hundredths of a bip (e.g. 100 = 1bp).
    uint24 public immutable fee;

    /// @notice Minimum pool fee, in hundredths of a bip (10 = 0.1bp = 10 ppm).
    /// @dev    The torus invariant is accepted within a 1 ppm tolerance, so each
    ///         swap can leave the pool off the manifold by up to ~1 ppm in either
    ///         direction. Requiring the fee to comfortably exceed that tolerance
    ///         means a swapper can never farm the rounding band for profit (the
    ///         fee on any round-trip dominates the worst-case drift). Blocks
    ///         zero/near-zero-fee pools at deploy.
    uint24 public constant MIN_FEE = 10;

    /// @dev Cached √N·WAD (= sqrt(N·WAD²)). N is immutable, so this geometric
    ///      constant is computed once at deploy instead of being re-derived via
    ///      an integer sqrt on every call — it is recomputed ~30×
    ///      per swap inside the Newton solver's `torusLHS`, plus in the crossing
    ///      and coefficient math. Threaded through `TorusState.sqrtN`.
    uint256 internal immutable sqrtN;

    Currency[] private _assets;
    mapping(Currency => uint8) private _assetIndexPlusOne;
    /// @dev Per-asset multiplier `10^(18-decimals)` to convert raw token units to
    ///      WAD. 1 for 18-decimal tokens; 1e12 for 6-decimal (USDC/USDT). Applied
    ///      only at the token-transfer boundaries — the engine stays in WAD.
    mapping(uint8 => uint256) private _scale;

    // ─────────────────────────────────────────────────────────────
    // Engine state (mirrors contracts/src/core/OrbitalPool.sol)
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
    mapping(uint8 => uint256) public feesAccrued; // WAD (scaled to raw on collect)
    mapping(uint8 => uint256) public feeGrowthGlobal; // WAD per unit interior rInt

    TickLib.Tick[] public ticks;
    /// @dev O(1) lookup of LIVE INTERIOR ticks by their `k` value, encoded as
    ///      `idx + 1` so 0 means absent. Boundary and dead ticks are kept out
    ///      of this map; they're filtered explicitly in the crossing scan.
    mapping(uint256 => uint256) private _interiorTickByK;
    /// @dev Stack of fully-burned tick array slots that are free to reuse.
    ///      Caps `ticks.length` growth across mint/burn cycles.
    uint256[] private _freeTickIndices;

    mapping(bytes32 => PositionLib.Position) public positions;
    mapping(bytes32 => mapping(uint8 => uint256)) public feeGrowthInsideLast;
    /// @dev Per-tick, per-asset range-fee accounting (Uniswap-v3 style). A tick
    ///      only earns fees while INTERIOR; `tickFeeGrowthInside` is the cumulative
    ///      growth frozen across boundary spells, and `tickFeeGrowthSnapshot` is
    ///      `feeGrowthGlobal` captured at the tick's last interior entry. Together
    ///      they ensure a boundary (depegged) tick accrues nothing, so the sum of
    ///      all positions' owed fees never exceeds `feesAccrued`.
    mapping(uint256 => mapping(uint8 => uint256)) private tickFeeGrowthInside;
    mapping(uint256 => mapping(uint8 => uint256)) private tickFeeGrowthSnapshot;
    mapping(bytes32 => mapping(uint8 => uint256)) public tokensOwed;

    // ─────────────────────────────────────────────────────────────
    // Errors and events
    // ─────────────────────────────────────────────────────────────

    error InvalidAssetCount(uint256 n);
    error AssetsNotSortedOrUnique();
    error AssetNotRegistered(Currency asset);
    error NativeLiquidityDisabled();
    error ZeroRWad();
    error KOutOfRange();
    error MintBlockedByBoundaryTicks();
    error SlippageExceeded(uint8 asset, uint256 requested, uint256 maxAllowed);
    error InvariantBroken();
    error InvalidAction();
    error NotEnoughLiquidity();
    error ExactOutputNotSupported();
    error ZeroSwapInput();
    error ZeroSwapOutput();
    error TooManyCrossings();
    error CrossingPartialExceedsRemaining();
    error CrossingPartialExceedsOutputReserve();
    error CrossingInputUnderflow();
    error NothingOwed();
    error FeeBucketShort();
    error SharesAreSoulbound();
    error AssetDecimalsTooHigh(Currency asset, uint8 decimals);
    error SwapAmountTooLarge(uint256 amountIn);
    error SwapAmountTooSmall(uint256 amountIn);
    error InteriorRadiusCapExceeded();
    error TooManyTicks();
    error FeeTooLow(uint24 fee);
    error BurnBlockedByBoundaryTicks();

    event Mint(address indexed recipient, uint256 indexed tickIdx, uint256 kWad, uint256 rWad, uint256[] amounts);
    event Burn(address indexed owner, uint256 indexed tickIdx, uint256 rWad, uint256[] amounts);
    event Collect(address indexed owner, uint256 indexed tickIdx, uint256[] fees);
    event Swap(address indexed sender, uint8 assetIn, uint8 assetOut, uint256 amountIn, uint256 amountOut);
    event TickCrossed(uint256 indexed tickIdx, bool nowInterior);

    // ─────────────────────────────────────────────────────────────
    // Unlock-callback action codes
    // ─────────────────────────────────────────────────────────────

    enum Action {
        MINT,
        BURN,
        COLLECT
    }

    struct MintData {
        address recipient;
        uint256 kWad;
        uint256 rWad;
        uint256[] maxAmounts;
        bool usePermit2;
    }

    struct BurnData {
        address owner;
        uint256 tickIdx;
        uint256 rWad;
        uint256[] minAmounts;
    }

    struct CollectData {
        address owner;
        uint256 tickIdx;
    }

    // ─────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        Currency[] memory assets_,
        uint24 fee_,
        address admin_
    ) BaseHook(_poolManager) Ownable(admin_) {
        permit2 = _permit2;

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
    // Guardian (automated depeg circuit-breaker)
    //
    // A `guardian` is an automation endpoint — in this deployment the
    // Reactive Network callback contract — allowed to pause the pool the
    // instant an external oracle reports a constituent stablecoin has
    // depegged, faster than any human keeper. It can ONLY pause (a
    // fail-safe action); resuming the pool stays owner-only so a human
    // reviews the situation before liquidity is re-enabled.
    // ─────────────────────────────────────────────────────────────

    /// @notice Trusted automation endpoint allowed to call {guardianPause}.
    address public guardian;

    event GuardianUpdated(address indexed previous, address indexed current);
    event GuardianPaused(address indexed caller);

    error NotGuardian();

    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Emergency pause triggered by the guardian (e.g. an on-chain
    ///         depeg signal relayed via Reactive Network). Idempotent-safe:
    ///         reverts only on authorization, not if already paused.
    function guardianPause() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        emit GuardianPaused(msg.sender);
        _pause();
    }

    // ─────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────

    function assets() external view returns (Currency[] memory) {
        return _assets;
    }

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

    function numTicks() external view returns (uint256) {
        return ticks.length;
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

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // v1: exactInput only.
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();
        if (slot0.rInt == 0) revert NotEnoughLiquidity();

        // `amountIn` is in the input token's RAW units (what the PoolManager
        // accounts and the trader pays). The engine works in WAD.
        uint256 amountInRaw = uint256(-params.amountSpecified);
        if (amountInRaw == 0) revert ZeroSwapInput();
        // Cap input at the BeforeSwapDelta int128 range so the cast at return
        // doesn't silently wrap and emit a negative-looking delta. Also bounds
        // the int256 intermediates inside the quartic solver well within range.
        if (amountInRaw > uint256(uint128(type(int128).max))) revert SwapAmountTooLarge(amountInRaw);

        (Currency cIn, Currency cOut) = params.zeroForOne
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);
        uint8 assetIn = indexOf(cIn);
        uint8 assetOut = indexOf(cOut);

        // Scale the raw input up to WAD for the engine and fee accounting.
        uint256 amountInWad = _toWad(assetIn, amountInRaw);
        uint256 feeAmount = FullMath.mulDiv(amountInWad, fee, 1_000_000);
        // A trade so small the fee floors to 0 would escape the MIN_FEE >
        // invariant-tolerance guarantee (the swap could nudge the pool inside the
        // 1 ppm band for free). Reject it — it's economically meaningless dust.
        if (feeAmount == 0) revert SwapAmountTooSmall(amountInRaw);
        uint256 amountInNet = amountInWad - feeAmount;
        _accumulateFee(assetIn, feeAmount);

        // Segmenting solver: handles within-tick and tick-crossing in one pass.
        uint256 amountOut;
        {
            SwapState memory state;
            state.torus = _buildTorusState();
            state.amountInRemaining = amountInNet;
            uint256[] memory res = _currentReserves();
            amountOut = _solveWithCrossings(state, res, assetIn, assetOut);
        }

        if (amountOut == 0) revert ZeroSwapOutput();

        // Commit final sumX/sumXSq + reserves[in/out] (all WAD).
        // sumX/sumXSq deltas telescope over partials so a single update with
        // (amountInNet, amountOut) and pre-trade xi/xj gives the correct totals.
        _updateReserves(assetIn, assetOut, amountInNet, amountOut);

        {
            (bool ok,) = TorusMath.checkInvariant(_buildTorusState());
            if (!ok) revert InvariantBroken();
        }

        // Scale the WAD output back down to the out token's raw units, rounding
        // down so the pool never owes more than it holds.
        uint256 amountOutRaw = _toRawDown(assetOut, amountOut);
        if (amountOutRaw == 0) revert ZeroSwapOutput();
        if (amountOutRaw > uint256(uint128(type(int128).max))) revert SwapAmountTooLarge(amountOutRaw);

        emit Swap(msg.sender, assetIn, assetOut, amountInRaw, amountOutRaw);

        cIn.take(poolManager, address(this), amountInRaw, true);
        cOut.settle(poolManager, address(this), amountOutRaw, true);

        return (
            this.beforeSwap.selector,
            toBeforeSwapDelta(int128(uint128(amountInRaw)), -int128(uint128(amountOutRaw))),
            0
        );
    }

    // ─────────────────────────────────────────────────────────────
    // Tick-crossing solver (ports of OrbitalPool.* swap internals)
    // ─────────────────────────────────────────────────────────────

    struct SwapState {
        TorusMath.TorusState torus;
        uint256 amountInRemaining;
    }

    struct XoverCoeffs {
        int256 bCoef;
        int256 cCoef;
        bool dPositive;
        uint256 D;
    }

    /// @dev Solve the full swap, segmenting on tick boundaries. Caps at
    ///      MAX_CROSSINGS partial segments per swap — a trade that would need
    ///      more reverts with `TooManyCrossings` so a router can chunk it.
    ///      The cap bounds worst-case gas; raising it doubles solver+detect cost.
    uint256 internal constant MAX_CROSSINGS = 20;

    /// @dev Hard cap on the live tick array length. `_detectCrossing` scans all
    ///      ticks linearly on every swap, so without a cap an attacker could mint
    ///      unboundedly many distinct-`k` ticks and make every swap's scan cost
    ///      grow without limit (a permanent griefing DoS). Capping the array
    ///      converts that UNBOUNDED cost into a bounded worst case.
    ///
    ///      NOTE: this is a bound, not the complete fix. The proper solution is
    ///      an ordered tick index (O(log n) next-tick lookup) so the scan is
    ///      O(crossings) instead of O(ticks) — tracked as a follow-up. The cap
    ///      has a mild residual tradeoff: once full, new *distinct-k* positions
    ///      revert until a tick is burned (merging into existing ticks, adding to
    ///      interior, burn and collect all keep working). 128 distinct
    ///      concentration points is generous for a stableswap.
    uint256 internal constant MAX_TICKS = 128;

    /// @dev Cap on the total interior radius (and therefore on reserve magnitude).
    ///      `SwapAmountTooLarge` bounds the swap *input*, but the tick-crossing
    ///      coefficients scale with RESERVE magnitude (e.g. `bCoef ≈ 2·xi`,
    ///      `cCoef ≈ sumXSq`), squared inside `QuadraticSolver`. Unbounded reserves
    ///      could push `bCoef²`/`8·cCoef·WAD` past int256 and revert the crossing
    ///      path (a partial DoS). Mints only run while `kBound == 0`, so `rInt` is
    ///      the whole pool radius then; capping it caps reserves for the pool's
    ///      lifetime (swaps and crossings conserve total radius). 1e34 WAD ≈ 1e16
    ///      18-decimal tokens — far above any real pool, with >1e6× int256 margin.
    uint256 internal constant MAX_RINT = 1e34;

    function _solveWithCrossings(SwapState memory state, uint256[] memory res, uint8 assetIn, uint8 assetOut)
        internal
        returns (uint256 totalOut)
    {
        for (uint256 iter = 0; iter < MAX_CROSSINGS; ++iter) {
            if (state.amountInRemaining == 0) break;

            uint256 alphaNormOld = _alphaNormOf(state.torus, state.torus.sumX);

            // solveSwap mutates torus.sumX/sumXSq. Save and restore around the call
            // so crossing-detection and coefficient math see the pre-swap state.
            uint256 savedSumX = state.torus.sumX;
            uint256 savedSumXSq = state.torus.sumXSq;

            uint256 candidateOut =
                TorusMath.solveSwap(state.torus, assetIn, assetOut, state.amountInRemaining, res);

            uint256 alphaNormNew = _alphaNormOf(state.torus, state.torus.sumX - candidateOut);

            state.torus.sumX = savedSumX;
            state.torus.sumXSq = savedSumXSq;

            (bool crossed, uint256 crossIdx) = _detectCrossing(alphaNormOld, alphaNormNew);

            if (!crossed) {
                totalOut += candidateOut;
                state.amountInRemaining = 0;
                break;
            }

            (uint256 partialIn, uint256 partialOut) =
                _tradeToXover(state, res, assetIn, assetOut, crossIdx);

            totalOut += partialOut;
            state.amountInRemaining -= partialIn;

            _applyPartial(state, res, assetIn, assetOut, partialIn, partialOut);
            _crossTick(crossIdx, state);

            if (iter == MAX_CROSSINGS - 1 && state.amountInRemaining > 0) revert TooManyCrossings();
        }
    }

    /// @dev Identify the first tick whose kNorm lies in (αNormOld, αNormNew] (rising)
    ///      or [αNormNew, αNormOld) (falling). Returns (false, 0) when no crossing.
    function _detectCrossing(uint256 alphaNormOld, uint256 alphaNormNew)
        internal
        view
        returns (bool crossed, uint256 crossTickIdx)
    {
        if (alphaNormNew == alphaNormOld) return (false, 0);
        uint256 len = ticks.length;

        if (alphaNormNew > alphaNormOld) {
            // Rising: scan interior ticks, pick smallest kNorm in [αNormOld, αNormNew).
            uint256 bestKNorm = type(uint256).max;
            for (uint256 i = 0; i < len; ++i) {
                TickLib.Tick storage t = ticks[i];
                if (!t.isInterior) continue;
                if (t.r == 0) continue; // dead tick from a full burn; skip
                uint256 kNorm = FullMath.mulDiv(t.k, WAD, t.r);
                if (kNorm >= alphaNormOld && kNorm < alphaNormNew && kNorm < bestKNorm) {
                    bestKNorm = kNorm;
                    crossTickIdx = i;
                    crossed = true;
                }
            }
        } else {
            // Falling: scan boundary ticks, pick largest kNorm in (αNormNew, αNormOld].
            uint256 bestKNorm = 0;
            for (uint256 i = 0; i < len; ++i) {
                TickLib.Tick storage t = ticks[i];
                if (t.isInterior) continue;
                if (t.r == 0) continue; // dead tick from a full burn; skip
                uint256 kNorm = FullMath.mulDiv(t.k, WAD, t.r);
                if (kNorm <= alphaNormOld && kNorm > alphaNormNew && kNorm > bestKNorm) {
                    bestKNorm = kNorm;
                    crossTickIdx = i;
                    crossed = true;
                }
            }
        }
    }

    /// @dev Compute (b, c) and the gap D for the partial-trade quadratic at the
    ///      boundary of `crossTickIdx`. See OrbitalPool._xoverCoeffs for the
    ///      derivation; coefficients are int256 in WAD¹ token-amount scale.
    function _xoverCoeffs(
        TorusMath.TorusState memory ts,
        uint256[] memory res,
        uint8 assetIn,
        uint8 assetOut,
        uint256 crossTickIdx
    ) internal view returns (XoverCoeffs memory q) {
        uint256 sqrtNc = ts.sqrtN; // cached √N·WAD (immutable `sqrtN` threaded via TorusState)

        uint256 kNormCross = FullMath.mulDiv(ticks[crossTickIdx].k, WAD, ticks[crossTickIdx].r);
        uint256 alphaIntTarget = FullMath.mulDiv(kNormCross, ts.rInt, WAD);
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

        uint256 xi = res[assetIn];
        uint256 xj = res[assetOut];
        uint256 twoXiD = FullMath.mulDiv(2 * xi, q.D, WAD);
        uint256 DSq = FullMath.mulDiv(q.D, q.D, WAD);

        if (q.dPositive) {
            uint256 xiPlusD = xi + q.D;
            q.bCoef = xiPlusD >= xj ? int256(2 * (xiPlusD - xj)) : -int256(2 * (xj - xiPlusD));

            uint256 cPos = ts.sumXSq + twoXiD + DSq;
            q.cCoef = cPos >= targetSumXSq ? int256(cPos - targetSumXSq) : -int256(targetSumXSq - cPos);
        } else {
            uint256 xiMinusD = xi >= q.D ? xi - q.D : 0;
            q.bCoef = xiMinusD >= xj ? int256(2 * (xiMinusD - xj)) : -int256(2 * (xj - xiMinusD));

            q.cCoef = int256(ts.sumXSq + DSq) - int256(twoXiD) - int256(targetSumXSq);
        }
    }

    /// @dev Compute the partial (in, out) that moves αNorm to the crossing tick.
    function _tradeToXover(
        SwapState memory state,
        uint256[] memory res,
        uint8 assetIn,
        uint8 assetOut,
        uint256 crossTickIdx
    ) internal view returns (uint256 partialIn, uint256 partialOut) {
        XoverCoeffs memory q = _xoverCoeffs(state.torus, res, assetIn, assetOut, crossTickIdx);

        partialOut = QuadraticSolver.solveSmallestNonNegativeRoot(q.bCoef, q.cCoef);
        if (q.dPositive) {
            partialIn = q.D + partialOut;
        } else {
            // !dPositive ⇒ D > 0 and partialIn = partialOut − D. If the solver
            // returns partialOut < D the segment would hand out `partialOut` for
            // ZERO input — a conservation violation. Revert instead of silently
            // clamping partialIn to 0 and relying on the 1 ppm invariant check to
            // (maybe) catch the off-manifold result.
            if (partialOut < q.D) revert CrossingInputUnderflow();
            partialIn = partialOut - q.D;
        }

        if (partialOut >= res[assetOut]) revert CrossingPartialExceedsOutputReserve();
        if (partialIn > state.amountInRemaining) revert CrossingPartialExceedsRemaining();
    }

    /// @dev Flip a tick interior↔boundary and update both `state.torus` and `slot0`.
    function _crossTick(uint256 tickIdx, SwapState memory state) internal {
        TickLib.Tick storage t = ticks[tickIdx];
        uint256 s = TorusMath.computeS(t.r, t.k, N);

        if (t.isInterior) {
            state.torus.rInt -= t.r;
            state.torus.kBound += t.k;
            state.torus.sBound += s;
            // Going interior → boundary: freeze fee accrual by banking the growth
            // earned since the last entry; the tick earns nothing while out.
            for (uint8 i = 0; i < N; ++i) {
                tickFeeGrowthInside[tickIdx][i] += feeGrowthGlobal[i] - tickFeeGrowthSnapshot[tickIdx][i];
            }
            // Drop the map entry so the next mint at this k creates a fresh
            // interior tick instead of merging.
            delete _interiorTickByK[t.k];
        } else {
            state.torus.rInt += t.r;
            state.torus.kBound -= t.k;
            state.torus.sBound -= s;
            // Boundary → interior recovery: resume accrual from the current global.
            for (uint8 i = 0; i < N; ++i) {
                tickFeeGrowthSnapshot[tickIdx][i] = feeGrowthGlobal[i];
            }
            // Re-register this tick as the live interior representative of its k.
            _interiorTickByK[t.k] = tickIdx + 1;
        }

        // Commit the updated torus aggregates — identical in both branches.
        slot0.rInt = state.torus.rInt;
        slot0.kBound = state.torus.kBound;
        slot0.sBound = state.torus.sBound;

        t.isInterior = !t.isInterior;

        (bool ok,) = TorusMath.checkInvariant(state.torus);
        if (!ok) revert InvariantBroken();

        emit TickCrossed(tickIdx, t.isInterior);
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
        state.torus.sumXSq = state.torus.sumXSq + FullMath.mulDiv(2 * xi, partialIn, WAD)
            + FullMath.mulDiv(partialIn, partialIn, WAD) - FullMath.mulDiv(2 * xj, partialOut, WAD)
            + FullMath.mulDiv(partialOut, partialOut, WAD);
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

        slot0.sumXSq = slot0.sumXSq + addIn - twoXjAmountOut + amountOutSq;

        reserves[assetIn] += amountIn;
        reserves[assetOut] -= amountOut;
    }

    // ─────────────────────────────────────────────────────────────
    // Public LP entry points (direct-to-hook)
    // ─────────────────────────────────────────────────────────────

    /// @notice Add liquidity at tick `kWad` with radius `rWad`. Pulls each asset
    ///         from the caller via direct ERC-20 approval (caller must approve
    ///         this hook to spend each asset).
    function addLiquidity(uint256 kWad, uint256 rWad, uint256[] calldata maxAmounts)
        external
        whenNotPaused
        returns (uint256 tickIdx, uint256[] memory amounts)
    {
        return _addLiquidity(kWad, rWad, maxAmounts, false);
    }

    /// @notice Same as `addLiquidity`, but pulls assets via Permit2 instead of
    ///         a direct ERC-20 allowance. Caller must have an active allowance
    ///         on permit2 for this hook to spend each asset.
    function addLiquidityViaPermit2(uint256 kWad, uint256 rWad, uint256[] calldata maxAmounts)
        external
        whenNotPaused
        returns (uint256 tickIdx, uint256[] memory amounts)
    {
        return _addLiquidity(kWad, rWad, maxAmounts, true);
    }

    function _addLiquidity(uint256 kWad, uint256 rWad, uint256[] calldata maxAmounts, bool usePermit2)
        internal
        returns (uint256 tickIdx, uint256[] memory amounts)
    {
        if (rWad == 0) revert ZeroRWad();
        if (maxAmounts.length != N) revert InvalidAssetCount(maxAmounts.length);

        bytes memory ret = poolManager.unlock(
            abi.encode(
                Action.MINT,
                abi.encode(
                    MintData({
                        recipient: msg.sender,
                        kWad: kWad,
                        rWad: rWad,
                        maxAmounts: maxAmounts,
                        usePermit2: usePermit2
                    })
                )
            )
        );
        (tickIdx, amounts) = abi.decode(ret, (uint256, uint256[]));
    }

    /// @notice Remove `rWad` of liquidity from tick `tickIdx`. Pays each asset
    ///         out to the caller, floored by `minAmounts[i]`.
    function removeLiquidity(uint256 tickIdx, uint256 rWad, uint256[] calldata minAmounts)
        external
        returns (uint256[] memory amounts)
    {
        if (rWad == 0) revert ZeroRWad();
        if (minAmounts.length != N) revert InvalidAssetCount(minAmounts.length);
        if (balanceOf[msg.sender][tickIdx] < rWad) revert NotEnoughLiquidity();

        bytes memory ret = poolManager.unlock(
            abi.encode(
                Action.BURN,
                abi.encode(BurnData({owner: msg.sender, tickIdx: tickIdx, rWad: rWad, minAmounts: minAmounts}))
            )
        );
        amounts = abi.decode(ret, (uint256[]));
    }

    /// @notice Claim accrued fees on `tickIdx` for the caller's position.
    function collect(uint256 tickIdx) external returns (uint256[] memory fees) {
        bytes memory ret = poolManager.unlock(
            abi.encode(Action.COLLECT, abi.encode(CollectData({owner: msg.sender, tickIdx: tickIdx})))
        );
        fees = abi.decode(ret, (uint256[]));
    }

    // ─────────────────────────────────────────────────────────────
    // Unlock callback dispatch
    // ─────────────────────────────────────────────────────────────

    function unlockCallback(bytes calldata raw) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory payload) = abi.decode(raw, (Action, bytes));

        if (action == Action.MINT) {
            MintData memory m = abi.decode(payload, (MintData));
            (uint256 tickIdx, uint256[] memory amounts) = _executeMint(m);
            return abi.encode(tickIdx, amounts);
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
        revert InvalidAction();
    }

    // ─────────────────────────────────────────────────────────────
    // Soulbound ERC-6909
    //
    // v1 keys position bookkeeping (fees, contributed r) by original minter.
    // Transferring the share without re-attaching that bookkeeping would
    // leave the new holder unable to burn or collect. Make the share
    // non-transferable until v2 introduces proper transferable positions.
    // ─────────────────────────────────────────────────────────────

    function transfer(address, uint256, uint256) public pure override returns (bool) {
        revert SharesAreSoulbound();
    }

    function transferFrom(address, address, uint256, uint256) public pure override returns (bool) {
        revert SharesAreSoulbound();
    }

    // ─────────────────────────────────────────────────────────────
    // MINT — port of OrbitalPool.mint
    // ─────────────────────────────────────────────────────────────

    function _executeMint(MintData memory m) internal returns (uint256 tickIdx, uint256[] memory amounts) {
        // Validate k ∈ [kMin, kMax].
        {
            uint256 km = TickLib.kMin(m.rWad, N);
            uint256 kM = TickLib.kMax(m.rWad, N);
            if (m.kWad < km || m.kWad > kM) revert KOutOfRange();
        }

        amounts = _computeDepositAmounts(m.rWad);

        // Slippage check.
        for (uint8 i = 0; i < N; ++i) {
            if (amounts[i] > m.maxAmounts[i]) revert SlippageExceeded(i, amounts[i], m.maxAmounts[i]);
        }

        // Tick merge-or-create.
        tickIdx = _findOrCreateTick(m.kWad, m.rWad);

        // Update reserves, sumX, sumXSq, rInt.
        _applyMintToTorus(amounts, m.rWad);

        // Bound total radius so the crossing-path solver coefficients stay within
        // int256 (see MAX_RINT). kBound == 0 here (mints are gated on it), so rInt
        // is the whole pool radius.
        if (slot0.rInt > MAX_RINT) revert InteriorRadiusCapExceeded();

        // Position bookkeeping.
        bytes32 pKey = PositionLib.positionKey(m.recipient, tickIdx);
        PositionLib.Position storage pos = positions[pKey];
        if (pos.r > 0) {
            _updatePositionFees(pKey, pos.r, tickIdx);
            pos.r += m.rWad;
        } else {
            pos.tickIndex = tickIdx;
            pos.r = m.rWad;
        }
        for (uint8 i = 0; i < N; ++i) {
            feeGrowthInsideLast[pKey][i] = _tickInsideGrowth(tickIdx, i);
        }

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
            if (m.usePermit2) {
                poolManager.sync(c);
                permit2.transferFrom(m.recipient, address(poolManager), uint160(amt), Currency.unwrap(c));
                poolManager.settle();
            } else {
                // CurrencySettler.settle uses SafeERC20 under the hood for the
                // direct-allowance path — supports non-bool-returning tokens.
                c.settle(poolManager, m.recipient, amt, false);
            }
            poolManager.mint(address(this), c.toId(), amt);
        }

        // Invariant guard.
        (bool ok,) = TorusMath.checkInvariant(_buildTorusState());
        if (!ok) revert InvariantBroken();

        // Mint LP shares (tokenId = tickIdx).
        _mint(m.recipient, tickIdx, m.rWad);

        emit Mint(m.recipient, tickIdx, m.kWad, m.rWad, amounts);
    }

    // ─────────────────────────────────────────────────────────────
    // Engine helpers (ports of contracts/src/core/OrbitalPool.sol)
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

    /// @notice Per-asset multiplier `10^(18-decimals)` (1 for 18-decimal tokens).
    function scaleOf(uint8 i) external view returns (uint256) {
        return _scale[i];
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

    function _computeDepositAmounts(uint256 rWad) internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](N);
        // Mints are not safe while any boundary tick is in play — the deposit
        // ratios needed to satisfy the torus invariant depend on kBound/sBound,
        // and neither the equalPricePoint nor the pro-rata branch accounts for
        // that. The pool must first have all ticks recovered (or burned) so
        // kBound == 0 before fresh liquidity can be added.
        if (slot0.kBound != 0) revert MintBlockedByBoundaryTicks();
        if (slot0.rInt == 0) {
            uint256 perAsset = SphereMath.equalPricePoint(rWad, N);
            for (uint8 i = 0; i < N; ++i) amounts[i] = perAsset;
        } else {
            for (uint8 i = 0; i < N; ++i) {
                amounts[i] = FullMath.mulDiv(reserves[i], rWad, slot0.rInt);
            }
        }
    }

    function _findOrCreateTick(uint256 kWad, uint256 rWad) internal returns (uint256 tickIdx) {
        // O(1) live-interior lookup. The map only ever holds live interior
        // ticks (see _crossTick and the burn full-zero path), so a hit is a
        // safe merge target — boundary and dead ticks are excluded by
        // construction (no "skip" loop needed).
        uint256 idxPlus1 = _interiorTickByK[kWad];
        if (idxPlus1 != 0) {
            tickIdx = idxPlus1 - 1;
            TickLib.Tick storage t = ticks[tickIdx];
            t.r += rWad;
            t.liquidityGross += rWad.toUint128();
            return tickIdx;
        }

        // Fresh interior tick. Reuse a dead slot if one's available so the
        // array doesn't grow unbounded across mint/burn cycles.
        uint256 freeLen = _freeTickIndices.length;
        if (freeLen > 0) {
            tickIdx = _freeTickIndices[freeLen - 1];
            _freeTickIndices.pop();
            ticks[tickIdx] = TickLib.Tick({
                k: kWad,
                r: rWad,
                isInterior: true,
                feeGrowthInside: 0,
                liquidityGross: rWad.toUint128()
            });
        } else {
            // Bound the crossing-scan: refuse to grow the array past MAX_TICKS.
            // Reuse of free slots above is exempt — it doesn't grow the scan.
            if (ticks.length >= MAX_TICKS) revert TooManyTicks();
            ticks.push(
                TickLib.Tick({k: kWad, r: rWad, isInterior: true, feeGrowthInside: 0, liquidityGross: rWad.toUint128()})
            );
            tickIdx = ticks.length - 1;
        }
        // Fresh (or recycled) interior tick: start its fee-growth snapshot at the
        // current global so it accrues only from now, and clear any recycled state.
        for (uint8 i = 0; i < N; ++i) {
            tickFeeGrowthSnapshot[tickIdx][i] = feeGrowthGlobal[i];
            tickFeeGrowthInside[tickIdx][i] = 0;
        }
        _interiorTickByK[kWad] = tickIdx + 1;
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

    function _accumulateFee(uint8 assetIn, uint256 feeAmount) internal {
        if (feeAmount == 0) return;
        feesAccrued[assetIn] += feeAmount;
        uint256 rInt = slot0.rInt;
        if (rInt == 0) return;
        feeGrowthGlobal[assetIn] += FullMath.mulDiv(feeAmount, WAD, rInt);
    }

    /// @dev Cumulative fee growth credited to `tickIdx` for asset `i`, counting
    ///      only the time the tick has been INTERIOR. For an interior tick this is
    ///      the frozen total plus the live growth since its last entry; for a
    ///      boundary tick it's just the frozen total (it earns nothing while out).
    ///      `feeGrowthGlobal` only increases and the snapshot is set to it on
    ///      entry, so the subtraction never underflows.
    function _tickInsideGrowth(uint256 tickIdx, uint8 i) internal view returns (uint256) {
        uint256 g = tickFeeGrowthInside[tickIdx][i];
        if (ticks[tickIdx].isInterior) {
            g += feeGrowthGlobal[i] - tickFeeGrowthSnapshot[tickIdx][i];
        }
        return g;
    }

    function _updatePositionFees(bytes32 pKey, uint256 posR, uint256 tickIdx) internal {
        for (uint8 i = 0; i < N; ++i) {
            uint256 inside = _tickInsideGrowth(tickIdx, i);
            uint256 last = feeGrowthInsideLast[pKey][i];
            if (inside != last) {
                if (posR > 0) {
                    tokensOwed[pKey][i] += FullMath.mulDiv(posR, inside - last, WAD);
                }
                feeGrowthInsideLast[pKey][i] = inside;
            }
        }
    }

    function _computeWithdrawAmounts(uint256 rWad) internal view returns (uint256[] memory amounts) {
        uint256 rInt = slot0.rInt;
        if (rInt == 0) revert NotEnoughLiquidity();
        amounts = new uint256[](N);
        for (uint8 i = 0; i < N; ++i) {
            amounts[i] = FullMath.mulDiv(reserves[i], rWad, rInt);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // BURN — port of OrbitalPool.burn
    // ─────────────────────────────────────────────────────────────

    function _executeBurn(BurnData memory b) internal returns (uint256[] memory amounts) {
        bytes32 pKey = PositionLib.positionKey(b.owner, b.tickIdx);
        PositionLib.Position storage pos = positions[pKey];
        if (pos.r < b.rWad) revert NotEnoughLiquidity();

        // Withdrawals are only valid while the pool is fully interior (kBound == 0),
        // mirroring the mint guard (`MintBlockedByBoundaryTicks`). The payout is
        // pro-rata of the TOTAL reserve vector by `rWad / rInt`, which is only exact
        // when every tick is interior: `reserves[]` is the whole pool, while `rInt`
        // excludes any boundary tick's radius. With a boundary tick present, the
        // pro-rata mis-accounts — and burning the last interior tick would pay out
        // 100% of reserves (including the parked boundary tokens) while the
        // `rInt > 0` invariant check is skipped, silently stranding the boundary
        // LP. Gating on kBound makes the accounting provably exact in every reachable
        // burn. A position becomes withdrawable again once its coin re-pegs and the
        // tick recovers to interior. Correct exit *during* a depeg (per-tick reserve
        // attribution) is deferred to v2.
        if (slot0.kBound != 0) revert BurnBlockedByBoundaryTicks();

        // Settle fees against the OLD position size before modifying it.
        _updatePositionFees(pKey, pos.r, b.tickIdx);

        // kBound == 0 above guarantees every live tick is interior.
        TickLib.Tick storage t = ticks[b.tickIdx];
        amounts = _computeWithdrawAmounts(b.rWad);

        // Slippage check.
        for (uint8 i = 0; i < N; ++i) {
            if (amounts[i] < b.minAmounts[i]) revert SlippageExceeded(i, amounts[i], b.minAmounts[i]);
        }

        // Tick is interior (guaranteed by the kBound == 0 gate above), so the
        // burn simply shrinks the interior radius.
        slot0.rInt -= b.rWad;

        // Update sumX, sumXSq, reserves.
        {
            uint256 totalRemoved;
            uint256 totalSqRemoved;
            for (uint8 i = 0; i < N; ++i) {
                uint256 xOld = reserves[i];
                uint256 amt = amounts[i];
                totalRemoved += amt;
                // Δ(x²) = 2·x·amt − amt²
                totalSqRemoved += FullMath.mulDiv(2 * xOld, amt, WAD) - FullMath.mulDiv(amt, amt, WAD);
                reserves[i] = xOld - amt;
            }
            slot0.sumX -= totalRemoved;
            // Saturating to absorb ≤ N wei of mulDiv rounding dust against mint.
            slot0.sumXSq = slot0.sumXSq > totalSqRemoved ? slot0.sumXSq - totalSqRemoved : 0;
        }

        t.r -= b.rWad;
        t.liquidityGross -= b.rWad.toUint128();
        pos.r -= b.rWad;

        if (pos.r == 0) {
            // Any pending fees must be collected separately; we wipe the position.
            delete positions[pKey];
        }

        // If the tick is now fully drained, retire its slot: unmap its k (the
        // tick is interior per the gate) and recycle the array slot via the
        // free-list.
        if (t.r == 0) {
            delete _interiorTickByK[t.k];
            _freeTickIndices.push(b.tickIdx);
        }

        // Burn the LP's ERC-6909 share.
        _burn(b.owner, b.tickIdx, b.rWad);

        // Engine state is now final — validate the invariant and emit BEFORE any
        // token movement (checks-effects-interactions). The payout loop below only
        // transfers tokens; it does not touch reserves/slot0.
        if (slot0.rInt > 0) {
            (bool ok,) = TorusMath.checkInvariant(_buildTorusState());
            if (!ok) revert InvariantBroken();
        }
        emit Burn(b.owner, b.tickIdx, b.rWad, amounts);

        // Interactions: pay owner each asset as raw ERC-20; hook covers the debt by
        // burning claim tokens. WAD -> raw rounds DOWN so the pool never pays out
        // more than it holds.
        for (uint8 i = 0; i < N; ++i) {
            uint256 amtWad = amounts[i];
            if (amtWad == 0) continue;
            uint256 amt = _toRawDown(i, amtWad);
            if (amt == 0) continue;
            Currency c = _assets[i];
            c.take(poolManager, b.owner, amt, false);
            c.settle(poolManager, address(this), amt, true);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // COLLECT — port of OrbitalPool.collect
    // ─────────────────────────────────────────────────────────────

    function _executeCollect(CollectData memory cdata) internal returns (uint256[] memory fees) {
        bytes32 pKey = PositionLib.positionKey(cdata.owner, cdata.tickIdx);
        PositionLib.Position storage pos = positions[pKey];

        _updatePositionFees(pKey, pos.r, cdata.tickIdx);

        fees = new uint256[](N);
        uint256[] memory payRaw = new uint256[](N);
        bool any;

        // Effects: settle all fee accounting first (checks-effects-interactions),
        // recording the raw amount to pay per asset.
        for (uint8 i = 0; i < N; ++i) {
            uint256 owed = tokensOwed[pKey][i];
            if (owed == 0) continue;
            if (feesAccrued[i] < owed) revert FeeBucketShort();

            // WAD -> raw, rounding down (pool's favour). Any sub-raw-unit
            // remainder stays in tokensOwed so it is paid once it grows past one
            // raw unit, rather than being silently wiped.
            uint256 owedRaw = _toRawDown(i, owed);
            if (owedRaw == 0) continue;
            uint256 paidWad = owedRaw * _scale[i];

            tokensOwed[pKey][i] = owed - paidWad;
            feesAccrued[i] -= paidWad;
            fees[i] = paidWad;
            payRaw[i] = owedRaw;
            any = true;
        }

        if (!any) revert NothingOwed();
        emit Collect(cdata.owner, cdata.tickIdx, fees);

        // Interactions: pay out only after all state is settled.
        for (uint8 i = 0; i < N; ++i) {
            uint256 owedRaw = payRaw[i];
            if (owedRaw == 0) continue;
            Currency c = _assets[i];
            c.take(poolManager, cdata.owner, owedRaw, false);
            c.settle(poolManager, address(this), owedRaw, true);
        }
    }
}
