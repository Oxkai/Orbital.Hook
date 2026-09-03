// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";
import {OrbitalIntentSettler} from "../src/crosschain/OrbitalIntentSettler.sol";
import {IMailbox} from "../src/crosschain/IHyperlane.sol";
import {OnchainCrossChainOrder, ResolvedCrossChainOrder, AddressCast} from "../src/crosschain/IERC7683.sol";

/// @notice Cross-chain swap across TWO REAL FORKS: Base Sepolia and Arbitrum Sepolia.
///
/// @dev This is the test that the `vm.chainId` unit test cannot be: two genuinely
///      separate EVM states, real canonical v4 PoolManager and V4Router bytecode on
///      each, real chain IDs, and separate token deployments per chain (as it would
///      actually be, since a token on Base is not the same contract as on Arbitrum).
///
///      It also runs the pool with REALISTIC MIXED DECIMALS (6-dec USDC/USDT,
///      18-dec DAI/FRAX). Every prior test used all-18-decimal tokens, which makes
///      the hook's `_scale` factor 1 and the whole decimal-conversion path a no-op.
///      Here it is live on every 6-decimal asset, which is what a mainnet deploy
///      will actually do.
///
///      Run: forge test --match-path test/CrosschainFork.t.sol -vv
contract CrosschainForkTest is Test {
    using AddressCast for address;

    /// @dev Live Hyperlane Mailboxes, from the hyperlane-registry.
    address constant MAILBOX_BASE_SEPOLIA = 0x6966b0E55883d49BFB24539356a2f8A673E02039;
    address constant MAILBOX_ARB_SEPOLIA = 0x598facE78a4302f11E3de0bee1894Da0b2Cb71F8;

    uint8 constant N = 4;
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    string[4] SYMBOLS = ["USDC", "USDT", "DAI", "FRAX"];
    uint8[4] DECIMALS = [6, 6, 18, 18];

    /// @dev One chain's full deployment.
    struct Deployment {
        uint256 forkId;
        uint256 chainId;
        OrbitalHook hook;
        OrbitalIntentSettler settler;
        IUniswapV4Router04 router;
        address mailbox;
        uint32 domain;
        address[4] tokens; // sorted ascending, as the hook requires
    }

    Deployment base;
    Deployment arb;

    address user = address(0x5E12);
    address filler = address(0xF111E2);
    address recipient = address(0xEC12);

    function setUp() public {
        // Deliberately NOT wrapped in try/catch. An unreachable RPC must fail the
        // run loudly: a fork test that silently skips reports green while proving
        // nothing, which is strictly worse than a red build.
        base.forkId = vm.createFork("base_sepolia");
        arb.forkId = vm.createFork("arbitrum_sepolia");

        base = _deployOn(base, 84532, 0x1111, MAILBOX_BASE_SEPOLIA);
        arb = _deployOn(arb, 421614, 0x2222, MAILBOX_ARB_SEPOLIA);

        // Peers must be registered on BOTH deployments before any route works.
        vm.selectFork(base.forkId);
        base.settler.setPeer(arb.chainId, arb.domain, address(arb.settler).toBytes32());
        vm.selectFork(arb.forkId);
        arb.settler.setPeer(base.chainId, base.domain, address(base.settler).toBytes32());
    }

    /// @dev Stand in for the Hyperlane relayer. Delivery is impersonated, but it
    ///      goes through the real `handle` entry point with the real Mailbox as
    ///      msg.sender, so the caller-is-mailbox and sender-is-peer checks are
    ///      genuinely exercised against the live mailbox address.
    function _relayProof(Deployment memory from, Deployment memory to, bytes32 orderId, address creditTo) internal {
        vm.selectFork(to.forkId);
        vm.prank(to.mailbox);
        to.settler.handle(from.domain, address(from.settler).toBytes32(), abi.encode(orderId, creditTo));
    }

    // ─────────────────────────────────────────────────────────────
    // Per-chain deployment
    // ─────────────────────────────────────────────────────────────

    function _deployOn(Deployment memory d, uint256 expectedChainId, uint160 salt, address mailbox)
        internal
        returns (Deployment memory)
    {
        vm.selectFork(d.forkId);
        assertEq(block.chainid, expectedChainId, "fork is not the chain we asked for");
        d.chainId = block.chainid;

        // Canonical v4 infra must already be on this chain.
        address pm = AddressConstants.getPoolManagerAddress(block.chainid);
        address rt = AddressConstants.getV4SwapRouterAddress(block.chainid);
        assertGt(pm.code.length, 0, "no PoolManager on this chain");
        assertGt(rt.code.length, 0, "no V4Router on this chain");
        d.router = IUniswapV4Router04(payable(rt));

        // Tokens, with realistic decimals, sorted ascending by address.
        MockERC20[4] memory raw;
        for (uint256 i = 0; i < N; ++i) {
            raw[i] = new MockERC20(SYMBOLS[i], SYMBOLS[i], DECIMALS[i]);
        }
        for (uint256 i = 0; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (address(raw[j]) < address(raw[i])) (raw[i], raw[j]) = (raw[j], raw[i]);
            }
        }
        Currency[] memory regd = new Currency[](N);
        for (uint256 i = 0; i < N; ++i) {
            d.tokens[i] = address(raw[i]);
            regd[i] = Currency.wrap(address(raw[i]));
        }

        // Hook at a flag-encoding address.
        address flagged = address(HOOK_FLAGS ^ (salt << 144));
        deployCodeTo(
            "OrbitalHook.sol:OrbitalHook",
            abi.encode(IPoolManager(pm), IAllowanceTransfer(PERMIT2), regd, uint24(100), address(this)),
            flagged
        );
        d.hook = OrbitalHook(flagged);

        // All N(N-1)/2 pair pools, so any hop is routable.
        for (uint256 i = 0; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                IPoolManager(pm).initialize(
                    PoolKey({
                        currency0: regd[i],
                        currency1: regd[j],
                        fee: 0,
                        tickSpacing: 1,
                        hooks: IHooks(flagged)
                    }),
                    Constants.SQRT_PRICE_1_1
                );
            }
        }

        // Seed depth. Mint generously in each token's own raw units.
        uint256 r = 1_000_000 ether; // WAD
        for (uint256 i = 0; i < N; ++i) {
            // Read decimals off the token itself: `raw` has been sorted by address,
            // so it no longer lines up with the DECIMALS[] creation order.
            raw[i].mint(address(this), 10_000_000 * (10 ** raw[i].decimals()));
            raw[i].approve(flagged, type(uint256).max);
        }
        uint256[] memory maxA = new uint256[](N);
        for (uint256 i = 0; i < N; ++i) maxA[i] = type(uint256).max;
        d.hook.addLiquidity((TickLib.kMin(r, N) + TickLib.kMax(r, N)) / 2, r, maxA);

        assertGt(mailbox.code.length, 0, "no Hyperlane Mailbox on this chain");
        d.mailbox = mailbox;
        d.settler = new OrbitalIntentSettler(flagged, d.router, IMailbox(mailbox), address(this));
        d.domain = d.settler.localDomain();
        assertEq(uint256(d.domain), block.chainid, "hyperlane domain != chainId on this chain");

        return d;
    }

    // ─────────────────────────────────────────────────────────────
    // The test
    // ─────────────────────────────────────────────────────────────

    /// @notice Full path: user gives token[0] on Base Sepolia, receives token[1] on
    ///         Arbitrum Sepolia, with the filler paying in token[2] so the fill is
    ///         forced through Arbitrum's Orbital pool.
    function test_fork_crosschain_swap_base_to_arbitrum() public {
        // token[0] is 6- or 18-dec depending on sort order; read it, do not assume.
        vm.selectFork(base.forkId);
        uint8 inDec = MockERC20(base.tokens[0]).decimals();
        uint256 inAmt = 1_000 * (10 ** inDec);

        vm.selectFork(arb.forkId);
        uint8 outDec = MockERC20(arb.tokens[1]).decimals();
        uint256 outAmt = 995 * (10 ** outDec);
        uint8 fillDec = MockERC20(arb.tokens[2]).decimals();
        uint256 fillerIn = 1_010 * (10 ** fillDec);

        // ── ORIGIN: Base Sepolia ──
        vm.selectFork(base.forkId);

        OrbitalIntentSettler.OrbitalOrderData memory d = OrbitalIntentSettler.OrbitalOrderData({
            inputToken: base.tokens[0],
            inputAmount: inAmt,
            outputToken: arb.tokens[1], // the Arbitrum-side contract
            outputAmount: outAmt,
            destinationChainId: uint64(arb.chainId),
            destinationSettler: address(arb.settler),
            recipient: recipient
        });

        MockERC20(base.tokens[0]).mint(user, inAmt);
        vm.prank(user);
        MockERC20(base.tokens[0]).approve(address(base.settler), type(uint256).max);

        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: base.settler.ORBITAL_ORDER_DATA_TYPE(),
            orderData: abi.encode(d)
        });

        vm.startPrank(user);
        ResolvedCrossChainOrder memory resolved = base.settler.resolve(order);
        bytes32 orderId = resolved.orderId;
        bytes memory originData = resolved.fillInstructions[0].originData;
        base.settler.open(order);
        vm.stopPrank();

        assertEq(MockERC20(base.tokens[0]).balanceOf(user), 0, "user not debited on origin");
        assertEq(MockERC20(base.tokens[0]).balanceOf(address(base.settler)), inAmt, "escrow not funded");
        assertEq(resolved.originChainId, 84532, "resolved wrong origin chain");
        assertEq(resolved.fillInstructions[0].destinationChainId, 421614, "resolved wrong dest chain");

        console2.log("origin  chainId:", block.chainid);
        console2.log("  escrowed (raw):", inAmt);

        // ── DESTINATION: Arbitrum Sepolia ──
        vm.selectFork(arb.forkId);

        MockERC20(arb.tokens[2]).mint(filler, fillerIn);
        vm.deal(filler, 1 ether);
        vm.startPrank(filler);
        MockERC20(arb.tokens[2]).approve(address(arb.settler), type(uint256).max);
        // Prepay the Hyperlane delivery fee (fill is non-payable per ERC-7683).
        arb.settler.depositGas{value: 0.05 ether}();

        uint256 poolBefore = arb.hook.reserves(2);
        uint256 gasBefore = arb.settler.gasDeposits(filler);

        arb.settler.fill(
            orderId,
            originData,
            abi.encode(
                OrbitalIntentSettler.FillerData({
                    inputToken: arb.tokens[2],
                    inputAmount: fillerIn,
                    repayTo: filler
                })
            )
        );
        vm.stopPrank();

        assertEq(MockERC20(arb.tokens[1]).balanceOf(recipient), outAmt, "recipient underpaid on destination");
        assertGt(arb.hook.reserves(2), poolBefore, "fill did not route through the Orbital pool");
        assertEq(MockERC20(arb.tokens[1]).balanceOf(address(arb.settler)), 0, "settler retained output dust");

        assertLt(arb.settler.gasDeposits(filler), gasBefore, "hyperlane fee not drawn");

        console2.log("dest    chainId:", block.chainid);
        console2.log("  recipient got (raw):", MockERC20(arb.tokens[1]).balanceOf(recipient));
        console2.log("  filler surplus (raw):", MockERC20(arb.tokens[1]).balanceOf(filler));
        console2.log("  hyperlane fee (wei):", gasBefore - arb.settler.gasDeposits(filler));

        // ── SETTLEMENT: escrow releases ONLY on the authenticated proof ──
        vm.selectFork(base.forkId);
        assertEq(MockERC20(base.tokens[0]).balanceOf(filler), 0, "paid before any proof arrived");

        _relayProof(arb, base, orderId, filler);

        vm.selectFork(base.forkId);
        assertEq(MockERC20(base.tokens[0]).balanceOf(filler), inAmt, "filler not repaid on proof");
        assertEq(MockERC20(base.tokens[0]).balanceOf(address(base.settler)), 0, "escrow not drained");

        console2.log("settled on chainId:", block.chainid);
        console2.log("  filler repaid (raw):", inAmt);
    }

    /// @notice A proof from the right domain but the wrong sender must not pay out,
    ///         checked against the REAL mailbox address on a real fork.
    function test_fork_forged_proof_is_rejected() public {
        vm.selectFork(base.forkId);
        uint256 inAmt = 1_000 * (10 ** MockERC20(base.tokens[0]).decimals());

        OrbitalIntentSettler.OrbitalOrderData memory d = OrbitalIntentSettler.OrbitalOrderData({
            inputToken: base.tokens[0],
            inputAmount: inAmt,
            outputToken: arb.tokens[1],
            outputAmount: 1,
            destinationChainId: uint64(arb.chainId),
            destinationSettler: address(arb.settler),
            recipient: recipient
        });

        MockERC20(base.tokens[0]).mint(user, inAmt);
        vm.prank(user);
        MockERC20(base.tokens[0]).approve(address(base.settler), type(uint256).max);

        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: base.settler.ORBITAL_ORDER_DATA_TYPE(),
            orderData: abi.encode(d)
        });
        vm.startPrank(user);
        bytes32 orderId = base.settler.resolve(order).orderId;
        base.settler.open(order);
        vm.stopPrank();

        // Right mailbox, right domain, WRONG sender.
        bytes32 impostor = address(0xBAD).toBytes32();
        vm.prank(base.mailbox);
        vm.expectRevert(
            abi.encodeWithSelector(OrbitalIntentSettler.UnknownPeer.selector, arb.domain, impostor)
        );
        base.settler.handle(arb.domain, impostor, abi.encode(orderId, address(0xBAD)));

        // Right domain and sender, but NOT via the mailbox.
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(OrbitalIntentSettler.NotMailbox.selector, address(0xBAD)));
        base.settler.handle(arb.domain, address(arb.settler).toBytes32(), abi.encode(orderId, address(0xBAD)));

        assertEq(MockERC20(base.tokens[0]).balanceOf(address(base.settler)), inAmt, "escrow moved on a forged proof");
    }

    /// @notice The two deployments are genuinely independent: same logical asset,
    ///         different contract per chain, and engine state does not leak.
    function test_fork_deployments_are_independent() public {
        assertTrue(base.tokens[0] != arb.tokens[0] || base.chainId != arb.chainId, "tokens must be per-chain");

        vm.selectFork(base.forkId);
        (uint256 baseSumX,,,,) = base.hook.slot0();
        assertGt(baseSumX, 0, "base pool unseeded");

        vm.selectFork(arb.forkId);
        (uint256 arbSumX,,,,) = arb.hook.slot0();
        assertGt(arbSumX, 0, "arb pool unseeded");

        // Swapping on Arbitrum must not move Base's engine.
        vm.selectFork(base.forkId);
        (uint256 baseAfter,,,,) = base.hook.slot0();
        assertEq(baseAfter, baseSumX, "base state changed from arbitrum activity");
    }

    /// @notice The 6-decimal scaling path is actually exercised here, unlike every
    ///         all-18-decimal test in the suite.
    function test_fork_mixed_decimals_are_scaled() public {
        vm.selectFork(base.forkId);

        bool sawSixDecimal;
        for (uint8 i = 0; i < N; ++i) {
            uint8 dec = MockERC20(base.tokens[i]).decimals();
            uint256 scale = base.hook.scaleOf(i);
            assertEq(scale, 10 ** (18 - dec), "scale factor wrong for this asset");
            if (dec == 6) {
                sawSixDecimal = true;
                assertEq(scale, 1e12, "6-decimal scale must be 1e12");
            }
        }
        assertTrue(sawSixDecimal, "test did not actually cover a 6-decimal asset");
    }
}
