// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title PositionLib
/// @notice LP position tracking for the orbital AMM.
///         Per-asset fee accounting is held in pool-level mappings keyed by
///         positionKey, not on the Position struct itself.
library PositionLib {
    // Position struct

    struct Position {
        uint256 tickIndex; // tick this position belongs to
        uint256 r;         // radius contribution (liquidity), WAD-scaled
    }

    // Key

    /// @notice Deterministic storage key for an (owner, tickIndex) pair.
    function positionKey(address owner, uint256 tickIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickIndex));
    }

    // Lookup

    /// @notice Retrieve a position from storage by owner and tick.
    function get(
        mapping(bytes32 => Position) storage positions,
        address owner,
        uint256 tickIndex
    ) internal view returns (Position storage) {
        return positions[positionKey(owner, tickIndex)];
    }
}
