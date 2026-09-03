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

interface IERC6909Balance {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

/// @notice Stateful invariant: the hook must always stay SOLVENT. For every asset,
///         the real claim-token balance the hook holds in the PoolManager must cover
///         everything it owes — the tracked reserves plus accrued fees. A random
///         sequence of add/swap/remove/collect (including depeg crossings) must never
///         create phantom value or let the pool owe more than it holds.
///
/// @dev    ABSTRACT so the same handler set runs against more than one decimal
///         profile. Solvency depends on the raw<->WAD scaling getting its rounding
///         directions right at four separate boundaries (swap in, swap out, deposit,
///         payout), and an all-18-decimal run makes every one of those a no-op
///         (`_scale == 1`), so it proves nothing about them. `MixedDecimals` below is
///         the run that actually exercises the layer.
abstract contract SolvencyInvariantBase is BaseTest {
    OrbitalHook hook;
    Currency[3] assets;
    uint256[3] scales; // 10^(18-decimals) per asset
    PoolKey key01;
    uint256[] heldTicks;


    uint8 constant N = 3;
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    /// @dev Decimals for each of the three assets. Overridden per profile.
    function _decimals() internal pure virtual returns (uint8[3] memory);

    /// @dev Distinct hook address per profile so the two runs cannot collide.
    function _hookSalt() internal pure virtual returns (uint160);

    function setUp() public {
        deployArtifactsAndLabel();

        uint8[3] memory dec = _decimals();
        MockERC20[3] memory t = [
            deployTokenWithDecimals(dec[0]),
            deployTokenWithDecimals(dec[1]),
            deployTokenWithDecimals(dec[2])
        ];
        // The hook requires assets sorted ascending by address.
        for (uint256 i = 0; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (address(t[j]) < address(t[i])) (t[i], t[j]) = (t[j], t[i]);
            }
        }
        Currency[] memory regd = new Currency[](N);
        for (uint256 i = 0; i < N; ++i) {
            assets[i] = Currency.wrap(address(t[i]));
            regd[i] = assets[i];
            // Read decimals back off the token: sorting above reshuffled `t`, so it
            // no longer lines up with the `dec` array it was built from.
            scales[i] = 10 ** uint256(18 - t[i].decimals());
        }

        address flagged = address(HOOK_FLAGS ^ (_hookSalt() << 144));
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook",
            abi.encode(poolManager, permit2, regd, uint24(100), address(this)),
            flagged
        );
        hook = OrbitalHook(flagged);

        // Sanity: the hook must agree with us about the scaling factors, or every
        // assertion below is measuring the wrong thing.
        for (uint8 i = 0; i < N; ++i) {
            assertEq(hook.scaleOf(i), scales[i], "scale mismatch between test and hook");
        }

        for (uint256 i = 0; i < N; ++i) {
            t[i].approve(address(hook), type(uint256).max);
        }

        key01 = PoolKey({
            currency0: assets[0],
            currency1: assets[1],
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(flagged)
        });
        poolManager.initialize(key01, Constants.SQRT_PRICE_1_1);

        // Seed a wide base position so swaps have depth from the start.
        uint256 r0 = 1_000_000 ether;
        uint256 k0 = (TickLib.kMin(r0, N) + TickLib.kMax(r0, N)) / 2;
        (uint256 tick0,) = hook.addLiquidity(k0, r0, _maxAmounts());
        heldTicks.push(tick0);

        bytes4[] memory sel = new bytes4[](4);
        sel[0] = this.h_add.selector;
        sel[1] = this.h_swap.selector;
        sel[2] = this.h_remove.selector;
        sel[3] = this.h_collect.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
        targetContract(address(this));
    }

    // ── Handlers (reverts are swallowed: invalid random inputs just no-op) ──

    function h_add(uint256 rSeed, uint256 kSeed) public {
        uint256 r = bound(rSeed, 1 ether, 100_000 ether);
        uint256 k = bound(kSeed, TickLib.kMin(r, N), TickLib.kMax(r, N));
        try hook.addLiquidity(k, r, _maxAmounts()) returns (uint256 tickIdx, uint256[] memory) {
            _track(tickIdx);
        } catch {}
    }

    function h_swap(uint256 amtSeed, uint256 dirSeed) public {
        bool zeroForOne = dirSeed % 2 == 0;
        uint8 inIdx = zeroForOne ? 0 : 1;

        // `reserves` is WAD; the router takes the token's RAW units. Feeding it a
        // WAD figure would overstate a 6-decimal amount by 1e12 and the handler
        // would revert every time, silently gutting the swap coverage.
        uint256 resWad = hook.reserves(inIdx);
        uint256 resRaw = resWad / scales[inIdx];
        // One whole token, expressed in this asset's raw units (1e18 for an
        // 18-decimal asset, 1e6 for a 6-decimal one). Also comfortably above the
        // point where the 1bp fee would floor to zero and the hook would reject
        // the swap as dust.
        uint256 minRaw = 1 ether / scales[inIdx];
        if (resRaw < 2 * minRaw) return;

        uint256 amtRaw = bound(amtSeed, minRaw, resRaw / 2);
        try swapRouter.swapExactTokensForTokens(
            amtRaw, 0, zeroForOne, key01, "", address(this), block.timestamp
        ) {} catch {}
    }

    function h_remove(uint256 tickSeed, uint256 rSeed) public {
        if (heldTicks.length == 0) return;
        uint256 tick = heldTicks[tickSeed % heldTicks.length];
        uint256 bal = hook.balanceOf(address(this), tick);
        if (bal == 0) return;
        uint256 r = bound(rSeed, 1, bal);
        try hook.removeLiquidity(tick, r, new uint256[](N)) {} catch {}
    }

    function h_collect(uint256 tickSeed) public {
        if (heldTicks.length == 0) return;
        uint256 tick = heldTicks[tickSeed % heldTicks.length];
        // NothingOwed is fine, but FeeBucketShort would mean total owed fees
        // exceeded the bucket — the exact symptom of fee over-attribution.
        try hook.collect(tick) {}
        catch (bytes memory reason) {
            if (reason.length >= 4) {
                assertTrue(
                    bytes4(reason) != OrbitalHook.FeeBucketShort.selector,
                    "FeeBucketShort: fee over-attribution"
                );
            }
        }
    }

    // ── The invariant ──

    /// @notice Real custody must cover the engine's obligations, for every asset.
    /// @dev    Claim tokens are held in the token's RAW units; `reserves` and
    ///         `feesAccrued` are WAD. Comparing them directly is only valid when
    ///         `scale == 1`, so the claim balance is lifted into WAD first. This is
    ///         what makes the assertion meaningful for a 6-decimal asset.
    function invariant_pool_is_solvent() public view {
        for (uint8 i = 0; i < N; ++i) {
            uint256 id = uint256(uint160(Currency.unwrap(assets[i])));
            uint256 claimRaw = IERC6909Balance(address(poolManager)).balanceOf(address(hook), id);
            uint256 claimWad = claimRaw * scales[i];
            uint256 owedWad = hook.reserves(i) + hook.feesAccrued(i);
            assertGe(claimWad, owedWad, "pool owes more WAD than its raw custody covers");
        }
    }

    /// @notice A payout must never be roundable up into insolvency.
    /// @dev    Every WAD->raw payout rounds DOWN and every raw->WAD deposit rounds
    ///         UP, so residual dust can only ever accumulate in the pool's favour.
    ///         Asserting the surplus is non-negative in RAW units catches a
    ///         rounding direction being flipped anywhere in the scaling layer.
    function invariant_rounding_favours_the_pool() public view {
        for (uint8 i = 0; i < N; ++i) {
            uint256 id = uint256(uint160(Currency.unwrap(assets[i])));
            uint256 claimRaw = IERC6909Balance(address(poolManager)).balanceOf(address(hook), id);
            uint256 owedWad = hook.reserves(i) + hook.feesAccrued(i);
            // Raw units needed to cover the WAD obligation, rounded up.
            uint256 neededRaw = (owedWad + scales[i] - 1) / scales[i];
            assertGe(claimRaw, neededRaw, "rounding leaked value out of the pool");
        }
    }

    // ── helpers ──

    function _maxAmounts() internal pure returns (uint256[] memory m) {
        m = new uint256[](N);
        for (uint256 i = 0; i < N; ++i) m[i] = type(uint256).max;
    }

    function _track(uint256 t) internal {
        for (uint256 i = 0; i < heldTicks.length; ++i) {
            if (heldTicks[i] == t) return;
        }
        heldTicks.push(t);
    }
}

/// @notice All-18-decimal profile. Every scale factor is 1, so this run covers the
///         engine but deliberately says nothing about the scaling layer.
contract SolvencyInvariantAll18 is SolvencyInvariantBase {
    function _decimals() internal pure override returns (uint8[3] memory) {
        return [18, 18, 18];
    }

    function _hookSalt() internal pure override returns (uint160) {
        return 0x4444;
    }
}

/// @notice The profile that matters: two 6-decimal assets (USDC/USDT shaped) beside
///         an 18-decimal one, so `_scale` is 1e12 for two of the three and every
///         raw<->WAD conversion in the hook is live under the fuzzer.
contract SolvencyInvariantMixedDecimals is SolvencyInvariantBase {
    function _decimals() internal pure override returns (uint8[3] memory) {
        return [6, 6, 18];
    }

    function _hookSalt() internal pure override returns (uint160) {
        return 0x5555;
    }
}
