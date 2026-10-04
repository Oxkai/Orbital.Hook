// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SoulboundShares
/// @notice The LP share ledger: an ERC-6909-shaped balance per (owner, id) that
///         cannot move between accounts.
///
/// @dev    Orbital's positions are soulbound. Fee checkpoints and contributed
///         radius are keyed by the minter, and moving a share without that
///         bookkeeping would leave the new holder unable to burn or collect, so
///         `OrbitalHook` refuses every transfer and every approval that exists
///         only to enable one.
///
///         That makes the transferable half of ERC-6909 — allowances, operators
///         and the logic that spends them — permanently dead: storage that is
///         always zero behind code that can never run. This holds the half that
///         is real. The balance mapping and `Transfer` event keep ERC-6909's
///         shape, so a reader that understands ERC-6909 still reads balances
///         and mints correctly; the hook keeps the refusing `transfer`,
///         `transferFrom`, `approve` and `setOperator` entry points so a caller
///         is told no by name rather than by a missing function.
abstract contract SoulboundShares {
    /// @notice Shares held, by owner and share id (the band).
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    /// @dev ERC-6909's event, with `from`/`to` zero for a mint/burn.
    event Transfer(
        address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount
    );

    function _mint(address to, uint256 id, uint256 amount) internal {
        balanceOf[to][id] += amount;
        emit Transfer(msg.sender, address(0), to, id, amount);
    }

    /// @dev Reverts on underflow, so a burn can never exceed the balance.
    function _burn(address from, uint256 id, uint256 amount) internal {
        balanceOf[from][id] -= amount;
        emit Transfer(msg.sender, from, address(0), id, amount);
    }
}
