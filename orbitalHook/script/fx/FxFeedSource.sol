// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {IAggregatorV3} from "../../src/fx/IAggregatorV3.sol";
import {TestnetFxFeed} from "../mocks/TestnetFxFeed.sol";

/// @notice Reads a round from a Chainlink feed on another chain and copies it
///         into a `TestnetFxFeed`. Shared by `DeployArcFX.s.sol` (first round)
///         and `SyncFxFeed.s.sol` (every round after).
/// @dev    The source is read on a temporary fork and the script switches back
///         to the chain it was started on before returning, so callers
///         broadcast only to their own chain.
abstract contract FxFeedSource is Script {
    /// @dev Chainlink EUR / USD on Ethereum mainnet (data.chain.link), the
    ///      source for the Arc testnet mirror.
    uint256 internal constant SOURCE_CHAIN_ID = 1;
    address internal constant SOURCE_EUR_USD = 0xb49f677943BC038e9857d61E7d053CaA2C1734C1;

    struct SourceRound {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint8 decimals;
        string description;
    }

    /// @dev RPC for the source chain: `FX_SOURCE_RPC` (URL or foundry.toml
    ///      alias), default the public `eth_mainnet` endpoint.
    function _readSource(uint256 chainId, address feed) internal returns (SourceRound memory r) {
        uint256 home = vm.activeFork();
        vm.createSelectFork(vm.envOr("FX_SOURCE_RPC", string("eth_mainnet")));
        require(block.chainid == chainId, "FX_SOURCE_RPC is not the source feed's chain");
        require(feed.code.length > 0, "no source feed at that address");

        (r.roundId, r.answer, r.startedAt, r.updatedAt,) = IAggregatorV3(feed).latestRoundData();
        r.decimals = IAggregatorV3(feed).decimals();
        r.description = IAggregatorV3(feed).description();
        vm.selectFork(home);
    }

    /// @dev Must run inside a broadcast from the mirror's owner.
    function _mirror(TestnetFxFeed mirror, SourceRound memory r) internal {
        require(r.decimals == mirror.decimals(), "source and mirror decimals differ");
        mirror.push(r.roundId, r.answer, r.startedAt, r.updatedAt);
    }
}
