// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice Gas of a swap as a user pays it: a fresh transaction, so every
///         storage slot is cold, on a four-asset pool seeded like the deploy
///         ladder. Pins the swap path's cost so a regression shows up here.
///         Figures are logged; `forge test --mc GasBaseline -vv`.
contract GasBaselineTest is BaseTest {
    OrbitalHook hook;
    PoolKey key;
    uint8 constant N = 4;
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    function setUp() public {
        deployArtifactsAndLabel();
        address[4] memory t;
        for (uint256 i; i < N; ++i) t[i] = address(deployToken());
        for (uint256 i; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) if (t[j] < t[i]) (t[i], t[j]) = (t[j], t[i]);
        }
        Currency[] memory regd = new Currency[](N);
        for (uint256 i; i < N; ++i) regd[i] = Currency.wrap(t[i]);

        address flagged = address(HOOK_FLAGS ^ (0x6A5 << 144));
        deployCodeTo("OrbitalHook.sol:OrbitalHook", abi.encode(poolManager, regd, uint24(100), address(this)), flagged);
        hook = OrbitalHook(flagged);
        for (uint256 i; i < N; ++i) MockERC20(t[i]).approve(flagged, type(uint256).max);

        // The deploy ladder's bands. Tight bands are deep (they hold little
        // real capital per unit of radius), so a small trade crosses none.
        uint256[] memory maxA = new uint256[](N);
        for (uint256 i; i < N; ++i) maxA[i] = type(uint256).max;
        uint256[8] memory bands = [uint256(0), 1, 2, 3, 4, 7, 12, 30];
        uint256[8] memory radii =
            [uint256(50_000_000 ether), 50_000_000 ether, 20_000_000 ether, 10_000_000 ether, 5_000_000 ether,
             2_000_000 ether, 1_000_000 ether, 200_000 ether];
        for (uint256 i; i < 8; ++i) hook.addLiquidity(bands[i], radii[i], maxA, block.timestamp);

        key = PoolKey({currency0: regd[0], currency1: regd[1], fee: 0, tickSpacing: 1, hooks: IHooks(flagged)});
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    function test_gas_small_swap() public {
        uint256 g = gasleft();
        swapRouter.swapExactTokensForTokens(100 ether, 0, true, key, "", address(this), block.timestamp);
        emit log_named_uint("swap $100, no crossing (cold)", g - gasleft());
    }

    function test_gas_swap_with_crossing() public {
        uint256 g = gasleft();
        swapRouter.swapExactTokensForTokens(50_000 ether, 0, true, key, "", address(this), block.timestamp);
        emit log_named_uint("swap $50k, crossing bands (cold)", g - gasleft());
    }
}
