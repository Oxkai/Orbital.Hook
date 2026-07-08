// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";
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
        deployCodeTo("OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, permit2, regd, uint24(100), address(this)), flagged);
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
        Currency[] memory got = hook.assets();
        assertEq(got.length, 3);
        assertEq(Currency.unwrap(got[0]), Currency.unwrap(c0));
        assertEq(Currency.unwrap(got[1]), Currency.unwrap(c1));
        assertEq(Currency.unwrap(got[2]), Currency.unwrap(c2));
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
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, permit2, one, uint24(100), address(this)), address(HOOK_FLAGS ^ (0x4445 << 144))
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
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, permit2, eleven, uint24(100), address(this)), address(HOOK_FLAGS ^ (0x4446 << 144))
        );
    }

    function test_constructor_revertsOn_duplicate() public {
        Currency[] memory dup = new Currency[](3);
        dup[0] = c0;
        dup[1] = c1;
        dup[2] = c1; // duplicate
        vm.expectRevert(OrbitalHook.AssetsNotSortedOrUnique.selector);
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, permit2, dup, uint24(100), address(this)), address(HOOK_FLAGS ^ (0x4447 << 144))
        );
    }

    function test_constructor_revertsOn_unsorted() public {
        Currency[] memory bad = new Currency[](3);
        bad[0] = c1;
        bad[1] = c0; // out of order
        bad[2] = c2;
        vm.expectRevert(OrbitalHook.AssetsNotSortedOrUnique.selector);
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, permit2, bad, uint24(100), address(this)), address(HOOK_FLAGS ^ (0x4448 << 144))
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

    function test_addLiquidity_emptyPool_mintsExpectedShares() public {
        uint256 rWad = 100 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        uint256 expectedPerAsset = SphereMath.equalPricePoint(rWad, 3);

        (uint256 tickIdx, uint256[] memory amounts) = hook.addLiquidity(kWad, rWad, maxA);

        assertEq(tickIdx, 0, "first tick");
        assertEq(amounts.length, 3);
        assertEq(amounts[0], expectedPerAsset, "asset0 amount");
        assertEq(amounts[1], expectedPerAsset, "asset1 amount");
        assertEq(amounts[2], expectedPerAsset, "asset2 amount");

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

        // ticks
        assertEq(hook.numTicks(), 1);
    }

    function test_addLiquidity_movesTokensIntoPoolManager() public {
        uint256 rWad = 50 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        uint256 expectedPerAsset = SphereMath.equalPricePoint(rWad, 3);

        uint256 balBeforeLP = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 balBeforePM = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));

        hook.addLiquidity(kWad, rWad, maxA);

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
        hook.addLiquidity(1 ether, 0, maxA);
    }

    function test_addLiquidity_reverts_on_k_below_kMin() public {
        uint256 rWad = 10 ether;
        uint256 km = TickLib.kMin(rWad, 3);
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        vm.expectRevert(OrbitalHook.KOutOfRange.selector);
        hook.addLiquidity(km - 1, rWad, maxA);
    }

    function test_addLiquidity_reverts_on_slippage() public {
        uint256 rWad = 10 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = 1; // far too tight
        vm.expectRevert(); // SlippageExceeded — args vary
        hook.addLiquidity(kWad, rWad, maxA);
    }

    function test_addLiquidity_secondMint_proRata() public {
        // kMin/kMax scale linearly with rWad, so a kWad valid at one r is invalid at
        // another. Use the same rWad twice — that's the realistic same-tick-merge path.
        uint256 rWad = 100 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        hook.addLiquidity(kWad, rWad, maxA);
        uint256 perAsset1 = SphereMath.equalPricePoint(rWad, 3);

        // Second mint: pool is balanced, so pro-rata yields the same per-asset amount.
        (uint256 tickIdx2, uint256[] memory amounts2) = hook.addLiquidity(kWad, rWad, maxA);

        assertEq(tickIdx2, 0, "tick merged");
        assertEq(amounts2[0], perAsset1);
        assertEq(amounts2[1], perAsset1);
        assertEq(amounts2[2], perAsset1);

        assertEq(hook.balanceOf(address(this), tickIdx2), rWad * 2);
        assertEq(hook.numTicks(), 1);

        (, , uint256 rInt, ,) = hook.slot0();
        assertEq(rInt, rWad * 2);
    }

    // DoS bound: the live tick array cannot grow past MAX_TICKS, so an attacker
    // can't make every swap's crossing-scan unboundedly expensive by minting
    // many distinct-k dust ticks. Merging into existing ticks still works.
    function test_tick_cap_bounds_distinct_k_ticks() public {
        uint256 rWad = 1 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        uint256 km = TickLib.kMin(rWad, 3);

        // Fill the array to the cap (128) with distinct-k interior ticks.
        for (uint256 i = 0; i < 128; ++i) {
            hook.addLiquidity(km + i, rWad, maxA);
        }
        assertEq(hook.numTicks(), 128, "array filled to MAX_TICKS");

        // A 129th distinct-k mint reverts rather than growing the scan unboundedly.
        vm.expectRevert(OrbitalHook.TooManyTicks.selector);
        hook.addLiquidity(km + 128, rWad, maxA);

        // Merging into an existing k still works and does not grow the array.
        hook.addLiquidity(km, rWad, maxA);
        assertEq(hook.numTicks(), 128, "merge does not grow the array past the cap");
    }

    // ─────────────────────────────────────────────────────────────
    // beforeSwap (Phase B: within-tick only)
    // ─────────────────────────────────────────────────────────────

    function _seedSinglePoolWithLiquidity(uint256 rWad) internal returns (PoolKey memory key) {
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(kWad, rWad, maxA);

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

    function test_swap_reverts_on_exactOutput() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);

        vm.expectRevert();
        swapRouter.swapTokensForExactTokens(
            1 ether, type(uint256).max, true, key, "", address(this), block.timestamp
        );
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
        (, , isInt, , ) = hook.ticks(i);
    }

    function test_swap_crosses_one_tick() public {
        uint256 r = 1_000 ether;
        uint256 rBack = 500 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // Tight tick at kMin — kNorm == αNorm at empty-pool equal-price, so it
        // is "ready to flip" the moment the price moves.
        hook.addLiquidity(TickLib.kMin(r, 3), r, maxA);
        // Backstop tick near kMax — stays interior throughout the test.
        hook.addLiquidity(TickLib.kMax(rBack, 3) - 1 ether, rBack, maxA);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        assertTrue(_isInterior(0), "tick0 starts interior");
        assertTrue(_isInterior(1), "tick1 starts interior");

        // 30% sweep — enough curve slippage for sumX to rise past the tight tick.
        uint256 amountIn = hook.reserves(0) * 30 / 100;
        swapRouter.swapExactTokensForTokens(
            amountIn, 0, true, key, "", address(this), block.timestamp
        );

        assertFalse(_isInterior(0), "tight tick crossed to boundary");
        assertTrue(_isInterior(1), "backstop tick still interior");

        // Slot0 reflects the crossing: rInt shrunk by tick0's r, kBound got tick0's k.
        // Tick at exactly kMin has computeS = 0, so sBound stays 0 — that's a property
        // of the formula, not a bug. Tests using ticks at k=kMin won't bump sBound.
        (, , uint256 rInt, uint256 kBound,) = hook.slot0();
        assertEq(rInt, rBack, "rInt now only backstop");
        assertGt(kBound, 0, "kBound non-zero after crossing");
    }

    function test_swap_does_not_cross_when_amount_small() public {
        uint256 r = 1_000 ether;
        uint256 rBack = 500 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // Tick set up to be tight (would cross on large swap) plus a backstop.
        hook.addLiquidity(TickLib.kMin(r, 3) + 5 ether, r, maxA);
        hook.addLiquidity(TickLib.kMax(rBack, 3) - 1 ether, rBack, maxA);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Tiny swap should stay within the tightest tick.
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, key, "", address(this), block.timestamp);

        assertTrue(_isInterior(0), "tight tick still interior");
        assertTrue(_isInterior(1), "backstop still interior");
    }

    // H1 regression: a tick that was fully burned has r == 0 and stays in the
    // array. Pre-fix, _detectCrossing would divide by zero on the next swap.
    function test_swap_after_full_burn_skips_dead_tick() public {
        uint256 r = 1_000 ether;
        uint256 rBack = 500 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        uint256 kA = (TickLib.kMin(r, 3) + TickLib.kMax(r, 3)) / 2;
        hook.addLiquidity(kA, r, maxA);                                     // tick 0
        hook.addLiquidity(TickLib.kMax(rBack, 3) - 1 ether, rBack, maxA);   // tick 1 (backstop)

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Fully burn tick 0 → tick 0 stays in the array with r == 0.
        uint256[] memory minA = new uint256[](3);
        hook.removeLiquidity(0, r, minA);

        // Pre-fix this reverts inside FullMath.mulDiv(t.k, WAD, 0). Post-fix it succeeds.
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, key, "", address(this), block.timestamp);

        assertGt(hook.reserves(1), 0, "swap settled output reserve");
    }

    // H1 regression + M2 free-list: re-minting at the same k after a full burn
    // must NOT silently resurrect a dead tick (different LP, different bookkeeping).
    // With the free-list optimization, the slot is recycled — but the tick must
    // be a *freshly* initialized interior tick, not a zombie.
    function test_mint_after_full_burn_creates_fresh_tick() public {
        uint256 r = 100 ether;
        uint256 kA = (TickLib.kMin(r, 3) + TickLib.kMax(r, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        hook.addLiquidity(kA, r, maxA);                  // tick 0
        uint256[] memory minA = new uint256[](3);
        hook.removeLiquidity(0, r, minA);                // tick 0 now dead (r == 0, free-listed)

        hook.addLiquidity(kA, r, maxA);                  // reuses slot 0 with a fresh tick

        // Whatever slot it lands in, the live tick must be interior and freshly sized.
        // Find it via the public ticks() getter on slot 0 (where it ought to be reused).
        (uint256 tk, uint256 tr, bool tInt, , uint128 tLiq) = hook.ticks(0);
        assertEq(tk, kA, "k preserved");
        assertEq(tr, r, "r reset to fresh deposit");
        assertTrue(tInt, "tick is interior");
        assertEq(uint256(tLiq), r, "liquidityGross reset to fresh deposit");
    }

    // M2 regression: fully-burned tick slots feed a free-list, so a fresh
    // mint at a DIFFERENT k recycles the slot instead of growing the array.
    function test_burned_tick_slot_is_recycled_on_next_mint() public {
        uint256 r = 100 ether;
        uint256 kA = (TickLib.kMin(r, 3) + TickLib.kMax(r, 3)) / 2;
        uint256 kB = kA + 10 ether;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        hook.addLiquidity(kA, r, maxA);                  // tick 0
        uint256[] memory minA = new uint256[](3);
        hook.removeLiquidity(0, r, minA);                // tick 0 freed
        assertEq(hook.numTicks(), 1, "array does not shrink, slot just freed");

        // Fresh mint at a different k recycles slot 0 — array stays length 1.
        hook.addLiquidity(kB, r, maxA);
        assertEq(hook.numTicks(), 1, "slot recycled, no array growth");
        (uint256 tk, , bool tInt, , ) = hook.ticks(0);
        assertEq(tk, kB, "slot now holds the new k");
        assertTrue(tInt, "and is interior");
    }

    // H2 regression: mints must be blocked whenever any boundary tick exists,
    // regardless of whether rInt is zero. Pre-fix, the rescue-mint path (rInt
    // == 0) would silently merge into a boundary tick via _findOrCreateTick and
    // desync kBound / sBound; the proper behavior is to reject the mint until
    // the pool fully recovers (kBound == 0).
    function test_mint_blocked_while_boundary_tick_exists() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // Tight tick A that boundary-flips on a moderate swap, plus a backstop B.
        uint256 rA = 200 ether;
        uint256 kA = TickLib.kMin(rA, 3);
        hook.addLiquidity(kA, rA, maxA);                                                 // tick 0
        uint256 rB = 1_000 ether;
        hook.addLiquidity(TickLib.kMax(rB, 3) - 1 ether, rB, maxA);                      // tick 1

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Flip tick 0 to boundary (tick 1 stays interior, so rInt > 0).
        swapRouter.swapExactTokensForTokens(
            hook.reserves(0) * 30 / 100, 0, true, key, "", address(this), block.timestamp
        );
        assertFalse(_isInterior(0), "tick 0 boundary");
        (, , , uint256 kBound,) = hook.slot0();
        assertGt(kBound, 0, "kBound set by the boundary tick");

        // A fresh mint at the boundary tick's k must revert — pre-fix it would
        // silently merge into tick 0 (boundary) and break the invariant.
        vm.expectRevert(OrbitalHook.MintBlockedByBoundaryTicks.selector);
        hook.addLiquidity(kA, rA, maxA);

        // A mint at any other valid k must also revert for the same reason.
        uint256 kMid = (TickLib.kMin(rA, 3) + TickLib.kMax(rA, 3)) / 2;
        vm.expectRevert(OrbitalHook.MintBlockedByBoundaryTicks.selector);
        hook.addLiquidity(kMid, rA, maxA);
    }

    // While ANY tick is on boundary (a coin has depegged), all burns are blocked
    // — both the boundary tick AND otherwise-interior ticks. The pro-rata payout
    // (total reserves ÷ interior rInt) only holds when the pool is fully interior;
    // allowing an interior burn here would pay out the parked boundary tokens and
    // strand the boundary LP. Withdrawals resume once the coin re-pegs.
    function test_burn_blocked_while_boundary_tick_exists() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        uint256 rA = 200 ether;
        uint256 kA = TickLib.kMin(rA, 3);
        hook.addLiquidity(kA, rA, maxA);                              // tick 0 (tight)
        uint256 rB = 1_000 ether;
        hook.addLiquidity(TickLib.kMax(rB, 3) - 1 ether, rB, maxA);   // tick 1 (backstop)

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Flip tick 0 to boundary.
        swapRouter.swapExactTokensForTokens(
            hook.reserves(0) * 30 / 100, 0, true, key, "", address(this), block.timestamp
        );
        assertFalse(_isInterior(0), "tick 0 on boundary");
        assertTrue(_isInterior(1), "tick 1 still interior");

        uint256[] memory minA = new uint256[](3);

        // Burning the boundary tick is blocked.
        vm.expectRevert(OrbitalHook.BurnBlockedByBoundaryTicks.selector);
        hook.removeLiquidity(0, rA, minA);

        // Burning the still-interior backstop is ALSO blocked — otherwise it would
        // drain tick 0's parked reserves and strand that LP.
        vm.expectRevert(OrbitalHook.BurnBlockedByBoundaryTicks.selector);
        hook.removeLiquidity(1, rB, minA);
    }

    // Fee conservation across a depeg (regression for the fee-misattribution bug):
    // a tick on its boundary must NOT accrue fees from swaps that happen while it
    // is out. Pre-fix, the boundary tick claimed against global growth and the sum
    // of owed fees exceeded `feesAccrued`, so a later collect hit `FeeBucketShort`.
    function test_fees_not_accrued_to_boundary_tick() public {
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        uint256 rA = 200 ether;
        hook.addLiquidity(TickLib.kMin(rA, 3), rA, maxA);               // tick 0 (tight)
        uint256 rB = 1_000 ether;
        hook.addLiquidity(TickLib.kMax(rB, 3) - 1 ether, rB, maxA);     // tick 1 (backstop)

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Fee while both interior, then a big swap to flip tick 0 to boundary,
        // then more swaps that accrue fees while tick 0 is out (only tick 1 earns).
        swapRouter.swapExactTokensForTokens(5 ether, 0, true, key, "", address(this), block.timestamp);
        swapRouter.swapExactTokensForTokens(hook.reserves(0) * 30 / 100, 0, true, key, "", address(this), block.timestamp);
        assertFalse(_isInterior(0), "tick 0 on boundary");
        swapRouter.swapExactTokensForTokens(20 ether, 0, true, key, "", address(this), block.timestamp);

        // All fees were taken on asset 0 (zeroForOne). Snapshot the bucket.
        uint256 bucket0 = hook.feesAccrued(0);
        assertGt(bucket0, 0, "fees accrued on asset 0");

        // Both positions can collect without FeeBucketShort, and the total paid out
        // never exceeds what the pool actually accrued (conservation).
        uint256[] memory fA = hook.collect(0);
        uint256[] memory fB = hook.collect(1);
        assertLe(fA[0] + fB[0], bucket0, "collected more fees than accrued");
    }

    // ─────────────────────────────────────────────────────────────
    // removeLiquidity (burn)
    // ─────────────────────────────────────────────────────────────

    function test_removeLiquidity_returnsProRataAssets() public {
        uint256 rWad = 100 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(kWad, rWad, maxA);

        uint256 perAssetDeposited = SphereMath.equalPricePoint(rWad, 3);

        // Burn half.
        uint256 halfR = rWad / 2;
        uint256[] memory minA = new uint256[](3);
        // empty pool → balanced → withdrawal is pro-rata at the deposited rate.
        uint256[] memory amounts = hook.removeLiquidity(0, halfR, minA);

        assertEq(amounts.length, 3);
        // Pool was perfectly balanced; pro-rata over rInt of the half should yield half of each deposit.
        assertApproxEqAbs(amounts[0], perAssetDeposited / 2, 1, "asset0 amount");
        assertApproxEqAbs(amounts[1], perAssetDeposited / 2, 1, "asset1 amount");
        assertApproxEqAbs(amounts[2], perAssetDeposited / 2, 1, "asset2 amount");

        // ERC-6909 share burned.
        assertEq(hook.balanceOf(address(this), 0), rWad - halfR);

        // slot0.rInt halved.
        (, , uint256 rInt, ,) = hook.slot0();
        assertEq(rInt, rWad - halfR);
    }

    function test_removeLiquidity_sendsTokensToOwner() public {
        uint256 rWad = 100 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(kWad, rWad, maxA);

        uint256 perAssetDeposited = SphereMath.equalPricePoint(rWad, 3);

        uint256 balC0Before = MockERC20(Currency.unwrap(c0)).balanceOf(address(this));
        uint256 pmBalBefore = MockERC20(Currency.unwrap(c0)).balanceOf(address(poolManager));

        uint256[] memory minA = new uint256[](3);
        hook.removeLiquidity(0, rWad, minA);

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
        hook.removeLiquidity(0, 1 ether, minA);
    }

    function test_removeLiquidity_reverts_on_slippage() public {
        uint256 rWad = 100 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(kWad, rWad, maxA);

        uint256[] memory minA = new uint256[](3);
        minA[0] = minA[1] = minA[2] = type(uint256).max; // impossibly high
        vm.expectRevert();
        hook.removeLiquidity(0, rWad / 2, minA);
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

        uint256[] memory fees = hook.collect(0);

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
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(kWad, rWad, maxA);

        vm.expectRevert(OrbitalHook.NothingOwed.selector);
        hook.collect(0);
    }

    // ─────────────────────────────────────────────────────────────
    // Correctness fixes — soulbound shares, USDT-like, decimal guard
    // ─────────────────────────────────────────────────────────────

    function test_shares_cannot_be_transferred() public {
        uint256 rWad = 50 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(kWad, rWad, maxA);

        // Direct transfer.
        vm.expectRevert(OrbitalHook.SharesAreSoulbound.selector);
        hook.transfer(address(0xBEEF), 0, 1);

        // Indirect via approve + transferFrom.
        // (approve itself succeeds; the transferFrom is what reverts.)
        hook.approve(address(this), 0, type(uint256).max);
        vm.expectRevert(OrbitalHook.SharesAreSoulbound.selector);
        hook.transferFrom(address(this), address(0xBEEF), 0, 1);
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
            abi.encode(poolManager, permit2, list, uint24(100), address(this)),
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
            abi.encode(poolManager, permit2, list, uint24(100), address(this)),
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
            abi.encode(poolManager, permit2, regd, uint24(9), address(this)),
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
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, permit2, list, uint24(100), address(this)), flagged
        );
        OrbitalHook usdtHook = OrbitalHook(flagged);

        for (uint256 i = 0; i < 3; ++i) {
            tks[i].approve(address(usdtHook), type(uint256).max);
        }

        uint256 rWad = 100 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // Would revert with the old raw transferFrom; passes with SafeERC20.
        usdtHook.addLiquidity(kWad, rWad, maxA);
        assertEq(usdtHook.balanceOf(address(this), 0), rWad);
    }

    // ─────────────────────────────────────────────────────────────
    // Pair-view state sharing across pools
    // ─────────────────────────────────────────────────────────────

    function test_swaps_on_different_pair_views_share_engine_state() public {
        uint256 r = 1_000 ether;
        uint256 kWad = (TickLib.kMin(r, 3) + TickLib.kMax(r, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(kWad, r, maxA);

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
        uint256 kWad = (TickLib.kMin(r, 3) + TickLib.kMax(r, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // Both LPs mint into the same tick.
        hook.addLiquidity(kWad, r, maxA);
        vm.prank(lpB);
        hook.addLiquidity(kWad, r, maxA);

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(hook))});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Drive a swap to generate fees.
        swapRouter.swapExactTokensForTokens(10 ether, 0, true, key, "", address(this), block.timestamp);

        // Both LPs collect.
        uint256[] memory feesA = hook.collect(0);
        vm.prank(lpB);
        uint256[] memory feesB = hook.collect(0);

        // Same liquidity → same fee on the input asset (within 1 wei of rounding).
        assertApproxEqAbs(feesA[0], feesB[0], 1, "asset0 fee split 50/50");
    }

    // ─────────────────────────────────────────────────────────────
    // Admin: pause / unpause
    // ─────────────────────────────────────────────────────────────

    function test_pause_blocks_addLiquidity() public {
        hook.pause();
        uint256 rWad = 50 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.addLiquidity(kWad, rWad, maxA);
    }

    function test_pause_blocks_swap() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);
        hook.pause();
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, key, "", address(this), block.timestamp);
    }

    function test_pause_does_NOT_block_removeLiquidity() public {
        uint256 rWad = 100 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        hook.addLiquidity(kWad, rWad, maxA);

        hook.pause();
        uint256[] memory minA = new uint256[](3);
        // Should NOT revert — LPs must always be able to exit.
        hook.removeLiquidity(0, rWad, minA);
    }

    function test_pause_does_NOT_block_collect() public {
        PoolKey memory key = _seedSinglePoolWithLiquidity(1_000 ether);
        // Generate a fee.
        swapRouter.swapExactTokensForTokens(10 ether, 0, true, key, "", address(this), block.timestamp);

        hook.pause();
        // collect must still work while paused.
        uint256[] memory fees = hook.collect(0);
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
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        // Should now succeed.
        hook.addLiquidity(kWad, rWad, maxA);
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
    // addLiquidityViaPermit2
    // ─────────────────────────────────────────────────────────────

    function test_addLiquidityViaPermit2_works() public {
        // Grant permit2 spending allowance to the hook for each registered asset.
        for (uint8 i = 0; i < 3; ++i) {
            Currency c = i == 0 ? c0 : (i == 1 ? c1 : c2);
            permit2.approve(Currency.unwrap(c), address(hook), type(uint160).max, type(uint48).max);
        }
        // The MockERC20 was already approved to permit2 in deployToken().

        uint256 rWad = 100 ether;
        uint256 kWad = (TickLib.kMin(rWad, 3) + TickLib.kMax(rWad, 3)) / 2;
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;

        // Revoke direct allowance so the only working path is permit2.
        MockERC20(Currency.unwrap(c0)).approve(address(hook), 0);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), 0);
        MockERC20(Currency.unwrap(c2)).approve(address(hook), 0);

        (uint256 tickIdx,) = hook.addLiquidityViaPermit2(kWad, rWad, maxA);
        assertEq(hook.balanceOf(address(this), tickIdx), rWad, "shares minted via permit2 path");
    }

    function test_addLiquidityViaPermit2_pause_blocks() public {
        hook.pause();
        uint256[] memory maxA = new uint256[](3);
        maxA[0] = maxA[1] = maxA[2] = type(uint256).max;
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.addLiquidityViaPermit2(1 ether, 1 ether, maxA);
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
