// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMailbox, IMessageRecipient} from "../../src/crosschain/IHyperlane.sol";

/// @notice Test double for a Hyperlane Mailbox.
/// @dev Records dispatches instead of relaying them, and exposes `deliver` so a
///      test can play the relayer explicitly. Delivery goes through the real
///      `handle` entry point with this mailbox as msg.sender, so the recipient's
///      authentication (caller-is-mailbox, sender-is-registered-peer) is genuinely
///      exercised rather than bypassed.
contract MockMailbox is IMailbox {
    uint32 public immutable localDomain;
    uint256 public feeWei = 1e13;

    struct Dispatched {
        uint32 destinationDomain;
        bytes32 recipient;
        bytes body;
        address sender;
    }

    Dispatched[] public sent;

    constructor(uint32 _localDomain) {
        localDomain = _localDomain;
    }

    function setFee(uint256 f) external {
        feeWei = f;
    }

    function sentCount() external view returns (uint256) {
        return sent.length;
    }

    function lastBody() external view returns (bytes memory) {
        return sent[sent.length - 1].body;
    }

    function quoteDispatch(uint32, bytes32, bytes calldata) external view override returns (uint256) {
        return feeWei;
    }

    function dispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody)
        external
        payable
        override
        returns (bytes32)
    {
        require(msg.value >= feeWei, "MockMailbox: underpaid");
        sent.push(
            Dispatched({
                destinationDomain: destinationDomain,
                recipient: recipientAddress,
                body: messageBody,
                sender: msg.sender
            })
        );
        return keccak256(abi.encode(sent.length, destinationDomain, messageBody));
    }

    /// @notice Play the relayer: hand `body` to `recipient` as if it arrived from
    ///         `origin`/`sender`. Called with this contract as msg.sender.
    function deliver(address recipient, uint32 origin, bytes32 sender, bytes memory body) external {
        IMessageRecipient(recipient).handle(origin, sender, body);
    }
}
