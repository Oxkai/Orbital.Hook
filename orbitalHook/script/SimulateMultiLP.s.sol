// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";

import {OrbitalHook} from "../src/OrbitalHook.sol";
import {TickLib} from "../src/libraries/TickLib.sol";

/// @notice Multi-LP lifecycle simulation, interleaved (not sequential phases).
///         Three LPs (Alice, Bob, Carol) with different ticks/positions, plus a
///         dedicated Swapper. Operations mix: imbalanced-pool mints, tiny + large
///         swaps in different directions, fee accrual across multiple ticks,
///         per-LP collects, partial and full burns.
///
/// @dev Uses anvil's first 5 pre-unlocked accounts. Run against fresh anvil:
///         anvil &
///         forge script script/SimulateMultiLP.s.sol --rpc-url http://localhost:8545 \
///             --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
contract SimulateMultiLPScript is Script {
    // Anvil default unlocked keys.
    uint256 internal constant PK_DEPLOYER = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant PK_ALICE = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant PK_BOB = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant PK_CAROL = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant PK_SWAPPER = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;

    address DEPLOYER;
    address ALICE;
    address BOB;
    address CAROL;
    address SWAPPER;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant POOL_FEE = 100; // 1 bp
    uint8 internal constant N = 4;
    uint256 internal constant LP_TOKEN_BUDGET = 2_000_000 ether;

    // Tick indices are deterministic: first to addLiquidity at a given k gets tickIdx=0, etc.
    uint256 internal constant TICK_MID = 0; // Alice/Bob share this
    uint256 internal constant TICK_WIDE = 1; // Carol's own

    OrbitalHook internal hook;
    IPoolManager internal poolManager;
    IUniswapV4Router04 internal swapRouter;
    IPermit2 internal permit2;
    Currency[] internal assets;
    string[4] internal SYMBOLS = ["sUSDA", "sUSDB", "sUSDC", "sUSDD"];

    function run() external {
        DEPLOYER = vm.addr(PK_DEPLOYER);
        ALICE = vm.addr(PK_ALICE);
        BOB = vm.addr(PK_BOB);
        CAROL = vm.addr(PK_CAROL);
        SWAPPER = vm.addr(PK_SWAPPER);

        _deployAndDistribute();
        _logHeader("INITIAL STATE");
        _logEngine();
        _logHoldings();

        // ┌──────────────────────────────────────────────────────────┐
        // │ 1. Alice — first mint on empty pool, midpoint tick       │
        // └──────────────────────────────────────────────────────────┘
        uint256 kMid = (TickLib.kMin(100_000 ether, N) + TickLib.kMax(100_000 ether, N)) / 2;
        _logHeader("Alice mints 100k at midpoint k");
        _mintAs(PK_ALICE, kMid, 100_000 ether);
        _logEngine();

        // ┌──────────────────────────────────────────────────────────┐
        // │ 2. Swapper — tiny probe                                  │
        // └──────────────────────────────────────────────────────────┘
        _logHeader("Swap: 0.5 sUSDA -> sUSDB");
        _swapAs(PK_SWAPPER, 0, 1, 0.5 ether);

        // ┌──────────────────────────────────────────────────────────┐
        // │ 3. Bob — joins Alice's tick (imbalanced-pool pro-rata)   │
        // └──────────────────────────────────────────────────────────┘
        _logHeader("Bob mints 100k at SAME midpoint tick (merge)");
        _mintAs(PK_BOB, kMid, 100_000 ether);
        _logEngine();
        console2.log("  tick count:", hook.numTicks());

        // ┌──────────────────────────────────────────────────────────┐
        // │ 4. Medium swap                                           │
        // └──────────────────────────────────────────────────────────┘
        _logHeader("Swap: 50 sUSDB -> sUSDC");
        _swapAs(PK_SWAPPER, 1, 2, 50 ether);

        // ┌──────────────────────────────────────────────────────────┐
        // │ 5. Carol — new tick (different k AND r)                  │
        // └──────────────────────────────────────────────────────────┘
        uint256 kCarol = TickLib.kMax(50_000 ether, N) - 5_000 ether;
        _logHeader("Carol mints 50k at her OWN wider tick");
        _mintAs(PK_CAROL, kCarol, 50_000 ether);
        _logEngine();
        console2.log("  tick count:", hook.numTicks());

        // ┌──────────────────────────────────────────────────────────┐
        // │ 6. Big swap                                              │
        // └──────────────────────────────────────────────────────────┘
        _logHeader("Swap: 1000 sUSDA -> sUSDD (large)");
        _swapAs(PK_SWAPPER, 0, 3, 1000 ether);
        _logEngine();

        // ┌──────────────────────────────────────────────────────────┐
        // │ 7. Micro reverse swap                                    │
        // └──────────────────────────────────────────────────────────┘
        _logHeader("Swap: 0.01 sUSDD -> sUSDA (micro)");
        _swapAs(PK_SWAPPER, 3, 0, 0.01 ether);

        // ┌──────────────────────────────────────────────────────────┐
        // │ 8. Alice tops up her position                            │
        // └──────────────────────────────────────────────────────────┘
        // For tick merge to work, top-up rWad must keep the existing kWad in [kMin, kMax].
        // Easiest path: use the same rWad as the original mint.
        _logHeader("Alice tops up with another 100k at the same tick");
        _mintAs(PK_ALICE, kMid, 100_000 ether);
        _logEngine();

        // ┌──────────────────────────────────────────────────────────┐
        // │ 9. Another medium swap, reverse direction               │
        // └──────────────────────────────────────────────────────────┘
        _logHeader("Swap: 100 sUSDC -> sUSDB");
        _swapAs(PK_SWAPPER, 2, 1, 100 ether);
        _logEngine();

        // ┌──────────────────────────────────────────────────────────┐
        // │ 10. Each LP collects their fees                          │
        // └──────────────────────────────────────────────────────────┘
        _logHeader("Alice collects");
        _collectAs(PK_ALICE, TICK_MID);
        _logHeader("Bob collects");
        _collectAs(PK_BOB, TICK_MID);
        _logHeader("Carol collects");
        _collectAs(PK_CAROL, TICK_WIDE);
        _logEngine();

        // ┌──────────────────────────────────────────────────────────┐
        // │ 11. Burns — partial and full                             │
        // └──────────────────────────────────────────────────────────┘
        _logHeader("Alice burns 50% (100k of 200k)");
        _burnAs(PK_ALICE, TICK_MID, 100_000 ether);
        _logHeader("Bob burns ALL (100k)");
        _burnAs(PK_BOB, TICK_MID, 100_000 ether);
        _logHeader("Carol burns half (25k of 50k)");
        _burnAs(PK_CAROL, TICK_WIDE, 25_000 ether);
        _logEngine();

        _logHeader("FINAL HOLDINGS");
        _logHoldings();
    }

    // ─────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────

    function _deployAndDistribute() internal {
        // Deployer phase.
        vm.startBroadcast(PK_DEPLOYER);

        permit2 = IPermit2(Permit2Deployer.deploy());
        poolManager = IPoolManager(V4PoolManagerDeployer.deploy(DEPLOYER));
        swapRouter = IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(poolManager), address(permit2))));

        console2.log("Permit2:    ", address(permit2));
        console2.log("PoolManager:", address(poolManager));
        console2.log("SwapRouter: ", address(swapRouter));

        // Deploy 4 mock tokens. Each minted to deployer; deployer disburses.
        MockERC20[] memory raw = new MockERC20[](N);
        for (uint8 i = 0; i < N; ++i) {
            MockERC20 t = new MockERC20(string.concat("Mock ", SYMBOLS[i]), SYMBOLS[i], 18);
            t.mint(DEPLOYER, LP_TOKEN_BUDGET * 5);
            raw[i] = t;
        }
        for (uint8 i = 0; i < N; ++i) {
            for (uint8 j = uint8(i + 1); j < N; ++j) {
                if (address(raw[j]) < address(raw[i])) (raw[i], raw[j]) = (raw[j], raw[i]);
            }
        }
        for (uint8 i = 0; i < N; ++i) {
            assets.push(Currency.wrap(address(raw[i])));
            // Disburse to all four parties (Alice, Bob, Carol, Swapper).
            raw[i].transfer(ALICE, LP_TOKEN_BUDGET);
            raw[i].transfer(BOB, LP_TOKEN_BUDGET);
            raw[i].transfer(CAROL, LP_TOKEN_BUDGET);
            raw[i].transfer(SWAPPER, LP_TOKEN_BUDGET);
        }

        // Hook deploy + pool init.
        hook = _deployHook();
        _initAllPools();

        console2.log("OrbitalHook:", address(hook));
        for (uint8 i = 0; i < N; ++i) {
            console2.log(string.concat("  ", SYMBOLS[i], ":"), Currency.unwrap(assets[i]));
        }

        vm.stopBroadcast();

        // Each LP + Swapper sets their own approvals.
        _approveAs(PK_ALICE);
        _approveAs(PK_BOB);
        _approveAs(PK_CAROL);
        _approveAs(PK_SWAPPER);
    }

    function _deployHook() internal returns (OrbitalHook h) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory ctorArgs = abi.encode(poolManager, permit2, assets, POOL_FEE, DEPLOYER);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(OrbitalHook).creationCode, ctorArgs);
        h = new OrbitalHook{salt: salt}(poolManager, permit2, assets, POOL_FEE, DEPLOYER);
        require(address(h) == expected, "hook addr mismatch");
    }

    function _initAllPools() internal {
        for (uint256 i = 0; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                PoolKey memory key = PoolKey({
                    currency0: assets[i],
                    currency1: assets[j],
                    fee: 0,
                    tickSpacing: 1,
                    hooks: IHooks(address(hook))
                });
                poolManager.initialize(key, SQRT_PRICE_1_1);
            }
        }
    }

    function _approveAs(uint256 pk) internal {
        vm.startBroadcast(pk);
        for (uint8 i = 0; i < N; ++i) {
            address t = Currency.unwrap(assets[i]);
            MockERC20(t).approve(address(hook), type(uint256).max);
            MockERC20(t).approve(address(permit2), type(uint256).max);
            MockERC20(t).approve(address(swapRouter), type(uint256).max);
            permit2.approve(t, address(swapRouter), type(uint160).max, type(uint48).max);
        }
        vm.stopBroadcast();
    }

    // ─────────────────────────────────────────────────────────────
    // LP actions
    // ─────────────────────────────────────────────────────────────

    function _mintAs(uint256 pk, uint256 kWad, uint256 rWad) internal {
        uint256[] memory maxA = new uint256[](N);
        for (uint256 i = 0; i < N; ++i) maxA[i] = type(uint256).max;
        vm.startBroadcast(pk);
        (uint256 tickIdx, uint256[] memory amounts) = hook.addLiquidity(kWad, rWad, maxA);
        vm.stopBroadcast();
        console2.log("  tickIdx :", tickIdx);
        console2.log("  rWad    :", rWad);
        for (uint256 i = 0; i < N; ++i) {
            console2.log(string.concat("  pulled[", SYMBOLS[i], "]:"), amounts[i]);
        }
    }

    function _swapAs(uint256 pk, uint8 fromIdx, uint8 toIdx, uint256 amountIn) internal {
        address sender = vm.addr(pk);
        (uint8 lo, uint8 hi) = fromIdx < toIdx ? (fromIdx, toIdx) : (toIdx, fromIdx);
        PoolKey memory key = PoolKey({
            currency0: assets[lo],
            currency1: assets[hi],
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        uint256 balOutBefore = MockERC20(Currency.unwrap(assets[toIdx])).balanceOf(sender);
        vm.startBroadcast(pk);
        swapRouter.swapExactTokensForTokens(
            amountIn, 0, fromIdx < toIdx, key, "", sender, block.timestamp + 1 hours
        );
        vm.stopBroadcast();
        uint256 got = MockERC20(Currency.unwrap(assets[toIdx])).balanceOf(sender) - balOutBefore;
        console2.log(string.concat("  in[", SYMBOLS[fromIdx], "]:"), amountIn);
        console2.log(string.concat("  out[", SYMBOLS[toIdx], "]:"), got);
    }

    function _collectAs(uint256 pk, uint256 tickIdx) internal {
        vm.startBroadcast(pk);
        uint256[] memory fees = hook.collect(tickIdx);
        vm.stopBroadcast();
        for (uint256 i = 0; i < N; ++i) {
            if (fees[i] > 0) console2.log(string.concat("  fees[", SYMBOLS[i], "]:"), fees[i]);
        }
    }

    function _burnAs(uint256 pk, uint256 tickIdx, uint256 rWad) internal {
        uint256[] memory minA = new uint256[](N);
        vm.startBroadcast(pk);
        uint256[] memory amts = hook.removeLiquidity(tickIdx, rWad, minA);
        vm.stopBroadcast();
        for (uint256 i = 0; i < N; ++i) {
            console2.log(string.concat("  returned[", SYMBOLS[i], "]:"), amts[i]);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Logging
    // ─────────────────────────────────────────────────────────────

    function _logHeader(string memory tag) internal pure {
        console2.log("");
        console2.log("==", tag, "==");
    }

    function _logEngine() internal view {
        (uint256 sumX, uint256 sumXSq, uint256 rInt, uint256 kBound, uint256 sBound) = hook.slot0();
        console2.log("  rInt    :", rInt);
        console2.log("  sumX    :", sumX);
        console2.log("  sumXSq  :", sumXSq);
        console2.log("  kBound  :", kBound);
        console2.log("  sBound  :", sBound);
        for (uint8 i = 0; i < N; ++i) {
            console2.log(
                string.concat("  reserves[", SYMBOLS[i], "]:"),
                hook.reserves(i),
                "feesAccrued:",
                hook.feesAccrued(i)
            );
        }
    }

    function _logHoldings() internal view {
        _logHoldingsFor("Alice ", ALICE);
        _logHoldingsFor("Bob   ", BOB);
        _logHoldingsFor("Carol ", CAROL);
        _logHoldingsFor("Swappr", SWAPPER);
    }

    function _logHoldingsFor(string memory tag, address who) internal view {
        console2.log("  ", tag);
        for (uint8 i = 0; i < N; ++i) {
            console2.log(
                string.concat("    ", SYMBOLS[i], ":"),
                MockERC20(Currency.unwrap(assets[i])).balanceOf(who)
            );
        }
        // ERC-6909 shares
        if (hook.balanceOf(who, TICK_MID) > 0) {
            console2.log("    shares@tickMid :", hook.balanceOf(who, TICK_MID));
        }
        if (hook.balanceOf(who, TICK_WIDE) > 0) {
            console2.log("    shares@tickWide:", hook.balanceOf(who, TICK_WIDE));
        }
    }
}
