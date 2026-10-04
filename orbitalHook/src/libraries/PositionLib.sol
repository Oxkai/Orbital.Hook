// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title PositionLib
/// @notice LP position tracking for the orbital AMM. A position is keyed by
///         (owner, tick), so the key already carries the tick; per-asset fee
///         accounting lives in the hook's mappings keyed by the same key.
library PositionLib {
    struct Position {
        uint256 r; // radius contribution (liquidity), WAD-scaled
    }

    /// @notice Deterministic storage key for an (owner, tickIndex) pair.
    /// @dev    Both parts are fixed-width, so `encodePacked` cannot collide.
    function positionKey(address owner, uint256 tickIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickIndex));
    }
}
