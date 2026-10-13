// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";
import {BandLib} from "../src/libraries/BandLib.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {SphereMath} from "../src/libraries/SphereMath.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @dev Mock token mimicking USDT's transferFrom: NO bool return value.
///      The raw `transferFrom` call would fail to ABI-decode; SafeERC20 handles it.
contract MockUSDTLike {
    string public name = "USDT-Like";
    string public symbol = "USDT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external {
        allowance[msg.sender][spender] = amt;
    }

    function transfer(address to, uint256 amt) external {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
    }

    function transferFrom(address from, address to, uint256 amt) external {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @dev Mock token with 6 decimals — used to verify decimal scaling (now supported).
contract MockSixDecimal {
    uint8 public constant decimals = 6;

    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}

/// @dev Mock token with 20 decimals — > 18 is rejected at construction.
contract MockTwentyDecimal {
    uint8 public constant decimals = 20;

    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}

contract OrbitalHookTest is BaseTest {
    OrbitalHook hook;

    Currency c0;
    Currency c1;
    Currency c2;
    Currency cUnregistered;

    // Bands on the hook's menu (`BandLib`), by index. Ids of ticks and shares
    // are the band index, whatever order positions are opened in.
    uint256 constant TIGHT = 0; // 0.9999, the narrowest band
    uint256 constant MID = 19; // 0.95
    uint256 constant FULL = 30; // full range

    /// @dev The plane constant the hook books for `rWad` in `band`.
    function _kOf(uint256 band, uint256 rWad) internal view returns (uint256) {
        return FullMath.mulDiv(hook.bandKNorm(band), rWad, 1e18);
    }

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    function setUp() public {
        deployArtifactsAndLabel();

        // Mint 3 registered tokens + 1 unregistered token, sort the registered ones.
        Currency[] memory raw = new Currency[](4);
        raw[0] = Currency.wrap(address(deployToken()));
        raw[1] = Currency.wrap(address(deployToken()));
        raw[2] = Currency.wrap(address(deployToken()));
        raw[3] = Currency.wrap(address(deployToken()));

        // Use the first 3 as registered, sorted ascending.
        Currency[] memory regd = _sortedThree(raw[0], raw[1], raw[2]);
        c0 = regd[0];
        c1 = regd[1];
        c2 = regd[2];
        cUnregistered = raw[3];

        // Deploy hook at flagged address.
        address flagged = address(HOOK_FLAGS ^ (0x4444 << 144));
        deployCodeTo("OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, regd, uint24(100), address(this)), flagged);
        hook = OrbitalHook(flagged);

        // Approve the hook to spend each registered asset (it transferFroms LP -> PoolManager).
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c2)).approve(address(hook), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────
    // Constructor: success
    // ─────────────────────────────────────────────────────────────

    function test_constructor_storesN() public view {
        assertEq(hook.N(), 3);
    }

    function test_constructor_storesAssetsInOrder() public view {
        assertEq(hook.N(), 3);
        assertEq(Currency.unwrap(hook.assetAt(0)), Currency.unwrap(c0));
        assertEq(Currency.unwrap(hook.assetAt(1)), Currency.unwrap(c1));
        assertEq(Currency.unwrap(hook.assetAt(2)), Currency.unwrap(c2));
    }

    function test_constructor_indexOf() public view {
        assertEq(hook.indexOf(c0), 0);
        assertEq(hook.indexOf(c1), 1);
        assertEq(hook.indexOf(c2), 2);
    }

    function test_constructor_isRegistered() public view {
        assertTrue(hook.isRegistered(c0));
        assertTrue(hook.isRegistered(c1));
        assertTrue(hook.isRegistered(c2));
        assertFalse(hook.isRegistered(cUnregistered));
    }

    function test_indexOf_reverts_on_unregistered() public {
        vm.expectRevert(abi.encodeWithSelector(OrbitalHook.AssetNotRegistered.selector, cUnregistered));
        hook.indexOf(cUnregistered);
    }

    // ─────────────────────────────────────────────────────────────
    // Constructor: failure cases
    // ─────────────────────────────────────────────────────────────

    function test_constructor_revertsOn_tooFewAssets() public {
        Currency[] memory one = new Currency[](1);
        one[0] = c0;
        vm.expectRevert(abi.encodeWithSelector(OrbitalHook.InvalidAssetCount.selector, 1));
        // We rely on deployCodeTo to surface the revert from the constructor.
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, one, uint24(100), address(this)), address(HOOK_FLAGS ^ (0x4445 << 144))
        );
    }

    function test_constructor_revertsOn_tooManyAssets() public {
        // MAX_ASSETS = 10, so 11 must revert (count is checked before the
        // per-asset decimals() probe, so synthetic addresses are fine here).
        Currency[] memory eleven = new Currency[](11);
        for (uint160 i = 0; i < 11; ++i) {
            eleven[i] = Currency.wrap(address(uint160(0x1000 + i)));
        }
        vm.expectRevert(abi.encodeWithSelector(OrbitalHook.InvalidAssetCount.selector, 11));
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, eleven, uint24(100), address(this)), address(HOOK_FLAGS ^ (0x4446 << 144))
        );
    }

    function test_constructor_revertsOn_duplicate() public {
        Currency[] memory dup = new Currency[](3);
        dup[0] = c0;
        dup[1] = c1;
        dup[2] = c1; // duplicate
        vm.expectRevert(OrbitalHook.AssetsNotSortedOrUnique.selector);
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, dup, uint24(100), address(this)), address(HOOK_FLAGS ^ (0x4447 << 144))
        );
    }

    function test_constructor_revertsOn_unsorted() public {
        Currency[] memory bad = new Currency[](3);
        bad[0] = c1;
        bad[1] = c0; // out of order
        bad[2] = c2;
        vm.expectRevert(OrbitalHook.AssetsNotSortedOrUnique.selector);
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, bad, uint24(100), address(this)), address(HOOK_FLAGS ^ (0x4448 << 144))
        );
    }

    // ─────────────────────────────────────────────────────────────
    // Pool initialization through v4
    // ─────────────────────────────────────────────────────────────

    function test_beforeInitialize_accepts_registered_pair() public {
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_rejects_unregistered_currency() public {
        // Sort (cUnregistered, c0) to satisfy PoolKey ordering invariant.
        (Currency a, Currency b) = Currency.unwrap(cUnregistered) < Currency.unwrap(c0)
            ? (cUnregistered, c0)
            : (c0, cUnregistered);
        PoolKey memory key =
            PoolKey({currency0: a, currency1: b, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});

        // v4 wraps hook reverts; assert it bubbles a Wrap of AssetNotRegistered.
        vm.expectRevert();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    // ─────────────────────────────────────────────────────────────
    // Native v4 liquidity is disabled
    // ─────────────────────────────────────────────────────────────

    function test_beforeAddLiquidity_reverts() public {
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});

        // Pretend to be the PoolManager so onlyPoolManager passes; the implementation must still revert.
        vm.prank(address(poolManager));
        vm.expectRevert(OrbitalHook.NativeLiquidityDisabled.selector);
        hook.beforeAddLiquidity(address(this), key, params, "");
    }

    function test_beforeRemoveLiquidity_reverts() public {
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1e18, salt: bytes32(0)});

        vm.prank(address(poolManager));
        vm.expectRevert(OrbitalHook.NativeLiquidityDisabled.selector);
        hook.beforeRemoveLiquidity(address(this), key, params, "");
    }

    // ─────────────────────────────────────────────────────────────
    // addLiquidity (empty-pool mint)
    // ─────────────────────────────────────────────────────────────

    /// @dev A tick's per-asset virtual reserve, exactly as the hook books it:
    ///      xMin less a 1e-9 haircut.
    function _virtualOf(uint256 rWad, uint256 kWad) internal pure returns (uint256) {
        uint256 xMin = TickLib.xMin(rWad, 3, kWad);
        return xMin - xMin / 1e9;
    }

    function test_addLiquidity_emptyPool_mintsExpectedShares() public {
        uint256 rWad = 100 ether;
        uint256 kWad = _kOf(MID, rWad);
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // The engine books the full equal-price reserve; the LP deposits only
        // the part above the tick's virtual floor.
        uint256 expectedPerAsset = SphereMath.equalPricePoint(rWad, 3);
        uint256 virt = _virtualOf(rWad, kWad);
        uint256 realPerAsset = expectedPerAsset - virt;

        (uint256 tickIdx, uint256[] memory amounts) = hook.addLiquidity(MID, rWad, maxA, block.timestamp);

        assertEq(tickIdx, MID, "tick id is the band");
        assertEq(amounts.length, 3);
        assertEq(amounts[0], realPerAsset, "asset0 amount");
        assertEq(amounts[1], realPerAsset, "asset1 amount");
        assertEq(amounts[2], realPerAsset, "asset2 amount");
        assertEq(hook.tickVirtual(tickIdx), virt, "tick virtual");
        assertEq(hook.virtualReserve(), virt, "pool virtual");

        // ERC-6909 share (tokenId = tickIdx).
        assertEq(hook.balanceOf(address(this), tickIdx), rWad, "6909 balance");

        // slot0
        (uint256 sumX,, uint256 rInt, uint256 kBound,) = hook.slot0();
        assertEq(sumX, expectedPerAsset * 3, "sumX");
        assertEq(rInt, rWad, "rInt");
        assertEq(kBound, 0, "kBound");

        // reserves
        assertEq(hook.reserves(0), expectedPerAsset);
        assertEq(hook.reserves(1), expectedPerAsset);
        assertEq(hook.reserves(2), expectedPerAsset);

        // The band's tick carries exactly this radius and the band's plane.
        (uint256 tk, uint256 tr, bool tInt) = hook.ticks(MID);
        assertEq(tr, rWad, "tick radius");
        assertEq(tk, kWad, "tick plane is the band's kNorm times r");
        assertTrue(tInt, "new tick is interior");
    }

    function test_addLiquidity_movesTokensIntoPoolManager() public {
        uint256 rWad = 50 ether;
        uint256 kWad = _kOf(MID, rWad);
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        uint256 expectedPerAsset = SphereMath.equalPricePoint(rWad, 3) - _virtualOf(rWad, kWad);

        uint256 balBeforeLP = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 balBeforePM = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));

        hook.addLiquidity(MID, rWad, maxA, block.timestamp);

        assertEq(
            MockERC20(Currency.unwrap(c0)).balanceOf(address(this)),
            balBeforeLP - expectedPerAsset,
            "LP balance debited"
        );
        assertEq(
            MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager)),
            balBeforePM + expectedPerAsset,
            "PoolManager credited"
        );

        // Hook holds matching ERC-6909 claim tokens against PoolManager.
        assertEq(
            poolManager.balanceOf(address(hook), c0.toId()),
            expectedPerAsset,
            "claim tokens minted to hook"
        );
    }

    function test_addLiquidity_reverts_on_zero_rWad() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        vm.expectRevert(OrbitalHook.ZeroRWad.selector);
        hook.addLiquidity(MID, 0, maxA, block.timestamp);
    }

    function test_addLiquidity_reverts_on_unknown_band() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        uint256 band = hook.numTicks();
        vm.expectRevert(abi.encodeWithSelector(OrbitalHook.InvalidBand.selector, band));
        hook.addLiquidity(band, 10 ether, maxA, block.timestamp);
    }

    function test_addLiquidity_reverts_after_deadline() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        vm.expectRevert(OrbitalHook.DeadlinePassed.selector);
        hook.addLiquidity(MID, 10 ether, maxA, block.timestamp - 1);
    }

    function test_addLiquidity_reverts_on_slippage() public {
        uint256 rWad = 10 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = 1; // far too tight
        vm.expectRevert(); // SlippageExceeded — args vary
        hook.addLiquidity(MID, rWad, maxA, block.timestamp);
    }

    /// @notice A second mint in the same band joins the band's tick: same id,
    ///         the radii add, and at a balanced pool it pays what the first did.
    function test_addLiquidity_secondMint_same_band_merges() public {
        uint256 rWad = 100 ether;
        uint256 kWad = _kOf(MID, rWad);
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        hook.addLiquidity(MID, rWad, maxA, block.timestamp);
        uint256 perAsset1 = SphereMath.equalPricePoint(rWad, 3) - _virtualOf(rWad, kWad);

        (uint256 tickIdx2, uint256[] memory amounts2) = hook.addLiquidity(MID, rWad, maxA, block.timestamp);

        assertEq(tickIdx2, MID, "same band, same tick");
        assertEq(amounts2[0], perAsset1);
        assertEq(amounts2[1], perAsset1);
        assertEq(amounts2[2], perAsset1);

        assertEq(hook.balanceOf(address(this), MID), 2 * rWad, "shares accumulate on the band");
        (, uint256 tr,) = hook.ticks(MID);
        assertEq(tr, 2 * rWad, "one tick, both radii");
        (, , uint256 rInt, ,) = hook.slot0();
        assertEq(rInt, rWad * 2);
    }

    /// @notice Merging can never move a band's boundary.
    ///
    ///         `kNorm = k/r` is what detection compares against αNorm, so it IS
    ///         the LP's depeg bound. An earlier merge added r without k and
    ///         halved kNorm (observed live: a tick left below parity, unable to
    ///         ever cross). Here k is derived from the band's fixed kNorm on
    ///         every change of r, so any number of mints — of any sizes — leave
    ///         the tick exactly on its band.
    function test_band_merges_keep_the_band_boundary() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        hook.addLiquidity(MID, 100 ether, maxA, block.timestamp);
        hook.addLiquidity(MID, 37 ether, maxA, block.timestamp);
        hook.addLiquidity(MID, 1_234 ether, maxA, block.timestamp);

        (uint256 k, uint256 r,) = hook.ticks(MID);
        assertEq(r, 1_371 ether);
        assertEq(k, _kOf(MID, r), "k is the band's kNorm times the total radius");
    }

    /// @notice Tick slots cannot be exhausted.
    ///
    ///         With a tick per position and a cap on ticks, filling every slot
    ///         with dust (measured at ~2.5e-7 tokens) locked every later LP out.
    ///         Positions now share their band's tick, so there are exactly as
    ///         many ticks as bands: dust in every band still leaves any honest
    ///         mint free to join one.
    function test_dust_in_every_band_cannot_block_new_lps() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // A real pool first, then the attacker's dust in every single band.
        hook.addLiquidity(FULL, 1_000_000 ether, maxA, block.timestamp);
        address attacker = address(0xA77AC);
        for (uint256 i = 0; i < 3; ++i) {
            Currency c = i == 0 ? c0 : i == 1 ? c1 : c2;
            MockERC20(Currency.unwrap(c)).mint(attacker, 1_000 ether);
            vm.prank(attacker);
            MockERC20(Currency.unwrap(c)).approve(address(hook), type(uint256).max);
        }
        vm.startPrank(attacker);
        for (uint256 b = 0; b < hook.numTicks(); ++b) {
            hook.addLiquidity(b, 1e9, maxA, block.timestamp);
        }
        vm.stopPrank();

        // Every band's tick is taken, and an honest LP still gets in — into
        // any band, sharing the attacker's tick there.
        for (uint256 b = 0; b < hook.numTicks(); b += 5) {
            (uint256 tickIdx,) = hook.addLiquidity(b, 500 ether, maxA, block.timestamp);
            assertEq(tickIdx, b);
            assertEq(hook.balanceOf(address(this), b), b == FULL ? 1_000_000 ether + 500 ether : 500 ether);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // beforeSwap (Phase B: within-tick only)
    // ─────────────────────────────────────────────────────────────

    /// @dev One full-range tick: deep enough that the swap tests below never
    ///      reach a boundary, which is what they are not testing.
    function _seedSinglePoolWithLiquidity(uint256 rWad) internal returns (PoolKey memory key) {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(FULL, rWad, maxA, block.timestamp);

        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    function test_swap_zeroForOne_returnsOrbitalOutput() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);

        uint256 amountIn = 1 ether;
        uint256 balC0Before = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 balC1Before = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));

        swapRouter.swapExactTokensForTokens(
            amountIn,
            0,
            true, // zeroForOne
            key,
            "",
            address(this),
            block.timestamp
        );

        uint256 balC0After = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 balC1After = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));

        assertEq(balC0Before - balC0After, amountIn, "input paid");
        assertGt(balC1After, balC1Before, "output received");

        // For a small swap on a balanced stableswap pool, output is close to input
        // minus the swap fee and a small amount of curve slippage. Exact magnitude
        // depends on tick concentration (we use the midpoint of [kMin, kMax]).
        uint256 received = balC1After - balC1Before;
        assertGt(received, amountIn * 99 / 100, "rate within 1pct (stableswap)");
        assertLt(received, amountIn, "lt input due to fee");
    }

    function test_swap_oneForZero_reverseDirection() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);

        uint256 amountIn = 1 ether;
        uint256 balC0Before = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 balC1Before = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));

        swapRouter.swapExactTokensForTokens(
            amountIn,
            0,
            false, // oneForZero
            key,
            "",
            address(this),
            block.timestamp
        );

        uint256 balC0After = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 balC1After = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));

        assertGt(balC0After, balC0Before, "c0 received");
        assertEq(balC1Before - balC1After, amountIn, "c1 paid");
    }

    function test_swap_accumulates_fee() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);

        uint256 amountIn = 100 ether;
        uint256 expectedFee = amountIn * 100 / 1_000_000; // fee=100 hundredths-of-bip

        swapRouter.swapExactTokensForTokens(
            amountIn, 0, true, key, "", address(this), block.timestamp
        );

        assertEq(hook.feesAccrued(0), expectedFee, "fee bucket on assetIn");
        // feeGrowthGlobal[in] += feeAmount * WAD / rInt
        // rInt = 1000 ether → expected growth = expectedFee * 1e18 / 1000e18 = expectedFee / 1000.
        assertApproxEqAbs(hook.feeGrowthGlobal(0), expectedFee * 1e18 / 1_000 ether, 1, "fee growth global");
    }

    // ─────────────────────────────────────────────────────────────
    // Exact output
    //
    // v4 lets a trade fix either side: `amountSpecified < 0` fixes what the
    // trader pays, `> 0` what they receive. The engine serves both, so routers
    // and quoters that work by output — the usual way a UI quotes "I want 100
    // USDC" — can use the pool.
    // ─────────────────────────────────────────────────────────────

    function test_exactOutput_delivers_exactly_what_was_asked() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);

        uint256 want = 10 ether;
        uint256 inBefore = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 outBefore = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));

        swapRouter.swapTokensForExactTokens(
            want, type(uint256).max, true, key, "", address(this), block.timestamp
        );

        uint256 got = MockERC20(Currency.unwrap(c1)).balanceOf(address(this)) - outBefore;
        uint256 paid = inBefore - MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        assertEq(got, want, "trader must receive exactly the amount specified");
        // Same-peg assets, so the input is the output plus the fee and the
        // curve's slippage — here 10 of a ~420 reserve, a deliberately shallow
        // test pool, so a couple of percent. `_agrees_with_exactInput` is what
        // pins the price; this only pins that it is a price at all.
        assertGe(paid, want, "exact output must cost at least its face value");
        assertLe(paid, want * 105 / 100, "exact output cost is near parity");
    }

    /// @notice The two halves of the engine must agree: buying Y by naming Y
    ///         costs what naming the input that yields Y costs. A gap either way
    ///         would be free value for whoever picks the cheaper side.
    function test_exactOutput_agrees_with_exactInput() public {
        uint256 amountIn = 10 ether;

        uint256 snap = vm.snapshotState();
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);
        uint256 outBefore = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(amountIn, 0, true, key, "", address(this), block.timestamp);
        uint256 outFromExactIn = MockERC20(Currency.unwrap(c1)).balanceOf(address(this)) - outBefore;
        vm.revertToState(snap);

        key = _seedSinglePoolWithLiquidity(1_000 ether);
        uint256 inBefore = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        swapRouter.swapTokensForExactTokens(
            outFromExactIn, type(uint256).max, true, key, "", address(this), block.timestamp
        );
        uint256 paid = inBefore - MockERC20(Currency.unwrap(c0)).balanceOf(address(this));

        // Both legs round the pool's way, so the exact-output price may be a
        // hair dearer, never cheaper, and only by rounding.
        assertGe(paid, amountIn, "buying the same output must not be cheaper");
        assertApproxEqRel(paid, amountIn, 1e12, "the two sides must quote one price");
    }

    function test_exactOutput_charges_the_fee() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);

        uint256 want = 100 ether;
        uint256 inBefore = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        swapRouter.swapTokensForExactTokens(
            want, type(uint256).max, true, key, "", address(this), block.timestamp
        );
        uint256 paid = inBefore - MockERC20(Currency.unwrap(c0)).balanceOf(address(this));

        // fee=100 (1bp) is charged on the input, so it is `paid * 100 / 1e6`.
        assertApproxEqAbs(hook.feesAccrued(0), paid * 100 / 1_000_000, 2, "fee on the input");
        assertEq(hook.feesAccrued(1), 0, "no fee on the output asset");
    }

    /// @notice An exact-output trade must walk band crossings like any other:
    ///         the tight band pins, and the trader still receives exactly what
    ///         they asked for.
    function test_exactOutput_crosses_a_tick() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(TIGHT, 1_000 ether, maxA, block.timestamp);
        hook.addLiquidity(FULL, 500 ether, maxA, block.timestamp);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        assertTrue(_isInterior(TIGHT), "tight band starts interior");

        // The 0.9999 band pins on the slightest move, so a small buy crosses
        // it; asking for more than the backstop alone can then sell would be
        // refused instead (`_rejects_more_than_the_pool_can_sell`).
        uint256 want = hook.reserves(1) * 2 / 100;
        uint256 outBefore = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));
        swapRouter.swapTokensForExactTokens(
            want, type(uint256).max, true, key, "", address(this), block.timestamp
        );

        assertEq(
            MockERC20(Currency.unwrap(c1)).balanceOf(address(this)) - outBefore, want, "exact output across a crossing"
        );
        assertFalse(_isInterior(TIGHT), "tight band crossed to its boundary");
        assertTrue(_isInterior(FULL), "backstop still interior");
    }

    /// @notice More output than the pool can sell is refused by name, not
    ///         filled at an invented price.
    function test_exactOutput_rejects_more_than_the_pool_can_sell() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(100 ether);

        try swapRouter.swapTokensForExactTokens(
            hook.reserves(1) * 2, type(uint256).max, true, key, "", address(this), block.timestamp
        ) returns (BalanceDelta) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(
                _revertContains(reason, OrbitalHook.SwapExceedsLiquidity.selector)
                    || _revertContains(reason, OrbitalHook.SwapBeyondZeroPrice.selector),
                "must be refused as beyond the pool's liquidity"
            );
        }
    }

    function test_exactOutput_reverts_on_zero() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);
        vm.expectRevert();
        swapRouter.swapTokensForExactTokens(0, type(uint256).max, true, key, "", address(this), block.timestamp);
    }

    // M3 regression: amountIn beyond int128 max would silently wrap when cast
    // for BeforeSwapDelta. The hook must reject such swaps explicitly.
    function test_swap_reverts_when_amount_exceeds_int128_max() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);

        uint256 oversized = uint256(uint128(type(int128).max)) + 1;
        // Fund the caller and the router with enough tokens to even attempt it,
        // then expect the hook's domain error to bubble up through the router.
        deal(Currency.unwrap(c0), address(this), oversized);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), oversized);

        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(
            oversized, 0, true, key, "", address(this), block.timestamp
        );
    }

    function test_swap_reverts_on_no_liquidity() public {
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(
            1 ether, 0, true, key, "", address(this), block.timestamp
        );
    }

    // ─────────────────────────────────────────────────────────────
    // Tick crossing
    // ─────────────────────────────────────────────────────────────

    function _isInterior(uint256 i) internal view returns (bool isInt) {
        (, , isInt) = hook.ticks(i);
    }

    function test_swap_crosses_one_tick() public {
        uint256 r = 1_000 ether;
        uint256 rBack = 500 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // The narrowest band (0.9999) pins as soon as the price moves; the
        // full-range backstop stays interior throughout.
        hook.addLiquidity(TIGHT, r, maxA, block.timestamp);
        hook.addLiquidity(FULL, rBack, maxA, block.timestamp);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        assertTrue(_isInterior(TIGHT), "tight tick starts interior");
        assertTrue(_isInterior(FULL), "backstop starts interior");

        // 30% sweep — enough curve slippage for sumX to rise past the tight tick.
        uint256 amountIn = hook.reserves(0) * 30 / 100;
        swapRouter.swapExactTokensForTokens(
            amountIn, 0, true, key, "", address(this), block.timestamp
        );

        assertFalse(_isInterior(TIGHT), "tight tick crossed to boundary");
        assertTrue(_isInterior(FULL), "backstop tick still interior");

        // Slot0 reflects the crossing: rInt lost the tight tick's r, kBound and
        // sBound gained its k and boundary radius.
        (, , uint256 rInt, uint256 kBound, uint256 sBound) = hook.slot0();
        (uint256 kTight,,) = hook.ticks(TIGHT);
        assertEq(rInt, rBack, "rInt now only backstop");
        assertEq(kBound, kTight, "kBound is the pinned tick's k");
        assertGt(sBound, 0, "sBound is the pinned tick's boundary radius");
    }

    /// @notice A pinned tick must come back to the interior when the price does.
    ///
    ///         This is the falling branch of the crossing math (paper §4.13 with
    ///         Σx decreasing): the partial trade's input is out − D, so the
    ///         quadratic's root must be at least D, and its linear coefficient is
    ///         2(xᵢ − D − xⱼ). Neither was exercised by any other test. The
    ///         return trade sells back the coin the depeg drained, which is the
    ///         case the coefficient must stay exact for.
    function test_boundary_tick_recovers_when_price_returns() public {
        uint256 r = 1_000 ether;
        uint256 rBack = 500 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // A band wide enough (0.95) that a round trip lands back inside it. Near
        // the equal-price point αNorm moves with the SQUARE of the imbalance, so
        // a tight band (0.999: 1.1e-7 of αNorm wide) sits closer to the peg than
        // the imbalance a round trip's slippage and fees leave behind — the
        // tick would rightly stay pinned. kMin's plane is the peg itself.
        hook.addLiquidity(MID, r, maxA, block.timestamp);
        hook.addLiquidity(FULL, rBack, maxA, block.timestamp);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Out: sell c0 until the tight band pins.
        uint256 c1Before = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(hook.reserves(0) * 30 / 100, 0, true, key, "", address(this), block.timestamp);
        assertFalse(_isInterior(MID), "band did not pin");
        uint256 got = MockERC20(Currency.unwrap(c1)).balanceOf(address(this)) - c1Before;

        // Back: sell the drained coin for the abundant one.
        swapRouter.swapExactTokensForTokens(got, 0, false, key, "", address(this), block.timestamp);

        assertTrue(_isInterior(MID), "band did not recover");
        (, , uint256 rInt, uint256 kBound, uint256 sBound) = hook.slot0();
        assertEq(rInt, r + rBack, "rInt not restored");
        assertEq(kBound, 0, "kBound not cleared");
        assertEq(sBound, 0, "sBound not cleared");

        // What that means for an LP: back at peg, they can leave. A tick left
        // pinned would keep kBound ≠ 0 and block every burn in the pool.
        uint256[] memory minA = new uint256[](3);
        hook.removeLiquidity(MID, r, minA, block.timestamp);
    }

    /// @notice Any number of positions in one band are one tick and cross as
    ///         one event.
    ///
    ///         A stack of separate ticks on one plane each took a slot of
    ///         `MAX_CROSSINGS`, so more than that walled the price off: every swap
    ///         reaching it reverted, and chunking could not help since no flip
    ///         needs input. Positions in a band now share its tick.
    function test_many_positions_in_one_band_cross_as_one_tick() public {
        uint256 r = 10 ether;
        uint256 rBack = 500 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        uint256 count = 25; // MAX_CROSSINGS is 20
        for (uint256 i = 0; i < count; ++i) {
            hook.addLiquidity(TIGHT, r, maxA, block.timestamp);
        }
        hook.addLiquidity(FULL, rBack, maxA, block.timestamp);
        (, uint256 tr,) = hook.ticks(TIGHT);
        assertEq(tr, count * r, "one tick holds every position in the band");

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        swapRouter.swapExactTokensForTokens(hook.reserves(0) * 30 / 100, 0, true, key, "", address(this), block.timestamp);

        assertFalse(_isInterior(TIGHT), "band not crossed");
        (, , uint256 rInt,,) = hook.slot0();
        assertEq(rInt, rBack, "only the backstop should remain interior");
    }

    /// @notice More DISTINCT bands than `MAX_CROSSINGS` in one swap fail with a
    ///         named, clean revert.
    ///
    ///         Unlike a stack on one band (which crosses as a single event, see
    ///         `test_many_positions_in_one_band_cross_as_one_tick`), each
    ///         distinct band needs its own partial trade, and the cap bounds the
    ///         swap's gas. Here chunking genuinely works — a smaller trade crosses
    ///         fewer bands and persists — so the revert is a routing signal, not a
    ///         wall.
    function test_more_distinct_bands_than_MAX_CROSSINGS_reverts_cleanly() public {
        uint256 r = 100 ether;
        uint256 rBack = 500 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // The 25 narrowest bands (0.9999 down to 0.85): distinct planes, all
        // inside the range a 30% sweep carries αNorm through.
        for (uint256 i = 0; i < 25; ++i) {
            hook.addLiquidity(i, r, maxA, block.timestamp);
        }
        hook.addLiquidity(FULL, rBack, maxA, block.timestamp);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        uint256 amountIn = hook.reserves(0) * 30 / 100;

        // v4 wraps a reverting hook in `WrappedError`, so `TooManyCrossings` is
        // nested rather than leading and `vm.expectRevert(selector)` will not
        // match it. Catch the raw returndata and look for the selector inside,
        // which asserts the specific cause rather than merely "it reverted".
        try swapRouter.swapExactTokensForTokens(
            amountIn, 0, true, key, "", address(this), block.timestamp
        ) returns (BalanceDelta) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(
                _revertContains(reason, OrbitalHook.TooManyCrossings.selector),
                "must fail with TooManyCrossings, not some other error"
            );
        }

        // The failed swap changed nothing: the pool is untouched and still quotes.
        for (uint256 i = 0; i < 25; ++i) assertTrue(_isInterior(i), "state rolled back");
    }

    /// @dev Search revert data for a 4-byte selector. Needed because v4 nests a
    ///      hook's own error inside `WrappedError` rather than surfacing it.
    function _revertContains(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; ++i) {
            if (
                data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2]
                    && data[i + 3] == sel[3]
            ) return true;
        }
        return false;
    }

    function test_swap_does_not_cross_when_amount_small() public {
        uint256 r = 1_000 ether;
        uint256 rBack = 500 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // A 0.99 band (would cross on a large swap) plus a backstop.
        uint256 band = BandLib.bandOf(0.99e18);
        hook.addLiquidity(band, r, maxA, block.timestamp);
        hook.addLiquidity(FULL, rBack, maxA, block.timestamp);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Tiny swap should stay inside the band.
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, key, "", address(this), block.timestamp);

        assertTrue(_isInterior(band), "band still interior");
        assertTrue(_isInterior(FULL), "backstop still interior");
    }

    /// @notice A band emptied by a full burn is skipped by later swaps.
    function test_swap_after_full_burn_skips_dead_tick() public {
        uint256 r = 1_000 ether;
        uint256 rBack = 500 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        hook.addLiquidity(MID, r, maxA, block.timestamp);
        hook.addLiquidity(FULL, rBack, maxA, block.timestamp);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        uint256[] memory minA = new uint256[](3);
        hook.removeLiquidity(MID, r, minA, block.timestamp);
        (, uint256 tr, bool tInt) = hook.ticks(MID);
        assertEq(tr, 0, "band emptied");
        assertFalse(tInt, "an empty band is not interior");

        swapRouter.swapExactTokensForTokens(1 ether, 0, true, key, "", address(this), block.timestamp);
        assertGt(hook.reserves(1), 0, "swap settled output reserve");
    }

    /// @notice A band emptied and then minted into again comes back as a fresh
    ///         interior tick: the band's plane, only the new radius, no fee
    ///         history carried over from its previous life.
    function test_mint_after_full_burn_revives_the_band() public {
        uint256 r = 100 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        uint256[] memory minA = new uint256[](3);

        hook.addLiquidity(MID, r, maxA, block.timestamp);
        hook.removeLiquidity(MID, r, minA, block.timestamp);
        hook.addLiquidity(MID, 2 * r, maxA, block.timestamp);

        (uint256 tk, uint256 tr, bool tInt) = hook.ticks(MID);
        assertEq(tr, 2 * r, "only the new radius");
        assertEq(tk, _kOf(MID, 2 * r), "on the band's plane");
        assertTrue(tInt, "interior");
    }

    /// @notice During a depeg a new position can open in any band the pool has
    ///         not moved past, and it takes exactly its share of the interior.
    ///
    ///         Paper §4.10 (case 1): every interior tick holds the same
    ///         normalised point, so the newcomer's reserves are (r / rInt) of
    ///         the interior reserves — the total less what the pinned ticks hold
    ///         (§4.11). Minting and then burning the same radius straight away
    ///         must therefore hand the deposit back, less only rounding: any
    ///         error in that attribution would show up as a gain or a loss here.
    function test_mint_during_depeg_joins_the_interior_exactly() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        hook.addLiquidity(TIGHT, 200 ether, maxA, block.timestamp);
        hook.addLiquidity(FULL, 1_000 ether, maxA, block.timestamp);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        swapRouter.swapExactTokensForTokens(
            hook.reserves(0) * 30 / 100, 0, true, key, "", address(this), block.timestamp
        );
        assertFalse(_isInterior(TIGHT), "depeg pinned the tight band");

        // A band the pool has moved past is refused...
        vm.expectRevert(OrbitalHook.TickOutsideItsBand.selector);
        hook.addLiquidity(TIGHT, 10 ether, maxA, block.timestamp);

        // ...one still ahead of it is not.
        address lp = address(0x1F);
        for (uint256 i = 0; i < 3; ++i) {
            Currency c = i == 0 ? c0 : i == 1 ? c1 : c2;
            MockERC20(Currency.unwrap(c)).mint(lp, 1_000 ether);
            vm.prank(lp);
            MockERC20(Currency.unwrap(c)).approve(address(hook), type(uint256).max);
        }
        vm.prank(lp);
        (, uint256[] memory put) = hook.addLiquidity(FULL, 100 ether, maxA, block.timestamp);
        assertGt(put[0], put[1], "the interior is c0-heavy after selling c0, and so is the deposit");

        uint256[] memory minA = new uint256[](3);
        vm.prank(lp);
        uint256[] memory back = hook.removeLiquidity(FULL, 100 ether, minA, block.timestamp);
        for (uint256 i = 0; i < 3; ++i) {
            assertApproxEqAbs(back[i], put[i], 4, "mint then burn must round-trip the deposit");
        }
    }

    /// @notice An LP can leave during a depeg, whether their band is pinned or
    ///         still interior, and every LP together takes out exactly what the
    ///         pool holds.
    ///
    ///         Each tick's holding is fixed by the paper: a pinned tick holds
    ///         k/√n of every coin plus s along ŵ (§4.11), an interior tick its
    ///         share of the rest (§4.10). If the split were wrong, the first LP
    ///         out would take from the second, and the pool's real reserves
    ///         would not add up to what the two are paid.
    function test_burn_during_depeg_pays_each_tick_its_own_holding() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        uint256 rA = 200 ether;
        uint256 rB = 1_000 ether;
        hook.addLiquidity(TIGHT, rA, maxA, block.timestamp);
        hook.addLiquidity(FULL, rB, maxA, block.timestamp);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        swapRouter.swapExactTokensForTokens(
            hook.reserves(0) * 30 / 100, 0, true, key, "", address(this), block.timestamp
        );
        assertFalse(_isInterior(TIGHT), "tight band pinned");
        assertTrue(_isInterior(FULL), "backstop interior");

        uint256[3] memory real;
        for (uint8 i = 0; i < 3; ++i) real[i] = hook.reserves(i) - hook.virtualReserve();

        uint256[] memory minA = new uint256[](3);
        uint256[] memory outPinned = hook.removeLiquidity(TIGHT, rA, minA, block.timestamp);
        uint256[] memory outInterior = hook.removeLiquidity(FULL, rB, minA, block.timestamp);

        // A pinned band holds the coin that depegged (c0, sold into the pool)
        // well above its peg share, and the least of the drained one (c1).
        assertGt(outPinned[0], outPinned[1], "pinned tick holds the depegged coin");

        for (uint8 i = 0; i < 3; ++i) {
            assertApproxEqAbs(outPinned[i] + outInterior[i], real[i], 8, "payouts must add up to the pool");
        }
        (, , uint256 rInt, uint256 kBound, uint256 sBound) = hook.slot0();
        assertEq(rInt, 0);
        assertEq(kBound, 0);
        assertEq(sBound, 0);
    }

    /// @notice A band pinned by a depeg and then burned out entirely must leave
    ///         no trace in the band bitmaps: a stale "pinned" bit would make the
    ///         empty band a crossing candidate and refuse every future deposit.
    function test_pinned_band_burned_out_leaves_no_stale_bit() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(TIGHT, 200 ether, maxA, block.timestamp);
        hook.addLiquidity(FULL, 1_000 ether, maxA, block.timestamp);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        swapRouter.swapExactTokensForTokens(hook.reserves(0) * 30 / 100, 0, true, key, "", address(this), block.timestamp);
        assertFalse(_isInterior(TIGHT), "tight band pinned");
        assertEq(_bandBits() >> 128, 1 << TIGHT, "pinned bit set");

        hook.removeLiquidity(TIGHT, 200 ether, new uint256[](3), block.timestamp);

        uint256 bits = _bandBits();
        assertEq(bits >> 128, 0, "a burned-out pinned band left its pinned bit");
        assertEq(bits & type(uint128).max, 1 << FULL, "only the backstop is live");

        // Trading back through the empty band's plane crosses nothing.
        swapRouter.swapExactTokensForTokens(hook.reserves(1) * 30 / 100, 0, false, key, "", address(this), block.timestamp);
        assertEq(_bandBits(), 1 << FULL, "the empty band came back to life");
    }

    /// @dev The hook's band bitmaps (see Solvency.invariant.t.sol for the slot
    ///      and how to regenerate it).
    function _bandBits() internal view returns (uint256) {
        return uint256(vm.load(address(hook), bytes32(uint256(111))));
    }

    /// @notice With every interior tick gone, nothing is left to join: a mint
    ///         waits for the pinned ticks to recover or leave.
    function test_mint_blocked_when_only_pinned_liquidity_remains() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        hook.addLiquidity(TIGHT, 200 ether, maxA, block.timestamp);
        hook.addLiquidity(FULL, 1_000 ether, maxA, block.timestamp);
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        swapRouter.swapExactTokensForTokens(
            hook.reserves(0) * 30 / 100, 0, true, key, "", address(this), block.timestamp
        );

        uint256[] memory minA = new uint256[](3);
        hook.removeLiquidity(FULL, 1_000 ether, minA, block.timestamp);

        vm.expectRevert(OrbitalHook.MintBlockedByBoundaryTicks.selector);
        hook.addLiquidity(FULL, 10 ether, maxA, block.timestamp);
    }

    // Fee conservation across a depeg (regression for the fee-misattribution bug):
    // a tick on its boundary must NOT accrue fees from swaps that happen while it
    // is out. Pre-fix, the boundary tick claimed against global growth and the sum
    // of owed fees exceeded `feesAccrued`, so a later collect hit `FeeBucketShort`.
    function test_fees_not_accrued_to_boundary_tick() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        uint256 rA = 200 ether;
        hook.addLiquidity(TIGHT, rA, maxA, block.timestamp);               // tick 0 (tight)
        uint256 rB = 1_000 ether;
        hook.addLiquidity(FULL, rB, maxA, block.timestamp);     // tick 1 (backstop)

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Fee while both interior, then a big swap to flip tick 0 to boundary,
        // then more swaps that accrue fees while tick 0 is out (only tick 1 earns).
        swapRouter.swapExactTokensForTokens(5 ether, 0, true, key, "", address(this), block.timestamp);
        swapRouter.swapExactTokensForTokens(hook.reserves(0) * 30 / 100, 0, true, key, "", address(this), block.timestamp);
        assertFalse(_isInterior(TIGHT), "tight band on boundary");
        swapRouter.swapExactTokensForTokens(20 ether, 0, true, key, "", address(this), block.timestamp);

        // All fees were taken on asset 0 (zeroForOne). Snapshot the bucket.
        uint256 bucket0 = hook.feesAccrued(0);
        assertGt(bucket0, 0, "fees accrued on asset 0");

        // Both positions can collect without FeeBucketShort, and the total paid out
        // never exceeds what the pool actually accrued (conservation).
        uint256[] memory fA = hook.collect(TIGHT);
        uint256[] memory fB = hook.collect(FULL);
        assertLe(fA[0] + fB[0], bucket0, "collected more fees than accrued");
    }

    // ─────────────────────────────────────────────────────────────
    // removeLiquidity (burn)
    // ─────────────────────────────────────────────────────────────

    function test_removeLiquidity_returnsProRataAssets() public {
        uint256 rWad = 100 ether;
        uint256 kWad = _kOf(MID, rWad);
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(MID, rWad, maxA, block.timestamp);

        uint256 perAssetDeposited = SphereMath.equalPricePoint(rWad, 3) - _virtualOf(rWad, kWad);

        // Burn half.
        uint256 halfR = rWad / 2;
        uint256[] memory minA = new uint256[](3);
        // empty pool → balanced → withdrawal is pro-rata at the deposited rate.
        uint256[] memory amounts = hook.removeLiquidity(MID, halfR, minA, block.timestamp);

        assertEq(amounts.length, 3);
        // Pool was perfectly balanced; pro-rata over rInt of the half should yield half of each deposit.
        assertApproxEqAbs(amounts[0], perAssetDeposited / 2, 1, "asset0 amount");
        assertApproxEqAbs(amounts[1], perAssetDeposited / 2, 1, "asset1 amount");
        assertApproxEqAbs(amounts[2], perAssetDeposited / 2, 1, "asset2 amount");

        // ERC-6909 share burned.
        assertEq(hook.balanceOf(address(this), MID), rWad - halfR);

        // slot0.rInt halved.
        (, , uint256 rInt, ,) = hook.slot0();
        assertEq(rInt, rWad - halfR);
    }

    function test_removeLiquidity_sendsTokensToOwner() public {
        uint256 rWad = 100 ether;
        uint256 kWad = _kOf(MID, rWad);
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(MID, rWad, maxA, block.timestamp);

        uint256 perAssetDeposited = SphereMath.equalPricePoint(rWad, 3) - _virtualOf(rWad, kWad);

        uint256 balC0Before = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 pmBalBefore = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));

        uint256[] memory minA = new uint256[](3);
        hook.removeLiquidity(MID, rWad, minA, block.timestamp);

        assertEq(
            MockERC20(Currency.unwrap(c0)).balanceOf(address(this)),
            balC0Before + perAssetDeposited,
            "LP refunded c0"
        );
        assertEq(
            MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager)),
            pmBalBefore - perAssetDeposited,
            "PoolManager drained"
        );
    }

    function test_removeLiquidity_reverts_on_no_shares() public {
        uint256[] memory minA = new uint256[](3);
        vm.expectRevert(OrbitalHook.NotEnoughLiquidity.selector);
        hook.removeLiquidity(MID, 1 ether, minA, block.timestamp);
    }

    function test_removeLiquidity_reverts_on_slippage() public {
        uint256 rWad = 100 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(MID, rWad, maxA, block.timestamp);

        uint256[] memory minA = new uint256[](3);
        minA[0] = minA[1] = minA[2] = type(uint256).max; // impossibly high
        vm.expectRevert();
        hook.removeLiquidity(MID, rWad / 2, minA, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────────
    // collect (fees)
    // ─────────────────────────────────────────────────────────────

    function test_collect_paysAccruedFees() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);

        // Two swaps to seed fees on both assets.
        swapRouter.swapExactTokensForTokens(10 ether, 0, true, key, "", address(this), block.timestamp);
        swapRouter.swapExactTokensForTokens(10 ether, 0, false, key, "", address(this), block.timestamp);

        uint256 feeOnC0 = hook.feesAccrued(0);
        uint256 feeOnC1 = hook.feesAccrued(1);
        assertGt(feeOnC0, 0);
        assertGt(feeOnC1, 0);

        uint256 balC0Before = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 balC1Before = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));

        uint256[] memory fees = hook.collect(FULL);

        assertApproxEqAbs(fees[0], feeOnC0, 1, "c0 fees collected");
        assertApproxEqAbs(fees[1], feeOnC1, 1, "c1 fees collected");
        assertEq(fees[2], 0, "no c2 fees");

        assertGt(MockERC20(Currency.unwrap(c0)).balanceOf(address(this)), balC0Before);
        assertGt(MockERC20(Currency.unwrap(c1)).balanceOf(address(this)), balC1Before);

        // Buckets drained.
        assertLe(hook.feesAccrued(0), 1, "c0 bucket cleared (<=1 dust)");
        assertLe(hook.feesAccrued(1), 1, "c1 bucket cleared (<=1 dust)");
    }

    function test_collect_reverts_when_nothing_owed() public {
        uint256 rWad = 100 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(MID, rWad, maxA, block.timestamp);

        vm.expectRevert(OrbitalHook.NothingOwed.selector);
        hook.collect(MID);
    }

    // ─────────────────────────────────────────────────────────────
    // Correctness fixes — soulbound shares, USDT-like, decimal guard
    // ─────────────────────────────────────────────────────────────

    function test_shares_cannot_be_transferred() public {
        uint256 rWad = 50 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(MID, rWad, maxA, block.timestamp);

// Shares are soulbound: ERC-6909's movement surface is not implemented
        // at all, so these calls have no function to reach and revert.
        (bool ok,) = address(hook).call(
            abi.encodeWithSignature("transfer(address,uint256,uint256)", address(0xBEEF), MID, uint256(1)));
        assertFalse(ok, "transfer must not succeed");
        (ok,) = address(hook).call(abi.encodeWithSignature(
            "transferFrom(address,address,uint256,uint256)", address(this), address(0xBEEF), MID, uint256(1)));
        assertFalse(ok, "transferFrom must not succeed");
        assertEq(hook.balanceOf(address(this), MID), rWad, "shares moved");
        (ok,) = address(hook).call(
            abi.encodeWithSignature("approve(address,uint256,uint256)", address(0xBEEF), MID, uint256(1)));
        assertFalse(ok, "approve must not succeed");
        (ok,) = address(hook).call(
            abi.encodeWithSignature("setOperator(address,bool)", address(0xBEEF), true));
        assertFalse(ok, "setOperator must not succeed");
    }

    function test_constructor_accepts_sub_18_decimal_token() public {
        // A 6-decimal token (e.g. USDC) is now supported via decimal scaling.
        address six = address(new MockSixDecimal());
        address regd0 = Currency.unwrap(c0);
        address regd1 = Currency.unwrap(c1);
        // Sort {six, c0, c1} ascending.
        address[3] memory raw = [regd0, regd1, six];
        for (uint256 i = 0; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (raw[j] < raw[i]) (raw[i], raw[j]) = (raw[j], raw[i]);
            }
        }
        Currency[] memory list = new Currency[](3);
        list[0] = Currency.wrap(raw[0]);
        list[1] = Currency.wrap(raw[1]);
        list[2] = Currency.wrap(raw[2]);

        address hookAddr = address(HOOK_FLAGS ^ (0x4449 << 144));
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook",
            abi.encode(poolManager, list, uint24(100), address(this)),
            hookAddr
        );

        // The 6-decimal token gets scale 1e12; the 18-decimal ones get scale 1.
        OrbitalHook h = OrbitalHook(payable(hookAddr));
        for (uint8 i = 0; i < 3; ++i) {
            uint256 expected = Currency.unwrap(h.assetAt(i)) == six ? 1e12 : 1;
            assertEq(h.scaleOf(i), expected, "scale factor");
        }
    }

    function test_constructor_rejects_over_18_decimal_token() public {
        // > 18 decimals would need to scale down (precision loss), so reject.
        address bad = address(new MockTwentyDecimal());
        address regd0 = Currency.unwrap(c0);
        address regd1 = Currency.unwrap(c1);
        address[3] memory raw = [regd0, regd1, bad];
        for (uint256 i = 0; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (raw[j] < raw[i]) (raw[i], raw[j]) = (raw[j], raw[i]);
            }
        }
        Currency[] memory list = new Currency[](3);
        list[0] = Currency.wrap(raw[0]);
        list[1] = Currency.wrap(raw[1]);
        list[2] = Currency.wrap(raw[2]);

        vm.expectRevert(
            abi.encodeWithSelector(OrbitalHook.AssetDecimalsTooHigh.selector, Currency.wrap(bad), uint8(20))
        );
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook",
            abi.encode(poolManager, list, uint24(100), address(this)),
            address(HOOK_FLAGS ^ (0x444A << 144))
        );
    }

    function test_constructor_revertsOn_fee_below_minimum() public {
        // Fee must exceed the invariant tolerance (MIN_FEE = 10) so rounding
        // drift can't be farmed; a 9-unit fee is rejected.
        Currency[] memory regd = _sortedThree(c0, c1, c2);
        vm.expectRevert(abi.encodeWithSelector(OrbitalHook.FeeTooLow.selector, uint24(9)));
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook",
            abi.encode(poolManager, regd, uint24(9), address(this)),
            address(HOOK_FLAGS ^ (0x444B << 144))
        );
    }

    function test_addLiquidity_works_with_usdt_like_token() public {
        // Deploy 3 USDT-like mocks and a fresh hook.
        MockUSDTLike[3] memory tks;
        tks[0] = new MockUSDTLike();
        tks[1] = new MockUSDTLike();
        tks[2] = new MockUSDTLike();
        // Sort.
        for (uint256 i = 0; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (address(tks[j]) < address(tks[i])) (tks[i], tks[j]) = (tks[j], tks[i]);
            }
        }

        Currency[] memory list = new Currency[](3);
        for (uint256 i = 0; i < 3; ++i) {
            list[i] = Currency.wrap(address(tks[i]));
            tks[i].mint(address(this), 1_000 ether);
        }

        address flagged = address(HOOK_FLAGS ^ (0x444A << 144));
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, list, uint24(100), address(this)), flagged
        );
        OrbitalHook usdtHook = OrbitalHook(flagged);

        for (uint256 i = 0; i < 3; ++i) {
            tks[i].approve(address(usdtHook), type(uint256).max);
        }

        uint256 rWad = 100 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // Would revert with the old raw transferFrom; passes with SafeERC20.
        usdtHook.addLiquidity(MID, rWad, maxA, block.timestamp);
        assertEq(usdtHook.balanceOf(address(this), MID), rWad);
    }

    // ─────────────────────────────────────────────────────────────
    // Pair-view state sharing across pools
    // ─────────────────────────────────────────────────────────────

    function test_swaps_on_different_pair_views_share_engine_state() public {
        uint256 r = 1_000 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(FULL, r, maxA, block.timestamp);

        // Initialize TWO pair-views over the same hook state.
        PoolKey memory key01 =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        PoolKey memory key02 =
            PoolKey({currency0: c0, currency1: c2, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key01, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(key02, Constants.SQRT_PRICE_1_1);

        uint256 r0Before = hook.reserves(0);
        uint256 r1Before = hook.reserves(1);
        uint256 r2Before = hook.reserves(2);

        // Swap c0 → c1 on the first pair-view.
        swapRouter.swapExactTokensForTokens(10 ether, 0, true, key01, "", address(this), block.timestamp);
        uint256 r0Mid = hook.reserves(0);
        uint256 r1Mid = hook.reserves(1);
        uint256 r2Mid = hook.reserves(2);
        assertGt(r0Mid, r0Before, "asset0 grew");
        assertLt(r1Mid, r1Before, "asset1 shrank");
        assertEq(r2Mid, r2Before, "asset2 untouched");

        // Swap c0 → c2 on the SECOND pair-view — must see the post-first-swap state.
        swapRouter.swapExactTokensForTokens(10 ether, 0, true, key02, "", address(this), block.timestamp);
        assertGt(hook.reserves(0), r0Mid, "asset0 grew again");
        assertEq(hook.reserves(1), r1Mid, "asset1 unchanged by second swap");
        assertLt(hook.reserves(2), r2Mid, "asset2 shrank in second swap");
    }

    // ─────────────────────────────────────────────────────────────
    // Heavy-swap edge case (near-empty reserve)
    // ─────────────────────────────────────────────────────────────

    function test_swap_revertsCleanly_when_too_large() public {
        // Single tick, modest pool; a swap larger than reserves[1] must revert
        // through the engine (not panic / overflow). Exact revert kind varies
        // by where insufficiency surfaces — assert revert, don't pin the selector.
        PoolKey memory key = _seedSinglePoolWithLiquidity(100 ether);
        // Try to take out nearly the entire pool by swapping more than one reserve.
        uint256 huge = hook.reserves(1) * 2;
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(huge, 0, true, key, "", address(this), block.timestamp);
    }

    /// @notice On a full-range sphere the input's price reaches zero at
    ///         x_in = r, and the surface still has solutions past it — ones that
    ///         pay LESS than selling up to that point would. The pool must stop
    ///         there rather than quote a trade no rational seller wants.
    function test_swap_cannot_sell_past_zero_price() public {
        uint256 r = 100 ether;
        PoolKey memory key = _seedSinglePoolWithLiquidity(r);
        uint256 x0 = hook.reserves(0);

        // Just short of x_in = r (net of the fee) fills normally.
        uint256 snap = vm.snapshotState();
        uint256 below = (r - x0) * 99 / 100;
        uint256 c1Before = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(below, 0, true, key, "", address(this), block.timestamp);
        uint256 outBelow = MockERC20(Currency.unwrap(c1)).balanceOf(address(this)) - c1Before;
        vm.revertToState(snap);

        // Past it the curve would still "solve" — for less output than `below`
        // earned — so the trade is refused by name.
        uint256 past = (r - x0) * 3 / 2;
        try swapRouter.swapExactTokensForTokens(past, 0, true, key, "", address(this), block.timestamp)
        returns (BalanceDelta) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(
                _revertContains(reason, OrbitalHook.SwapBeyondZeroPrice.selector), "must fail with SwapBeyondZeroPrice"
            );
        }
        assertGt(outBelow, 0, "the in-range trade paid out");
    }

    // ─────────────────────────────────────────────────────────────
    // Multi-LP fee distribution
    // ─────────────────────────────────────────────────────────────

    function test_multiLP_fees_distribute_proportionally() public {
        // LP A (this contract) provides the same r as LP B at the same tick.
        // After a swap, each should see roughly half the fees.
        address lpB = address(0xB0B);
        // Fund and approve LP B.
        MockERC20(Currency.unwrap(c0)).transfer(lpB, 10_000 ether);
        MockERC20(Currency.unwrap(c1)).transfer(lpB, 10_000 ether);
        MockERC20(Currency.unwrap(c2)).transfer(lpB, 10_000 ether);
        vm.startPrank(lpB);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c2)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        uint256 r = 100 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // Both LPs mint into the same band, so they share its one tick; each
        // position collects its own part of that tick's fees, and equal radius
        // must earn equally.
        (uint256 tickA,) = hook.addLiquidity(FULL, r, maxA, block.timestamp);
        vm.prank(lpB);
        (uint256 tickB,) = hook.addLiquidity(FULL, r, maxA, block.timestamp);
        assertEq(tickA, tickB, "same band, same tick");

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Drive a swap to generate fees.
        swapRouter.swapExactTokensForTokens(10 ether, 0, true, key, "", address(this), block.timestamp);

        // Both LPs collect from their own tick.
        uint256[] memory feesA = hook.collect(tickA);
        vm.prank(lpB);
        uint256[] memory feesB = hook.collect(tickB);

        // Same liquidity → same fee on the input asset (within 1 wei of rounding).
        assertApproxEqAbs(feesA[0], feesB[0], 1, "asset0 fee split 50/50");
    }

    // ─────────────────────────────────────────────────────────────
    // Admin: pause / unpause
    // ─────────────────────────────────────────────────────────────

    function test_pause_blocks_addLiquidity() public {
        hook.pause();
        uint256 rWad = 50 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.addLiquidity(MID, rWad, maxA, block.timestamp);
    }

    function test_pause_blocks_swap() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);
        hook.pause();
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, key, "", address(this), block.timestamp);
    }

    function test_pause_does_NOT_block_removeLiquidity() public {
        uint256 rWad = 100 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(MID, rWad, maxA, block.timestamp);

        hook.pause();
        uint256[] memory minA = new uint256[](3);
        // Should NOT revert — LPs must always be able to exit.
        hook.removeLiquidity(MID, rWad, minA, block.timestamp);
    }

    function test_pause_does_NOT_block_collect() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);
        // Generate a fee.
        swapRouter.swapExactTokensForTokens(10 ether, 0, true, key, "", address(this), block.timestamp);

        hook.pause();
        // collect must still work while paused.
        uint256[] memory fees = hook.collect(FULL);
        assertGt(fees[0], 0, "fees collected during pause");
    }

    function test_pause_onlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        hook.pause();
    }

    function test_unpause_restoresOperation() public {
        hook.pause();
        hook.unpause();

        uint256 rWad = 50 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        // Should now succeed.
        hook.addLiquidity(MID, rWad, maxA, block.timestamp);
    }

    function test_ownership_twoStep_transfer() public {
        address newOwner = address(0xC0FFEE);
        hook.transferOwnership(newOwner);
        // Until acceptance, old owner still controls.
        assertEq(hook.owner(), address(this));
        // Old owner can still pause.
        hook.pause();
        hook.unpause();

        // New owner accepts.
        vm.prank(newOwner);
        hook.acceptOwnership();
        assertEq(hook.owner(), newOwner);

        // Old owner can no longer pause.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.pause();
        // New owner can.
        vm.prank(newOwner);
        hook.pause();
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

    function _sortedThree(Currency a, Currency b, Currency c) internal pure returns (Currency[] memory out) {
        out = new Currency[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
        for (uint256 i = 0; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (Currency.unwrap(out[j]) < Currency.unwrap(out[i])) {
                    (out[i], out[j]) = (out[j], out[i]);
                }
            }
        }
    }
}
