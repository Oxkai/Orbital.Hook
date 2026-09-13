// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TierLadder} from "./lib/TierLadder.sol";
import {OrbitalIntentSettler} from "../src/crosschain/OrbitalIntentSettler.sol";
import {IMailbox} from "../src/crosschain/IHyperlane.sol";
import {TestnetMailbox} from "./mocks/TestnetMailbox.sol";

/// @notice Orbital deployment for Circle's Arc.
///
/// @dev Arc needs its own script because `DeployTestnet.s.sol` resolves the v4
///      contracts from `hookmate`'s `AddressConstants`, which covers 19 chains
///      and does not include Arc. Verified against Arc testnet on 2026-09-06:
///
///        PRESENT   Permit2          0x000000000022D473030F116dDEE9F6B43aC78BA3  (9152 bytes)
///        PRESENT   CREATE2 factory  0x4e59b44847b379578588920cA78FbF26c0B4956C  (69 bytes)
///        PRESENT   Multicall3       0xcA11bde05977b3631167028862bE2a173976CA11
///        PRESENT   USDC predeploy   0x3600000000000000000000000000000000000000  (6dp ERC-20 view)
///        ABSENT    Uniswap v4       every known PoolManager address returns 0 bytes
///        ABSENT    Hyperlane        no testnet entry in the Hyperlane registry
///
///      Arc MAINNET (5042) has both: PoolManager 0x8366a39cc670b4001a1121b8f6a443a643e40951
///      and Hyperlane mailbox 0x7f50C5776722630a0024fAE05fDe8b47571D7B39. Mainnet
///      opens 2026-09-16. So every dependency here is resolved as
///      "use the canonical address if one is configured, otherwise deploy it",
///      and the same script serves both networks without edits.
///
///      Mock stables are used rather than Arc's native USDC predeploy so that the
///      basket matches the other three chains in `deployments.json` exactly, and
///      so seeding does not depend on faucet balances. Decimals are still mixed
///      (6/6/18/18) so the hook's `_scale` path is exercised, not bypassed.
///
///      Arc's gas token IS USDC, and native USDC is 18-decimal while the ERC-20
///      view is 6-decimal. Nothing here reads a native balance, so that split
///      does not reach the hook, but it is the first place to look if a value
///      transfer ever misbehaves on this chain.
///
///      Optional env:
///        V4_POOL_MANAGER   canonical PoolManager; deployed fresh when unset
///        V4_ROUTER         canonical router;      deployed fresh when unset
///        HYPERLANE_MAILBOX canonical mailbox;     TestnetMailbox shim when unset
///
///      Run:
///        forge script script/DeployArc.s.sol --rpc-url arc_testnet \
///            --broadcast --private-key $PRIVATE_KEY
///
///      Gas is USDC on Arc. Fund the deployer at https://faucet.circle.com first.
contract DeployArcScript is Script {
    uint256 internal constant ARC_MAINNET = 5042;
    uint256 internal constant ARC_TESTNET = 5042002;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant POOL_FEE = 100; // 1bp, in hundredths of a bip
    uint8 internal constant N = 4;

    string[4] internal SYMBOLS = ["USDC", "USDT", "DAI", "FRAX"];
    string[4] internal NAMES = ["USD Coin", "Tether USD", "Dai Stablecoin", "Frax"];
    uint8[4] internal DECIMALS = [6, 6, 18, 18];

    bool internal mailboxIsShim;

    function run() external {
        require(
            block.chainid == ARC_TESTNET || block.chainid == ARC_MAINNET,
            "DeployArc: not an Arc chain (expected 5042002 or 5042)"
        );
        require(PERMIT2.code.length > 0, "no Permit2 on this chain");
        require(CREATE2_FACTORY.code.length > 0, "no CREATE2 factory; cannot mine hook address");

        vm.startBroadcast();

        address pm = _resolvePoolManager();
        address rt = _resolveRouter(pm);
        address mb = _resolveMailbox();

        Currency[] memory assets = _deployTokens();
        OrbitalHook hook = _deployHook(IPoolManager(pm), IAllowanceTransfer(PERMIT2), assets, msg.sender);
        _initPools(IPoolManager(pm), hook, assets);
        _seed(hook, assets);

        OrbitalIntentSettler settler = new OrbitalIntentSettler(
            address(hook), IUniswapV4Router04(payable(rt)), IMailbox(mb), msg.sender
        );

        vm.stopBroadcast();

        _report(hook, settler, assets, pm, rt, mb);
    }

    // ───────────────────────── dependency resolution ─────────────────────────

    /// @dev Canonical if configured and code-bearing, else a fresh deploy owned
    ///      by the deployer. Arc testnet has no v4, so the fresh path is normal
    ///      there and is not a fallback for a misconfiguration.
    function _resolvePoolManager() internal returns (address pm) {
        pm = vm.envOr("V4_POOL_MANAGER", address(0));
        if (pm != address(0)) {
            require(pm.code.length > 0, "V4_POOL_MANAGER set but has no code");
            console2.log("PoolManager:    canonical", pm);
            return pm;
        }
        pm = V4PoolManagerDeployer.deploy(msg.sender);
        console2.log("PoolManager:    DEPLOYED   ", pm);
    }

    function _resolveRouter(address pm) internal returns (address rt) {
        rt = vm.envOr("V4_ROUTER", address(0));
        if (rt != address(0)) {
            require(rt.code.length > 0, "V4_ROUTER set but has no code");
            console2.log("V4Router:       canonical", rt);
            return rt;
        }
        rt = V4RouterDeployer.deploy(pm, PERMIT2);
        console2.log("V4Router:       DEPLOYED   ", rt);
    }

    /// @dev The shim is transport-only scaffolding; see TestnetMailbox for the
    ///      full warning. Supplying HYPERLANE_MAILBOX bypasses it entirely,
    ///      which is what Arc mainnet should do.
    function _resolveMailbox() internal returns (address mb) {
        mb = vm.envOr("HYPERLANE_MAILBOX", address(0));
        if (mb != address(0)) {
            require(mb.code.length > 0, "HYPERLANE_MAILBOX set but has no code");
            console2.log("Mailbox:        canonical", mb);
            return mb;
        }
        mailboxIsShim = true;
        mb = address(new TestnetMailbox(uint32(block.chainid), msg.sender));
        console2.log("Mailbox:        SHIM       ", mb);
    }

    // ──────────────────────────────── pool ───────────────────────────────────

    function _deployTokens() internal returns (Currency[] memory sorted) {
        MockERC20[4] memory raw;
        for (uint8 i = 0; i < N; ++i) {
            raw[i] = new MockERC20(NAMES[i], SYMBOLS[i], DECIMALS[i]);
            raw[i].mint(msg.sender, 100_000_000 * (10 ** DECIMALS[i]));
        }
        // Sort ascending by address (the hook constructor requires it).
        for (uint8 i = 0; i < N; ++i) {
            for (uint8 j = uint8(i + 1); j < N; ++j) {
                if (address(raw[j]) < address(raw[i])) (raw[i], raw[j]) = (raw[j], raw[i]);
            }
        }
        sorted = new Currency[](N);
        for (uint8 i = 0; i < N; ++i) sorted[i] = Currency.wrap(address(raw[i]));
    }

    function _deployHook(IPoolManager pm, IAllowanceTransfer permit2, Currency[] memory assets, address admin)
        internal
        returns (OrbitalHook hook)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(pm, permit2, assets, POOL_FEE, admin);
        (address expected, bytes32 salt) = HookMiner.find(CREATE2_FACTORY, flags, type(OrbitalHook).creationCode, args);

        hook = new OrbitalHook{salt: salt}(pm, permit2, assets, POOL_FEE, admin);
        require(address(hook) == expected, "hook address mismatch");
    }

    function _initPools(IPoolManager pm, OrbitalHook hook, Currency[] memory assets) internal {
        for (uint8 i = 0; i < N; ++i) {
            for (uint8 j = uint8(i + 1); j < N; ++j) {
                pm.initialize(
                    PoolKey({
                        currency0: assets[i],
                        currency1: assets[j],
                        fee: 0, // engine runs its own fee; PoolKey.lpFee must be 0
                        tickSpacing: 1,
                        hooks: IHooks(address(hook))
                    }),
                    SQRT_PRICE_1_1
                );
            }
        }
    }

    function _seed(OrbitalHook hook, Currency[] memory assets) internal {
        for (uint8 i = 0; i < N; ++i) {
            MockERC20(Currency.unwrap(assets[i])).approve(address(hook), type(uint256).max);
        }
        TierLadder.seed(hook, N, TierLadder.Profile.STABLE, TierLadder.DEFAULT_CAPITAL_PER_ASSET);
    }

    // ─────────────────────────────── report ──────────────────────────────────

    function _report(
        OrbitalHook hook,
        OrbitalIntentSettler settler,
        Currency[] memory assets,
        address pm,
        address rt,
        address mb
    ) internal view {
        (uint256 sumX,, uint256 rInt,,) = hook.slot0();
        console2.log("");
        console2.log("=========== ORBITAL ON ARC ===========");
        console2.log("chainId:       ", block.chainid);
        console2.log("PoolManager:   ", pm);
        console2.log("V4Router:      ", rt);
        console2.log("OrbitalHook:   ", address(hook));
        console2.log("IntentSettler: ", address(settler));
        console2.log("mailbox:       ", mb);
        console2.log("localDomain:   ", settler.localDomain());
        console2.log("rInt:          ", rInt);
        // sumX is the engine's (virtual) total; the tokens held are that less
        // the virtual floor on every asset.
        console2.log("TVL (real, wad):", sumX - uint256(N) * hook.virtualReserve());
        console2.log("sumX (virtual): ", sumX);
        console2.log("--- assets (sorted, index order) ---");
        for (uint8 i = 0; i < N; ++i) {
            address a = Currency.unwrap(assets[i]);
            console2.log(MockERC20(a).symbol(), a);
            console2.log("   index:", i, "scale:", hook.scaleOf(i));
        }
        if (mailboxIsShim) {
            console2.log("--------------------------------------");
            console2.log("WARNING: mailbox is a TestnetMailbox SHIM.");
            console2.log("No Hyperlane on this chain: messages are NOT relayed.");
            console2.log("Set HYPERLANE_MAILBOX on Arc mainnet for real transport.");
        }
        console2.log("======================================");
    }
}
