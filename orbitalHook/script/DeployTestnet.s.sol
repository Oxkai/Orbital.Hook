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
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TierLadder} from "./lib/TierLadder.sol";
import {OrbitalIntentSettler} from "../src/crosschain/OrbitalIntentSettler.sol";
import {IMailbox} from "../src/crosschain/IHyperlane.sol";

/// @notice Chain-agnostic testnet deploy: mock stables -> OrbitalHook -> all pair
///         pools -> seeded liquidity -> ERC-7683 settler. Run once per chain.
///
/// @dev Unlike the older Deploy.s.sol this script:
///        - resolves PoolManager/Router from `AddressConstants` by chainId rather
///          than hardcoding Unichain Sepolia
///        - uses REALISTIC MIXED DECIMALS (USDC/USDT 6, DAI/FRAX 18) so the hook's
///          `_scale` conversion path is exercised, not bypassed
///        - seeds the shared `TierLadder`: six concentrated bands whose depth
///          tapers away from the peg, plus a small full-range backstop
///        - also deploys the intent settler, so one run per chain is enough
///
///      Required env: HYPERLANE_MAILBOX
///      Optional env: V4_ROUTER (override; needed where no canonical router exists)
///
///      forge script script/DeployTestnet.s.sol --rpc-url base_sepolia \
///          --broadcast --private-key $PRIVATE_KEY
contract DeployTestnetScript is Script {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant POOL_FEE = 100; // 1bp, in hundredths of a bip
    uint8 internal constant N = 4;

    string[4] internal SYMBOLS = ["USDC", "USDT", "DAI", "FRAX"];
    string[4] internal NAMES = ["USD Coin", "Tether USD", "Dai Stablecoin", "Frax"];
    uint8[4] internal DECIMALS = [6, 6, 18, 18];


    function run() external {
        address mailbox = vm.envAddress("HYPERLANE_MAILBOX");

        address pm = AddressConstants.getPoolManagerAddress(block.chainid);
        address rt = vm.envOr("V4_ROUTER", address(0));
        if (rt == address(0)) rt = AddressConstants.getV4SwapRouterAddress(block.chainid);
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

        require(pm.code.length > 0, "no PoolManager on this chain");
        require(rt.code.length > 0, "no V4Router on this chain");
        require(permit2.code.length > 0, "no Permit2 on this chain");

        vm.startBroadcast();

        Currency[] memory assets = _deployTokens();
        OrbitalHook hook = _deployHook(IPoolManager(pm), IAllowanceTransfer(permit2), assets, msg.sender);
        _initPools(IPoolManager(pm), hook, assets);
        _seed(hook, assets);
        OrbitalIntentSettler settler =
            new OrbitalIntentSettler(address(hook), IUniswapV4Router04(payable(rt)), IMailbox(mailbox), msg.sender);

        vm.stopBroadcast();

        _report(hook, settler, assets, pm, rt, mailbox);
    }

    // ─────────────────────────────────────────────────────────────

    function _deployTokens() internal returns (Currency[] memory sorted) {
        MockERC20[4] memory raw;
        for (uint8 i = 0; i < N; ++i) {
            raw[i] = new MockERC20(NAMES[i], SYMBOLS[i], DECIMALS[i]);
            // Mint plenty: seeding takes ~1.5M per asset at these tiers.
            raw[i].mint(msg.sender, 100_000_000 * (10 ** DECIMALS[i])); // >> the ~6M/asset the seed consumes
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

    function _deployHook(
        IPoolManager pm,
        IAllowanceTransfer permit2,
        Currency[] memory assets,
        address admin
    ) internal returns (OrbitalHook hook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(pm, permit2, assets, POOL_FEE, admin);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(OrbitalHook).creationCode, args);

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

    function _report(
        OrbitalHook hook,
        OrbitalIntentSettler settler,
        Currency[] memory assets,
        address pm,
        address rt,
        address mailbox
    ) internal view {
        (uint256 sumX,, uint256 rInt,,) = hook.slot0();
        console2.log("");
        console2.log("=========== ORBITAL DEPLOYMENT ===========");
        console2.log("chainId:       ", block.chainid);
        console2.log("PoolManager:   ", pm);
        console2.log("V4Router:      ", rt);
        console2.log("OrbitalHook:   ", address(hook));
        console2.log("IntentSettler: ", address(settler));
        console2.log("mailbox:       ", mailbox);
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
        console2.log("=========================================");
    }
}
