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

/// @notice Lifecycle simulation on the live X Layer pool, kept near peg:
///         swaps -> seed again (new tick) -> swaps. Swaps are small relative to
///         the ~10M rInt and roughly balanced, so reserves barely move and no
///         tick crosses to boundary (kBound stays 0).
///
/// @dev forge script script/SeedActivity.s.sol --rpc-url <xlayer> \
///          --broadcast --slow --private-key $PRIVATE_KEY
contract SeedActivityScript is Script {
    OrbitalHook internal constant HOOK = OrbitalHook(0x4024911A26B5BF5160D156eccBAc148bd55c6a88);
    IUniswapV4Router04 internal constant ROUTER =
        IUniswapV4Router04(payable(0xC30819b8ac12B5d12751b83cFfebD6F0bFa0b53E));

    address internal constant A = 0xBe272Bcb1Fa1d99616F53Ce7d7703589C92bb33b; // USDC
    address internal constant B = 0x3a2bCfc287b8106774Ec85533d821D3604cB7DC5; // USDT
    address internal constant C = 0x78340e3C5169b6DF15F13a8d627Db2C0e23cf921; // DAI
    address internal constant D = 0x17c868495deF240091E95410e2B2D5a6cEabf6f0; // FRAX

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
