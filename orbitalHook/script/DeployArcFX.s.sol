// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {OrbitalFXHook} from "../src/fx/OrbitalFXHook.sol";
import {IAggregatorV3} from "../src/fx/IAggregatorV3.sol";
import {TierLadder} from "./lib/TierLadder.sol";
import {TestnetFxFeed} from "./mocks/TestnetFxFeed.sol";
import {FxFeedSource} from "./fx/FxFeedSource.sol";

/// @notice Deploy the Orbital FX pool on Arc: USDC and USDT (USD, the numeraire)
///         beside EURC and EURe (EUR, priced by Chainlink EUR / USD), onto the v4
///         core that `DeployArc.s.sol` already stood up.
///
/// @dev    Two issuers per currency in one book: a USD<->EUR trade and a
///         same-currency USDC<->USDT or EURC<->EURe trade all draw on the same
///         liquidity. Both EUR stables share the EUR / USD feed, so they are
///         held at parity with each other and at the market rate against USD.
///
///         THE FEED, by chain:
///           - `FX_EUR_USD_FEED` set: that feed, on any chain.
///           - Arc mainnet (5042): Chainlink EUR / USD, the default below.
///           - Arc testnet (5042002): Chainlink has no feeds there, so a
///             `TestnetFxFeed` is deployed and seeded with the live round of
///             Chainlink EUR / USD on Ethereum mainnet. Keep it current with
///             `script/fx/SyncFxFeed.s.sol`.
///         Any other chain requires `FX_EUR_USD_FEED`.
///
///         Every check that could fail at construction (feed pair, decimals,
///         freshness) runs BEFORE broadcasting, so a bad config stops the
///         script with an explanation instead of a reverted deploy.
///
///         EURC and EURe are minted mocks (6 decimals, matching the real ones),
///         so the pool can be seeded deep; USDC and USDT are too unless
///         `FX_USDC` / `FX_USDT` name existing tokens to share with another pool.
///         The FX rate is real: each EUR asset's centre is the live EUR / USD
///         answer at deploy, folded exactly into its scale.
///
///         Seeding uses the shared `TierLadder` with its FX profile: six bands
///         from 0.5% to 10% around the rate, depth tapering outward, and a
///         small full-range backstop that keeps the pool filling beyond them.
///
///         Required env: V4_POOL_MANAGER   (Arc testnet: 0x9BEACCac4e0358Cc276703dcE7341B9B9fEfd5f7)
///         Optional env: FX_EUR_USD_FEED      see above
///                       FX_MAX_PRICE_AGE     default 25 hours (24h heartbeat + 1h lag);
///                                            30 hours on a mirror (+ relay lag)
///                       FX_MAX_DEVIATION_BPS default 50
///                       FX_SOURCE_RPC        mirror source RPC, default eth_mainnet
///                       FX_USDC, FX_USDT     existing 6-decimal USD tokens to trade
///                                            instead of minting new ones; on Arc
///                                            testnet, the stable pool's, so one
///                                            USDC and one USDT trade in both pools.
///                                            The broadcaster must hold enough to
///                                            seed (SEED_BUDGET of each).
///
///         forge script script/DeployArcFX.s.sol --rpc-url arc_testnet \
///             --broadcast --slow --private-key $PRIVATE_KEY
contract DeployArcFXScript is FxFeedSource {
    uint256 internal constant ARC_MAINNET = 5042;
    uint256 internal constant ARC_TESTNET = 5042002;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Chainlink EUR / USD on Arc mainnet (data.chain.link).
    address internal constant CHAINLINK_EUR_USD_ARC = 0xDd5B15443cd733D3966a50a3E48cB7DF9Fb5DE0D;
    string internal constant EUR_USD = "EUR / USD";

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant POOL_FEE = 100; // 1 bp, in hundredths of a bip
    uint8 internal constant N = 4;
    uint8 internal constant DECIMALS = 6;

    string[4] internal SYMBOLS = ["USDC", "USDT", "EURC", "EURe"];
    string[4] internal NAMES =
        ["USD Coin (Orbital FX)", "Tether USD (Orbital FX)", "Euro Coin (Orbital FX)", "Monerium EUR (Orbital FX)"];
    /// @dev false = numeraire (exactly $1); true = priced by EUR / USD.
    bool[4] internal PRICED = [false, false, true, true];

    /// @dev Raw units of each asset the broadcaster must hold to seed the
    ///      ladder: it deposits 1.25M of USD value per asset (fewer raw units
    ///      of a EUR asset), so 2M leaves headroom.
    uint256 internal constant SEED_BUDGET = 2_000_000 * 10 ** DECIMALS;

    struct Config {
        IPoolManager pm;
        /// @dev Zero when a mirror is to be deployed.
        IAggregatorV3 feed;
        uint256 maxAge;
        uint256 band;
    }

    function run() external {
        Config memory c = _config();

        // Resolve the feed and prove it would pass the constructor's checks.
        SourceRound memory seed;
        bool mirror = address(c.feed) == address(0);
        if (mirror) {
            seed = _readSource(SOURCE_CHAIN_ID, SOURCE_EUR_USD);
            _requireUsable(seed.description, seed.decimals, seed.answer, seed.updatedAt, c.maxAge);
        } else {
            (, int256 answer,, uint256 updatedAt,) = c.feed.latestRoundData();
            _requireUsable(c.feed.description(), c.feed.decimals(), answer, updatedAt, c.maxAge);
        }

        vm.startBroadcast();
        if (mirror) {
            TestnetFxFeed m = new TestnetFxFeed(seed.decimals, seed.description, SOURCE_CHAIN_ID, SOURCE_EUR_USD, msg.sender);
            _mirror(m, seed);
            c.feed = m;
        }
        (Currency[] memory assets, IAggregatorV3[] memory feeds, MockERC20[] memory tokens) = _deployTokens(c.feed);
        OrbitalFXHook hook = _deployHook(c, assets, feeds, msg.sender);
        _initPools(c.pm, hook, assets);
        _seed(hook, tokens);
        vm.stopBroadcast();

        _report(c, mirror, hook, assets);
    }

    // ─────────────────────────────── config ──────────────────────────────────

    function _config() internal view returns (Config memory c) {
        c.pm = IPoolManager(vm.envAddress("V4_POOL_MANAGER"));
        require(address(c.pm).code.length > 0, "V4_POOL_MANAGER has no code on this chain");

        address feed = vm.envOr("FX_EUR_USD_FEED", block.chainid == ARC_MAINNET ? CHAINLINK_EUR_USD_ARC : address(0));
        require(
            feed != address(0) || block.chainid == ARC_TESTNET,
            "FX_EUR_USD_FEED required: no default EUR / USD feed for this chain"
        );
        if (feed != address(0)) require(feed.code.length > 0, "FX_EUR_USD_FEED has no code on this chain");
        c.feed = IAggregatorV3(feed);

        // Chainlink's 24h FX heartbeat plus an hour of update lag; a mirror adds
        // a relay hop, so it also gets the relay's worst-case lag.
        c.maxAge = vm.envOr("FX_MAX_PRICE_AGE", feed == address(0) ? uint256(30 hours) : uint256(25 hours));
        c.band = vm.envOr("FX_MAX_DEVIATION_BPS", uint256(50));

        require(PERMIT2.code.length > 0, "no Permit2 on this chain");
        require(CREATE2_FACTORY.code.length > 0, "no CREATE2 factory; cannot mine the hook address");
    }

    /// @dev The constructor's feed checks, run against this chain's clock
    ///      before anything is broadcast.
    function _requireUsable(
        string memory description,
        uint8 feedDecimals,
        int256 answer,
        uint256 updatedAt,
        uint256 maxAge
    ) internal view {
        require(keccak256(bytes(description)) == keccak256(bytes(EUR_USD)), "feed is not EUR / USD");
        // The hook's exact-representation rule: 10^(18 - 6) divisible by 10^feedDecimals.
        require(feedDecimals <= 18 - DECIMALS, "feed decimals too fine for a 6-decimal token");
        require(answer > 0, "feed answer is not positive");
        require(updatedAt != 0 && updatedAt <= block.timestamp, "feed timestamp unset or in the future");
        require(block.timestamp - updatedAt <= maxAge, "feed is older than FX_MAX_PRICE_AGE");
        console2.log("EUR / USD answer", uint256(answer), "decimals", feedDecimals);
        console2.log("  updated (s ago):", block.timestamp - updatedAt);
    }

    // ──────────────────────────────── pool ───────────────────────────────────

    function _deployTokens(IAggregatorV3 eurUsd)
        internal
        returns (Currency[] memory sorted, IAggregatorV3[] memory feeds, MockERC20[] memory tokens)
    {
        MockERC20[4] memory raw;
        IAggregatorV3[4] memory feed;
        for (uint256 i = 0; i < N; ++i) {
            // A numeraire may reuse an existing token; priced assets are always new.
            address existing = PRICED[i] ? address(0) : vm.envOr(string.concat("FX_", SYMBOLS[i]), address(0));
            if (existing != address(0)) {
                raw[i] = MockERC20(existing);
                require(existing.code.length > 0, string.concat("FX_", SYMBOLS[i], " has no code on this chain"));
                require(raw[i].decimals() == DECIMALS, string.concat("FX_", SYMBOLS[i], " is not 6-decimal"));
                require(
                    raw[i].balanceOf(msg.sender) >= SEED_BUDGET,
                    string.concat("broadcaster holds too little ", SYMBOLS[i], " to seed")
                );
            } else {
                raw[i] = new MockERC20(NAMES[i], SYMBOLS[i], DECIMALS);
                raw[i].mint(msg.sender, SEED_BUDGET);
            }
            if (PRICED[i]) feed[i] = eurUsd;
        }
        // The hook requires assets sorted by address; keep each feed with its token.
        for (uint256 i = 0; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (address(raw[j]) < address(raw[i])) {
                    (raw[i], raw[j]) = (raw[j], raw[i]);
                    (feed[i], feed[j]) = (feed[j], feed[i]);
                }
            }
        }
        sorted = new Currency[](N);
        feeds = new IAggregatorV3[](N);
        tokens = new MockERC20[](N);
        for (uint256 i = 0; i < N; ++i) {
            sorted[i] = Currency.wrap(address(raw[i]));
            feeds[i] = feed[i];
            tokens[i] = raw[i];
        }
    }

    function _deployHook(Config memory c, Currency[] memory assets, IAggregatorV3[] memory feeds, address admin)
        internal
        returns (OrbitalFXHook hook)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory args =
            abi.encode(c.pm, IAllowanceTransfer(PERMIT2), assets, POOL_FEE, admin, feeds, c.maxAge, c.band);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(OrbitalFXHook).creationCode, args);

        hook = new OrbitalFXHook{salt: salt}(
            c.pm, IAllowanceTransfer(PERMIT2), assets, POOL_FEE, admin, feeds, c.maxAge, c.band
        );
        require(address(hook) == expected, "hook address mismatch");
    }

    function _initPools(IPoolManager pm, OrbitalFXHook hook, Currency[] memory assets) internal {
        for (uint8 i = 0; i < N; ++i) {
            for (uint8 j = i + 1; j < N; ++j) {
                pm.initialize(
                    PoolKey({
                        currency0: assets[i],
                        currency1: assets[j],
                        fee: 0, // the engine runs its own fee; PoolKey.lpFee must be 0
                        tickSpacing: 1,
                        hooks: IHooks(address(hook))
                    }),
                    SQRT_PRICE_1_1
                );
            }
        }
    }

    function _seed(OrbitalFXHook hook, MockERC20[] memory tokens) internal {
        for (uint256 i = 0; i < N; ++i) {
            tokens[i].approve(address(hook), type(uint256).max);
        }
        TierLadder.seed(hook, N, TierLadder.Profile.FX, TierLadder.DEFAULT_CAPITAL_PER_ASSET);
    }

    // ─────────────────────────────── report ──────────────────────────────────

    function _report(Config memory c, bool mirror, OrbitalFXHook hook, Currency[] memory assets) internal view {
        (uint256 sumX,, uint256 rInt,,) = hook.slot0();
        console2.log("");
        console2.log("=========== ORBITAL FX ON ARC ===========");
        console2.log("chainId:        ", block.chainid);
        console2.log("PoolManager:    ", address(c.pm));
        console2.log("OrbitalFXHook:  ", address(hook));
        console2.log(mirror ? "EUR/USD mirror: " : "EUR/USD feed:   ", address(c.feed));
        if (mirror) console2.log("  mirrors Chainlink on chain 1:", SOURCE_EUR_USD);
        console2.log("maxPriceAge (s):", c.maxAge);
        console2.log("band (bps):     ", c.band);
        console2.log("rInt:           ", rInt);
        // sumX is the engine's (virtual) total; the tokens held are that less
        // the virtual floor on every asset.
        console2.log("TVL (real, wad):", sumX - uint256(N) * hook.virtualReserve());
        console2.log("sumX (virtual): ", sumX);
        console2.log("--- assets (sorted, index order) ---");
        for (uint8 i = 0; i < N; ++i) {
            address a = Currency.unwrap(assets[i]);
            console2.log(MockERC20(a).symbol(), a);
            console2.log("   index:", i, "centre scale:", hook.scaleOf(i));
            console2.log("   feed:", address(hook.feedOf(i)));
        }
        console2.log("=========================================");
    }
}
