// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Chainlink's `AggregatorV3Interface`: the price-feed surface OrbitalFXHook
///         reads. Full docs: https://docs.chain.link/data-feeds/api-reference
///
///         It is the de facto standard for on-chain price feeds, so any source
///         that implements it plugs in unchanged: Chainlink feeds directly,
///         other oracles through their Chainlink-compatible adapters, and the
///         testnet mirror in `script/mocks/TestnetFxFeed.sol`.
interface IAggregatorV3 {
    /// @notice Decimals of `answer` (8 for Chainlink FX feeds).
    function decimals() external view returns (uint8);

    /// @notice Human label, e.g. "EUR / USD".
    function description() external view returns (string memory);

    /// @notice Latest price. `answer` is the price scaled by `10^decimals()`;
    ///         `updatedAt` is when it was last written, the value staleness
    ///         checks must use.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
