// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {ArbitrumOne} from "./realworld/ArbitrumOne.sol";
import {FullMath} from "../src/libraries/FullMath.sol";

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

interface IUniswapV3PoolState {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

interface IOrbitalHook {
    function reserves(uint8 i) external view returns (uint256);
    function indexOf(Currency c) external view returns (uint8);
    function scaleOf(uint8 i) external view returns (uint256);
    function fee() external view returns (uint24);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160, uint32, uint256);
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Replay real Arbitrum One USDC/USDT0 trades, in their real order,
///         through BOTH the live Uniswap v3 0.01% pool and Orbital, as real
///         transactions from one trader.
///
///         On mainnet, arbitrage returns a pool to the market price between
///         trades; a fork has no arbitrageurs, so without them each trade
///         would meet a pool left skewed by the ones before it, a state no real
///         trader sees. So after every trade the replay sends a rebalancing
///         transaction that returns that pool to its pre-trade state, and each
///         real trade is measured against a pool at the market price:
///
///           v3       swap back with the pre-trade sqrtPrice as the price
///                    limit; the pool stops exactly there.
///           Orbital  the invariant is a function of the reserves alone, so
///                    buying back until the output asset's reserve is where
///                    it was also returns the input asset's; the input that
///                    does it is computed exactly, fee included.
///
///         Rebalances are real transactions too, recorded in the plan so the
///         report can tell them from the trades.
///
///         Orbital is freshly seeded, so it starts at exactly 1:1, while the
///         market (v3) prices USDC and USDT0 a few basis points apart. Left
///         alone, every trade would differ by that gap, which measures the
///         starting price rather than the pool. So the replay first arbitrages
///         Orbital to v3's price, as the first arbitrageur would on mainnet:
///         one trade, sized by read-only quotes, and recorded in the plan.
///
/// @dev    Input: `script/realworld/replay.json` (sample-trades.py), each trade
///         a real swap with its Arbiscan hash. Every trade is quoted on each
///         pool first (a read, never broadcast): a pool that would refuse it
///         gets no transaction, and the refusal and its reason are recorded
///         instead of a failed transaction. The trades a pool does take are
///         sent for real, so every output in the report is read back from its
///         transaction's receipt (report.py), not from this script.
///
///         Writes `script/realworld/replay-plan.json`: per trade, which pools
///         were sent a transaction and why any refused.
///
///         HOOK=<orbital hook> forge script script/RealWorldReplay.s.sol \
///             --rpc-url $RPC --broadcast --slow --private-key $TRADER_KEY
contract RealWorldReplayScript is Script {
    using stdJson for string;
    using SafeERC20 for IERC20;

    /// Uniswap's canonical V4Quoter and QuoterV2 on Arbitrum One.
    IV4Quoter internal constant V4_QUOTER = IV4Quoter(0x3972C00f7ed4885e145823eb7C655375d275A1C5);
    IQuoterV2 internal constant V3_QUOTER = IQuoterV2(0x61fFE014bA17989E743c5F6cB21bF9697530B21e);
    uint24 internal constant V3_FEE = 100;

    function run() external {
        address hook = vm.envAddress("HOOK");
        address trader = msg.sender;
        IUniswapV4Router04 v4 = IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)));
        ISwapRouter02 v3 = ISwapRouter02(ArbitrumOne.V3_SWAP_ROUTER02);

        string memory path = string.concat(vm.projectRoot(), "/script/realworld/replay.json");
        string memory json = vm.readFile(path);
        bool[] memory usdcIn = json.readBoolArray(".usdcIn");
        uint256[] memory amountIn = json.readUintArray(".amountIn");

        // USDC is the lower address, so it is currency0 of the Orbital pair.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(ArbitrumOne.USDC),
            currency1: Currency.wrap(ArbitrumOne.USDT0),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(hook)
        });

        vm.startBroadcast();
        IERC20(ArbitrumOne.USDC).forceApprove(address(v3), type(uint256).max);
        IERC20(ArbitrumOne.USDT0).forceApprove(address(v3), type(uint256).max);
        IERC20(ArbitrumOne.USDC).forceApprove(address(v4), type(uint256).max);
        IERC20(ArbitrumOne.USDT0).forceApprove(address(v4), type(uint256).max);
        vm.stopBroadcast();

        bool aligned = _alignOrbitalToMarket(v4, key, trader);

        uint256 n = amountIn.length;
        bool[] memory v3Sent = new bool[](n);
        bool[] memory orbitalSent = new bool[](n);
        bool[] memory v3Rebalanced = new bool[](n);
        bool[] memory orbitalRebalanced = new bool[](n);
        // How far each rebalance left the pool from its pre-trade state: v3's
        // price (sqrtPrice units) and Orbital's input-asset reserve (WAD).
        uint256 worstV3Miss;
        uint256 worstOrbitalMiss;
        string[] memory v3Refusal = new string[](n);
        string[] memory orbitalRefusal = new string[](n);

        for (uint256 i = 0; i < n; ++i) {
            (address tin, address tout) =
                usdcIn[i] ? (ArbitrumOne.USDC, ArbitrumOne.USDT0) : (ArbitrumOne.USDT0, ArbitrumOne.USDC);

            // Uniswap v3.
            (uint160 v3Price,,,,,,) = IUniswapV3PoolState(ArbitrumOne.V3_USDC_USDT0_POOL).slot0();
            try V3_QUOTER.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tin, tokenOut: tout, amountIn: amountIn[i], fee: V3_FEE, sqrtPriceLimitX96: 0
                })
            ) returns (uint256 q, uint160, uint32, uint256) {
                if (q == 0) {
                    v3Refusal[i] = "pays nothing";
                } else {
                    vm.broadcast();
                    v3.exactInputSingle(
                        ISwapRouter02.ExactInputSingleParams({
                            tokenIn: tin,
                            tokenOut: tout,
                            fee: V3_FEE,
                            recipient: trader,
                            amountIn: amountIn[i],
                            amountOutMinimum: 0,
                            sqrtPriceLimitX96: 0
                        })
                    );
                    v3Sent[i] = true;
                    v3Rebalanced[i] = _rebalanceV3(v3, trader, tout, tin, v3Price);
                    (uint160 after_,,,,,,) = IUniswapV3PoolState(ArbitrumOne.V3_USDC_USDT0_POOL).slot0();
                    uint256 miss = after_ > v3Price ? after_ - v3Price : v3Price - after_;
                    if (miss > worstV3Miss) worstV3Miss = miss;
                }
            } catch (bytes memory err) {
                v3Refusal[i] = vm.toString(err);
            }

            // Orbital.
            try V4_QUOTER.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key, zeroForOne: usdcIn[i], exactAmount: uint128(amountIn[i]), hookData: ""
                })
            ) returns (uint256, uint256) {
                uint8 outIdx = IOrbitalHook(hook).indexOf(Currency.wrap(tout));
                uint256 outReserve = IOrbitalHook(hook).reserves(outIdx);
                uint8 inIdx = IOrbitalHook(hook).indexOf(Currency.wrap(tin));
                uint256 inReserve = IOrbitalHook(hook).reserves(inIdx);
                vm.broadcast();
                v4.swapExactTokensForTokens(amountIn[i], 0, usdcIn[i], key, "", trader, block.timestamp + 1 hours);
                orbitalSent[i] = true;
                orbitalRebalanced[i] = _rebalanceOrbital(v4, key, IOrbitalHook(hook), trader, !usdcIn[i], outIdx, outReserve);
                {
                    uint256 back = IOrbitalHook(hook).reserves(inIdx);
                    uint256 miss = back > inReserve ? back - inReserve : inReserve - back;
                    if (miss > worstOrbitalMiss) worstOrbitalMiss = miss;
                }
            } catch (bytes memory err) {
                orbitalRefusal[i] = vm.toString(err);
            }
        }

        string memory plan = "plan";
        plan.serialize("hook", hook);
        plan.serialize("trader", trader);
        plan.serialize("forkBlock", block.number);
        plan.serialize("orbitalAligned", aligned);
        plan.serialize("v3Sent", v3Sent);
        plan.serialize("orbitalSent", orbitalSent);
        plan.serialize("v3Rebalanced", v3Rebalanced);
        plan.serialize("orbitalRebalanced", orbitalRebalanced);
        plan.serialize("v3Refusal", v3Refusal);
        plan = plan.serialize("orbitalRefusal", orbitalRefusal);
        plan.write(string.concat(vm.projectRoot(), "/script/realworld/replay-plan.json"));

        uint256 sent3;
        uint256 sentO;
        for (uint256 i = 0; i < n; ++i) {
            if (v3Sent[i]) ++sent3;
            if (orbitalSent[i]) ++sentO;
        }
        console2.log("trades:", n);
        console2.log("sent to Uniswap v3:", sent3);
        console2.log("sent to Orbital:   ", sentO);
        console2.log("worst v3 rebalance miss (sqrtPriceX96 units):", worstV3Miss);
        console2.log("worst Orbital rebalance miss (WAD, 1e18 = $1):", worstOrbitalMiss);
    }

    /// @dev Swap `tokenIn` back into the v3 pool until its price is `target`
    ///      again. The input is only a cap: the pool stops at the price limit
    ///      and the router pulls exactly what it used.
    function _rebalanceV3(ISwapRouter02 v3, address trader, address tokenIn, address tokenOut, uint160 target)
        internal
        returns (bool)
    {
        (uint160 now_,,,,,,) = IUniswapV3PoolState(ArbitrumOne.V3_USDC_USDT0_POOL).slot0();
        if (now_ == target) return false;
        uint256 cap = IERC20(tokenIn).balanceOf(trader);
        vm.broadcast();
        v3.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: V3_FEE,
                recipient: trader,
                amountIn: cap,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: target
            })
        );
        return true;
    }

    /// @dev Buy back into Orbital until asset `outIdx` (what the trade took
    ///      out) is at `target` again. Its reserve rises by exactly the net
    ///      input, `amountIn − ⌊amountIn·fee/1e6⌋`, so the gross input is that
    ///      shortfall grossed up for the fee, in the token's raw units.
    function _rebalanceOrbital(
        IUniswapV4Router04 v4,
        PoolKey memory key,
        IOrbitalHook hook,
        address trader,
        bool zeroForOne,
        uint8 outIdx,
        uint256 target
    ) internal returns (bool) {
        uint256 reserve = hook.reserves(outIdx);
        if (reserve >= target) return false;
        uint256 feePpm = hook.fee();
        uint256 netWad = target - reserve;
        uint256 grossWad = (netWad * 1_000_000 + (1_000_000 - feePpm) - 1) / (1_000_000 - feePpm);
        uint256 scale = hook.scaleOf(outIdx);
        uint256 raw = (grossWad + scale - 1) / scale;
        vm.broadcast();
        v4.swapExactTokensForTokens(raw, 0, zeroForOne, key, "", trader, block.timestamp + 1 hours);
        return true;
    }

    /// @dev Trade Orbital's USDC/USDT0 price to v3's, `P` = USDT0 per USDC.
    ///
    ///      After selling `a` of one asset, the pool's marginal rate is
    ///      measured from two read-only quotes a small step apart, and its
    ///      mid-price follows by taking the fee back out:
    ///
    ///        selling USDT0:  rate = USDC per USDT0 = (1 − fee) / P
    ///        selling USDC:   rate = USDT0 per USDC = (1 − fee) · P
    ///
    ///      P moves monotonically with `a`, so a binary search on `a` lands on
    ///      v3's price; the one trade that gets there is then sent.
    function _alignOrbitalToMarket(IUniswapV4Router04 v4, PoolKey memory key, address trader)
        internal
        returns (bool)
    {
        (uint160 sp,,,,,,) = IUniswapV3PoolState(ArbitrumOne.V3_USDC_USDT0_POOL).slot0();
        // Both tokens have 6 decimals, so the raw price is the price.
        uint256 target = FullMath.mulDiv(uint256(sp) * uint256(sp), 1e18, 1 << 192);
        console2.log("v3 market price, USDT0 per USDC (1e18 = 1:1):", target);
        if (target == 1e18) return false;

        // USDC dearer than 1:1 -> buy USDC with USDT0, and vice versa.
        bool sellUsdc = target < 1e18;
        uint256 lo = 0;
        // The whole balance bounds the search: a deep pool can need a large
        // trade to move a few basis points (a cap here once left it short).
        uint256 hi = IERC20(sellUsdc ? ArbitrumOne.USDC : ArbitrumOne.USDT0).balanceOf(trader);
        for (uint256 k = 0; k < 64 && hi - lo > 1e6; ++k) {
            uint256 mid = (lo + hi) / 2;
            (bool ok, uint256 price) = _orbitalPriceAfter(key, sellUsdc, mid);
            // A size the pool refuses is past any price it can reach: too far.
            // Otherwise: selling USDC lowers P; selling USDT0 raises it.
            bool short_ = ok && (sellUsdc ? price > target : price < target);
            if (short_) lo = mid;
            else hi = mid;
        }
        if (lo == 0) return false;
        vm.broadcast();
        v4.swapExactTokensForTokens(lo, 0, sellUsdc, key, "", trader, block.timestamp + 1 hours);
        (, uint256 reached) = _orbitalPriceAfter(key, sellUsdc, 0);
        console2.log("Orbital aligned with a trade of (raw units):", lo);
        console2.log("Orbital price after, USDT0 per USDC (1e18 = 1:1):", reached);
        // Every comparison below assumes the two pools start at one price: a
        // miss would show up in every row as a price gap, not a depth one.
        uint256 miss = reached > target ? reached - target : target - reached;
        require(miss <= 5e12, "Orbital could not be aligned to the market price (> 0.05 bps off)");
        return true;
    }

    /// @dev Orbital's mid-price, USDT0 per USDC (1e18 = 1:1), after selling `a`
    ///      raw units of USDC (`sellUsdc`) or USDT0 — from quotes only.
    ///      `ok` is false when the pool refuses a trade of that size.
    function _orbitalPriceAfter(PoolKey memory key, bool sellUsdc, uint256 a)
        internal
        returns (bool ok, uint256 price)
    {
        uint256 step = 100e6; // $100: fine enough that curvature over it is negligible
        uint256 q0;
        if (a != 0) {
            (ok, q0) = _quote(key, sellUsdc, a);
            if (!ok) return (false, 0);
        }
        uint256 q1;
        (ok, q1) = _quote(key, sellUsdc, a + step);
        if (!ok || q1 <= q0) return (false, 0);
        uint256 rate = (q1 - q0) * 1e18 / step;
        uint256 keep = 1e18 - uint256(IOrbitalHook(address(key.hooks)).fee()) * 1e12; // 1 − fee
        price = sellUsdc ? rate * 1e18 / keep : keep * 1e18 / rate;
    }

    function _quote(PoolKey memory key, bool zeroForOne, uint256 amount) internal returns (bool, uint256) {
        try V4_QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: zeroForOne, exactAmount: uint128(amount), hookData: ""
            })
        ) returns (uint256 out, uint256) {
            return (true, out);
        } catch {
            return (false, 0);
        }
    }
}
