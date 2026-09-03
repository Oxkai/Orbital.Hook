import { type Address } from "viem";
import {
  DEPLOYMENTS,
  PRIMARY_CHAIN_ID,
  ROUTABLE_SYMBOLS,
  TOKEN_DISPLAY,
} from "@/lib/crosschain";

// ─── Deployed addresses ───────────────────────────────────────────────────────
// DERIVED, never hand-written. Every address here comes from the single registry
// in `lib/crosschain.ts`, which is generated from `orbitalHook/deployments.json`.
//
// These used to be a second, hand-maintained copy of the addresses, and it went
// stale the moment anything was redeployed: the pools, positions and
// transactions pages were still pointing at a dead hook while the swap widget
// had moved on. Deriving them means a redeploy updates one file and every page
// follows.
//
// The exports below are the PRIMARY chain's deployment, for the pages that show
// a single chain. Anything multi-chain should read `DEPLOYMENTS` directly.

const PRIMARY = DEPLOYMENTS[PRIMARY_CHAIN_ID];

export const PRIMARY_CHAIN = PRIMARY_CHAIN_ID;

export const HOOK_ADDRESS    = PRIMARY.orbitalHook as Address;
export const POOL_MANAGER    = PRIMARY.poolManager as Address;
export const SWAP_ROUTER     = PRIMARY.swapRouter as Address;
export const QUOTER_ADDRESS  = PRIMARY.quoter as Address;
export const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as Address;

// The OrbitalHook is both the "pool" (engine state + LP surface) and the swap
// target. LP positions are soulbound ERC-6909 shares on the hook (tokenId =
// tickIdx) the Positions/LP pages read & write the hook directly via
// HOOK_LP_ABI; there is no separate PositionManager.
export const POOL_ADDRESS    = HOOK_ADDRESS;
/// The pool. Orbital is one N-asset book shared by many LPs via ticks; the Base
/// and Arbitrum deployments are the same pool with a settler at each end for
/// cross-chain orders, not separate pools. `ALL_POOLS` in the registry has every
/// deployment for anything that genuinely needs to enumerate them.
export const POOL_ADDRESSES  = [HOOK_ADDRESS] as readonly Address[];
export const ROUTER_ADDRESS  = SWAP_ROUTER;

/// Primary-chain assets by symbol. Note the addresses differ per chain, so this
/// is only meaningful alongside `PRIMARY_CHAIN`.
export const TOKEN_ADDRESSES = Object.fromEntries(
  ROUTABLE_SYMBOLS.map((s) => [s, PRIMARY.assets[s].address as Address])
) as Record<(typeof ROUTABLE_SYMBOLS)[number], Address>;

// Pool fee in hundredths of a bip (matches the hook's immutable `fee`).
export const POOL_FEE: number = 100;
export const POOL_TICK_SPACING: number = 1;
export const POOL_KEY_LP_FEE: number = 0;

/// Block the primary hook was deployed at: event scanners start here.
export const DEPLOY_BLOCK = PRIMARY.deployBlock;

/// Per-chain deploy block, for scanners that follow a specific chain.
export function deployBlockFor(chainId: number): bigint {
  return DEPLOYMENTS[chainId]?.deployBlock ?? 0n;
}

// ─── Token metadata ───────────────────────────────────────────────────────────
// Keyed by lowercased token address, spanning EVERY chain, so a component that
// resolves an address from any deployment gets the right symbol and: crucially
//  the right decimals. The previous hardcoded table claimed USDC and USDT were
// 18-decimal, which is wrong on all three chains now.

export const TOKEN_META = TOKEN_DISPLAY;

// ─── PoolKey ──────────────────────────────────────────────────────────────────

export interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

/// Build the canonical v4 PoolKey for a pair, plus the swap direction.
/// `zeroForOne` is true when the input token is currency0 (the lower address).
export function buildPoolKey(tokenIn: Address, tokenOut: Address): { key: PoolKey; zeroForOne: boolean } {
  const inLower = tokenIn.toLowerCase();
  const outLower = tokenOut.toLowerCase();
  const zeroForOne = inLower < outLower;
  const [currency0, currency1] = zeroForOne ? [tokenIn, tokenOut] : [tokenOut, tokenIn];
  return {
    key: { currency0, currency1, fee: POOL_KEY_LP_FEE, tickSpacing: POOL_TICK_SPACING, hooks: HOOK_ADDRESS },
    zeroForOne,
  };
}

// ─── ABIs ─────────────────────────────────────────────────────────────────────

// OrbitalHook (the "pool" engine). Note v4 naming: N(), assetAt(), 5-field slot0.
export const POOL_ABI = [
  { type: "function", name: "N",        inputs: [], outputs: [{ type: "uint8"   }], stateMutability: "view" },
  { type: "function", name: "fee",      inputs: [], outputs: [{ type: "uint24"  }], stateMutability: "view" },
  { type: "function", name: "numTicks", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
  {
    type: "function", name: "slot0", inputs: [],
    outputs: [
      { name: "sumX",   type: "uint256" },
      { name: "sumXSq", type: "uint256" },
      { name: "rInt",   type: "uint256" },
      { name: "kBound", type: "uint256" },
      { name: "sBound", type: "uint256" },
    ],
    stateMutability: "view",
  },
  { type: "function", name: "assetAt",  inputs: [{ name: "", type: "uint8"   }], outputs: [{ type: "address" }], stateMutability: "view" },
  { type: "function", name: "reserves", inputs: [{ name: "", type: "uint8"   }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  {
    type: "function", name: "ticks", inputs: [{ name: "", type: "uint256" }],
    outputs: [
      { name: "k",               type: "uint256" },
      { name: "r",               type: "uint256" },
      { name: "isInterior",      type: "bool"    },
      { name: "feeGrowthInside", type: "uint256" },
      { name: "liquidityGross",  type: "uint128" },
    ],
    stateMutability: "view",
  },
  { type: "function", name: "feeGrowthGlobal", inputs: [{ name: "", type: "uint8" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
] as const;

export const ERC20_ABI = [
  { type: "function", name: "balanceOf", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "allowance", inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "approve",   inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ type: "bool" }], stateMutability: "nonpayable" },
  { type: "function", name: "decimals",  inputs: [], outputs: [{ type: "uint8" }], stateMutability: "view" },
  { type: "function", name: "symbol",    inputs: [], outputs: [{ type: "string" }], stateMutability: "view" },
] as const;

export const MOCK_ERC20_ABI = [
  ...ERC20_ABI,
  { type: "function", name: "mint", inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
] as const;

const POOL_KEY_COMPONENTS = [
  { name: "currency0",   type: "address" },
  { name: "currency1",   type: "address" },
  { name: "fee",         type: "uint24"  },
  { name: "tickSpacing", type: "int24"   },
  { name: "hooks",       type: "address" },
] as const;

// V4Quoter: quoteExactInputSingle is `nonpayable` on-chain but read-only via
// eth_call (it reverts internally and returns the decoded result). We type it
// `view` so the frontend can read it with `useReadContract` (a plain eth_call,
// no connected wallet required) instead of `useSimulateContract`.
export const QUOTER_ABI = [
  {
    type: "function", name: "quoteExactInputSingle",
    inputs: [{
      name: "params", type: "tuple",
      components: [
        { name: "poolKey",     type: "tuple", components: POOL_KEY_COMPONENTS },
        { name: "zeroForOne",  type: "bool"    },
        { name: "exactAmount", type: "uint128" },
        { name: "hookData",    type: "bytes"   },
      ],
    }],
    outputs: [
      { name: "amountOut",   type: "uint256" },
      { name: "gasEstimate", type: "uint256" },
    ],
    stateMutability: "view",
  },
] as const;

// OrbitalHook LP surface: ERC-6909 share balance + direct LP entry points.
// Positions live as soulbound ERC-6909 shares (tokenId = tickIdx) on the hook.
export const HOOK_LP_ABI = [
  { type: "function", name: "balanceOf", inputs: [{ name: "owner", type: "address" }, { name: "id", type: "uint256" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  {
    type: "function", name: "addLiquidity",
    inputs: [
      { name: "kWad", type: "uint256" },
      { name: "rWad", type: "uint256" },
      { name: "maxAmounts", type: "uint256[]" },
    ],
    outputs: [{ name: "tickIdx", type: "uint256" }, { name: "amounts", type: "uint256[]" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function", name: "removeLiquidity",
    inputs: [
      { name: "tickIdx", type: "uint256" },
      { name: "rWad", type: "uint256" },
      { name: "minAmounts", type: "uint256[]" },
    ],
    outputs: [{ name: "amounts", type: "uint256[]" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function", name: "collect",
    inputs: [{ name: "tickIdx", type: "uint256" }],
    outputs: [{ name: "fees", type: "uint256[]" }],
    stateMutability: "nonpayable",
  },
  {
    type: "event", name: "Mint",
    inputs: [
      { name: "recipient", type: "address", indexed: true },
      { name: "tickIdx",   type: "uint256", indexed: true },
      { name: "kWad",      type: "uint256", indexed: false },
      { name: "rWad",      type: "uint256", indexed: false },
      { name: "amounts",   type: "uint256[]", indexed: false },
    ],
  },
] as const;

// v4 single-pool swap router (hookmate IUniswapV4Router04).
export const ROUTER_ABI = [
  {
    type: "function", name: "swapExactTokensForTokens",
    inputs: [
      { name: "amountIn",     type: "uint256" },
      { name: "amountOutMin", type: "uint256" },
      { name: "zeroForOne",   type: "bool"    },
      { name: "poolKey",      type: "tuple", components: POOL_KEY_COMPONENTS },
      { name: "hookData",     type: "bytes"   },
      { name: "receiver",     type: "address" },
      { name: "deadline",     type: "uint256" },
    ],
    outputs: [{ name: "delta", type: "int256" }],
    stateMutability: "payable",
  },
] as const;
