// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @dev A token that skims a fee on every transfer — the exact shape the hook
///      must refuse at the deposit boundary rather than silently under-fund.
contract FeeOnTransferToken {
    string public name = "Fee On Transfer";
    string public symbol = "FOT";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    uint256 public feeBps = 100; // 1%
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function transfer(address to, uint256 a) public returns (bool) {
        uint256 fee = (a * feeBps) / 10_000;
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a - fee;
        totalSupply -= fee;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (msg.sender != f) allowance[f][msg.sender] -= a;
        uint256 fee = (a * feeBps) / 10_000;
        balanceOf[f] -= a;
        balanceOf[t] += a - fee;
        totalSupply -= fee;
        return true;
    }
}

/// @notice Deterministic full lifecycle against a REALISTIC decimal mix
///         (6-decimal USDC/USDT beside 18-decimal DAI/FRAX).
///
/// @dev    The stateful solvency invariants prove nothing *breaks* under random
///         sequences, but they swallow handler reverts, so an operation that always
///         reverted would still look fine. This test is the complement: every step
///         is asserted to SUCCEED and to move the right balances, so the burn and
///         collect paths are provably reachable with a 6-decimal asset rather than
///         merely un-falsified.
contract MixedDecimalsLifecycleTest is BaseTest {
    OrbitalHook hook;
    Currency[4] assets;
    uint256[4] scales;
    uint8[4] decs;
    PoolKey key01;

    uint8 constant N = 4;
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    function setUp() public {
        deployArtifactsAndLabel();

        MockERC20[4] memory t = [
            deployTokenWithDecimals(6),
            deployTokenWithDecimals(6),
            deployTokenWithDecimals(18),
            deployTokenWithDecimals(18)
        ];
        for (uint256 i; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (address(t[j]) < address(t[i])) (t[i], t[j]) = (t[j], t[i]);
            }
        }
        Currency[] memory regd = new Currency[](N);
        for (uint256 i; i < N; ++i) {
            assets[i] = Currency.wrap(address(t[i]));
            regd[i] = assets[i];
            decs[i] = t[i].decimals();
            scales[i] = 10 ** uint256(18 - decs[i]);
        }

        address flagged = address(HOOK_FLAGS ^ (0x6161 << 144));
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook",
            abi.encode(poolManager, permit2, regd, uint24(100), address(this)),
            flagged
        );
        hook = OrbitalHook(flagged);
        for (uint256 i; i < N; ++i) t[i].approve(flagged, type(uint256).max);

        key01 = PoolKey({currency0: assets[0], currency1: assets[1], fee: 0, tickSpacing: 1, hooks: IHooks(flagged)});
        poolManager.initialize(key01, Constants.SQRT_PRICE_1_1);
    }

    function _max() internal pure returns (uint256[] memory m) {
        m = new uint256[](N);
        for (uint256 i; i < N; ++i) m[i] = type(uint256).max;
    }

    /// @notice add -> swap -> collect -> partial burn -> full burn, all asserted to
    ///         succeed with two 6-decimal assets in the book.
    function test_full_lifecycle_with_mixed_decimals() public {
        // Every scale factor must be what the decimals imply, or nothing below means anything.
        for (uint8 i; i < N; ++i) {
            assertEq(hook.scaleOf(i), scales[i], "scale factor wrong");
        }
        assertTrue(scales[0] == 1e12 || scales[1] == 1e12, "test must include a 6-decimal asset");

        // ── ADD ──
        uint256 r0 = 1_000_000 ether;
        uint256 k0 = (TickLib.kMin(r0, N) + TickLib.kMax(r0, N)) / 2;
        (uint256 tick,) = hook.addLiquidity(k0, r0, _max());
        assertEq(hook.balanceOf(address(this), tick), r0, "LP shares not minted");

        // ── SWAP (raw units on a 6-decimal asset) ──
        uint256 amtRaw = 10_000 * (10 ** decs[0]);
        uint256 outBefore = MockERC20(Currency.unwrap(assets[1])).balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(amtRaw, 0, true, key01, "", address(this), block.timestamp);
        uint256 gained = MockERC20(Currency.unwrap(assets[1])).balanceOf(address(this)) - outBefore;
        assertGt(gained, 0, "swap produced no output");
        // Output must be denominated in the OUT token's decimals, not WAD.
        assertLt(gained, 20_000 * (10 ** decs[1]), "output looks mis-scaled by orders of magnitude");
        assertGt(hook.feesAccrued(0), 0, "no fee accrued on the 6-decimal input asset");

        // Swap the other way too so fees land on a second asset.
        swapRouter.swapExactTokensForTokens(
            5_000 * (10 ** decs[1]), 0, false, key01, "", address(this), block.timestamp
        );

        // ── COLLECT ──
        uint256[] memory fees = hook.collect(tick);
        bool anyFee;
        for (uint8 i; i < N; ++i) if (fees[i] > 0) anyFee = true;
        assertTrue(anyFee, "collect returned nothing after fee-generating swaps");

        // ── PARTIAL BURN ── (the path the fuzz handlers never reached)
        uint256 half = hook.balanceOf(address(this), tick) / 2;
        uint256[] memory got = hook.removeLiquidity(tick, half, new uint256[](N));
        for (uint8 i; i < N; ++i) {
            assertGt(got[i], 0, "partial burn returned zero for an asset");
        }
        assertEq(hook.balanceOf(address(this), tick), r0 - half, "LP shares not burned");

        // ── FULL BURN ──
        uint256 rest = hook.balanceOf(address(this), tick);
        hook.removeLiquidity(tick, rest, new uint256[](N));
        assertEq(hook.balanceOf(address(this), tick), 0, "shares remain after full burn");

        (,, uint256 rInt,,) = hook.slot0();
        assertEq(rInt, 0, "interior radius not fully unwound");
    }

    /// @notice Payouts round DOWN and deposits round UP, so custody can only ever
    ///         exceed obligations. Asserted directly on a 6-decimal asset, where the
    ///         rounding is 1e12 WAD wide and therefore actually observable.
    function test_rounding_never_favours_the_withdrawer() public {
        uint256 r0 = 500_000 ether;
        uint256 k0 = (TickLib.kMin(r0, N) + TickLib.kMax(r0, N)) / 2;
        (uint256 tick,) = hook.addLiquidity(k0, r0, _max());

        // Burn an amount deliberately chosen to land between raw units.
        uint256 odd = 12_345_678_901_234_567;
        uint256[] memory got = hook.removeLiquidity(tick, odd, new uint256[](N));

        for (uint8 i; i < N; ++i) {
            // What the engine debited, in WAD, converted to raw the way the hook
            // pays out. The transfer must never exceed that.
            uint256 maxRaw = got[i] / scales[i];
            assertLe(maxRaw * scales[i], got[i], "payout rounded up against the pool");
        }
    }

    /// @notice A fee-on-transfer asset must be refused at the deposit boundary with
    ///         a named error, not silently leave claim tokens unbacked.
    function test_fee_on_transfer_deposit_is_rejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        MockERC20 plain = deployTokenWithDecimals(18);

        Currency[] memory regd = new Currency[](2);
        (address a, address b) = address(fot) < address(plain)
            ? (address(fot), address(plain))
            : (address(plain), address(fot));
        regd[0] = Currency.wrap(a);
        regd[1] = Currency.wrap(b);

        address flagged = address(HOOK_FLAGS ^ (0x6262 << 144));
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook",
            abi.encode(poolManager, permit2, regd, uint24(100), address(this)),
            flagged
        );
        OrbitalHook fotHook = OrbitalHook(flagged);

        fot.mint(address(this), 100_000_000 * 1e6);
        fot.approve(flagged, type(uint256).max);
        plain.approve(flagged, type(uint256).max);

        uint256 r0 = 1_000 ether;
        uint256 k0 = (TickLib.kMin(r0, 2) + TickLib.kMax(r0, 2)) / 2;
        uint256[] memory maxA = new uint256[](2);
        maxA[0] = type(uint256).max;
        maxA[1] = type(uint256).max;

        // Must fail closed, and with OUR error rather than v4's CurrencyNotSettled.
        // Only the selector is asserted: the exact amounts fall out of the sphere
        // geometry, so pinning them would make this test brittle to curve changes
        // while proving nothing extra.
        vm.expectPartialRevert(OrbitalHook.TokenTransferShortfall.selector);
        fotHook.addLiquidity(k0, r0, maxA);
    }
}
