import { type Address } from "viem";

// ─── Deployed addresses (Unichain Sepolia, chainId 1301) ──────────────────────
// PoolManager and V4Quoter are canonical Uniswap v4 deployments on Unichain
// (https://developers.uniswap.org/contracts/v4/deployments). Permit2 is the
// canonical singleton, same on every chain. The OrbitalHook, the SwapRouter
// (deployed via orbitalHook/script/DeployPeriphery.s.sol since Unichain has
// no canonical v4 SwapRouter), and the four mock-stablecoin addresses are
// filled in after the Deploy.s.sol + DeployPeriphery.s.sol runs.

export const HOOK_ADDRESS    = "0x08E32551Cf10f042721E1387e7Be8538beC02A88" as Address; // OrbitalHook (USDC/USDT/DAI/FRAX)
export const POOL_MANAGER    = "0x00B036B58a818B1BC34d502D3fE730Db729e62AC" as Address; // canonical
export const SWAP_ROUTER     = "0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540" as Address; // our v4Router04 -> canonical PoolManager
export const QUOTER_ADDRESS  = "0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472" as Address; // canonical V4Quoter
export const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3" as Address;

// The OrbitalHook is both the "pool" (engine state + LP surface) and the swap
// target. LP positions are soulbound ERC-6909 shares on the hook (tokenId =
// tickIdx) — the Positions/LP pages read & write the hook directly via
// HOOK_LP_ABI; there is no separate PositionManager.
export const POOL_ADDRESS    = HOOK_ADDRESS;
export const POOL_ADDRESSES  = [HOOK_ADDRESS] as const;
export const ROUTER_ADDRESS  = SWAP_ROUTER;

// Registered assets, named by symbol. The hook internally stores them
// sorted-ascending by address; the frontend looks them up via TOKEN_META.
export const TOKEN_ADDRESSES = {
  USDC: "0x26301b1f7Ec55Cea35111b79E1Df986c314B4a93" as Address,
  USDT: "0x37FC8Eade109847a5CA65cf25A7Cf8a1d003fEEd" as Address,
  DAI:  "0x35ff498cE5FC23Ba5536044F8358C194386c9832" as Address,
  FRAX: "0x76b1B6078f392Ef3101f7b01E7B593aB1BeA9d6b" as Address,
} as const;

// Pool fee in hundredths of a bip (matches the hook's immutable `fee`).
export const POOL_FEE: number = 100;
export const POOL_TICK_SPACING: number = 1;
export const POOL_KEY_LP_FEE: number = 0;

// Block the OrbitalHook was deployed at on Unichain Sepolia — event scanners
// start here instead of genesis.
export const DEPLOY_BLOCK = 55529382n;

// ─── Token metadata (static) ──────────────────────────────────────────────────
// Keys are lowercased token addresses; values are display metadata.

export const TOKEN_META: Record<string, { symbol: string; name: string; color: string; decimals: number }> = {
  "0x26301b1f7ec55cea35111b79e1df986c314b4a93": { symbol: "USDC", name: "USD Coin",       color: "#2775CA", decimals: 18 },
  "0x37fc8eade109847a5ca65cf25a7cf8a1d003feed": { symbol: "USDT", name: "Tether USD",     color: "#26A17B", decimals: 18 },
  "0x35ff498ce5fc23ba5536044f8358c194386c9832": { symbol: "DAI",  name: "Dai Stablecoin",  color: "#F5AC37", decimals: 18 },
  "0x76b1b6078f392ef3101f7b01e7b593ab1bea9d6b": { symbol: "FRAX", name: "Frax",            color: "#BFBFBF", decimals: 18 },
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

// V4Quoter — quoteExactInputSingle is `nonpayable` on-chain but read-only via
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
