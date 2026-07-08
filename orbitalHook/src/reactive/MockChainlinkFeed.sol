// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockChainlinkFeed
/// @notice Minimal Chainlink-style aggregator for the Reactive depeg-breaker
///         demo. It emits exactly the `AnswerUpdated(int256,uint256,uint256)`
///         event the {OrbitalDepegReactive} watcher subscribes to, and lets the
///         owner push any price on demand — so a depeg can be triggered for the
///         demo (a real stablecoin feed never actually depegs in a test window).
///
///         Deploy this on the ORIGIN chain, point the Reactive watcher's
///         PRICE_FEED at it, then call `updateAnswer(...)` with an out-of-band
///         price to fire the breaker.
contract MockChainlinkFeed {
    /// @dev Matches the canonical Chainlink aggregator event the RSC subscribes to.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    uint8 public constant decimals = 8; // Chainlink USD feeds use 8 decimals
    string public description;
    address public owner;

    int256 public latestAnswer;
    uint80 public latestRound;
    uint256 public latestTimestamp;

    constructor(string memory _description, int256 initialAnswer) {
        owner = msg.sender;
        description = _description;
        _update(initialAnswer);
    }

    /// @notice Push a new price and emit AnswerUpdated. e.g. 100000000 = $1.00,
    ///         90000000 = $0.90 (a depeg).
    function updateAnswer(int256 answer) external {
        require(msg.sender == owner, "only owner");
        _update(answer);
    }

    function _update(int256 answer) internal {
        latestRound += 1;
        latestAnswer = answer;
        latestTimestamp = block.timestamp;
        emit AnswerUpdated(answer, latestRound, block.timestamp);
    }

    /// @notice AggregatorV3-style read (handy for sanity checks).
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (latestRound, latestAnswer, latestTimestamp, latestTimestamp, latestRound);
    }
}
