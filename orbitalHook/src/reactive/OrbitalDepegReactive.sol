// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @title OrbitalDepegReactive
/// @notice Reactive-Network-side contract (deployed on Reactive Lasna testnet)
///         that watches a Chainlink price feed for one of the pool's
///         stablecoins. When the reported price leaves the configured peg band,
///         it emits a cross-chain {Callback} to the {OrbitalDepegCallback} on
///         the destination chain, which pauses the Orbital pool — a keeper-free
///         depeg circuit-breaker that reacts faster than any human.
/// @dev    Subscribes to the feed's `AnswerUpdated(int256,uint256,uint256)`
///         event. Chainlink indexes `current` (the new price) as topic_1 and
///         `roundId` as topic_2, so the price is read directly from the log
///         topics with no `data` decoding.
contract OrbitalDepegReactive is IReactive, AbstractReactive {
    /// @dev keccak256("AnswerUpdated(int256,uint256,uint256)").
    uint256 private constant ANSWER_UPDATED_TOPIC_0 =
        0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f;

    uint64 private constant CALLBACK_GAS_LIMIT = 200_000;

    /// @notice EIP-155 chain id of the chain emitting the oracle events.
    uint256 public immutable originChainId;
    /// @notice The Chainlink aggregator being monitored.
    address public immutable feed;
    /// @notice The stablecoin this feed prices (passed through to the callback).
    address public immutable asset;
    /// @notice Destination chain id (Unichain Sepolia = 1301).
    uint256 public immutable destinationChainId;
    /// @notice The {OrbitalDepegCallback} on the destination chain.
    address public immutable callbackContract;
    /// @notice Peg band, in the feed's decimals (Chainlink USD feeds use 8).
    int256 public immutable lowerBound;
    int256 public immutable upperBound;

    constructor(
        uint256 _originChainId,
        address _feed,
        address _asset,
        uint256 _destinationChainId,
        address _callbackContract,
        int256 _lowerBound,
        int256 _upperBound
    ) payable {
        originChainId = _originChainId;
        feed = _feed;
        asset = _asset;
        destinationChainId = _destinationChainId;
        callbackContract = _callbackContract;
        lowerBound = _lowerBound;
        upperBound = _upperBound;

        // Subscribe only on the Reactive Network side; the RVM copy has no
        // system contract and must not attempt to subscribe.
        if (!vm) {
            service.subscribe(
                _originChainId,
                _feed,
                ANSWER_UPDATED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log) external vmOnly {
        // Chainlink indexes the new answer (int256) as topic_1.
        int256 price = int256(log.topic_1);

        // Still within the peg band — no action.
        if (price >= lowerBound && price <= upperBound) return;

        // Breach: relay a pause to the destination pool. The leading address(0)
        // is a placeholder the callback proxy overwrites with the RVM id.
        bytes memory payload = abi.encodeWithSignature(
            "pauseOnDepeg(address,address,int256)",
            address(0),
            asset,
            price
        );
        emit Callback(destinationChainId, callbackContract, CALLBACK_GAS_LIMIT, payload);
    }
}
