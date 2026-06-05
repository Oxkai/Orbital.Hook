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

/// @notice Lifecycle simulation on the live Unichain Sepolia pool, kept near peg:
///         swaps -> seed again (new tick) -> swaps. Swaps are small relative to
///         the ~10M rInt and roughly balanced, so reserves barely move and no
///         tick crosses to boundary (kBound stays 0).
///
/// @dev forge script script/SeedActivity.s.sol --rpc-url <unichain-sepolia> \
///          --broadcast --slow --private-key $PRIVATE_KEY
contract SeedActivityScript is Script {
    // Filled from the Unichain Sepolia Deploy.s.sol + DeployPeriphery.s.sol output.
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

        address[4] memory toks = [A, B, C, D];
        for (uint256 i = 0; i < 4; ++i) {
            IERC20(toks[i]).approve(address(ROUTER), type(uint256).max);
            IERC20(toks[i]).approve(address(HOOK), type(uint256).max);
        }

        console2.log("--- T0: seeded (4 tiers, ~20M TVL) ---");
        _logState();

        // T1 — first wave: small, near-balanced swaps (volume + tiny skew, near peg).
        _swap(A, B, 12_000 ether);
        _swap(B, A, 9_000 ether);
        _swap(C, D, 10_000 ether);
        _swap(D, C, 8_000 ether);
        _swap(A, C, 7_000 ether);
        _swap(B, D, 6_000 ether);
        console2.log("--- T1: after first swap wave ---");
        _logState();

        // T2 — seed again: add a fifth tick at a fresh depeg bound (pool still
        // near peg + all-interior, so the mint is valid and pro-rata).
        _seedTier(2_000_000 ether, 0.88e18);
        console2.log("--- T2: re-seeded (new tick added) ---");
        _logState();

        // T3 — second wave: more small near-balanced swaps.
        _swap(C, A, 8_000 ether);
        _swap(D, B, 7_000 ether);
        _swap(A, D, 6_000 ether);
        _swap(B, C, 9_000 ether);
        _swap(C, B, 7_000 ether);

        vm.stopBroadcast();

        console2.log("--- final state (near peg, no crossing) ---");
        _logState();
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
        ROUTER.swapExactTokensForTokens(amountIn, 0, tokenIn == c0, key, "", msg.sender, block.timestamp + 7200);
    }

    function _seedTier(uint256 rWad, uint256 depegWad) internal {
        uint256 k = TickLib.kFromDepegPrice(rWad, N, depegWad);
        uint256[] memory maxA = new uint256[](N);
        for (uint256 i = 0; i < N; ++i) maxA[i] = type(uint256).max;
        HOOK.addLiquidity(k, rWad, maxA);
    }

    function _logState() internal view {
        (uint256 sumX, , uint256 rInt, uint256 kBound,) = HOOK.slot0();
        console2.log("  numTicks:", HOOK.numTicks(), "rInt:", rInt);
        console2.log("  sumX(TVL):", sumX, "kBound:", kBound);
        for (uint8 i = 0; i < N; ++i) {
            console2.log("  reserve", i, HOOK.reserves(i));
        }
    }
}
