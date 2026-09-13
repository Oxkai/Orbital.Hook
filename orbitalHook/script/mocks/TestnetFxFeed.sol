// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAggregatorV3} from "../../src/fx/IAggregatorV3.sol";

/// @title TestnetFxFeed
///
/// @notice An `AggregatorV3` mirror of a real Chainlink feed on another chain,
///         for testnets where Chainlink has no deployment. Arc testnet (5042002)
///         is the motivating case: as of 2026-09-12 Chainlink publishes FX
///         feeds on Arc MAINNET (EUR / USD at
///         0xDd5B15443cd733D3966a50a3E48cB7DF9Fb5DE0D) and nothing on testnet.
///
///         This contract exists so `OrbitalFXHook` can run on Arc testnet at
///         real market rates. It adds no oracle security of its own: the owner copies
///         each round from the source feed (`script/fx/SyncFxFeed.s.sol`), and
///         nothing on-chain proves the copy is faithful. `sourceChainId` and
///         `sourceFeed` record where every answer came from, so anyone can
///         check a round against the original.
///
/// @dev    The hook is left unmodified and reads this exactly as it reads a
///         Chainlink proxy: its staleness and sign checks still run against
///         the mirrored `updatedAt` and `answer`. Only the transport is fake.
///
///         `push` enforces what a real feed guarantees: a positive answer, a
///         timestamp that is set and not in the future, and rounds that only
///         move forward. A mirrored round keeps the source's round id and
///         timestamps, so it reads as the same round it copies.
///
///         On Arc mainnet, `DeployArcFX.s.sol` points the hook at Chainlink's
///         feed and this contract is never deployed.
contract TestnetFxFeed is IAggregatorV3 {
    uint8 public immutable override decimals;
    string public override description;

    /// @notice Chain id and address of the feed this mirrors.
    uint256 public immutable sourceChainId;
    address public immutable sourceFeed;

    /// @notice Allowed to `push`. Transferable, so a syncing job can be handed
    ///         its own key without redeploying the pool that reads this feed.
    address public owner;

    uint80 internal _roundId;
    int256 internal _answer;
    uint256 internal _startedAt;
    uint256 internal _updatedAt;

    event RoundMirrored(uint80 indexed roundId, int256 answer, uint256 updatedAt);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner(address caller);
    error ZeroOwner();
    error InvalidAnswer(int256 answer);
    error InvalidTimestamps(uint256 startedAt, uint256 updatedAt);
    error RoundNotNewer(uint80 roundId, uint256 updatedAt);

    constructor(
        uint8 decimals_,
        string memory description_,
        uint256 sourceChainId_,
        address sourceFeed_,
        address owner_
    ) {
        if (owner_ == address(0)) revert ZeroOwner();
        decimals = decimals_;
        description = description_;
        sourceChainId = sourceChainId_;
        sourceFeed = sourceFeed_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    /// @notice Copy one round from the source feed, field for field.
    function push(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt) external onlyOwner {
        if (answer <= 0) revert InvalidAnswer(answer);
        if (updatedAt == 0 || updatedAt > block.timestamp || startedAt > updatedAt) {
            revert InvalidTimestamps(startedAt, updatedAt);
        }
        if (roundId <= _roundId || updatedAt <= _updatedAt) revert RoundNotNewer(roundId, updatedAt);

        _roundId = roundId;
        _answer = answer;
        _startedAt = startedAt;
        _updatedAt = updatedAt;
        emit RoundMirrored(roundId, answer, updatedAt);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice The latest mirrored round, in the source's own terms. All zeros
    ///         before the first `push`, like a feed with no rounds.
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _startedAt, _updatedAt, _roundId);
    }
}
