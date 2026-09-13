// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {OrbitalFXHook} from "../../src/fx/OrbitalFXHook.sol";
import {IAggregatorV3} from "../../src/fx/IAggregatorV3.sol";
import {TickLib} from "../../src/libraries/TickLib.sol";

/// @notice OrbitalFXHook against REAL contracts on Ethereum Sepolia: Chainlink's
///         EUR/USD feed, and Uniswap's canonical v4 PoolManager and router.
///
/// @dev    The unit tests run against `MockAggregator`; this suite shows the
///         hook integrates with a production Chainlink feed and production v4
///         core. Arc testnet has no Chainlink deployment, so Sepolia is where
///         both exist together. Nothing hard-codes a price: every expectation
///         is derived from what the live feed returns at the forked block.
///
///         Run: forge test --match-path test/fx/OrbitalFXHookFork.t.sol -vv
contract OrbitalFXHookForkTest is Test {
    uint256 constant SEPOLIA = 11155111;

    /// @dev Chainlink EUR / USD on Sepolia (data.chain.link).
    IAggregatorV3 constant EUR_USD = IAggregatorV3(0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910);
    /// @dev Canonical Uniswap v4 on Sepolia (hookmate AddressConstants).
    IPoolManager constant POOL_MANAGER = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IUniswapV4Router04 constant ROUTER = IUniswapV4Router04(payable(0xf13D190e9117920c703d79B5F33732e10049b115));
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev The production staleness bound: Chainlink's 24h FX heartbeat plus
    ///      an hour of update lag, as the deploy script uses.
    uint256 constant PROD_MAX_AGE = 25 hours;
    uint256 constant BAND_BPS = 50;
    uint8 constant N = 4;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    function setUp() public {
        // Deliberately not wrapped in try/catch: an unreachable RPC must fail the
        // run loudly rather than report green having proven nothing.
        vm.createSelectFork("eth_sepolia");
        assertEq(block.chainid, SEPOLIA, "fork is not Ethereum Sepolia");
        assertGt(address(EUR_USD).code.length, 0, "no Chainlink feed on this fork");
        assertGt(address(POOL_MANAGER).code.length, 0, "no PoolManager on this fork");
        assertGt(address(ROUTER).code.length, 0, "no router on this fork");
    }

    // ═════════════════════════════════════════════════════════════
    // The real feed behaves as the hook and MockAggregator assume
    // ═════════════════════════════════════════════════════════════

    /// @notice The real feed decodes through our `IAggregatorV3`, is the pair
    ///         we think it is, and has the 8 decimals that make a 6-decimal
    ///         token's scale exact.
    function test_fork_real_feed_decodes_and_is_exactly_representable() public view {
        assertEq(EUR_USD.description(), "EUR / USD", "wrong feed");
        uint8 dec = EUR_USD.decimals();
        assertEq(1e12 % 10 ** uint256(dec), 0, "a 6-decimal token's scale would not be exact");

        (uint80 roundId, int256 answer,, uint256 updatedAt,) = EUR_USD.latestRoundData();
        assertGt(roundId, 0, "no rounds");
        assertGt(answer, 0, "non-positive live answer");
        assertGt(updatedAt, 0, "never updated");
        assertLe(updatedAt, block.timestamp, "timestamp from the future");
    }

    // ═════════════════════════════════════════════════════════════
    // The hook on real Chainlink + real v4 core
    // ═════════════════════════════════════════════════════════════

    /// @notice With the production staleness bound, deploying succeeds exactly
    ///         when the feed is fresh and otherwise reverts with the hook's
    ///         `StalePrice`. Whichever holds at the forked block is asserted,
    ///         so this reports the live state honestly instead of assuming it.
    function test_fork_production_staleness_bound_against_the_live_feed() public {
        (Currency[] memory regd, IAggregatorV3[] memory feeds,) = _tokens();
        (bool ok, bytes memory ret) = _tryDeploy(_flagged(0xA001), regd, feeds, PROD_MAX_AGE);

        (,,, uint256 updatedAt,) = EUR_USD.latestRoundData();
        if (block.timestamp - updatedAt <= PROD_MAX_AGE) {
            assertTrue(ok, "fresh feed but deploy failed");
        } else {
            assertFalse(ok, "stale feed accepted");
            assertEq(bytes4(ret), OrbitalFXHook.StalePrice.selector, "stale feed should revert StalePrice");
        }
    }

    /// @notice End to end on real contracts: centre scales equal the live
    ///         Chainlink answer exactly, a small trade clears at the live rate
    ///         less the fee, and pushing the pool past the market is rejected.
    /// @dev    The staleness bound is the production one, widened only if the
    ///         feed at the forked block is older, so this test is about
    ///         integration and never flakes on a late heartbeat. Freshness is
    ///         covered by the unit tests and the production-bound test above.
    function test_fork_fx_pool_trades_on_real_v4_and_chainlink() public {
        (Currency[] memory regd, IAggregatorV3[] memory feeds, MockERC20[] memory tok) = _tokens();
        (, int256 answer,, uint256 updatedAt,) = EUR_USD.latestRoundData();
        uint256 age = block.timestamp - updatedAt;

        address where = _flagged(0xA002);
        (bool ok,) = _tryDeploy(where, regd, feeds, age > PROD_MAX_AGE ? age + 1 hours : PROD_MAX_AGE);
        assertTrue(ok, "deploy against live Chainlink failed");
        OrbitalFXHook hook = OrbitalFXHook(where);

        // Centre scale == live answer * 10^(12 - 8), exactly.
        uint256 perAnswer = 1e12 / 10 ** uint256(EUR_USD.decimals());
        uint8 usd;
        uint8 eur;
        for (uint8 i; i < N; ++i) {
            if (address(feeds[i]) == address(0)) {
                usd = i;
                assertEq(hook.scaleOf(i), 1e12, "numeraire scale");
            } else {
                eur = i;
                assertEq(hook.scaleOf(i), uint256(answer) * perAnswer, "centre != live answer");
            }
        }

        for (uint256 i; i < N; ++i) {
            tok[i].approve(where, type(uint256).max);
            tok[i].approve(address(ROUTER), type(uint256).max);
        }
        for (uint8 i; i < N; ++i) {
            for (uint8 j = i + 1; j < N; ++j) {
                POOL_MANAGER.initialize(_key(regd, where, i, j), Constants.SQRT_PRICE_1_1);
            }
        }
        uint256[] memory maxA = new uint256[](N);
        for (uint256 i; i < N; ++i) maxA[i] = type(uint256).max;
        hook.addLiquidity(TickLib.kFromDepegPrice(400_000 ether, N, 0.97e18), 400_000 ether, maxA);
        hook.addLiquidity(TickLib.kFromDepegPrice(100_000 ether, N, 0.8e18), 100_000 ether, maxA);

        // A tiny USD -> EUR trade through the REAL router clears at the live
        // rate less the 1 bp fee.
        uint256 amtIn = hook.reserves(usd) / hook.scaleOf(usd) / 100_000; // 10 ppm
        uint256 out = _swap(regd, where, tok, usd, eur, amtIn);
        uint256 vIn = amtIn * 1e12;
        uint256 vOut = out * hook.oracleScaleOf(eur);
        assertLe(vOut, vIn, "paid out more value than it took in");
        assertGe(vOut * 10_000, vIn * 9_998, "cleared more than fee + 1 bp from the live rate");

        // Pushing the pool 1% of reserves past the market is rejected by the guard.
        uint256 large = hook.reserves(usd) / hook.scaleOf(usd) / 100;
        (PoolKey memory k, bool zeroForOne) = _route(regd, where, usd, eur);
        try ROUTER.swapExactTokensForTokens(large, 0, zeroForOne, k, "", address(this), block.timestamp) {
            revert("push past the market was accepted");
        } catch (bytes memory err) {
            assertEq(bytes4(err), CustomRevert.WrappedError.selector, "not a wrapped hook revert");
            (address target,, bytes memory reason,) = this.decodeWrapped(err);
            assertEq(target, where, "revert did not come from the hook");
            assertEq(bytes4(reason), OrbitalFXHook.FxPriceBeyondBand.selector, "wrong hook error");
        }
    }

    // ═════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════

    function decodeWrapped(bytes calldata err) external pure returns (address, bytes4, bytes memory, bytes memory) {
        return abi.decode(err[4:], (address, bytes4, bytes, bytes));
    }

    /// @dev The production basket as fresh 6-decimal mocks, address-sorted, with
    ///      their feeds: two USD numeraires and two EUR stables on EUR/USD.
    function _tokens()
        internal
        returns (Currency[] memory regd, IAggregatorV3[] memory feeds, MockERC20[] memory tok)
    {
        MockERC20[4] memory t = [
            new MockERC20("USD Coin", "USDC", 6),
            new MockERC20("Tether USD", "USDT", 6),
            new MockERC20("Euro Coin", "EURC", 6),
            new MockERC20("Monerium EUR", "EURe", 6)
        ];
        IAggregatorV3 none = IAggregatorV3(address(0));
        IAggregatorV3[4] memory role = [none, none, EUR_USD, EUR_USD];
        for (uint256 i; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (address(t[j]) < address(t[i])) {
                    (t[i], t[j]) = (t[j], t[i]);
                    (role[i], role[j]) = (role[j], role[i]);
                }
            }
        }
        regd = new Currency[](N);
        feeds = new IAggregatorV3[](N);
        tok = new MockERC20[](N);
        for (uint256 i; i < N; ++i) {
            regd[i] = Currency.wrap(address(t[i]));
            feeds[i] = role[i];
            tok[i] = t[i];
            t[i].mint(address(this), 100_000_000e6);
        }
    }

    function _flagged(uint160 salt) internal pure returns (address) {
        return address(HOOK_FLAGS ^ (salt << 144));
    }

    function _tryDeploy(address where, Currency[] memory regd, IAggregatorV3[] memory feeds, uint256 maxAge)
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes memory args = abi.encode(POOL_MANAGER, PERMIT2, regd, uint24(100), address(this), feeds, maxAge, BAND_BPS);
        vm.etch(where, abi.encodePacked(vm.getCode("OrbitalFXHook.sol:OrbitalFXHook"), args));
        (ok, ret) = where.call("");
        if (ok) vm.etch(where, ret);
    }

    function _key(Currency[] memory regd, address hook, uint8 a, uint8 b) internal pure returns (PoolKey memory) {
        return PoolKey({currency0: regd[a], currency1: regd[b], fee: 0, tickSpacing: 1, hooks: IHooks(hook)});
    }

    function _route(Currency[] memory regd, address hook, uint8 inI, uint8 outI)
        internal
        pure
        returns (PoolKey memory k, bool zeroForOne)
    {
        zeroForOne = inI < outI;
        k = zeroForOne ? _key(regd, hook, inI, outI) : _key(regd, hook, outI, inI);
    }

    function _swap(
        Currency[] memory regd,
        address hook,
        MockERC20[] memory tok,
        uint8 inI,
        uint8 outI,
        uint256 amtIn
    ) internal returns (uint256 out) {
        (PoolKey memory k, bool zeroForOne) = _route(regd, hook, inI, outI);
        uint256 before = tok[outI].balanceOf(address(this));
        ROUTER.swapExactTokensForTokens(amtIn, 0, zeroForOne, k, "", address(this), block.timestamp);
        out = tok[outI].balanceOf(address(this)) - before;
    }
}
