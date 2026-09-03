// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {OrbitalIntentSettler} from "../src/crosschain/OrbitalIntentSettler.sol";
import {IMailbox} from "../src/crosschain/IHyperlane.sol";

/// @notice Deploys the ERC-7683 settler on ONE chain, pointed at that chain's
///         already-deployed OrbitalHook. Run once per chain; each deployment plays
///         both the origin and destination role for its own chain.
///
/// @dev Required env:
///        ORBITAL_HOOK   address of the OrbitalHook on THIS chain
///        HYPERLANE_MAILBOX  Hyperlane Mailbox on THIS chain
///      Optional env:
///        V4_ROUTER      override the router; defaults to the canonical one for
///                       this chainId, which Unichain lacks (deploy via
///                       DeployPeriphery.s.sol and pass it here)
///        ADMIN          owner; defaults to the broadcasting account
///
///      Example:
///        export ORBITAL_HOOK=0x...
///        export ARBITER=0x...
///        forge script script/DeployCrosschain.s.sol \
///            --rpc-url $BASE_RPC --broadcast --private-key $PRIVATE_KEY
///
///      AFTER deploying on every chain, register each settler's address in the
///      solver config and in the frontend's per-chain map. The settler addresses
///      differ per chain (different constructor args), so there is no single
///      canonical address to hardcode.
contract DeployCrosschainScript is Script {
    function run() external {
        address hook = vm.envAddress("ORBITAL_HOOK");
        address mailbox = vm.envAddress("HYPERLANE_MAILBOX");
        address admin = vm.envOr("ADMIN", msg.sender);

        address router = vm.envOr("V4_ROUTER", address(0));
        if (router == address(0)) {
            router = AddressConstants.getV4SwapRouterAddress(block.chainid);
        }
        require(router.code.length > 0, "router has no code on this chain");
        require(hook.code.length > 0, "hook has no code on this chain");

        vm.startBroadcast();
        OrbitalIntentSettler settler =
            new OrbitalIntentSettler(hook, IUniswapV4Router04(payable(router)), IMailbox(mailbox), admin);
        vm.stopBroadcast();

        console2.log("chainId:          ", block.chainid);
        console2.log("OrbitalHook:      ", hook);
        console2.log("V4 Router:        ", router);
        console2.log("IntentSettler:    ", address(settler));
        console2.log("admin:            ", admin);
        console2.log("mailbox:          ", mailbox);
        console2.log("localDomain:      ", settler.localDomain());
        console2.log("refundBuffer:     ", settler.refundBuffer());
    }
}
