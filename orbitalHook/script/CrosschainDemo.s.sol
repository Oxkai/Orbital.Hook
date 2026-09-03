// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {OrbitalIntentSettler} from "../src/crosschain/OrbitalIntentSettler.sol";
import {OnchainCrossChainOrder, ResolvedCrossChainOrder} from "../src/crosschain/IERC7683.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Drives a real cross-chain swap across the live deployments:
///         USDC on the origin chain -> USDT on the destination, with the filler
///         paying in DAI so the fill routes through the destination Orbital pool.
///
/// @dev No pinned token addresses. Assets are resolved by SYMBOL off each chain's
///      hook, because they differ per chain and rotate on every redeploy.
///      There is no claim/settle step: `fill` dispatches a Hyperlane message and
///      a relayer delivers it, after which `handle` releases the escrow.
///
///      Required env: ORIGIN_SETTLER, ORIGIN_HOOK, DEST_SETTLER, DEST_HOOK, DEST_CHAIN_ID
///
///   0) --sig "step0_depositGas()"  --rpc-url <dest>
///   1) --sig "step1_open()"        --rpc-url <origin>     (prints ORDER_ID / ORIGIN_DATA)
///   2) export ORDER_ID=.. ORIGIN_DATA=..
///      --sig "step2_fill()"        --rpc-url <dest>
///   3) --sig "step3_status()"      --rpc-url <origin>
contract CrosschainDemoScript is Script {
    uint256 constant IN_WHOLE = 1_000;
    uint256 constant OUT_WHOLE = 995;
    uint256 constant FILLER_IN_WHOLE = 1_010;

    function _originSettler() internal view returns (OrbitalIntentSettler) {
        return OrbitalIntentSettler(payable(vm.envAddress("ORIGIN_SETTLER")));
    }

    function _destSettler() internal view returns (OrbitalIntentSettler) {
        return OrbitalIntentSettler(payable(vm.envAddress("DEST_SETTLER")));
    }

    /// @dev Resolve a symbol to (address, decimals) on a given hook.
    function _asset(address hookAddr, string memory symbol) internal view returns (address, uint8) {
        OrbitalHook h = OrbitalHook(hookAddr);
        uint8 nn = h.N();
        for (uint8 i = 0; i < nn; ++i) {
            address t = Currency.unwrap(h.assetAt(i));
            if (keccak256(bytes(IERC20Meta(t).symbol())) == keccak256(bytes(symbol))) {
                return (t, IERC20Meta(t).decimals());
            }
        }
        revert(string.concat("asset not on hook: ", symbol));
    }

    /// @dev The DESTINATION asset cannot be resolved here: this runs against the
    ///      ORIGIN chain's RPC, so reading the destination hook reverts with
    ///      "call to non-contract address". It is supplied instead; `printAssets`
    ///      below prints the values to export, run against the destination chain.
    function _orderData(address recipient)
        internal
        view
        returns (OrbitalIntentSettler.OrbitalOrderData memory d)
    {
        (address inTok, uint8 inDec) = _asset(vm.envAddress("ORIGIN_HOOK"), "USDC");
        address outTok = vm.envAddress("DEST_OUT_TOKEN");
        uint8 outDec = uint8(vm.envUint("DEST_OUT_DECIMALS"));
        d = OrbitalIntentSettler.OrbitalOrderData({
            inputToken: inTok,
            inputAmount: IN_WHOLE * (10 ** uint256(inDec)),
            outputToken: outTok,
            outputAmount: OUT_WHOLE * (10 ** uint256(outDec)),
            destinationChainId: uint64(vm.envUint("DEST_CHAIN_ID")),
            destinationSettler: address(_destSettler()),
            recipient: recipient
        });
    }

    // ─────────────────────────────────────────────────────────────

    /// @notice Run against the DESTINATION chain to get the values step 1 needs.
    function printAssets() external view {
        address hookAddr = vm.envAddress("DEST_HOOK");
        (address usdt, uint8 usdtDec) = _asset(hookAddr, "USDT");
        (address dai, uint8 daiDec) = _asset(hookAddr, "DAI");
        console2.log("  export DEST_OUT_TOKEN=%s", vm.toString(usdt));
        console2.log("  export DEST_OUT_DECIMALS=%s", vm.toString(uint256(usdtDec)));
        console2.log("  (filler pays DAI %s, %s dp)", vm.toString(dai), vm.toString(uint256(daiDec)));
    }

    function step0_depositGas() external {
        OrbitalIntentSettler dest = _destSettler();
        vm.startBroadcast();
        dest.depositGas{value: 0.005 ether}();
        vm.stopBroadcast();
        console2.log("=== STEP 0: gas deposited on destination ===");
        console2.log("  filler gas balance (wei):", dest.gasDeposits(msg.sender));
    }

    function step1_open() external {
        OrbitalIntentSettler origin = _originSettler();
        OrbitalIntentSettler.OrbitalOrderData memory d = _orderData(msg.sender);

        OnchainCrossChainOrder memory order = OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 6 hours),
            orderDataType: origin.ORBITAL_ORDER_DATA_TYPE(),
            orderData: abi.encode(d)
        });

        vm.startBroadcast();
        IERC20(d.inputToken).approve(address(origin), type(uint256).max);
        ResolvedCrossChainOrder memory r = origin.resolve(order);
        origin.open(order);
        vm.stopBroadcast();

        console2.log("=== STEP 1: opened on origin ===");
        console2.log("  escrowed (raw):", IERC20(d.inputToken).balanceOf(address(origin)));
        console2.log("");
        console2.log("  export ORDER_ID=%s", vm.toString(r.orderId));
        console2.log("  export ORIGIN_DATA=%s", vm.toString(r.fillInstructions[0].originData));
    }

    function step2_fill() external {
        OrbitalIntentSettler dest = _destSettler();
        bytes32 orderId = vm.envBytes32("ORDER_ID");
        bytes memory originData = vm.envBytes("ORIGIN_DATA");
        address me = msg.sender;

        // Filler pays in DAI, which is neither side of the user's pair, so the
        // settler must route it through the destination Orbital pool.
        (address dai, uint8 daiDec) = _asset(vm.envAddress("DEST_HOOK"), "DAI");
        (address usdt,) = _asset(vm.envAddress("DEST_HOOK"), "USDT");
        uint256 fillerIn = FILLER_IN_WHOLE * (10 ** uint256(daiDec));

        uint256 usdtBefore = IERC20(usdt).balanceOf(me);
        uint256 gasBefore = dest.gasDeposits(me);

        vm.startBroadcast();
        IERC20(dai).approve(address(dest), type(uint256).max);
        dest.fill(
            orderId,
            originData,
            abi.encode(
                OrbitalIntentSettler.FillerData({inputToken: dai, inputAmount: fillerIn, repayTo: me})
            )
        );
        vm.stopBroadcast();

        console2.log("=== STEP 2: filled on destination ===");
        console2.log("  DAI spent (raw):", fillerIn);
        console2.log("  USDT delta (raw):", IERC20(usdt).balanceOf(me) - usdtBefore);
        console2.log("  hyperlane fee (wei):", gasBefore - dest.gasDeposits(me));
        console2.log("  proof dispatched; a relayer now delivers it to the origin");
    }

    function step3_status() external view {
        OrbitalIntentSettler origin = _originSettler();
        bytes32 orderId = vm.envBytes32("ORDER_ID");
        (,, uint256 amount,,, OrbitalIntentSettler.OrderStatus status) = origin.orders(orderId);

        console2.log("=== STEP 3: origin state ===");
        console2.log("  escrow amount (raw):", amount);
        console2.log("  status (1=OPENED 2=SETTLED 3=REFUNDED):", uint256(status));
        if (status == OrbitalIntentSettler.OrderStatus.SETTLED) {
            console2.log("  >> proof delivered, escrow released to the filler");
        } else {
            console2.log("  >> not delivered yet; re-run in a minute");
        }
    }
}
