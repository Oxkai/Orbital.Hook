// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TierLadder} from "./lib/TierLadder.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Multi-LP activity against a LIVE deployment.
///
/// @dev    `SimulateMultiLP.s.sol` proves the same flows but only on anvil: it
///         relies on anvil's pre-unlocked accounts, so a live pool ends up with a
///         single LP (the deployer) and the Positions page has nothing
///         interesting in it. This script derives three LP accounts plus a
///         swapper deterministically, funds them a little gas from the deployer,
///         lets them self-mint the mock stables, and has each LP take a DIFFERENT
///         tick so the pool genuinely has several independent positions.
///
///         Self-describing: the asset set and decimals are read off the hook, so
///         it survives redeploys and differing decimal mixes per chain.
///
///         SEEDED: every size, band, pair and exit follows from `ACTIVITY_SEED`,
///         so each pool gets its own history instead of an identical one, and a
///         run is reproducible from its seed.
///
///         Each LP deposits a random amount of capital (`LP_MIN_CAPITAL` to
///         `LP_MAX_CAPITAL` of every asset) into a random band; the radius that
///         buys it is read off the pool's own `depositAmounts` quote, so the
///         pool's TVL grows by what the LPs actually put in. Swaps are sized as
///         a fraction of the input asset's REAL reserve (tokens held, not the
///         virtual reserve the engine quotes on) and mixed like real flow: most
///         are retail, up to a tenth of `MAX_SWAP_BPS`, and about three in ten
///         are large, up to `MAX_SWAP_BPS`. Liquidity actions are skipped, with
///         a log line, whenever a tick sits on its boundary, since mint and
///         burn are blocked then.
///
///         BALANCED: before, between and after the swap waves an arbitrage
///         pass brings every reserve back to within 0.02% of the mean (selling
///         the scarcest asset for the most abundant), the flow that holds a
///         real stable pool at parity, so the pool is left with tight quotes
///         rather than drifted by one-sided random trades.
///
///         Required env: ORBITAL_HOOK, V4_ROUTER, V4_QUOTER
///         Optional env: ACTIVITY_SEED (default 1)
///                       MAX_SWAP_BPS  (bps of the input asset's real reserve,
///                                      default 200)
///                       GAS_PER_ACTOR (wei, default 0.004 ether)
///                       REBALANCE_ONLY (default false): only run the parity
///                                      pass, no LP or swap-wave activity
contract SimulateMultiLPLiveScript is Script {
    OrbitalHook hook;
    IUniswapV4Router04 router;
    IV4Quoter quoter;
    uint8 n;
    address[] toks;
    uint8[] decs;

    uint256 seed;
    uint256 nonce;
    uint256 maxSwapBps;

    /// @dev Band bounds an LP may pick, WAD; 0 is full range.
    uint256[7] BOUNDS = [uint256(0.985e18), 0.97e18, 0.95e18, 0.92e18, 0.88e18, 0.85e18, 0];

    /// @dev Capital an LP deposits of EVERY asset (WAD value units).
    uint256 constant LP_MIN_CAPITAL = 10_000 ether;
    uint256 constant LP_MAX_CAPITAL = 100_000 ether;

    /// @dev Share of swaps that are large (out of 10); the rest are retail.
    uint256 constant LARGE_SWAPS_IN_10 = 3;

    // Deterministic throwaway actors. Derived, not hardcoded, so this file
    // carries no key material and the addresses follow from the label alone.
    uint256 constant PK_ALICE = uint256(keccak256("orbital.live.lp.alice"));
    uint256 constant PK_BOB = uint256(keccak256("orbital.live.lp.bob"));
    uint256 constant PK_CAROL = uint256(keccak256("orbital.live.lp.carol"));
    uint256 constant PK_SWAPPER = uint256(keccak256("orbital.live.swapper"));

    function run() external {
        hook = OrbitalHook(vm.envAddress("ORBITAL_HOOK"));
        router = IUniswapV4Router04(payable(vm.envAddress("V4_ROUTER")));
        quoter = IV4Quoter(vm.envAddress("V4_QUOTER"));
        uint256 gasPerActor = vm.envOr("GAS_PER_ACTOR", uint256(0.004 ether));
        seed = vm.envOr("ACTIVITY_SEED", uint256(1));
        maxSwapBps = vm.envOr("MAX_SWAP_BPS", uint256(200));
        require(maxSwapBps > 0 && maxSwapBps <= 500, "MAX_SWAP_BPS out of range");

        n = hook.N();
        for (uint8 i = 0; i < n; ++i) {
            address t = Currency.unwrap(hook.assetAt(i));
            toks.push(t);
            decs.push(IERC20(t).decimals());
        }

        uint256[3] memory pks = [PK_ALICE, PK_BOB, PK_CAROL];
        string[3] memory names = ["alice", "bob", "carol"];
        address swapper = vm.addr(PK_SWAPPER);

        console2.log("=== seed", seed, "max swap bps", maxSwapBps);
        _logState("initial");
        _logSpread();

        if (vm.envOr("REBALANCE_ONLY", false)) {
            vm.startBroadcast();
            _fund(swapper, gasPerActor);
            vm.stopBroadcast();
            _rebalance();
            _logState("rebalanced");
            _logSpread();
            return;
        }

        // ── fund gas ──
        vm.startBroadcast();
        for (uint256 a = 0; a < 3; ++a) _fund(vm.addr(pks[a]), gasPerActor);
        _fund(swapper, gasPerActor);
        vm.stopBroadcast();

        // Start from parity, whatever earlier activity left behind.
        _rebalance();

        // ── three LPs, each with its own capital and band ──
        uint256[3] memory ticks_;
        for (uint256 a = 0; a < 3; ++a) {
            uint256 capital = LP_MIN_CAPITAL + _rand(LP_MAX_CAPITAL - LP_MIN_CAPITAL + 1);
            uint256 b = BOUNDS[_rand(BOUNDS.length)];
            ticks_[a] = _lpJoin(pks[a], capital, b, names[a]);
        }
        _logState("after LPs joined");

        // ── first swap wave ──
        _swapWave(8 + _rand(7));
        _rebalance();
        _logState("after swap wave 1");

        // ── each LP collects its own share ──
        for (uint256 a = 0; a < 3; ++a) _collect(pks[a], ticks_[a], names[a]);

        // ── exits: one partial, one possibly full, one stays whole ──
        uint256 partialLp = _rand(3);
        uint256 otherLp = (partialLp + 1 + _rand(2)) % 3;
        _burnPart(pks[partialLp], ticks_[partialLp], names[partialLp], 20 + _rand(61)); // 20..80%
        if (_rand(2) == 0) _burnPart(pks[otherLp], ticks_[otherLp], names[otherLp], 100);

        // ── second swap wave on the reshaped book ──
        _swapWave(4 + _rand(6));
        _rebalance();
        _logState("final");
        _logSpread();

        console2.log("=== positions ===");
        for (uint256 a = 0; a < 3; ++a) {
            if (ticks_[a] == type(uint256).max) continue;
            console2.log(string.concat("  ", names[a], " @tick"), ticks_[a], hook.balanceOf(vm.addr(pks[a]), ticks_[a]));
        }
    }

    /// @dev Next deterministic value in [0, bound).
    function _rand(uint256 bound) internal returns (uint256) {
        return uint256(keccak256(abi.encode(seed, nonce++))) % bound;
    }

    /// @dev `count` swaps on random distinct pairs, each a random fraction of
    ///      the input asset's real reserve: from 1 bp up to a tenth of
    ///      MAX_SWAP_BPS for retail flow, up to MAX_SWAP_BPS for a large trade.
    ///      Drawn in hundredths of a bp, so amounts aren't round numbers.
    function _swapWave(uint256 count) internal {
        for (uint256 s_ = 0; s_ < count; ++s_) {
            uint8 i = uint8(_rand(n));
            uint8 j = uint8((i + 1 + _rand(n - 1)) % n);
            uint256 capBps = _rand(10) < LARGE_SWAPS_IN_10 ? maxSwapBps : maxSwapBps / 10;
            if (capBps < 2) capBps = 2;
            uint256 centiBps = 100 + _rand((capBps - 1) * 100);
            _swapRawAs(PK_SWAPPER, i, j, _realRaw(i) * centiBps / 1_000_000);
        }
    }

    /// @dev Arbitrage back to parity: while the reserves spread by more than
    ///      0.02% of the mean real reserve, sell the scarcest asset for the most abundant,
    ///      sized to close the smaller of the two gaps. A few rounds converge;
    ///      the cap only bounds a pathological case.
    function _rebalance() internal {
        for (uint256 round = 0; round < 12; ++round) {
            (uint8 lo, uint8 hi, uint256 mean, uint256 spread) = _extremes();
            // Measured against the REAL mean: virtual reserves are far larger
            // than the tokens held, so a share of them would hide a real gap.
            if (spread * 10_000 <= (mean - hook.virtualReserve()) * 2) return;
            uint256 gapLo = mean - hook.reserves(lo);
            uint256 gapHi = hook.reserves(hi) - mean;
            uint256 wad = gapLo < gapHi ? gapLo : gapHi;
            _swapRawAs(PK_SWAPPER, lo, hi, wad / hook.scaleOf(lo));
        }
    }

    /// @dev Scarcest and most abundant asset (by WAD reserve), the mean, and
    ///      the max − min spread.
    function _extremes() internal view returns (uint8 lo, uint8 hi, uint256 mean, uint256 spread) {
        uint256 minR = type(uint256).max;
        uint256 maxR;
        uint256 sum;
        for (uint8 i = 0; i < n; ++i) {
            uint256 r = hook.reserves(i);
            sum += r;
            if (r < minR) (minR, lo) = (r, i);
            if (r > maxR) (maxR, hi) = (r, i);
        }
        mean = sum / n;
        spread = maxR - minR;
    }

    function _logSpread() internal view {
        (,, uint256 mean, uint256 spread) = _extremes();
        console2.log("  reserve spread (bps of real mean x100):", spread * 1_000_000 / (mean - hook.virtualReserve()));
    }

    /// @dev Tokens the pool actually holds for asset `i`, raw units: its
    ///      reserve less the virtual part concentrated liquidity never pays out.
    function _realRaw(uint8 i) internal view returns (uint256) {
        return (hook.reserves(i) - hook.virtualReserve()) / hook.scaleOf(i);
    }

    /// @dev Mint and burn are blocked while any tick sits on its boundary.
    function _liquidityOpen(string memory what) internal view returns (bool) {
        (,,, uint256 kBound,) = hook.slot0();
        if (kBound == 0) return true;
        console2.log(string.concat("  skipped ", what, ": a tick is on its boundary"));
        return false;
    }

    // ─────────────────────────────────────────────────────────────

    function _fund(address to, uint256 amount) internal {
        if (to.balance >= amount) return;
        (bool ok,) = to.call{value: amount - to.balance}("");
        require(ok, "gas funding failed");
    }

    /// @dev Self-mint the mocks, approve, then deposit `capital` of every
    ///      asset into a tick whose band ends at `depeg` (0 = full range).
    function _lpJoin(uint256 pk, uint256 capital, uint256 depeg, string memory who)
        internal
        returns (uint256 tickIdx)
    {
        if (!_liquidityOpen(string.concat(who, "'s join"))) return type(uint256).max;
        uint256 rWad = _radiusFor(capital, depeg);
        address me = vm.addr(pk);
        vm.startBroadcast(pk);
        for (uint8 i = 0; i < n; ++i) {
            // Pro-rata deposits scale with the pool, so mint generously.
            IMintable(toks[i]).mint(me, 5_000_000 * (10 ** uint256(decs[i])));
            IERC20(toks[i]).approve(address(hook), type(uint256).max);
        }
        uint256[] memory maxA = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) maxA[i] = type(uint256).max;
        (tickIdx,) = hook.addLiquidity(TierLadder.plane(rWad, n, depeg), rWad, maxA);
        vm.stopBroadcast();
        console2.log(string.concat("  ", who, " joined tick"), tickIdx, "r:", rWad);
        console2.log("    capital per asset (wad):", capital);
        if (depeg == 0) console2.log("    full range");
        else console2.log("    band bound (wad):", depeg);
    }

    /// @dev Radius at which a tick with band `depeg` deposits `capital` of each
    ///      asset. Deposits are linear in r, so the pool's quote at one probe
    ///      radius prices every radius.
    function _radiusFor(uint256 capital, uint256 depeg) internal view returns (uint256) {
        uint256 probeR = 1_000_000 ether;
        uint256[] memory perProbe = hook.depositAmounts(TierLadder.plane(probeR, n, depeg), probeR);
        uint256 total;
        for (uint8 i = 0; i < n; ++i) total += perProbe[i];
        return probeR * capital * n / total;
    }

    /// @dev Swap `amountIn` raw of asset i for j. The swap is first quoted
    ///      through the V4Quoter, which runs it against the real hook and
    ///      reverts if the hook refuses it (an FX pool's oracle band, or a
    ///      trade larger than the pool can fill). Then the reverse trade is
    ///      taken instead, as an arbitrageur would, and if that is refused too
    ///      the swap is skipped. Quotes run outside the broadcast block, so
    ///      nothing refused is ever sent.
    function _swapRawAs(uint256 pk, uint8 i, uint8 j, uint256 amountIn) internal {
        if (i >= n || j >= n || amountIn == 0) return;
        if (!_quotes(i, j, amountIn)) {
            // Same share of the other asset's reserve, the other way.
            uint256 back = amountIn * _realRaw(j) / _realRaw(i);
            if (back == 0 || !_quotes(j, i, back)) {
                console2.log("  skipped swap: refused both ways", i, j);
                return;
            }
            (i, j, amountIn) = (j, i, back);
        }

        address me = vm.addr(pk);
        (PoolKey memory key, bool zeroForOne) = _route(i, j);
        vm.startBroadcast(pk);
        IMintable(toks[i]).mint(me, amountIn);
        IERC20(toks[i]).approve(address(router), type(uint256).max);
        router.swapExactTokensForTokens(amountIn, 0, zeroForOne, key, "", me, block.timestamp + 1 hours);
        vm.stopBroadcast();
    }

    function _quotes(uint8 i, uint8 j, uint256 amountIn) internal returns (bool) {
        (PoolKey memory key, bool zeroForOne) = _route(i, j);
        try quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: uint128(amountIn),
                hookData: ""
            })
        ) returns (uint256 amountOut, uint256) {
            return amountOut > 0;
        } catch {
            return false;
        }
    }

    function _route(uint8 i, uint8 j) internal view returns (PoolKey memory key, bool zeroForOne) {
        (address c0, address c1) = toks[i] < toks[j] ? (toks[i], toks[j]) : (toks[j], toks[i]);
        zeroForOne = toks[i] == c0;
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
    }

    function _collect(uint256 pk, uint256 tickIdx, string memory who) internal {
        if (tickIdx == type(uint256).max) return;
        vm.startBroadcast(pk);
        try hook.collect(tickIdx) returns (uint256[] memory fees) {
            uint256 total;
            for (uint8 i = 0; i < n; ++i) total += fees[i];
            console2.log(string.concat("  ", who, " collected (summed wad):"), total);
        } catch {
            console2.log(string.concat("  ", who, " had nothing to collect"));
        }
        vm.stopBroadcast();
    }

    /// @dev Burn `pct`% of the position (100 = full exit).
    function _burnPart(uint256 pk, uint256 tickIdx, string memory who, uint256 pct) internal {
        if (tickIdx == type(uint256).max) return;
        address me = vm.addr(pk);
        uint256 bal = hook.balanceOf(me, tickIdx);
        uint256 amount = pct >= 100 ? bal : bal * pct / 100;
        if (amount == 0 || !_liquidityOpen(string.concat(who, "'s exit"))) return;
        vm.startBroadcast(pk);
        hook.removeLiquidity(tickIdx, amount, new uint256[](n));
        vm.stopBroadcast();
        console2.log(string.concat("  ", who, " burned %, left:"), pct, hook.balanceOf(me, tickIdx));
    }

    function _logState(string memory tag) internal view {
        (uint256 sumX,, uint256 rInt, uint256 kBound,) = hook.slot0();
        console2.log(string.concat("--- ", tag, " ---"));
        console2.log("  numTicks:", hook.numTicks(), "rInt:", rInt);
        // sumX is the engine's (virtual) total; the tokens held are that less
        // the virtual floor on every asset.
        console2.log("  TVL (real, wad):", sumX - uint256(n) * hook.virtualReserve(), "kBound:", kBound);
    }
}
