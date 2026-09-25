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

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Random retail swap flow against a LIVE deployment.
///
/// @dev    Unlike `SimulateMultiLPLive.s.sol`, which sizes swaps as a share of
///         the pool's reserves (thousands of dollars on a $5M pool), every swap
///         here is sized in DOLLARS and capped at `MAX_SWAP_USD`, so the
///         pool sees small retail trades only. No liquidity is touched.
///
///         Several trader accounts are derived deterministically, funded a
///         little gas from the deployer, and self-mint the mock stables, so the
///         activity feed shows independent traders rather than one address.
///
///         SEEDED: pair, direction, size and trader all follow from
///         `ACTIVITY_SEED`, so each chain gets its own history and a run is
///         reproducible. Sizes are drawn in cents between `MIN_SWAP_USD` and
///         `MAX_SWAP_USD`, skewed toward small trades, so none are round numbers.
///
///         Every swap is quoted through the V4Quoter first (outside the
///         broadcast), and skipped with a log line if the hook refuses it.
///
///         Required env: ORBITAL_HOOK, V4_ROUTER, V4_QUOTER
///         Optional env: ACTIVITY_SEED (default 1)
///                       SWAP_COUNT    (default 25)
///                       MIN_SWAP_USD  (default 5)
///                       MAX_SWAP_USD  (default 5000, at most 5000)
///                       GAS_PER_ACTOR (wei, default 0.001 ether)
///
///      ORBITAL_HOOK=0x... V4_ROUTER=0x... V4_QUOTER=0x... \
///      forge script script/SimulateSwaps.s.sol --rpc-url arbitrum_sepolia \
///          --broadcast --slow --private-key $PRIVATE_KEY
contract SimulateSwapsScript is Script {
    OrbitalHook hook;
    IUniswapV4Router04 router;
    IV4Quoter quoter;
    uint8 n;
    address[] toks;
    uint8[] decs;

    uint256 seed;
    uint256 nonce;

    uint256 constant TRADERS = 5;

    /// @dev Mock balance a trader mints per asset when it runs low, in dollars.
    ///      Well above any single swap, so most swaps need no mint.
    uint256 constant MINT_BUFFER_USD = 20_000;

    function run() external {
        hook = OrbitalHook(vm.envAddress("ORBITAL_HOOK"));
        router = IUniswapV4Router04(payable(vm.envAddress("V4_ROUTER")));
        quoter = IV4Quoter(vm.envAddress("V4_QUOTER"));
        seed = vm.envOr("ACTIVITY_SEED", uint256(1));
        uint256 count = vm.envOr("SWAP_COUNT", uint256(25));
        uint256 minUsd = vm.envOr("MIN_SWAP_USD", uint256(5));
        uint256 maxUsd = vm.envOr("MAX_SWAP_USD", uint256(5000));
        uint256 gasPerActor = vm.envOr("GAS_PER_ACTOR", uint256(0.001 ether));
        require(maxUsd <= 5000, "MAX_SWAP_USD must be at most 5000");
        require(minUsd > 0 && minUsd < maxUsd, "MIN_SWAP_USD out of range");

        n = hook.N();
        for (uint8 i = 0; i < n; ++i) {
            address t = Currency.unwrap(hook.assetAt(i));
            toks.push(t);
            decs.push(IERC20(t).decimals());
        }

        console2.log("=== seed", seed, "swaps", count);
        console2.log("    size range ($):", minUsd, maxUsd);
        _logState("before");

        vm.startBroadcast();
        for (uint256 t = 0; t < TRADERS; ++t) _fund(vm.addr(_traderPk(t)), gasPerActor);
        vm.stopBroadcast();

        uint256 done;
        uint256 volumeCents;
        for (uint256 s = 0; s < count; ++s) {
            uint8 i = uint8(_rand(n));
            uint8 j = uint8((i + 1 + _rand(n - 1)) % n);
            uint256 cents = _sizeCents(minUsd * 100, maxUsd * 100);
            uint256 pk = _traderPk(_rand(TRADERS));
            if (_swap(pk, i, j, cents)) {
                ++done;
                volumeCents += cents;
            }
        }

        console2.log("=== swaps executed:", done, "of", count);
        console2.log("    volume ($):", volumeCents / 100);
        _logState("after");
    }

    // ─────────────────────────────────────────────────────────────

    function _traderPk(uint256 t) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode("orbital.live.trader", t)));
    }

    /// @dev Next deterministic value in [0, bound).
    function _rand(uint256 bound) internal returns (uint256) {
        return uint256(keccak256(abi.encode(seed, nonce++))) % bound;
    }

    /// @dev Size in cents within [lo, hi], skewed small the way retail flow
    ///      is: half the trades land in the bottom tenth of the range, three in
    ///      ten in the next quarter, the rest anywhere up to `hi`.
    function _sizeCents(uint256 lo, uint256 hi) internal returns (uint256) {
        uint256 span = hi - lo;
        uint256 roll = _rand(10);
        uint256 top = roll < 5 ? span / 10 : roll < 8 ? span * 35 / 100 : span;
        return lo + _rand(top + 1);
    }

    function _fund(address to, uint256 amount) internal {
        if (to.balance >= amount) return;
        (bool ok,) = to.call{value: amount - to.balance}("");
        require(ok, "gas funding failed");
    }

    /// @dev Swap `cents` worth of asset i for j as the trader `pk`. The mocks
    ///      are $1 each, so a dollar amount maps straight to raw units.
    function _swap(uint256 pk, uint8 i, uint8 j, uint256 cents) internal returns (bool) {
        uint256 amountIn = cents * (10 ** uint256(decs[i])) / 100;
        if (!_quotes(i, j, amountIn)) {
            console2.log("  skipped: hook refused", i, j, cents);
            return false;
        }

        address me = vm.addr(pk);
        (PoolKey memory key, bool zeroForOne) = _route(i, j);
        vm.startBroadcast(pk);
        if (IERC20(toks[i]).balanceOf(me) < amountIn) {
            IMintable(toks[i]).mint(me, MINT_BUFFER_USD * (10 ** uint256(decs[i])));
        }
        if (IERC20(toks[i]).allowance(me, address(router)) < amountIn) {
            IERC20(toks[i]).approve(address(router), type(uint256).max);
        }
        router.swapExactTokensForTokens(amountIn, 0, zeroForOne, key, "", me, block.timestamp + 1 hours);
        vm.stopBroadcast();

        console2.log(string.concat("  swap $", _fmtCents(cents), " ", IERC20(toks[i]).symbol(), " -> ", IERC20(toks[j]).symbol()));
        return true;
    }

    function _quotes(uint8 i, uint8 j, uint256 amountIn) internal returns (bool) {
        (PoolKey memory key, bool zeroForOne) = _route(i, j);
        try quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: uint128(amountIn), hookData: ""
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

    function _fmtCents(uint256 cents) internal pure returns (string memory) {
        uint256 c = cents % 100;
        return string.concat(vm.toString(cents / 100), ".", c < 10 ? "0" : "", vm.toString(c));
    }

    function _logState(string memory tag) internal view {
        (uint256 sumX,, uint256 rInt, uint256 kBound,) = hook.slot0();
        console2.log(string.concat("--- ", tag, " ---"));
        console2.log("  numTicks:", hook.numTicks(), "rInt:", rInt);
        console2.log("  TVL (real, wad):", sumX - uint256(n) * hook.virtualReserve(), "kBound:", kBound);
    }
}
