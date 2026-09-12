// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMailbox, IMessageRecipient} from "../../src/crosschain/IHyperlane.sol";

/// @title TestnetMailbox
///
/// @notice ⚠️  NOT HYPERLANE. NOT FOR MAINNET. TESTNET SCAFFOLDING ONLY. ⚠️
///
///         A minimal `IMailbox` stand-in for chains where Hyperlane has no
///         deployment yet. Arc testnet (5042002) is the motivating case: as of
///         2026-09-06 the Hyperlane registry carries Arc MAINNET only
///         (domain 5042, mailbox 0x7f50C5776722630a0024fAE05fDe8b47571D7B39),
///         and there is no testnet entry at all.
///
///         This contract exists so `OrbitalIntentSettler` can be deployed and
///         exercised on Arc testnet. It does NOT relay anything. There is no
///         validator set, no ISM, no interchain security of any kind. A message
///         "sent" here is only an event; it never reaches another chain.
///
/// @dev    What it does provide:
///           - `localDomain()` / `quoteDispatch()` / `dispatch()` so the settler
///             constructor and its outbound path work unmodified.
///           - `deliver()`, an owner-gated hook that calls `handle` on a local
///             recipient, so the settler's INBOUND authentication path
///             (msg.sender == mailbox, origin -> peer, sender == peer) can be
///             driven end-to-end in a scripted demo.
///
///         The settler is deliberately left unmodified: it still verifies
///         `msg.sender == address(mailbox)` and that `(origin, sender)` maps to
///         a registered peer. Those checks are real. Only the transport is fake.
///
///         On Arc mainnet, pass the canonical Hyperlane mailbox via the
///         `HYPERLANE_MAILBOX` env var and this contract is never deployed.
contract TestnetMailbox is IMailbox {
    /// @notice Domain reported to the settler. Set to the chain id for parity
    ///         with the rest of the mesh, where domain == chainId by convention.
    uint32 public immutable override localDomain;

    /// @notice Allowed to call `deliver`. Set at construction, not transferable:
    ///         this is throwaway testnet scaffolding, not a governed contract.
    address public immutable owner;

    /// @notice Monotonic counter folded into the message id.
    uint256 public nonce;

    /// @dev Mirrors Hyperlane's event shape closely enough to be legible in an
    ///      explorer, without pretending to be the real thing.
    event Dispatch(
        uint32 indexed destinationDomain, bytes32 indexed recipient, bytes32 indexed messageId, bytes messageBody
    );
    event Delivered(uint32 indexed origin, bytes32 indexed sender, address indexed recipient);

    error NotOwner(address caller);

    constructor(uint32 _localDomain, address _owner) {
        localDomain = _localDomain;
        owner = _owner;
    }

    /// @notice Always free. There is no relayer to pay.
    function quoteDispatch(uint32, bytes32, bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Records the message and returns an id. Goes nowhere.
    function dispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody)
        external
        payable
        override
        returns (bytes32 messageId)
    {
        unchecked {
            messageId = keccak256(abi.encode(localDomain, destinationDomain, recipientAddress, nonce++, messageBody));
        }
        emit Dispatch(destinationDomain, recipientAddress, messageId, messageBody);
    }

    /// @notice Simulate inbound delivery so the settler's `handle` path is
    ///         reachable on a chain with no relayer.
    /// @dev    Owner-gated purely so a stranger cannot spoof arbitrary origins
    ///         into a deployed settler on a public testnet. The settler's own
    ///         peer checks still run and still have to pass.
    function deliver(address recipient, uint32 origin, bytes32 sender, bytes calldata message) external payable {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        IMessageRecipient(recipient).handle{value: msg.value}(origin, sender, message);
        emit Delivered(origin, sender, recipient);
    }
}
