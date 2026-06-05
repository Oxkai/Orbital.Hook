// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";

/// @notice Full LP lifecycle exercise on the live Unichain Sepolia pool:
///         add at a new tick → swaps → collect fees → partial burn → full burn
///         → verify free-list reuse → second add at a different k → burn.
/// @dev    forge script script/Lifecycle.s.sol --rpc-url <unichain-sepolia> \
///             --broadcast --slow --private-key $PRIVATE_KEY
contract LifecycleScript is Script {
    OrbitalHook internal constant HOOK = OrbitalHook(0x405E3C4541077C501854082cf3256926BeF6AA88);
    IUniswapV4Router04 internal constant ROUTER =
        IUniswapV4Router04(payable(0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540));

    address internal constant A = 0x3f53c9ae1ae5D34D8A89986ea456da8e69916725; // USDC
    address internal constant B = 0x17684C1C522E7cCD9a38E1Ab5994BB294Bf1ef90; // USDT
    address internal constant C = 0x345581C18e6b15D02b303A4E7Cc2F0671591acbE; // DAI
    address internal constant D = 0x1D49545CccDA551d5f5b2Ec95Fc53C34432016cF; // FRAX

    uint8 internal constant N = 4;

    function run() external {
        vm.startBroadcast();

        _approveAll();

        console2.log("==== START: live pool LP lifecycle ====");
        _logState();
        uint256 numTicksStart = HOOK.numTicks();

        // ────────────────────────────────────────────────────────────
        // STEP 1 - add a new tick at a fresh depeg bound (0.92, between
        // existing seed tiers 0.95 / 0.90). Confirms addLiquidity at a k
        // not previously seen creates a new tick.
        // ────────────────────────────────────────────────────────────
        console2.log("");
        console2.log(">>> STEP 1: addLiquidity new tick (depeg 0.92, rWad 500k)");
        uint256 tick1 = _addTier(500_000 ether, 0.92e18);
        console2.log("    new tickIdx:", tick1);
        console2.log("    LP balance @ tickIdx:", HOOK.balanceOf(msg.sender, tick1));
        _logState();

        // ────────────────────────────────────────────────────────────
        // STEP 2 - swap wave to accrue fees on every interior tick
        // (including the new one). All 4 directions so fees accrue on
        // every input asset.
        // ────────────────────────────────────────────────────────────
        console2.log("");
        console2.log(">>> STEP 2: swap wave to accrue fees");
        _swap(A, B, 5_000 ether);
        _swap(C, D, 4_000 ether);
        _swap(B, A, 6_000 ether);
        _swap(D, C, 3_000 ether);
        _swap(A, C, 4_500 ether);
        _swap(B, D, 3_500 ether);
        _logState();

        // ────────────────────────────────────────────────────────────
        // STEP 3 - collect accrued fees on the new tick.
        // ────────────────────────────────────────────────────────────
        console2.log("");
        console2.log(">>> STEP 3: collect fees on new tick");
        try HOOK.collect(tick1) returns (uint256[] memory fees) {
            for (uint8 i = 0; i < N; ++i) console2.log("    fee asset", i, fees[i]);
        } catch {
            console2.log("    (no fees accrued)");
        }

        // ────────────────────────────────────────────────────────────
        // STEP 4 - partial burn: remove 50% of the new tick.
        // ────────────────────────────────────────────────────────────
        console2.log("");
        console2.log(">>> STEP 4: partial burn (50% of new tick)");
        uint256 bal1 = HOOK.balanceOf(msg.sender, tick1);
        _burnTick(tick1, bal1 / 2);
        console2.log("    post-burn balance:", HOOK.balanceOf(msg.sender, tick1));
        _logState();

        // ────────────────────────────────────────────────────────────
        // STEP 5 - full burn of the remaining share. Tick should land
        // on the free-list (r == 0) for reuse.
        // ────────────────────────────────────────────────────────────
        console2.log("");
        console2.log(">>> STEP 5: full burn the rest");
        uint256 rem1 = HOOK.balanceOf(msg.sender, tick1);
        _burnTick(tick1, rem1);
        console2.log("    post-burn balance:", HOOK.balanceOf(msg.sender, tick1));
        _logState();

        // ────────────────────────────────────────────────────────────
        // STEP 6 - add at a different k (0.83). Free-list should recycle
        // the slot, so numTicks does NOT grow.
        // ────────────────────────────────────────────────────────────
        console2.log("");
        console2.log(">>> STEP 6: add at depeg 0.83 - should reuse freed slot");
        uint256 numTicksPre = HOOK.numTicks();
        uint256 tick2 = _addTier(300_000 ether, 0.83e18);
        console2.log("    numTicks before / after:", numTicksPre, HOOK.numTicks());
        console2.log("    new tickIdx:", tick2);
        require(HOOK.numTicks() == numTicksPre, "free-list should recycle slot, not grow array");
        _logState();

        // ────────────────────────────────────────────────────────────
        // STEP 7 - clean up: full burn the recycled tick.
        // ────────────────────────────────────────────────────────────
        console2.log("");
        console2.log(">>> STEP 7: full burn the recycled tick");
        _burnTick(tick2, HOOK.balanceOf(msg.sender, tick2));
        _logState();

        vm.stopBroadcast();

        console2.log("");
        console2.log("==== END: all flows succeeded ====");
        console2.log("  initial numTicks:", numTicksStart);
        console2.log("  final numTicks:  ", HOOK.numTicks());
    }

    // ────────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────────

    function _approveAll() internal {
        address[4] memory toks = [A, B, C, D];
        for (uint256 i = 0; i < 4; ++i) {
            IERC20(toks[i]).approve(address(ROUTER), type(uint256).max);
            IERC20(toks[i]).approve(address(HOOK), type(uint256).max);
        }
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        (address c0, address c1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(HOOK))
        });
        ROUTER.swapExactTokensForTokens(
            amountIn, 0, tokenIn == c0, key, "", msg.sender, block.timestamp + 7200
        );
    }

    function _addTier(uint256 rWad, uint256 depegWad) internal returns (uint256 tickIdx) {
        uint256 k = TickLib.kFromDepegPrice(rWad, N, depegWad);
        uint256[] memory maxA = new uint256[](N);
        for (uint256 i = 0; i < N; ++i) maxA[i] = type(uint256).max;
        (tickIdx, ) = HOOK.addLiquidity(k, rWad, maxA);
    }

    function _burnTick(uint256 tickIdx, uint256 rWad) internal {
        uint256[] memory minA = new uint256[](N);
        HOOK.removeLiquidity(tickIdx, rWad, minA);
    }

    function _logState() internal view {
        (uint256 sumX, , uint256 rInt, uint256 kBound, ) = HOOK.slot0();
        console2.log("    numTicks:", HOOK.numTicks(), "rInt:", rInt);
        console2.log("    sumX(TVL):", sumX, "kBound:", kBound);
    }
}
