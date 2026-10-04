// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {OrbitalHook} from "../../src/OrbitalHook.sol";
import {TierLadder} from "./TierLadder.sol";

/// @notice The deploy steps every Orbital deployment shares, whatever tokens it
///         lists: mine the hook address, register every pair with the
///         PoolManager, seed the liquidity ladder, report. The testnet script
///         brings its own mock tokens and the real-token script brings live
///         ones; both run these same steps, so they cannot drift apart.
library OrbitalDeploy {
    using SafeERC20 for IERC20;

    /// @dev The deterministic CREATE2 deployer forge broadcasts `new X{salt}`
    ///      through.
    address internal constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    /// @dev 1 bp, in hundredths of a bip.
    uint24 internal constant POOL_FEE = 100;

    /// @notice Sort `tokens` ascending by address, as the hook requires.
    function sorted(address[] memory tokens) internal pure returns (Currency[] memory out) {
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (tokens[j] < tokens[i]) (tokens[i], tokens[j]) = (tokens[j], tokens[i]);
            }
        }
        out = new Currency[](n);
        for (uint256 i = 0; i < n; ++i) out[i] = Currency.wrap(tokens[i]);
    }

    /// @notice Deploy the hook at a CREATE2 address carrying its permission flags.
    function deployHook(IPoolManager pm, Currency[] memory assets, address admin)
        internal
        returns (OrbitalHook hook)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(pm, assets, POOL_FEE, admin);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(OrbitalHook).creationCode, args);

        hook = new OrbitalHook{salt: salt}(pm, assets, POOL_FEE, admin);
        require(address(hook) == expected, "hook address mismatch");
    }

    /// @notice Register every pair as a v4 pool pointing at the hook.
    function initPools(IPoolManager pm, OrbitalHook hook, Currency[] memory assets) internal {
        uint256 n = assets.length;
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                pm.initialize(
                    PoolKey({
                        currency0: assets[i],
                        currency1: assets[j],
                        fee: 0, // the engine runs its own fee; PoolKey.lpFee must be 0
                        tickSpacing: 1,
                        hooks: IHooks(address(hook))
                    }),
                    SQRT_PRICE_1_1
                );
            }
        }
    }

    /// @notice Approve the hook and seed the ladder with `capitalPerAsset`
    ///         (engine WAD value units) of every asset.
    function seed(OrbitalHook hook, Currency[] memory assets, uint256 capitalPerAsset) internal {
        for (uint256 i = 0; i < assets.length; ++i) {
            IERC20(Currency.unwrap(assets[i])).forceApprove(address(hook), type(uint256).max);
        }
        TierLadder.seed(hook, uint8(assets.length), capitalPerAsset);
    }

    function report(OrbitalHook hook, Currency[] memory assets, address pm, address router) internal view {
        uint256 n = assets.length;
        (uint256 sumX,, uint256 rInt,,) = hook.slot0();
        console2.log("");
        console2.log("=========== ORBITAL DEPLOYMENT ===========");
        console2.log("chainId:       ", block.chainid);
        console2.log("PoolManager:   ", pm);
        console2.log("V4Router:      ", router);
        console2.log("OrbitalHook:   ", address(hook));
        console2.log("rInt:          ", rInt);
        // sumX is the engine's (virtual) total; the tokens held are that less
        // the virtual floor on every asset.
        console2.log("TVL (real, wad):", sumX - n * hook.virtualReserve());
        console2.log("sumX (virtual): ", sumX);
        console2.log("--- assets (sorted, index order) ---");
        for (uint256 i = 0; i < n; ++i) {
            address a = Currency.unwrap(assets[i]);
            console2.log(IERC20Metadata(a).symbol(), a);
            console2.log("   index:", i, "scale:", hook.scaleOf(uint8(i)));
        }
        console2.log("=========================================");
    }
}
