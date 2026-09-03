// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";
import {OrbitalIntentSettler} from "../src/crosschain/OrbitalIntentSettler.sol";
import {IMailbox} from "../src/crosschain/IHyperlane.sol";
import {OnchainCrossChainOrder, ResolvedCrossChainOrder, AddressCast} from "../src/crosschain/IERC7683.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {MockMailbox} from "./utils/MockMailbox.sol";

/// @notice ERC-7683 cross-chain swap against the Orbital pool, settled by an
///         authenticated Hyperlane proof. Two "chains" in one EVM, switched with
///         `vm.chainId`; each side has its own MockMailbox so the inbound
///         authentication path in `handle` is genuinely exercised.
contract OrbitalIntentSettlerTest is BaseTest {
    using AddressCast for address;

    OrbitalHook hook;
    OrbitalIntentSettler origin; // "Base"
    OrbitalIntentSettler dest; // "Arbitrum"
    MockMailbox originMailbox;
    MockMailbox destMailbox;

    Currency c0;
    Currency c1;
    Currency c2;

    uint256 constant CHAIN_BASE = 8453;
    uint256 constant CHAIN_ARB = 42161;
    uint32 constant DOMAIN_BASE = 8453;
    uint32 constant DOMAIN_ARB = 42161;

    address user = address(0x5E12);
    address filler = address(0xF111E2);
    address recipient = address(0xEC12);

    uint8 constant N = 3;
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    function setUp() public {
        deployArtifactsAndLabel();

        MockERC20[3] memory t = [deployToken(), deployToken(), deployToken()];
        for (uint256 i = 0; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (address(t[j]) < address(t[i])) (t[i], t[j]) = (t[j], t[i]);
            }
        }
        Currency[] memory regd = new Currency[](N);
        for (uint256 i = 0; i < N; ++i) regd[i] = Currency.wrap(address(t[i]));
        (c0, c1, c2) = (regd[0], regd[1], regd[2]);

        address flagged = address(HOOK_FLAGS ^ (0x1234 << 144));
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, permit2, regd, uint24(100), address(this)), flagged
        );
        hook = OrbitalHook(flagged);

        for (uint256 i = 0; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                poolManager.initialize(
                    PoolKey({currency0: regd[i], currency1: regd[j], fee: 0, tickSpacing: 1, hooks: IHooks(flagged)}),
                    Constants.SQRT_PRICE_1_1
                );
            }
        }

        for (uint256 i = 0; i < N; ++i) t[i].approve(address(hook), type(uint256).max);
        uint256 r = 1_000_000 ether;
        uint256[] memory maxA = new uint256[](N);
        for (uint256 i = 0; i < N; ++i) maxA[i] = type(uint256).max;
        hook.addLiquidity((TickLib.kMin(r, N) + TickLib.kMax(r, N)) / 2, r, maxA);

        originMailbox = new MockMailbox(DOMAIN_BASE);
        destMailbox = new MockMailbox(DOMAIN_ARB);
        origin = new OrbitalIntentSettler(address(hook), swapRouter, IMailbox(address(originMailbox)), address(this));
        dest = new OrbitalIntentSettler(address(hook), swapRouter, IMailbox(address(destMailbox)), address(this));

        // Peers must be registered in BOTH directions before any route works.
        origin.setPeer(CHAIN_ARB, DOMAIN_ARB, address(dest).toBytes32());
        dest.setPeer(CHAIN_BASE, DOMAIN_BASE, address(origin).toBytes32());

        MockERC20(Currency.unwrap(c0)).mint(user, 10_000 ether);
        MockERC20(Currency.unwrap(c1)).mint(filler, 10_000 ether);
        MockERC20(Currency.unwrap(c2)).mint(filler, 10_000 ether);
        vm.deal(filler, 10 ether);

        vm.prank(user);
        MockERC20(Currency.unwrap(c0)).approve(address(origin), type(uint256).max);
        vm.startPrank(filler);
        MockERC20(Currency.unwrap(c1)).approve(address(dest), type(uint256).max);
        MockERC20(Currency.unwrap(c2)).approve(address(dest), type(uint256).max);
        dest.depositGas{value: 1 ether}();
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

    function _orderData(address outputToken, uint256 inAmt, uint256 outAmt)
        internal
        view
        returns (OrbitalIntentSettler.OrbitalOrderData memory)
    {
        return OrbitalIntentSettler.OrbitalOrderData({
            inputToken: Currency.unwrap(c0),
            inputAmount: inAmt,
            outputToken: outputToken,
            outputAmount: outAmt,
            destinationChainId: uint64(CHAIN_ARB),
            destinationSettler: address(dest),
            recipient: recipient
        });
    }

    function _openOrder(OrbitalIntentSettler.OrbitalOrderData memory d, uint32 fillDeadline)
        internal
        returns (bytes32 orderId, bytes memory originData)
    {
        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: fillDeadline,
            orderDataType: origin.ORBITAL_ORDER_DATA_TYPE(),
            orderData: abi.encode(d)
        });
        vm.startPrank(user);
        ResolvedCrossChainOrder memory r = origin.resolve(order);
        orderId = r.orderId;
        originData = r.fillInstructions[0].originData;
        origin.open(order);
        vm.stopPrank();
    }

    function _fillerData(address inTok, uint256 inAmt) internal view returns (bytes memory) {
        return abi.encode(OrbitalIntentSettler.FillerData({inputToken: inTok, inputAmount: inAmt, repayTo: filler}));
    }

    /// @dev Play the Hyperlane relayer: carry the last proof from dest to origin.
    function _relayProof() internal {
        originMailbox.deliver(address(origin), DOMAIN_ARB, address(dest).toBytes32(), destMailbox.lastBody());
    }

    // ─────────────────────────────────────────────────────────────
    // Headline flow
    // ─────────────────────────────────────────────────────────────

    function test_endToEnd_proof_settles_escrow() public {
        vm.chainId(CHAIN_BASE);
        uint256 inAmt = 1_000 ether;
        uint256 outAmt = 995 ether;
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c2), inAmt, outAmt);

        (bytes32 orderId, bytes memory originData) = _openOrder(d, uint32(block.timestamp + 1 hours));
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(origin)), inAmt, "escrow not funded");

        // ── Destination: filler pays in c1, forcing the Orbital hop to c2 ──
        vm.chainId(CHAIN_ARB);
        uint256 poolBefore = hook.reserves(1);
        uint256 gasBefore = dest.gasDeposits(filler);

        vm.prank(filler);
        dest.fill(orderId, originData, _fillerData(Currency.unwrap(c1), 1_010 ether));

        assertEq(MockERC20(Currency.unwrap(c2)).balanceOf(recipient), outAmt, "recipient underpaid");
        assertGt(hook.reserves(1), poolBefore, "fill did not route through the Orbital pool");
        assertEq(MockERC20(Currency.unwrap(c2)).balanceOf(address(dest)), 0, "settler retained dust");
        assertLt(dest.gasDeposits(filler), gasBefore, "hyperlane fee not drawn from deposit");
        assertEq(destMailbox.sentCount(), 1, "no proof dispatched");

        // ── Origin: escrow releases ONLY on the authenticated proof ──
        vm.chainId(CHAIN_BASE);
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(filler), 0, "paid before proof arrived");

        _relayProof();

        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(filler), inAmt, "filler not repaid on proof");
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(origin)), 0, "escrow not drained");
    }

    // ─────────────────────────────────────────────────────────────
    // Settlement authentication: the security-critical surface
    // ─────────────────────────────────────────────────────────────

    function test_handle_reverts_when_caller_is_not_mailbox() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        (bytes32 orderId,) = _openOrder(d, uint32(block.timestamp + 1 hours));

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OrbitalIntentSettler.NotMailbox.selector, address(0xBAD)));
        origin.handle(DOMAIN_ARB, address(dest).toBytes32(), abi.encode(orderId, address(0xBAD)));
    }

    function test_handle_reverts_on_unregistered_domain() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        (bytes32 orderId,) = _openOrder(d, uint32(block.timestamp + 1 hours));

        uint32 rogueDomain = 999;
        vm.expectRevert(
            abi.encodeWithSelector(
                OrbitalIntentSettler.UnknownPeer.selector, rogueDomain, address(dest).toBytes32()
            )
        );
        originMailbox.deliver(address(origin), rogueDomain, address(dest).toBytes32(), abi.encode(orderId, filler));
    }

    function test_handle_reverts_when_sender_is_not_the_registered_peer() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        (bytes32 orderId,) = _openOrder(d, uint32(block.timestamp + 1 hours));

        bytes32 impostor = address(0xBAD).toBytes32();
        vm.expectRevert(abi.encodeWithSelector(OrbitalIntentSettler.UnknownPeer.selector, DOMAIN_ARB, impostor));
        originMailbox.deliver(address(origin), DOMAIN_ARB, impostor, abi.encode(orderId, address(0xBAD)));
    }

    function test_handle_is_idempotent_on_redelivery() public {
        vm.chainId(CHAIN_BASE);
        uint256 inAmt = 1_000 ether;
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), inAmt, 995 ether);
        (bytes32 orderId, bytes memory originData) = _openOrder(d, uint32(block.timestamp + 1 hours));

        vm.chainId(CHAIN_ARB);
        vm.prank(filler);
        dest.fill(orderId, originData, _fillerData(Currency.unwrap(c1), 995 ether));

        vm.chainId(CHAIN_BASE);
        _relayProof();
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(filler), inAmt, "first proof did not pay");

        // Redelivery must be a no-op, not a double-pay and not a revert.
        _relayProof();
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(filler), inAmt, "redelivery double-paid");
    }

    function test_handle_after_refund_does_not_double_pay() public {
        vm.chainId(CHAIN_BASE);
        uint256 inAmt = 1_000 ether;
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), inAmt, 995 ether);
        uint256 userBefore = MockERC20(Currency.unwrap(c0)).balanceOf(user);
        (bytes32 orderId, bytes memory originData) = _openOrder(d, uint32(block.timestamp + 1 hours));

        vm.chainId(CHAIN_ARB);
        vm.prank(filler);
        dest.fill(orderId, originData, _fillerData(Currency.unwrap(c1), 995 ether));

        // User refunds after the full buffer; the late proof must not pay again.
        vm.chainId(CHAIN_BASE);
        vm.warp(block.timestamp + 1 hours + 12 hours + 1);
        origin.refund(orderId);
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(user), userBefore, "user not refunded");

        _relayProof();
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(filler), 0, "late proof paid after refund");
    }

    // ─────────────────────────────────────────────────────────────
    // Refund timing
    // ─────────────────────────────────────────────────────────────

    function test_refund_blocked_until_fillDeadline_plus_buffer() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        (bytes32 orderId,) = _openOrder(d, uint32(block.timestamp + 1 hours));

        // Past the fill deadline but inside the buffer: a slow proof is still safe.
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(OrbitalIntentSettler.DeadlineNotPassed.selector);
        origin.refund(orderId);

        vm.warp(block.timestamp + 12 hours);
        origin.refund(orderId);
    }

    function test_setRefundBuffer_enforces_minimum() public {
        vm.expectRevert(
            abi.encodeWithSelector(OrbitalIntentSettler.RefundBufferTooShort.selector, uint32(1 hours), uint32(3 hours))
        );
        origin.setRefundBuffer(1 hours);
        origin.setRefundBuffer(6 hours);
        assertEq(origin.refundBuffer(), 6 hours);
    }

    function test_refundAfter_frozen_at_open_against_later_buffer_change() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        uint32 deadline = uint32(block.timestamp + 1 hours);
        (bytes32 orderId,) = _openOrder(d, deadline);

        // Shrinking the buffer afterwards must not shorten an existing order's
        // protection window for a filler mid-flight.
        origin.setRefundBuffer(MIN());
        vm.warp(deadline + 3 hours + 1);
        vm.expectRevert(OrbitalIntentSettler.DeadlineNotPassed.selector);
        origin.refund(orderId);
    }

    function MIN() internal view returns (uint32) {
        return origin.MIN_REFUND_BUFFER();
    }

    // ─────────────────────────────────────────────────────────────
    // Peering and gas deposits
    // ─────────────────────────────────────────────────────────────

    function test_open_reverts_when_destination_peer_not_configured() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        d.destinationChainId = 12345; // never registered

        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: origin.ORBITAL_ORDER_DATA_TYPE(),
            orderData: abi.encode(d)
        });
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OrbitalIntentSettler.PeerNotConfigured.selector, uint256(12345)));
        origin.open(order);
    }

    function test_setPeer_repointing_clears_stale_domain() public {
        origin.setPeer(CHAIN_ARB, 777, address(dest).toBytes32());
        // The old domain must no longer authenticate anything.
        assertEq(origin.peerByDomain(DOMAIN_ARB), bytes32(0), "stale domain still authorised");
        assertEq(origin.peerByDomain(777), address(dest).toBytes32(), "new domain not set");
    }

    function test_setPeer_onlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        origin.setPeer(CHAIN_ARB, DOMAIN_ARB, address(dest).toBytes32());
    }

    function test_fill_reverts_without_gas_deposit() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        (bytes32 orderId, bytes memory originData) = _openOrder(d, uint32(block.timestamp + 1 hours));

        vm.chainId(CHAIN_ARB);
        address poorFiller = address(0xF00D);
        MockERC20(Currency.unwrap(c1)).mint(poorFiller, 10_000 ether);
        vm.startPrank(poorFiller);
        MockERC20(Currency.unwrap(c1)).approve(address(dest), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(OrbitalIntentSettler.InsufficientGasDeposit.selector, 0, 1e13));
        dest.fill(orderId, originData, _fillerData(Currency.unwrap(c1), 995 ether));
        vm.stopPrank();
    }

    function test_gas_deposit_and_withdraw() public {
        uint256 before = dest.gasDeposits(filler);
        vm.prank(filler);
        dest.depositGas{value: 0.5 ether}();
        assertEq(dest.gasDeposits(filler), before + 0.5 ether);

        uint256 ethBefore = filler.balance;
        vm.prank(filler);
        dest.withdrawGas(0.5 ether);
        assertEq(dest.gasDeposits(filler), before);
        assertEq(filler.balance, ethBefore + 0.5 ether);
    }

    // ─────────────────────────────────────────────────────────────
    // Fill-side safety
    // ─────────────────────────────────────────────────────────────

    function test_fill_without_pool_hop_when_filler_holds_output() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        (bytes32 orderId, bytes memory originData) = _openOrder(d, uint32(block.timestamp + 1 hours));

        vm.chainId(CHAIN_ARB);
        uint256 poolBefore = hook.reserves(1);
        vm.prank(filler);
        dest.fill(orderId, originData, _fillerData(Currency.unwrap(c1), 995 ether));

        assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(recipient), 995 ether, "recipient underpaid");
        assertEq(hook.reserves(1), poolBefore, "pool touched on a direct fill");
    }

    function test_fill_reverts_on_double_fill() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        (bytes32 orderId, bytes memory originData) = _openOrder(d, uint32(block.timestamp + 1 hours));

        vm.chainId(CHAIN_ARB);
        vm.startPrank(filler);
        dest.fill(orderId, originData, _fillerData(Currency.unwrap(c1), 995 ether));
        vm.expectRevert(abi.encodeWithSelector(OrbitalIntentSettler.AlreadyFilled.selector, orderId));
        dest.fill(orderId, originData, _fillerData(Currency.unwrap(c1), 995 ether));
        vm.stopPrank();
    }

    function test_fill_reverts_on_wrong_chain() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        (bytes32 orderId, bytes memory originData) = _openOrder(d, uint32(block.timestamp + 1 hours));

        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(OrbitalIntentSettler.WrongChain.selector, CHAIN_BASE, CHAIN_ARB));
        dest.fill(orderId, originData, _fillerData(Currency.unwrap(c1), 995 ether));
    }

    function test_fill_reverts_when_filler_underfunds() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        (bytes32 orderId, bytes memory originData) = _openOrder(d, uint32(block.timestamp + 1 hours));

        vm.chainId(CHAIN_ARB);
        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(OrbitalIntentSettler.InsufficientOutput.selector, 500 ether, 995 ether)
        );
        dest.fill(orderId, originData, _fillerData(Currency.unwrap(c1), 500 ether));
    }

    function test_open_rejects_same_chain_order() public {
        vm.chainId(CHAIN_ARB);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: origin.ORBITAL_ORDER_DATA_TYPE(),
            orderData: abi.encode(d)
        });
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OrbitalIntentSettler.WrongChain.selector, CHAIN_ARB, CHAIN_ARB));
        origin.open(order);
    }

    function test_open_rejects_unknown_order_type() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: keccak256("SomeOtherOrder"),
            orderData: abi.encode(d)
        });
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(OrbitalIntentSettler.UnsupportedOrderType.selector, keccak256("SomeOtherOrder"))
        );
        origin.open(order);
    }

    function test_pause_blocks_open_and_fill_but_never_refund_or_handle() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c1), 1_000 ether, 995 ether);
        uint32 deadline = uint32(block.timestamp + 1 hours);
        (bytes32 orderId, bytes memory originData) = _openOrder(d, deadline);

        // Fill first, so there is a real proof in flight when the pause lands.
        vm.chainId(CHAIN_ARB);
        vm.prank(filler);
        dest.fill(orderId, originData, _fillerData(Currency.unwrap(c1), 995 ether));

        vm.chainId(CHAIN_BASE);
        origin.pause();

        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: deadline,
            orderDataType: origin.ORBITAL_ORDER_DATA_TYPE(),
            orderData: abi.encode(d)
        });
        vm.prank(user);
        vm.expectRevert();
        origin.open(order);

        // A pause must never strand a filler who already paid out.
        _relayProof();
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(filler), 1_000 ether, "pause stranded the filler");
    }
}
