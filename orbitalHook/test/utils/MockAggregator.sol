// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAggregatorV3} from "../../src/fx/IAggregatorV3.sol";

/// @notice Test double for one Chainlink `AggregatorV3` feed. It returns
///         whatever was last set with no checks of its own, like a real feed:
///         staleness and sign are the CONSUMER's job, which is exactly what the
///         tests exercise. Before the first `setAnswer` it returns all zeros,
///         the shape of a feed with no rounds.
contract MockAggregator is IAggregatorV3 {
    uint8 public immutable override decimals;
    string public override description;

    uint80 internal _roundId;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_, string memory description_) {
        decimals = decimals_;
        description = description_;
    }

    function setAnswer(int256 answer, uint256 updatedAt) external {
        _roundId++;
        _answer = answer;
        _updatedAt = updatedAt;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
