import { type Address } from "viem";

// ─── Deployed addresses (Unichain Sepolia, chainId 1301) ──────────────────────
// PoolManager and V4Quoter are canonical Uniswap v4 deployments on Unichain
// (https://developers.uniswap.org/contracts/v4/deployments). Permit2 is the
// canonical singleton, same on every chain. The OrbitalHook, the SwapRouter
// (deployed via orbitalHook/script/DeployPeriphery.s.sol since Unichain has
// no canonical v4 SwapRouter), and the four mock-stablecoin addresses are
// filled in after the Deploy.s.sol + DeployPeriphery.s.sol runs.

export const HOOK_ADDRESS    = "0x405E3C4541077C501854082cf3256926BeF6AA88" as Address; // OrbitalHook (USDC/USDT/DAI/FRAX)
export const POOL_MANAGER    = "0x00B036B58a818B1BC34d502D3fE730Db729e62AC" as Address; // canonical
export const SWAP_ROUTER     = "0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540" as Address; // our v4Router04 -> canonical PoolManager
export const QUOTER_ADDRESS  = "0x56DcD40A3F2D466F48E7F48BdBe5cc9b92aE4472" as Address; // canonical V4Quoter
export const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as Address;

// Back-compat aliases for components written against the standalone AMM.
// The hook is both the "pool" (engine state) and the swap target.
export const POOL_ADDRESS    = HOOK_ADDRESS;
export const POOL_ADDRESSES  = [HOOK_ADDRESS] as const;
export const ROUTER_ADDRESS  = SWAP_ROUTER;
export const PM_ADDRESS       = POOL_MANAGER;

// Registered assets, named by symbol. The hook internally stores them
// sorted-ascending by address; the frontend looks them up via TOKEN_META.
export const TOKEN_ADDRESSES = {
  USDC: "0x3f53c9ae1ae5D34D8A89986ea456da8e69916725" as Address,
  USDT: "0x17684C1C522E7cCD9a38E1Ab5994BB294Bf1ef90" as Address,
  DAI:  "0x345581C18e6b15D02b303A4E7Cc2F0671591acbE" as Address,
  FRAX: "0x1D49545CccDA551d5f5b2Ec95Fc53C34432016cF" as Address,
} as const;

// Pool fee in hundredths of a bip (matches the hook's immutable `fee`).
export const POOL_FEE: number = 100;
export const POOL_TICK_SPACING: number = 1;
export const POOL_KEY_LP_FEE: number = 0;

// Block the OrbitalHook was deployed at on Unichain Sepolia — event scanners
// start here instead of genesis.
export const DEPLOY_BLOCK = 53729846n;

// ─── Token metadata (static) ──────────────────────────────────────────────────
// Keys are lowercased token addresses; values are display metadata.

export const TOKEN_META: Record<string, { symbol: string; name: string; color: string; decimals: number }> = {
  "0x3f53c9ae1ae5d34d8a89986ea456da8e69916725": { symbol: "USDC", name: "USD Coin",       color: "#2775CA", decimals: 18 },
  "0x17684c1c522e7ccd9a38e1ab5994bb294bf1ef90": { symbol: "USDT", name: "Tether USD",     color: "#26A17B", decimals: 18 },
  "0x345581c18e6b15d02b303a4e7cc2f0671591acbe": { symbol: "DAI",  name: "Dai Stablecoin",  color: "#F5AC37", decimals: 18 },
  "0x1d49545cccda551d5f5b2ec95fc53c34432016cf": { symbol: "FRAX", name: "Frax",            color: "#BFBFBF", decimals: 18 },
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
