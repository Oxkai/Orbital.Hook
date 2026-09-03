// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {IMailbox, IMessageRecipient} from "./IHyperlane.sol";
import {
    IOriginSettler,
    IDestinationSettler,
    GaslessCrossChainOrder,
    OnchainCrossChainOrder,
    ResolvedCrossChainOrder,
    Output,
    FillInstruction,
    AddressCast
} from "./IERC7683.sol";

/// @title  OrbitalIntentSettler
/// @notice ERC-7683 settlement for cross-chain swaps backed by the Orbital pool.
///
/// @dev    ONE contract per chain, playing BOTH roles (the Across SpokePool model):
///         a chain is always simultaneously a source and a destination.
///
///         ORIGIN role   escrows the user's input token, and releases it to the
///                       filler ONLY on receipt of an authenticated Hyperlane
///                       message from the peer settler on the destination chain.
///         DEST   role   pays the user out of the FILLER's inventory, routing
///                       through the local Orbital pool when the filler's inventory
///                       is not the asset the user asked for, then dispatches the
///                       proof-of-fill message back to the origin.
///
///         WHY THE ORBITAL HOP MATTERS. A cross-chain filler normally needs
///         inventory in every asset on every chain (N x M positions). Because
///         Orbital holds all N stables in ONE book, any asset is one hop from any
///         other, so a filler needs inventory in only ONE asset per chain. That
///         collapses N x M to 1 x M, and it is the concrete reason for a filler to
///         route through this contract rather than around it.
///
///         SETTLEMENT SECURITY. There is no arbiter, no bond, no dispute game and
///         no challenge window. The origin chain releases escrow if and only if the
///         local Hyperlane Mailbox delivers a message whose (domain, sender) pair
///         matches a peer registered by the owner. The trust assumption is exactly
///         Hyperlane's Interchain Security Module for that route, and nothing else.
///         `handle` is idempotent so redelivery cannot double-pay.
///
///         LIVENESS. If the proof message is never delivered, the user reclaims the
///         escrow after `fillDeadline + refundBuffer`. The buffer must comfortably
///         exceed worst-case message latency, otherwise an honest filler who paid
///         out on the destination could be front-run by the user's refund. This is
///         the one genuinely tunable safety parameter; it is bounded below by
///         MIN_REFUND_BUFFER so it can never be set to a value that strands fillers.
contract OrbitalIntentSettler is
    IOriginSettler,
    IDestinationSettler,
    IMessageRecipient,
    Ownable2Step,
    Pausable,
    ReentrancyGuard,
    EIP712
{
    using SafeERC20 for IERC20;
    using AddressCast for address;
    using AddressCast for bytes32;

    // ─────────────────────────────────────────────────────────────
    // Order payload (the `orderData` sub-type this settler understands)
    // ─────────────────────────────────────────────────────────────

    struct OrbitalOrderData {
        address inputToken; // what the user gives up on the ORIGIN chain
        uint256 inputAmount;
        address outputToken; // what the user receives on the DESTINATION chain
        uint256 outputAmount; // exact amount the recipient must receive
        uint64 destinationChainId;
        address destinationSettler;
        address recipient;
    }

    bytes32 public constant ORBITAL_ORDER_DATA_TYPE = keccak256(
        "OrbitalOrderData(address inputToken,uint256 inputAmount,address outputToken,uint256 outputAmount,uint64 destinationChainId,address destinationSettler,address recipient)"
    );

    bytes32 private constant GASLESS_ORDER_TYPEHASH = keccak256(
        "GaslessCrossChainOrder(address originSettler,address user,uint256 nonce,uint256 originChainId,uint32 openDeadline,uint32 fillDeadline,bytes32 orderDataType,bytes orderData)"
    );

    /// @notice What the filler is paying with, supplied as `fillerData` to `fill`.
    struct FillerData {
        address inputToken; // the filler's inventory asset
        uint256 inputAmount; // how much of it they are supplying
        address repayTo; // address to credit on the ORIGIN chain
    }

    // ─────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────

    enum OrderStatus {
        NONE,
        OPENED,
        SETTLED,
        REFUNDED
    }

    /// @dev ORIGIN-side escrow record.
    struct EscrowedOrder {
        address user;
        address inputToken;
        uint256 inputAmount;
        uint32 fillDeadline;
        uint32 refundAfter; // fillDeadline + refundBuffer, frozen at open
        OrderStatus status;
    }

    /// @dev A trusted counterpart deployment on another chain.
    struct Peer {
        uint32 domain; // Hyperlane domain of that chain
        bytes32 settler; // peer settler address on that chain, as bytes32
        bool set;
    }

    /// @notice The Orbital pool this settler routes fills through.
    address public immutable hook;
    /// @notice v4 router used for the Orbital hop.
    IUniswapV4Router04 public immutable router;
    /// @notice Local Hyperlane Mailbox. Sole authority for inbound proofs.
    IMailbox public immutable mailbox;
    /// @notice Hyperlane domain of THIS chain.
    uint32 public immutable localDomain;

    /// @dev Peer lookup by EVM chainId, used when DISPATCHING a proof.
    mapping(uint256 => Peer) public peerByChainId;
    /// @dev Peer lookup by Hyperlane domain, used when AUTHENTICATING an inbound
    ///      proof in `handle`. Kept in lockstep with `peerByChainId` by `setPeer`.
    mapping(uint32 => bytes32) public peerByDomain;

    /// @notice Lower bound on `refundBuffer`. A buffer shorter than this would let
    ///         a user refund out from under a filler whose proof is merely slow,
    ///         so it is enforced in code rather than left to operator discipline.
    uint32 public constant MIN_REFUND_BUFFER = 3 hours;
    /// @notice Extra time past `fillDeadline` before the user may reclaim escrow.
    uint32 public refundBuffer = 12 hours;

    mapping(bytes32 => EscrowedOrder) public orders;
    /// @dev DESTINATION-side: which filler satisfied an order. Also the guard
    ///      against double-filling.
    mapping(bytes32 => address) public filledBy;
    mapping(address => uint256) public nonces;
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    /// @notice Per-filler native balance used to pay Hyperlane for proof delivery.
    /// @dev    ERC-7683 declares `fill` non-payable, so the fee cannot ride along
    ///         with the call. A prepaid balance is also what a solver actually
    ///         wants: top up once, fill many times, withdraw what is left.
    mapping(address => uint256) public gasDeposits;

    // ─────────────────────────────────────────────────────────────
    // Errors and events
    // ─────────────────────────────────────────────────────────────

    error UnsupportedOrderType(bytes32 orderDataType);
    error WrongChain(uint256 expected, uint256 actual);
    error WrongSettler(address expected, address actual);
    error DeadlinePassed();
    error DeadlineNotPassed();
    error ZeroAmount();
    error ZeroAddress();
    error SameToken();
    error OrderNotOpen(bytes32 orderId);
    error OrderAlreadyExists(bytes32 orderId);
    error AlreadyFilled(bytes32 orderId);
    error NonceUsed(uint256 nonce);
    error BadSignature();
    error InsufficientOutput(uint256 got, uint256 need);
    error NotMailbox(address caller);
    error UnknownPeer(uint32 domain, bytes32 sender);
    error PeerNotConfigured(uint256 chainId);
    error InsufficientGasDeposit(uint256 have, uint256 need);
    error RefundBufferTooShort(uint32 given, uint32 min);
    error EthTransferFailed();

    event Filled(bytes32 indexed orderId, address indexed filler, address recipient, uint256 amountOut);
    event ProofDispatched(bytes32 indexed orderId, uint32 indexed originDomain, bytes32 messageId);
    event ProofReceived(bytes32 indexed orderId, uint32 indexed originDomain, address indexed filler);
    event Settled(bytes32 indexed orderId, address indexed paidTo, uint256 amount);
    event Refunded(bytes32 indexed orderId, address indexed user, uint256 amount);
    event PeerSet(uint256 indexed chainId, uint32 indexed domain, bytes32 settler);
    event RefundBufferSet(uint32 refundBuffer);
    event GasDeposited(address indexed filler, uint256 amount, uint256 balance);
    event GasWithdrawn(address indexed filler, uint256 amount, uint256 balance);

    // ─────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(address _hook, IUniswapV4Router04 _router, IMailbox _mailbox, address _admin) Ownable(_admin) EIP712("OrbitalIntentSettler", "2") {
        if (_hook == address(0) || address(_mailbox) == address(0)) revert ZeroAddress();
        hook = _hook;
        router = _router;
        mailbox = _mailbox;
        localDomain = _mailbox.localDomain();
    }

    // ─────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────

    /// @notice Register the counterpart settler on another chain. Both directions
    ///         must be registered before any route works, on both deployments.
    function setPeer(uint256 chainId, uint32 domain, bytes32 settler) external onlyOwner {
        if (settler == bytes32(0)) revert ZeroAddress();
        // Clear any stale domain mapping so re-pointing a chain cannot leave an
        // old domain authorised.
        Peer memory existing = peerByChainId[chainId];
        if (existing.set && existing.domain != domain) delete peerByDomain[existing.domain];

        peerByChainId[chainId] = Peer({domain: domain, settler: settler, set: true});
        peerByDomain[domain] = settler;
        emit PeerSet(chainId, domain, settler);
    }

    function setRefundBuffer(uint32 _refundBuffer) external onlyOwner {
        if (_refundBuffer < MIN_REFUND_BUFFER) revert RefundBufferTooShort(_refundBuffer, MIN_REFUND_BUFFER);
        refundBuffer = _refundBuffer;
        emit RefundBufferSet(_refundBuffer);
    }

    /// @dev Blocks new opens and new fills. Never blocks `handle` or `refund`:
    ///      escrowed money must always be able to reach its rightful owner, and a
    ///      pause must not strand a filler who already paid out.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─────────────────────────────────────────────────────────────
    // ORIGIN: open
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IOriginSettler
    function open(OnchainCrossChainOrder calldata order) external override whenNotPaused nonReentrant {
        OrbitalOrderData memory d = _decode(order.orderDataType, order.orderData);
        _validate(d, order.fillDeadline);

        uint256 nonce = nonces[msg.sender]++;
        bytes32 orderId = _orderId(msg.sender, nonce, order.fillDeadline, order.orderData);

        _escrow(orderId, msg.sender, d, order.fillDeadline);
        emit Open(orderId, _resolved(orderId, msg.sender, type(uint32).max, order.fillDeadline, d));
    }

    /// @inheritdoc IOriginSettler
    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata)
        external
        override
        whenNotPaused
        nonReentrant
    {
        if (order.originSettler != address(this)) revert WrongSettler(address(this), order.originSettler);
        if (order.originChainId != block.chainid) revert WrongChain(block.chainid, order.originChainId);
        if (block.timestamp > order.openDeadline) revert DeadlinePassed();
        if (usedNonces[order.user][order.nonce]) revert NonceUsed(order.nonce);

        if (!SignatureChecker.isValidSignatureNow(order.user, _hashGasless(order), signature)) revert BadSignature();
        usedNonces[order.user][order.nonce] = true;

        OrbitalOrderData memory d = _decode(order.orderDataType, order.orderData);
        _validate(d, order.fillDeadline);

        bytes32 orderId = _orderId(order.user, order.nonce, order.fillDeadline, order.orderData);
        _escrow(orderId, order.user, d, order.fillDeadline);
        emit Open(orderId, _resolved(orderId, order.user, order.openDeadline, order.fillDeadline, d));
    }

    function _escrow(bytes32 orderId, address user, OrbitalOrderData memory d, uint32 fillDeadline) internal {
        if (orders[orderId].status != OrderStatus.NONE) revert OrderAlreadyExists(orderId);
        // Refuse to escrow against a route we cannot verify a proof for: without a
        // configured peer the destination's message could never be authenticated,
        // and the funds would sit until refund. Fail at open instead.
        if (!peerByChainId[d.destinationChainId].set) revert PeerNotConfigured(d.destinationChainId);

        orders[orderId] = EscrowedOrder({
            user: user,
            inputToken: d.inputToken,
            inputAmount: d.inputAmount,
            fillDeadline: fillDeadline,
            refundAfter: fillDeadline + refundBuffer,
            status: OrderStatus.OPENED
        });

        IERC20(d.inputToken).safeTransferFrom(user, address(this), d.inputAmount);
    }

    // ─────────────────────────────────────────────────────────────
    // DESTINATION: filler gas balance
    // ─────────────────────────────────────────────────────────────

    /// @notice Top up the caller's balance for Hyperlane proof delivery.
    function depositGas() external payable {
        if (msg.value == 0) revert ZeroAmount();
        uint256 bal = gasDeposits[msg.sender] + msg.value;
        gasDeposits[msg.sender] = bal;
        emit GasDeposited(msg.sender, msg.value, bal);
    }

    /// @notice Withdraw unspent gas balance. Always available; never pausable.
    function withdrawGas(uint256 amount) external nonReentrant {
        uint256 bal = gasDeposits[msg.sender];
        if (amount == 0 || amount > bal) revert ZeroAmount();
        unchecked {
            bal -= amount;
        }
        gasDeposits[msg.sender] = bal;
        emit GasWithdrawn(msg.sender, amount, bal);
        _sendEth(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────
    // DESTINATION: fill
    // ─────────────────────────────────────────────────────────────

    /// @notice Native fee `fill` will draw from the caller's `gasDeposits`.
    function quoteFill(bytes32 orderId, bytes calldata originData) external view returns (uint256) {
        (uint256 originChainId,,) = abi.decode(originData, (uint256, address, OrbitalOrderData));
        Peer memory p = peerByChainId[originChainId];
        if (!p.set) revert PeerNotConfigured(originChainId);
        return mailbox.quoteDispatch(p.domain, p.settler, abi.encode(orderId, msg.sender));
    }

    /// @inheritdoc IDestinationSettler
    /// @dev Non-payable, per the ERC-7683 interface. The Hyperlane delivery fee is
    ///      drawn from the caller's prepaid `gasDeposits` balance instead.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData)
        external
        override
        whenNotPaused
        nonReentrant
    {
        if (filledBy[orderId] != address(0)) revert AlreadyFilled(orderId);

        (uint256 originChainId,, OrbitalOrderData memory d) =
            abi.decode(originData, (uint256, address, OrbitalOrderData));

        if (d.destinationChainId != block.chainid) revert WrongChain(block.chainid, d.destinationChainId);
        if (d.destinationSettler != address(this)) revert WrongSettler(address(this), d.destinationSettler);

        Peer memory p = peerByChainId[originChainId];
        if (!p.set) revert PeerNotConfigured(originChainId);

        FillerData memory f = abi.decode(fillerData, (FillerData));
        if (f.inputAmount == 0) revert ZeroAmount();
        address creditTo = f.repayTo == address(0) ? msg.sender : f.repayTo;

        // Effects first: a reentrant call cannot double-fill.
        filledBy[orderId] = msg.sender;

        IERC20(f.inputToken).safeTransferFrom(msg.sender, address(this), f.inputAmount);

        uint256 available;
        if (f.inputToken == d.outputToken) {
            available = f.inputAmount;
        } else {
            // Filler holds a different stable: one hop through the Orbital book.
            available = _swapViaOrbital(f.inputToken, d.outputToken, f.inputAmount, d.outputAmount);
        }
        if (available < d.outputAmount) revert InsufficientOutput(available, d.outputAmount);

        IERC20(d.outputToken).safeTransfer(d.recipient, d.outputAmount);

        uint256 surplus = available - d.outputAmount;
        if (surplus > 0) IERC20(d.outputToken).safeTransfer(creditTo, surplus);

        emit Filled(orderId, msg.sender, d.recipient, d.outputAmount);

        // Dispatch the proof. `creditTo` is what the origin will pay, so it is what
        // gets signed over the wire, not msg.sender.
        bytes memory body = abi.encode(orderId, creditTo);
        uint256 fee = mailbox.quoteDispatch(p.domain, p.settler, body);
        uint256 bal = gasDeposits[msg.sender];
        if (bal < fee) revert InsufficientGasDeposit(bal, fee);
        unchecked {
            gasDeposits[msg.sender] = bal - fee;
        }

        bytes32 messageId = mailbox.dispatch{value: fee}(p.domain, p.settler, body);
        emit ProofDispatched(orderId, p.domain, messageId);
    }

    /// @dev One hop through the Orbital pool. Every registered asset shares a single
    ///      N-asset book, so any (in, out) pair is one swap regardless of N.
    function _swapViaOrbital(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 received)
    {
        if (tokenIn == tokenOut) revert SameToken();

        (address c0, address c1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0, // engine runs its own fee; PoolKey.lpFee must be 0
            tickSpacing: 1,
            hooks: IHooks(hook)
        });

        if (IERC20(tokenIn).allowance(address(this), address(router)) < amountIn) {
            IERC20(tokenIn).forceApprove(address(router), type(uint256).max);
        }

        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        router.swapExactTokensForTokens(amountIn, minOut, tokenIn == c0, key, "", address(this), block.timestamp);
        received = IERC20(tokenOut).balanceOf(address(this)) - before;
    }

    // ─────────────────────────────────────────────────────────────
    // ORIGIN: settlement by authenticated proof
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IMessageRecipient
    /// @dev The ONLY path that releases escrow to a filler. Three gates:
    ///        1. caller is the local Mailbox (Hyperlane authenticated delivery)
    ///        2. the origin domain maps to a registered peer
    ///        3. the sender IS that peer
    ///      Idempotent: a redelivered message for an already-terminal order is a
    ///      no-op rather than a revert, so Hyperlane does not retry forever.
    function handle(uint32 _origin, bytes32 _sender, bytes calldata _message) external payable override nonReentrant {
        if (msg.sender != address(mailbox)) revert NotMailbox(msg.sender);
        bytes32 expected = peerByDomain[_origin];
        if (expected == bytes32(0) || expected != _sender) revert UnknownPeer(_origin, _sender);

        (bytes32 orderId, address filler) = abi.decode(_message, (bytes32, address));

        EscrowedOrder storage o = orders[orderId];
        // Terminal already (settled or refunded): accept the message and do nothing.
        if (o.status != OrderStatus.OPENED) {
            emit ProofReceived(orderId, _origin, filler);
            return;
        }

        o.status = OrderStatus.SETTLED;
        uint256 amount = o.inputAmount;
        address token = o.inputToken;

        emit ProofReceived(orderId, _origin, filler);
        emit Settled(orderId, filler, amount);

        IERC20(token).safeTransfer(filler, amount);
    }

    /// @notice User reclaims escrow if no proof arrived in time. Never blocked by
    ///         pause. The `refundAfter` stamp is frozen at open, so a later change
    ///         to `refundBuffer` cannot retroactively shorten an existing order's
    ///         protection window for the filler.
    function refund(bytes32 orderId) external nonReentrant {
        EscrowedOrder storage o = orders[orderId];
        if (o.status != OrderStatus.OPENED) revert OrderNotOpen(orderId);
        if (block.timestamp <= o.refundAfter) revert DeadlineNotPassed();

        o.status = OrderStatus.REFUNDED;
        address user = o.user;
        uint256 amount = o.inputAmount;

        emit Refunded(orderId, user, amount);
        IERC20(o.inputToken).safeTransfer(user, amount);
    }

    // ─────────────────────────────────────────────────────────────
    // Resolution views (filler-facing)
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IOriginSettler
    function resolve(OnchainCrossChainOrder calldata order)
        external
        view
        override
        returns (ResolvedCrossChainOrder memory)
    {
        OrbitalOrderData memory d = _decode(order.orderDataType, order.orderData);
        bytes32 orderId = _orderId(msg.sender, nonces[msg.sender], order.fillDeadline, order.orderData);
        return _resolved(orderId, msg.sender, type(uint32).max, order.fillDeadline, d);
    }

    /// @inheritdoc IOriginSettler
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata)
        external
        view
        override
        returns (ResolvedCrossChainOrder memory)
    {
        OrbitalOrderData memory d = _decode(order.orderDataType, order.orderData);
        bytes32 orderId = _orderId(order.user, order.nonce, order.fillDeadline, order.orderData);
        return _resolved(orderId, order.user, order.openDeadline, order.fillDeadline, d);
    }

    function _resolved(
        bytes32 orderId,
        address user,
        uint32 openDeadline,
        uint32 fillDeadline,
        OrbitalOrderData memory d
    ) internal view returns (ResolvedCrossChainOrder memory r) {
        Output[] memory maxSpent = new Output[](1);
        maxSpent[0] = Output({
            token: d.outputToken.toBytes32(),
            amount: d.outputAmount,
            recipient: d.recipient.toBytes32(),
            chainId: d.destinationChainId
        });

        Output[] memory minReceived = new Output[](1);
        minReceived[0] = Output({
            token: d.inputToken.toBytes32(),
            amount: d.inputAmount,
            recipient: bytes32(0), // whichever filler proves the fill
            chainId: block.chainid
        });

        FillInstruction[] memory instructions = new FillInstruction[](1);
        instructions[0] = FillInstruction({
            destinationChainId: d.destinationChainId,
            destinationSettler: d.destinationSettler.toBytes32(),
            originData: abi.encode(block.chainid, user, d)
        });

        r = ResolvedCrossChainOrder({
            user: user,
            originChainId: block.chainid,
            openDeadline: openDeadline,
            fillDeadline: fillDeadline,
            orderId: orderId,
            maxSpent: maxSpent,
            minReceived: minReceived,
            fillInstructions: instructions
        });
    }

    // ─────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────

    function _decode(bytes32 orderDataType, bytes calldata orderData)
        internal
        pure
        returns (OrbitalOrderData memory d)
    {
        if (orderDataType != ORBITAL_ORDER_DATA_TYPE) revert UnsupportedOrderType(orderDataType);
        d = abi.decode(orderData, (OrbitalOrderData));
    }

    function _validate(OrbitalOrderData memory d, uint32 fillDeadline) internal view {
        if (block.timestamp > fillDeadline) revert DeadlinePassed();
        if (d.inputAmount == 0 || d.outputAmount == 0) revert ZeroAmount();
        if (d.recipient == address(0) || d.destinationSettler == address(0)) revert ZeroAddress();
        if (d.destinationChainId == block.chainid) {
            // Same-chain is not a cross-chain order; the proof round-trip is
            // meaningless and the escrow could be claimed against a free fill.
            revert WrongChain(block.chainid, d.destinationChainId);
        }
    }

    function _orderId(address user, uint256 nonce, uint32 fillDeadline, bytes calldata orderData)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), user, nonce, fillDeadline, keccak256(orderData)));
    }

    function _hashGasless(GaslessCrossChainOrder calldata o) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    GASLESS_ORDER_TYPEHASH,
                    o.originSettler,
                    o.user,
                    o.nonce,
                    o.originChainId,
                    o.openDeadline,
                    o.fillDeadline,
                    o.orderDataType,
                    keccak256(o.orderData)
                )
            )
        );
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
