import { type Address } from "viem";

// ─── Deployed addresses (X Layer Testnet, chainId 1952) ───────────────────────
// Self-hosted v4 stack — X Layer is not a canonical Uniswap v4 chain.

export const HOOK_ADDRESS    = "0x4024911A26B5BF5160D156eccBAc148bd55c6a88" as Address; // OrbitalHook (USDC/USDT/DAI/FRAX, ~20M TVL)
export const POOL_MANAGER    = "0x9BEACCac4e0358Cc276703dcE7341B9B9fEfd5f7" as Address; // v4 PoolManager
export const SWAP_ROUTER     = "0xC30819b8ac12B5d12751b83cFfebD6F0bFa0b53E" as Address; // v4 swap router
export const QUOTER_ADDRESS  = "0x77442de670D723Db1Ae17fa9cA887c9426eBb41f" as Address; // V4Quoter
export const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as Address;

// Back-compat aliases for components written against the standalone AMM.
// The hook is both the "pool" (engine state) and the swap target.
export const POOL_ADDRESS    = HOOK_ADDRESS;
export const POOL_ADDRESSES  = [HOOK_ADDRESS] as const;
export const ROUTER_ADDRESS  = SWAP_ROUTER;
export const PM_ADDRESS       = POOL_MANAGER;

// Registered assets, in the hook's canonical (sorted-ascending) order.
export const TOKEN_ADDRESSES = {
  USDC: "0xBe272Bcb1Fa1d99616F53Ce7d7703589C92bb33b" as Address,
  USDT: "0x3a2bCfc287b8106774Ec85533d821D3604cB7DC5" as Address,
  DAI:  "0x78340e3C5169b6DF15F13a8d627Db2C0e23cf921" as Address,
  FRAX: "0x17c868495deF240091E95410e2B2D5a6cEabf6f0" as Address,
} as const;

// Pool fee in hundredths of a bip (matches the hook's immutable `fee`).
export const POOL_FEE: number = 100;
export const POOL_TICK_SPACING: number = 1;
export const POOL_KEY_LP_FEE: number = 0;

// Block the OrbitalHook was deployed at on X Layer testnet — event scanners
// start here instead of genesis.
export const DEPLOY_BLOCK = 31509226n;

// ─── Token metadata (static) ──────────────────────────────────────────────────

export const TOKEN_META: Record<string, { symbol: string; name: string; color: string; decimals: number }> = {
  "0xbe272bcb1fa1d99616f53ce7d7703589c92bb33b": { symbol: "USDC", name: "USD Coin",       color: "#2775CA", decimals: 18 },
  "0x3a2bcfc287b8106774ec85533d821d3604cb7dc5": { symbol: "USDT", name: "Tether USD",     color: "#26A17B", decimals: 18 },
  "0x78340e3c5169b6df15f13a8d627db2c0e23cf921": { symbol: "DAI",  name: "Dai Stablecoin",  color: "#F5AC37", decimals: 18 },
  "0x17c868495def240091e95410e2b2d5a6ceabf6f0": { symbol: "FRAX", name: "Frax",            color: "#BFBFBF", decimals: 18 },
};

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

// V4Quoter — quoteExactInputSingle reverts internally to return data; call via eth_call (useSimulateContract).
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
    stateMutability: "nonpayable",
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

// NOTE: PM_ABI is retained only so the LP/positions pages still compile.
// Those pages target the standalone AMM PositionManager and are NOT wired to
// the v4 hook yet (out of scope — swap widget only). They will not function.
export const PM_ABI = [
  {
    type: "function", name: "positions",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [
      { name: "pool",      type: "address" },
      { name: "tickIndex", type: "uint256" },
      { name: "kWad",      type: "uint256" },
      { name: "rWad",      type: "uint256" },
    ],
    stateMutability: "view",
  },
  { type: "function", name: "balanceOf", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "ownerOf",   inputs: [{ name: "tokenId", type: "uint256" }], outputs: [{ type: "address" }], stateMutability: "view" },
  {
    type: "event", name: "Transfer",
    inputs: [
      { name: "from",    type: "address", indexed: true },
      { name: "to",      type: "address", indexed: true },
      { name: "tokenId", type: "uint256", indexed: true },
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
