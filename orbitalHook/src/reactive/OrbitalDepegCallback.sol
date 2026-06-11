// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";

interface IOrbitalGuardian {
    function guardianPause() external;
}

/// @title OrbitalDepegCallback
/// @notice Destination-chain (Unichain Sepolia) receiver for the Reactive
///         Network depeg circuit-breaker. The Reactive callback proxy invokes
///         {pauseOnDepeg} when an off-chain price oracle reports that one of
///         the pool's stablecoins has broken its peg; this contract relays that
///         into the live {OrbitalHook} by calling its guardian-gated pause.
/// @dev    Deploy this, then call `OrbitalHook.setGuardian(address(this))` from
///         the hook owner so this contract is authorized to pause the pool.
///         `_callback_sender` must be the Unichain Sepolia callback proxy:
///         0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4
contract OrbitalDepegCallback is AbstractCallback {
    /// @notice The Orbital hook this circuit-breaker protects.
    IOrbitalGuardian public immutable hook;

    /// @notice Emitted when a depeg signal is relayed into the hook.
    /// @param rvmId The originating ReactVM id (validated against `rvm_id`).
    /// @param asset The stablecoin reported to have depegged.
    /// @param price The breaching price, in the oracle feed's decimals.
    event DepegPauseRelayed(address indexed rvmId, address indexed asset, int256 price);

    constructor(address _callback_sender, address _hook)
        payable
        AbstractCallback(_callback_sender)
    {
        hook = IOrbitalGuardian(_hook);
    }

    /// @notice Reactive callback entry point. Pauses the protected pool.
    /// @dev `sender` is injected by the callback proxy as the first argument and
    ///      must equal this contract's `rvm_id` (the deploying account). The
    ///      `authorizedSenderOnly` modifier confirms the caller is the proxy.
    /// @param sender The originating ReactVM id.
    /// @param asset  The depegged stablecoin (for the event trail only).
    /// @param price  The breaching price, in the feed's decimals (for the event).
    function pauseOnDepeg(address sender, address asset, int256 price)
        external
        authorizedSenderOnly
        rvmIdOnly(sender)
    {
        emit DepegPauseRelayed(sender, asset, price);
        hook.guardianPause();
    }
}
