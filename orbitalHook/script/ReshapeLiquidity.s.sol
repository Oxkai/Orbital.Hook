// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TierLadder} from "./lib/TierLadder.sol";

/// @notice Move a live pool onto the current `TierLadder` in place: seed the
///         new ladder, then withdraw every position the broadcaster held
///         before it and collect those positions' fees. Same hook, same
///         address, no redeploy; other LPs' positions are left untouched.
///
/// @dev    The new ladder is added BEFORE the old positions are withdrawn, so
///         the pool is never thin in between. Neither step moves the price: a
///         mint or burn changes every interior tick's reserves in proportion.
///
///         The pool must be fully interior (kBound == 0), since burns are gated
///         on it, and inside the ladder's narrowest band, since a mint outside
///         its band reverts. Both are checked before anything is sent, so a
///         pool that needs rebalancing stops here with a reason rather than
///         half-way through.
///
///         Each withdrawal is floored at its exact expected payout less
///         `BURN_SLIPPAGE_BPS`, computed from the pool state just before it:
///         the pro-rata share of reserves less the tick's virtual floor, which
///         is what the hook pays while every tick is interior.
///
///         Env: HOOK               the pool's hook (OrbitalHook or OrbitalFXHook)
///              PROFILE            STABLE (default) or FX
///              CAPITAL_PER_ASSET  real WAD value per asset, default the ladder's
///
///         forge script script/ReshapeLiquidity.s.sol --rpc-url arc_testnet \
///             --broadcast --slow --private-key $PRIVATE_KEY
contract ReshapeLiquidityScript is Script {
    uint256 internal constant BURN_SLIPPAGE_BPS = 10;

    struct Held {
        uint256 tick;
        uint256 r;
    }

    function run() external {
        OrbitalHook hook = OrbitalHook(vm.envAddress("HOOK"));
        TierLadder.Profile profile = _profile(vm.envOr("PROFILE", string("STABLE")));
        uint256 capital = vm.envOr("CAPITAL_PER_ASSET", TierLadder.DEFAULT_CAPITAL_PER_ASSET);
        uint8 n = hook.N();

        _checkReady(hook, profile, n, capital);
        Held[] memory old = _held(hook, msg.sender);
        require(old.length > 0, "broadcaster holds no positions in this pool");

        console2.log("=========== RESHAPE ===========");
        console2.log("hook:   ", address(hook));
        console2.log("profile:", profile == TierLadder.Profile.STABLE ? "STABLE" : "FX");
        console2.log("capital per asset (wad):", capital);
        _logPool(hook, n, "before");

        vm.startBroadcast();
        _approveAll(hook, n);
        console2.log("--- seeding the new ladder ---");
        TierLadder.seed(hook, n, profile, capital);
        console2.log("--- withdrawing the old positions ---");
        for (uint256 i = 0; i < old.length; ++i) {
            _withdraw(hook, n, old[i]);
        }
        vm.stopBroadcast();

        _logPool(hook, n, "after");
    }

    // ─────────────────────────────── checks ──────────────────────────────────

    /// @dev Stop before broadcasting if a step would revert on-chain.
    function _checkReady(OrbitalHook hook, TierLadder.Profile profile, uint8 n, uint256 capital) internal view {
        (,,, uint256 kBound,) = hook.slot0();
        require(kBound == 0, "a tick is on its boundary: rebalance the pool first");

        // Tier 0 is the narrowest band; the pool must still be inside it.
        uint256 r0 = TierLadder.radii(profile, n, capital)[0];
        uint256 k0 = TierLadder.plane(r0, n, TierLadder.bound(profile, 0));
        try hook.depositAmounts(k0, r0) returns (uint256[] memory) {}
        catch {
            revert("pool price is outside the ladder's narrowest band: rebalance the pool first");
        }
    }

    /// @dev Every position `owner` holds, read before the new ladder is seeded
    ///      (a mint may recycle a dead tick slot, so ticks are listed now).
    function _held(OrbitalHook hook, address owner) internal view returns (Held[] memory held) {
        uint256 count = hook.numTicks();
        Held[] memory all = new Held[](count);
        uint256 len;
        for (uint256 t = 0; t < count; ++t) {
            uint256 r = hook.balanceOf(owner, t);
            if (r > 0) all[len++] = Held({tick: t, r: r});
        }
        held = new Held[](len);
        for (uint256 i = 0; i < len; ++i) held[i] = all[i];
    }

    // ─────────────────────────────── actions ─────────────────────────────────

    function _approveAll(OrbitalHook hook, uint8 n) internal {
        for (uint8 i = 0; i < n; ++i) {
            IERC20 token = IERC20(Currency.unwrap(hook.assetAt(i)));
            if (token.allowance(msg.sender, address(hook)) < type(uint128).max) {
                token.approve(address(hook), type(uint256).max);
            }
        }
    }

    /// @dev Burn a whole position with a slippage floor, then collect its fees.
    function _withdraw(OrbitalHook hook, uint8 n, Held memory h) internal {
        (,, uint256 rInt,,) = hook.slot0();
        uint256 virtOut = hook.tickVirtual(h.tick);
        (, uint256 tickR,,,) = hook.ticks(h.tick);
        if (h.r != tickR) virtOut = FullMath.mulDiv(virtOut, h.r, tickR);

        uint256[] memory minOut = new uint256[](n);
        for (uint8 i = 0; i < n; ++i) {
            uint256 expected = FullMath.mulDiv(hook.reserves(i), h.r, rInt) - virtOut;
            minOut[i] = expected - expected * BURN_SLIPPAGE_BPS / 10_000;
        }

        uint256[] memory paid = hook.removeLiquidity(h.tick, h.r, minOut);
        uint256[] memory fees = hook.collect(h.tick);
        console2.log("  withdrew tick", h.tick, "r:", h.r);
        console2.log("    paid (wad, asset 0):", paid[0], "fees (wad, asset 0):", fees[0]);
    }

    // ─────────────────────────────── report ──────────────────────────────────

    function _logPool(OrbitalHook hook, uint8 n, string memory label) internal view {
        (uint256 sumX,, uint256 rInt, uint256 kBound,) = hook.slot0();
        console2.log(string.concat("--- pool ", label, " ---"));
        console2.log("  rInt:           ", rInt);
        console2.log("  kBound:         ", kBound);
        console2.log("  TVL (real, wad):", sumX - uint256(n) * hook.virtualReserve());
        for (uint8 i = 0; i < n; ++i) {
            console2.log("  real reserve", i, hook.reserves(i) - hook.virtualReserve());
        }
    }

    function _profile(string memory name) internal pure returns (TierLadder.Profile) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("STABLE")) return TierLadder.Profile.STABLE;
        if (h == keccak256("FX")) return TierLadder.Profile.FX;
        revert("PROFILE must be STABLE or FX");
    }
}
