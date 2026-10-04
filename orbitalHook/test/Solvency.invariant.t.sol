// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {BandLib} from "../src/libraries/BandLib.sol";
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
    uint256[3] scales; // raw -> WAD multiplier per asset, as the hook must hold it
    PoolKey key01;
    uint256[] heldTicks;

    uint8 constant N = 3;
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    /// @dev Decimals for each of the three assets. Overridden per profile.
    function _decimals() internal pure virtual returns (uint8[3] memory);

    /// @dev Distinct hook address per profile so the runs cannot collide.
    function _hookSalt() internal pure virtual returns (uint160);

    /// @dev Deploy the hook under test at `flagged`, over the address-sorted
    ///      `regd`. A plain OrbitalHook by default; a profile may deploy a
    ///      subclass so the same handlers and invariants run against it.
    function _deployHook(Currency[] memory regd, address flagged) internal virtual {
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook",
            abi.encode(poolManager, regd, uint24(100), address(this)),
            flagged
        );
    }

    /// @dev The raw -> WAD scale the hook must hold for asset `i` (address
    ///      order) with `dec` decimals. `10^(18-dec)` unless a profile prices it.
    function _expectedScale(uint8, uint8 dec) internal view virtual returns (uint256) {
        return 10 ** uint256(18 - dec);
    }

    /// @dev Handlers the fuzzer may call. A profile may append its own.
    function _handlerSelectors() internal view virtual returns (bytes4[] memory sel) {
        sel = new bytes4[](7);
        sel[0] = this.h_add.selector;
        sel[1] = this.h_swap.selector;
        sel[2] = this.h_remove.selector;
        sel[3] = this.h_collect.selector;
        sel[4] = this.h_freeze.selector;
        sel[5] = this.h_claimOwed.selector;
        sel[6] = this.h_swapExactOut.selector;
    }

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
        }

        address flagged = address(HOOK_FLAGS ^ (_hookSalt() << 144));
        _deployHook(regd, flagged);
        hook = OrbitalHook(flagged);

        // Sanity: the hook must agree with us about the scaling factors, or every
        // assertion below is measuring the wrong thing. Decimals are read back off
        // the token: sorting above reshuffled `t`, so it no longer lines up with
        // the `dec` array it was built from.
        for (uint8 i = 0; i < N; ++i) {
            scales[i] = _expectedScale(i, t[i].decimals());
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
        (uint256 tick0,) = hook.addLiquidity(BandLib.bandOf(0.95e18), r0, _maxAmounts(), block.timestamp);
        heldTicks.push(tick0);

        targetSelector(FuzzSelector({addr: address(this), selectors: _handlerSelectors()}));
        targetContract(address(this));
    }

    // ── Handlers (reverts are swallowed: invalid random inputs just no-op) ──

    /// Any band, any size — including during a depeg, where a mint joins the
    /// interior by the paper's attribution and a pinned band is refused.
    function h_add(uint256 rSeed, uint256 bandSeed) public {
        uint256 r = bound(rSeed, 1 ether, 100_000 ether);
        uint256 band = bound(bandSeed, 0, BandLib.COUNT - 1);
        try hook.addLiquidity(band, r, _maxAmounts(), block.timestamp) returns (uint256 tickIdx, uint256[] memory) {
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

    /// The other half of the swap interface: the trader names the output and
    /// the engine solves for the input. Custody must hold either way round.
    function h_swapExactOut(uint256 amtSeed, uint256 dirSeed) public {
        bool zeroForOne = dirSeed % 2 == 0;
        uint8 outIdx = zeroForOne ? 1 : 0;

        uint256 resRaw = hook.reserves(outIdx) / scales[outIdx];
        uint256 minRaw = 1 ether / scales[outIdx];
        if (resRaw < 2 * minRaw) return;

        uint256 amtRaw = bound(amtSeed, minRaw, resRaw / 2);
        try swapRouter.swapTokensForExactTokens(
            amtRaw, type(uint256).max, zeroForOne, key01, "", address(this), block.timestamp
        ) {} catch {}
    }

    function h_remove(uint256 tickSeed, uint256 rSeed) public {
        if (heldTicks.length == 0) return;
        uint256 tick = heldTicks[tickSeed % heldTicks.length];
        uint256 bal = hook.balanceOf(address(this), tick);
        if (bal == 0) return;
        uint256 r = bound(rSeed, 1, bal);
        try hook.removeLiquidity(tick, r, new uint256[](N), block.timestamp) {} catch {}
    }

    /// The asset currently frozen, plus one (0 = none).
    uint8 frozenPlusOne;

    /// Freeze one asset the way an issuer pause does — nothing moves in or out
    /// of anyone's balance — or, if one is frozen, lift it. Withdrawals and fee
    /// collections then pay the other assets and hold the frozen one as `owed`.
    function h_freeze(uint256 seed) public {
        vm.clearMockedCalls();
        if (frozenPlusOne != 0) {
            frozenPlusOne = 0;
            return;
        }
        uint8 i = uint8(seed % N);
        address token = Currency.unwrap(assets[i]);
        vm.mockCallRevert(token, abi.encodeWithSignature("transfer(address,uint256)"), "PAUSED");
        vm.mockCallRevert(token, abi.encodeWithSignature("transferFrom(address,address,uint256)"), "PAUSED");
        frozenPlusOne = i + 1;
    }

    function h_claimOwed(uint256 seed) public {
        uint8 i = uint8(seed % N);
        uint256 before = hook.owed(address(this), i);
        try hook.claimOwed(i) returns (uint256 paid) {
            assertEq(paid, before, "claimOwed paid other than what was owed");
            assertTrue(frozenPlusOne != i + 1, "a frozen asset was paid out");
        } catch {
            // Nothing owed, or the asset is still frozen: the claim must stand.
            assertEq(hook.owed(address(this), i), before, "a failed claim changed what is owed");
        }
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
    ///
    ///         `reserves` is the engine's VIRTUAL reserve vector; the part the
    ///         pool actually owes in tokens is `reserves − virtualReserve`. On
    ///         top of that it owes the payouts it held back for frozen tokens
    ///         (`totalOwed`, raw).
    function invariant_pool_is_solvent() public view {
        for (uint8 i = 0; i < N; ++i) {
            uint256 id = uint256(uint160(Currency.unwrap(assets[i])));
            uint256 claimRaw = IERC6909Balance(address(poolManager)).balanceOf(address(hook), id);
            uint256 claimWad = claimRaw * scales[i];
            uint256 owedWad =
                hook.reserves(i) - hook.virtualReserve() + hook.feesAccrued(i) + hook.totalOwed(i) * scales[i];
            assertGe(claimWad, owedWad, "pool owes more WAD than its raw custody covers");
        }
    }

    /// @dev Storage slot of the hook's band bitmaps (`_interiorBands` in the low
    ///      128 bits, `_pinnedBands` in the high). Read it off the contract with
    ///
    ///          forge inspect src/OrbitalHook.sol:OrbitalHook storageLayout
    ///
    ///      and update it when the layout moves: the invariant below then reads
    ///      the wrong word and fails loudly rather than passing vacuously.
    uint256 constant BAND_BITS_SLOT = 111;

    /// @notice The band bitmaps are the only record of which side of its plane
    ///         each band is on, so they must match the liquidity exactly: a
    ///         band is live on exactly one side iff it holds liquidity. A stale
    ///         bit on an empty band would make crossing detection pick it, or
    ///         refuse deposits into it forever.
    function invariant_band_bitmaps_match_liquidity() public view {
        uint256 word = uint256(vm.load(address(hook), bytes32(BAND_BITS_SLOT)));
        uint256 interior = word & type(uint128).max;
        uint256 pinned = word >> 128;
        assertEq(interior & pinned, 0, "a band is both interior and pinned");
        uint256 n = hook.numTicks();
        assertEq((interior | pinned) >> n, 0, "a bit is set past the last band");
        for (uint256 b = 0; b < n; ++b) {
            (, uint256 r,) = hook.ticks(b);
            bool live = ((interior | pinned) >> b) & 1 == 1;
            assertEq(live, r > 0, "a band's bit does not match its liquidity");
        }
    }

    /// @notice Held-back payouts are accounted exactly: the one account that
    ///         withdraws here is owed the whole of `totalOwed`.
    function invariant_owed_adds_up() public view {
        for (uint8 i = 0; i < N; ++i) {
            assertEq(hook.totalOwed(i), hook.owed(address(this), i), "totalOwed drifted from the per-account sum");
        }
    }

    /// @notice No asset's reserve ever falls below the virtual floor: the real
    ///         part of every reserve stays non-negative through any sequence of
    ///         mints, swaps (including tick crossings) and burns.
    function invariant_reserves_cover_the_virtual_floor() public view {
        uint256 v = hook.virtualReserve();
        for (uint8 i = 0; i < N; ++i) {
            assertGe(hook.reserves(i), v, "a reserve fell below the virtual floor");
        }
    }

    /// @notice The pool's virtual reserve is exactly the sum over live ticks:
    ///         mint adds a tick's share, burn removes the burned part, and
    ///         nothing else touches either.
    function invariant_virtual_reserve_is_the_sum_over_ticks() public view {
        uint256 sum;
        uint256 n = hook.numTicks();
        for (uint256 t = 0; t < n; ++t) {
            (, uint256 r,) = hook.ticks(t);
            if (r == 0) assertEq(hook.tickVirtual(t), 0, "a dead tick still carries virtual reserve");
            sum += hook.tickVirtual(t);
        }
        assertEq(sum, hook.virtualReserve(), "virtualReserve drifted from the per-tick sum");
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
            uint256 owedWad = hook.reserves(i) - hook.virtualReserve() + hook.feesAccrued(i);
            // Raw units needed to cover the WAD obligation, rounded up, plus the
            // held-back payouts, already raw.
            uint256 neededRaw = (owedWad + scales[i] - 1) / scales[i] + hook.totalOwed(i);
            assertGe(claimRaw, neededRaw, "rounding leaked value out of the pool");
        }
    }

    /// @notice The raw <-> WAD scale is fixed for the pool's lifetime.
    /// @dev    Reserves, radii and fees are stored in WAD against raw custody, so
    ///         a scale that moved after the first mint would silently
    ///         re-denominate every stored figure. `_setScale` forbids it; this
    ///         proves no handler sequence gets around that.
    function invariant_scale_never_changes() public view {
        for (uint8 i = 0; i < N; ++i) {
            assertEq(hook.scaleOf(i), scales[i], "scale changed after liquidity existed");
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
