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
import {BandLib} from "../src/libraries/BandLib.sol";
import {OrbitalIntentSettler} from "../src/crosschain/OrbitalIntentSettler.sol";
import {IMailbox} from "../src/crosschain/IHyperlane.sol";
import {OnchainCrossChainOrder, ResolvedCrossChainOrder, AddressCast} from "../src/crosschain/IERC7683.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {MockMailbox} from "./utils/MockMailbox.sol";

/// @notice Settlement-authentication regressions for the ERC-7683 settler.
///         `OrbitalIntentSettler.t.sol` covers the happy path and the inbound
///         `handle` gates; this file covers the binding between the `orderId`
///         a fill proves and the order data it actually paid out.
contract CrosschainSecurityTest is BaseTest {
    using AddressCast for address;

    OrbitalHook hook;
    OrbitalIntentSettler origin;
    OrbitalIntentSettler dest;
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
    address attacker = address(0xBAD5);

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

        address flagged = address(HOOK_FLAGS ^ (0x4321 << 144));
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, regd, uint24(100), address(this)), flagged
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
        hook.addLiquidity(BandLib.bandOf(0.95e18), r, maxA, block.timestamp);

        originMailbox = new MockMailbox(DOMAIN_BASE);
        destMailbox = new MockMailbox(DOMAIN_ARB);
        origin = new OrbitalIntentSettler(address(hook), swapRouter, IMailbox(address(originMailbox)), address(this));
        dest = new OrbitalIntentSettler(address(hook), swapRouter, IMailbox(address(destMailbox)), address(this));

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

        // The attacker is an ordinary participant: a little inventory and gas.
        MockERC20(Currency.unwrap(c1)).mint(attacker, 1 ether);
        vm.deal(attacker, 1 ether);
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(c1)).approve(address(dest), type(uint256).max);
        dest.depositGas{value: 0.5 ether}();
        vm.stopPrank();
    }

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

    function _relayProof() internal {
        originMailbox.deliver(address(origin), DOMAIN_ARB, address(dest).toBytes32(), destMailbox.lastBody());
    }

    /// @notice The escrow may only be released against a fill of THAT order.
    ///
    ///         `fill` takes `orderId` and `originData` as independent arguments.
    ///         If nothing binds them, anyone who has seen a victim's `orderId`
    ///         (it is public in the `Open` event) can "fill" a worthless order
    ///         of their own construction while quoting the victim's id, and the
    ///         proof that reaches the origin releases the victim's escrow to
    ///         them. The victim's recipient is never paid.
    function test_fill_cannot_settle_an_unrelated_orderId() public {
        vm.chainId(CHAIN_BASE);
        uint256 inAmt = 1_000 ether;
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c2), inAmt, 995 ether);
        (bytes32 victimOrderId,) = _openOrder(d, uint32(block.timestamp + 1 hours));

        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(origin)), inAmt, "escrow not funded");

        // A worthless order of the attacker's own making: pay yourself 1 wei.
        OrbitalIntentSettler.OrbitalOrderData memory fake = OrbitalIntentSettler.OrbitalOrderData({
            inputToken: Currency.unwrap(c0),
            inputAmount: 1,
            outputToken: Currency.unwrap(c1),
            outputAmount: 1,
            destinationChainId: uint64(CHAIN_ARB),
            destinationSettler: address(dest),
            recipient: attacker
        });
        // ...carrying the VICTIM's orderId, in a well-formed blob: assume the
        // attacker knows the wire format exactly.
        bytes memory forgedOriginData =
            abi.encode(CHAIN_BASE, attacker, uint256(0), uint32(block.timestamp + 1 hours), abi.encode(fake));
        bytes memory fillerData = abi.encode(
            OrbitalIntentSettler.FillerData({inputToken: Currency.unwrap(c1), inputAmount: 1, repayTo: attacker})
        );

        vm.chainId(CHAIN_ARB);
        vm.prank(attacker);
        vm.expectPartialRevert(OrbitalIntentSettler.OrderIdMismatch.selector);
        dest.fill(victimOrderId, forgedOriginData, fillerData);

        // Escrow untouched, and the order is still fillable by an honest filler.
        vm.chainId(CHAIN_BASE);
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(origin)), inAmt, "escrow moved");
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(attacker), 0, "attacker drained the victim's escrow");
    }

    /// @notice The honest path still settles once the binding is enforced: the
    ///         `originData` the origin publishes must be exactly what `fill`
    ///         accepts, or the fix would brick every real fill.
    function test_honest_fill_still_settles_after_binding() public {
        vm.chainId(CHAIN_BASE);
        uint256 inAmt = 1_000 ether;
        uint256 outAmt = 995 ether;
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c2), inAmt, outAmt);
        (bytes32 orderId, bytes memory originData) = _openOrder(d, uint32(block.timestamp + 1 hours));

        vm.chainId(CHAIN_ARB);
        vm.prank(filler);
        dest.fill(
            orderId,
            originData,
            abi.encode(
                OrbitalIntentSettler.FillerData({
                    inputToken: Currency.unwrap(c2),
                    inputAmount: outAmt,
                    repayTo: filler
                })
            )
        );
        assertEq(MockERC20(Currency.unwrap(c2)).balanceOf(recipient), outAmt, "recipient underpaid");

        vm.chainId(CHAIN_BASE);
        _relayProof();
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(filler), inAmt, "filler not repaid on proof");
    }

    /// @notice A fill after `fillDeadline` must not earn a proof: the user may
    ///         already be entitled to refund, and settling both would pay the
    ///         escrow out twice.
    function test_fill_rejected_after_fillDeadline() public {
        vm.chainId(CHAIN_BASE);
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(Currency.unwrap(c2), 1_000 ether, 995 ether);
        uint32 deadline = uint32(block.timestamp + 1 hours);
        (bytes32 orderId, bytes memory originData) = _openOrder(d, deadline);

        vm.warp(uint256(deadline) + 1);
        vm.chainId(CHAIN_ARB);
        vm.prank(filler);
        vm.expectRevert(OrbitalIntentSettler.DeadlinePassed.selector);
        dest.fill(
            orderId,
            originData,
            abi.encode(
                OrbitalIntentSettler.FillerData({
                    inputToken: Currency.unwrap(c2),
                    inputAmount: 995 ether,
                    repayTo: filler
                })
            )
        );
    }
}
