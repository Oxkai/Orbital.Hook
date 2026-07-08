// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {OrbitalDepegCallback} from "../src/reactive/OrbitalDepegCallback.sol";
import {OrbitalDepegReactive} from "../src/reactive/OrbitalDepegReactive.sol";
import {MockChainlinkFeed} from "../src/reactive/MockChainlinkFeed.sol";

interface IOrbitalGuardianAdmin {
    function setGuardian(address newGuardian) external;
    function guardian() external view returns (address);
}

/// @notice Deploys the Reactive Network depeg circuit-breaker for Orbital.
///
/// Steps, in order:
///   STEP 0 — origin chain: deploy a triggerable mock Chainlink feed (demo).
///   STEP 1 — destination chain (Unichain Sepolia, 1301): deploy the callback
///            receiver and wire it as the hook's guardian.
///   STEP 2 — Reactive Lasna testnet (5318007): deploy the reactive watcher,
///            pointing it at the callback from step 1.
///
/// Mainnets and testnets must not be mixed: a testnet origin/destination pairs
/// only with the Reactive Lasna testnet.
///
/// Env vars:
///   HOOK              deployed OrbitalHook address (destination chain)
///   CALLBACK_SENDER   destination-chain callback proxy
///                     (Unichain Sepolia = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4)
///   CALLBACK_CONTRACT address printed by deployCallback() (used by deployReactive())
///   ORIGIN_CHAIN_ID   chain emitting the Chainlink AnswerUpdated events
///   PRICE_FEED        Chainlink aggregator to watch (the stablecoin's USD feed)
///   ASSET             the stablecoin address that feed prices
///   DEST_CHAIN_ID     destination chain id (1301 for Unichain Sepolia)
///   LOWER_BOUND       peg-band floor in feed decimals  (e.g. 98000000  = $0.98 @ 8dp)
///   UPPER_BOUND       peg-band ceiling in feed decimals (e.g. 102000000 = $1.02 @ 8dp)
///   DEPEG_PRICE       (triggerDepeg only) out-of-band price to push (e.g. 90000000)
///
/// IMPORTANT: deploy the callback and the reactive watcher from the SAME
/// account — the callback's `rvm_id` is bound to its deployer, and the reactive
/// contract's callbacks are issued under that same RVM id.
contract DeployReactiveScript is Script {
    /// STEP 1 — destination chain (Unichain Sepolia).
    function deployCallback() external {
        address hook = vm.envAddress("HOOK");
        address callbackSender = vm.envAddress("CALLBACK_SENDER");

        vm.startBroadcast();

        // A small ETH balance lets the contract settle callback-proxy debt.
        OrbitalDepegCallback callback = new OrbitalDepegCallback{value: 0.05 ether}(callbackSender, hook);
        console2.log("OrbitalDepegCallback:", address(callback));

        // Authorize it as the hook's guardian (deployer must be the hook owner).
        IOrbitalGuardianAdmin(hook).setGuardian(address(callback));
        require(IOrbitalGuardianAdmin(hook).guardian() == address(callback), "guardian not set");
        console2.log("Guardian set on hook:", hook);

        vm.stopBroadcast();

        console2.log("Next: set CALLBACK_CONTRACT=%s and run deployReactive() on Lasna", address(callback));
    }

    /// STEP 2 — Reactive Lasna.
    /// NOTE: deploy with `forge create` (not this script's broadcast) because the
    /// RSC constructor calls the Lasna system-contract precompile, which forge's
    /// local simulation cannot execute. This function is kept for reference; the
    /// canonical path is the `forge create ...` command in DEPLOY.md.
    function deployReactive() external {
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        address feed = vm.envAddress("PRICE_FEED");
        address asset = vm.envAddress("ASSET");
        uint256 destChainId = vm.envUint("DEST_CHAIN_ID");
        address callbackContract = vm.envAddress("CALLBACK_CONTRACT");
        int256 lowerBound = vm.envInt("LOWER_BOUND");
        int256 upperBound = vm.envInt("UPPER_BOUND");

        vm.startBroadcast();

        // Fund it so it can pay for emitted callbacks.
        OrbitalDepegReactive reactive = new OrbitalDepegReactive{value: 0.1 ether}(
            originChainId, feed, asset, destChainId, callbackContract, lowerBound, upperBound
        );

        vm.stopBroadcast();

        console2.log("OrbitalDepegReactive:", address(reactive));
        console2.log("Watching feed:", feed);
        console2.log("Origin chain:", originChainId);
    }

    /// STEP 0 (origin chain) — deploy a triggerable mock Chainlink feed for the
    /// demo. Starts pegged at $1.00 (8 decimals). Set its printed address as
    /// PRICE_FEED for deployReactive().
    function deployMockFeed() external {
        vm.startBroadcast();
        MockChainlinkFeed feed = new MockChainlinkFeed("USDC / USD (mock)", 100_000_000);
        vm.stopBroadcast();
        console2.log("MockChainlinkFeed:", address(feed));
        console2.log("Set PRICE_FEED=%s for deployReactive()", address(feed));
    }

    /// DEMO TRIGGER (origin chain) — push an out-of-band price to the mock feed,
    /// which fires AnswerUpdated -> the RSC -> the cross-chain pause.
    /// Env: PRICE_FEED, DEPEG_PRICE (e.g. 90000000 = $0.90).
    function triggerDepeg() external {
        address feed = vm.envAddress("PRICE_FEED");
        int256 price = vm.envInt("DEPEG_PRICE");
        vm.startBroadcast();
        MockChainlinkFeed(feed).updateAnswer(price);
        vm.stopBroadcast();
        console2.log("Pushed depeg price to feed:", feed);
    }
}
