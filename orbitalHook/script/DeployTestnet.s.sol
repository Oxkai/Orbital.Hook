// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TierLadder} from "./lib/TierLadder.sol";
import {OrbitalDeploy} from "./lib/OrbitalDeploy.sol";
import {OrbitalIntentSettler} from "../src/crosschain/OrbitalIntentSettler.sol";
import {IMailbox} from "../src/crosschain/IHyperlane.sol";

/// @notice Chain-agnostic testnet deploy: mock stables -> OrbitalHook -> all pair
///         pools -> seeded liquidity -> ERC-7683 settler. Run once per chain.
///
/// @dev This script:
///        - resolves PoolManager/Router from `AddressConstants` by chainId rather
///          than hardcoding Unichain Sepolia
///        - uses REALISTIC MIXED DECIMALS (USDC/USDT 6, DAI/FRAX 18) so the hook's
///          `_scale` conversion path is exercised, not bypassed
///        - seeds the shared `TierLadder`: six concentrated bands whose depth
///          tapers away from the peg, plus a small full-range backstop
///        - also deploys the intent settler when the chain has a Hyperlane
///          Mailbox, so one run per chain is enough
///
///      Optional env: HYPERLANE_MAILBOX (unset = no settler; the chain is
///                                       same-chain only)
///                    V4_POOL_MANAGER   (override; needed on chains hookmate
///                                       does not know, e.g. Robinhood testnet)
///                    V4_ROUTER         (override; needed where no canonical
///                                       router exists)
///
///      forge script script/DeployTestnet.s.sol --rpc-url base_sepolia \
///          --broadcast --private-key $PRIVATE_KEY
contract DeployTestnetScript is Script {
    uint8 internal constant N = 4;

    string[4] internal SYMBOLS = ["USDC", "USDT", "DAI", "FRAX"];
    string[4] internal NAMES = ["USD Coin", "Tether USD", "Dai Stablecoin", "Frax"];
    uint8[4] internal DECIMALS = [6, 6, 18, 18];


    function run() external {
        address mailbox = vm.envOr("HYPERLANE_MAILBOX", address(0));

        address pm = vm.envOr("V4_POOL_MANAGER", address(0));
        if (pm == address(0)) pm = AddressConstants.getPoolManagerAddress(block.chainid);
        address rt = vm.envOr("V4_ROUTER", address(0));
        if (rt == address(0)) rt = AddressConstants.getV4SwapRouterAddress(block.chainid);
        address permit2 = OrbitalDeploy.PERMIT2;

        require(pm.code.length > 0, "no PoolManager on this chain");
        require(rt.code.length > 0, "no V4Router on this chain");
        require(permit2.code.length > 0, "no Permit2 on this chain");
        require(
            vm.envOr("CREATE2_DEPLOYER", OrbitalDeploy.CREATE2_FACTORY).code.length > 0,
            "no CREATE2 deployer on this chain"
        );
        require(mailbox == address(0) || mailbox.code.length > 0, "no Mailbox at HYPERLANE_MAILBOX");

        vm.startBroadcast();

        Currency[] memory assets = _deployTokens();
        // Chains without the canonical deterministic deployer pass their own
        // CREATE2 factory, so the hook's permission-flag address can still be mined.
        address create2Deployer = vm.envOr("CREATE2_DEPLOYER", OrbitalDeploy.CREATE2_FACTORY);
        OrbitalHook hook = OrbitalDeploy.deployHook(IPoolManager(pm), assets, msg.sender, create2Deployer);
        OrbitalDeploy.initPools(IPoolManager(pm), hook, assets);
        OrbitalDeploy.seed(hook, assets, TierLadder.DEFAULT_CAPITAL_PER_ASSET);
        OrbitalIntentSettler settler;
        if (mailbox != address(0)) {
            settler =
                new OrbitalIntentSettler(address(hook), IUniswapV4Router04(payable(rt)), IMailbox(mailbox), msg.sender);
        }

        vm.stopBroadcast();

        _report(hook, settler, assets, pm, rt, mailbox);
    }

    // ─────────────────────────────────────────────────────────────

    function _deployTokens() internal returns (Currency[] memory sorted) {
        MockERC20[4] memory raw;
        for (uint8 i = 0; i < N; ++i) {
            raw[i] = new MockERC20(NAMES[i], SYMBOLS[i], DECIMALS[i]);
            // Mint plenty: seeding takes ~1.5M per asset at these tiers.
            raw[i].mint(msg.sender, 100_000_000 * (10 ** DECIMALS[i])); // >> the 1.25M/asset the seed consumes
        }
        address[] memory addrs = new address[](N);
        for (uint8 i = 0; i < N; ++i) addrs[i] = address(raw[i]);
        sorted = OrbitalDeploy.sorted(addrs);
    }

    function _report(
        OrbitalHook hook,
        OrbitalIntentSettler settler,
        Currency[] memory assets,
        address pm,
        address rt,
        address mailbox
    ) internal view {
        OrbitalDeploy.report(hook, assets, pm, rt);
        if (address(settler) != address(0)) {
            console2.log("IntentSettler: ", address(settler));
            console2.log("mailbox:       ", mailbox);
            console2.log("localDomain:   ", settler.localDomain());
        } else {
            console2.log("IntentSettler:  none (no HYPERLANE_MAILBOX; same-chain only)");
        }
    }
}
