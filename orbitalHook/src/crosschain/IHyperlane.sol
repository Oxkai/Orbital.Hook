// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal Hyperlane surface used by OrbitalIntentSettler.
///         Full docs: https://docs.hyperlane.xyz

interface IMailbox {
    /// @notice The Hyperlane domain of the chain this mailbox is deployed on.
    ///         For the chains we target this equals the EVM chainId, but that is a
    ///         coincidence and is NOT relied on: domains are configured explicitly.
    function localDomain() external view returns (uint32);

    /// @notice Native fee required to deliver a message to `destinationDomain`.
    function quoteDispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody)
        external
        view
        returns (uint256 fee);

    /// @notice Send `messageBody` to `recipientAddress` on `destinationDomain`.
    ///         Must be called with at least `quoteDispatch(...)` as msg.value.
    function dispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody)
        external
        payable
        returns (bytes32 messageId);
}

/// @notice Implemented by contracts that receive Hyperlane messages.
interface IMessageRecipient {
    /// @param _origin  Hyperlane domain the message came from.
    /// @param _sender  Sending contract on that domain, as bytes32.
    /// @param _message Opaque payload.
    /// @dev MUST verify that msg.sender is the local Mailbox, and that
    ///      (_origin, _sender) is a trusted peer. Hyperlane authenticates
    ///      delivery; it does NOT authenticate who is allowed to talk to you.
    function handle(uint32 _origin, bytes32 _sender, bytes calldata _message) external payable;
}
