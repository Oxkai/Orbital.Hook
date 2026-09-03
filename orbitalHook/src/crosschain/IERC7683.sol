// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ERC-7683 Cross-Chain Intents
/// @notice Verbatim structs and interfaces from the ERC-7683 standard
///         (Uniswap Labs + Across; Mark Toda, Matt Rice, Nick Pai).
///         Spec: https://eips.ethereum.org/EIPS/eip-7683
///
/// @dev    Addresses are `bytes32` in the standard so the same order format can
///         address non-EVM chains. On EVM they are left-padded 20-byte addresses;
///         use `AddressCast` below to convert.

// ─────────────────────────────────────────────────────────────
// Order structs
// ─────────────────────────────────────────────────────────────

/// @notice A cross-chain order signed off-chain by the user and opened by a filler.
struct GaslessCrossChainOrder {
    /// @dev The settlement contract on the origin chain that will open this order.
    address originSettler;
    /// @dev The user placing the order, who must sign it.
    address user;
    /// @dev Replay protection, scoped to (originSettler, user).
    uint256 nonce;
    /// @dev The chain this order is opened on. Must match block.chainid at open.
    uint256 originChainId;
    /// @dev The last timestamp at which the order may be OPENED on the origin.
    uint32 openDeadline;
    /// @dev The last timestamp at which the order may be FILLED on the destination.
    uint32 fillDeadline;
    /// @dev EIP-712 typehash identifying how to parse `orderData`.
    bytes32 orderDataType;
    /// @dev Implementation-specific order payload. Opaque to the standard.
    bytes orderData;
}

/// @notice A cross-chain order opened directly by the user in a transaction.
struct OnchainCrossChainOrder {
    /// @dev The last timestamp at which the order may be FILLED on the destination.
    uint32 fillDeadline;
    /// @dev EIP-712 typehash identifying how to parse `orderData`.
    bytes32 orderDataType;
    /// @dev Implementation-specific order payload. Opaque to the standard.
    bytes orderData;
}

/// @notice One token movement, on a named chain.
struct Output {
    /// @dev ERC-20 address as bytes32. `bytes32(0)` means the chain's native asset.
    bytes32 token;
    uint256 amount;
    bytes32 recipient;
    uint256 chainId;
}

/// @notice Per-destination-chain instructions a filler needs to execute a leg.
struct FillInstruction {
    uint64 destinationChainId;
    bytes32 destinationSettler;
    /// @dev Passed verbatim to `IDestinationSettler.fill` as `originData`.
    bytes originData;
}

/// @notice The implementation-agnostic view of an order, so a filler can price and
///         execute it without understanding the settler's `orderData` encoding.
struct ResolvedCrossChainOrder {
    address user;
    uint256 originChainId;
    uint32 openDeadline;
    uint32 fillDeadline;
    /// @dev Unique identifier for this order across all chains.
    bytes32 orderId;
    /// @dev The maximum the filler will have to spend, per destination chain.
    Output[] maxSpent;
    /// @dev The minimum the filler is guaranteed to receive on settlement.
    Output[] minReceived;
    /// @dev One instruction per destination leg.
    FillInstruction[] fillInstructions;
}

// ─────────────────────────────────────────────────────────────
// Interfaces
// ─────────────────────────────────────────────────────────────

/// @notice Settlement contract on the ORIGIN chain. Escrows the user's input and
///         later repays whichever filler proves it satisfied the order.
interface IOriginSettler {
    /// @notice MUST be emitted on every successful open. Fillers index this.
    event Open(bytes32 indexed orderId, ResolvedCrossChainOrder resolvedOrder);

    /// @notice Open a gasless order on behalf of a user, using their signature.
    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata originFillerData)
        external;

    /// @notice Open an order directly. `msg.sender` is the user.
    function open(OnchainCrossChainOrder calldata order) external;

    /// @notice Resolve a gasless order into the filler-facing representation.
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData)
        external
        view
        returns (ResolvedCrossChainOrder memory);

    /// @notice Resolve an on-chain order into the filler-facing representation.
    function resolve(OnchainCrossChainOrder calldata order) external view returns (ResolvedCrossChainOrder memory);
}

/// @notice Settlement contract on the DESTINATION chain. Pays the user out of the
///         filler's inventory.
interface IDestinationSettler {
    /// @notice Fill a single leg of a cross-chain order.
    /// @param orderId    Unique order identifier from the origin chain.
    /// @param originData The `FillInstruction.originData` produced by the origin settler.
    /// @param fillerData Filler-supplied execution parameters. Opaque to the standard.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external;
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

/// @notice bytes32 <-> address conversion for the standard's chain-agnostic fields.
library AddressCast {
    error AddressCastOverflow(bytes32 value);

    function toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev Reverts if the high 96 bits are set, which would mean the value is a
    ///      genuine non-EVM address being silently truncated into an EVM one.
    function toAddress(bytes32 b) internal pure returns (address) {
        if (uint256(b) >> 160 != 0) revert AddressCastOverflow(b);
        return address(uint160(uint256(b)));
    }
}
