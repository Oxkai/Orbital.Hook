// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {TestnetFxFeed} from "../mocks/TestnetFxFeed.sol";
import {FxFeedSource} from "./FxFeedSource.sol";

/// @notice Copy the latest round of the source Chainlink feed into a
///         `TestnetFxFeed` mirror. Does nothing, and broadcasts nothing, when
///         the mirror already carries that round.
///
/// @dev    The FX pool halts once the mirror's `updatedAt` is older than the
///         pool's `maxPriceAge`, exactly as it would on a real feed that
///         stopped. Chainlink FX feeds update at least every 24h, so running
///         this hourly keeps the mirror within about an hour of the source.
///
///         Required env: FX_FEED        the mirror (see deployments.json)
///         Optional env: FX_SOURCE_RPC  source chain RPC, default eth_mainnet
///
///         forge script script/fx/SyncFxFeed.s.sol --rpc-url arc_testnet \
///             --broadcast --private-key $PRIVATE_KEY
contract SyncFxFeedScript is FxFeedSource {
    function run() external {
        TestnetFxFeed mirror = TestnetFxFeed(vm.envAddress("FX_FEED"));
        require(address(mirror).code.length > 0, "FX_FEED has no code on this chain");

        SourceRound memory r = _readSource(mirror.sourceChainId(), mirror.sourceFeed());
        (uint80 have,,, uint256 haveAt,) = mirror.latestRoundData();
        console2.log("source", r.description, "round", r.roundId);
        console2.log("  answer", uint256(r.answer), "updatedAt", r.updatedAt);

        if (r.updatedAt <= haveAt) {
            console2.log("mirror already current at round", have);
            return;
        }
        require(r.updatedAt <= block.timestamp, "source round is ahead of this chain's clock; rerun shortly");

        vm.startBroadcast();
        _mirror(mirror, r);
        vm.stopBroadcast();
        console2.log("mirrored; age on this chain (s):", block.timestamp - r.updatedAt);
    }
}
