import { type Address, type Hex, BaseError, ContractFunctionRevertedError, decodeErrorResult } from "viem";

// ─── Orbital FX pool ─────────────────────────────────────────────────────────
// One OrbitalFXHook on Arc: a single book for USDC, USDT, EURC and EURe, with
// the EUR stables priced against USD by an AggregatorV3 (Chainlink-interface)
// EUR / USD feed. Deployed by `orbitalHook/script/DeployArcFX.s.sol` onto the
// same v4 core as the Arc stable pool, so router and quoter are shared.
//
// Unlike the stable pools this is a SECOND pool on one chain, which the
// one-deployment-per-chain `DEPLOYMENTS` registry cannot express, so it lives
// in its own registry rather than being forced into that shape.

export interface FxAsset {
  symbol: string;
  name: string;
  address: Address;
  decimals: number;
  /// Index in the hook's own (address-sorted) asset array.
  index: number;
  /// AggregatorV3 feed quoting this asset in USD; null for a USD numeraire.
  feed: Address | null;
}

export interface FxPool {
  chainId: number;
  hook: Address;
  router: Address;
  quoter: Address;
  explorer: string;
  deployBlock: bigint;
  /// Where the feed's rates come from, shown beside them.
  rateSource: { label: string; href: string };
  assets: FxAsset[];
}

/// EUR / USD on Arc testnet: a TestnetFxFeed mirroring Chainlink EUR / USD on
/// Ethereum mainnet, since Chainlink has no Arc testnet feeds.
const ARC_TESTNET_EUR_USD: Address = "0x8a4a34d41f3234215D20bb7472C9Cf2d71D3BD24";

/// From the DeployArcFX report; keep in step with `orbitalHook/deployments.json`
/// (`5042002.fx`). `null` would mean not deployed: no FX pool is listed or read.
///
/// USDC and USDT are the SAME contracts as the Arc stable pool's, so one USDC
/// trades in both pools; only EURC and EURe are unique to this pool.
export const FX_POOL: FxPool | null = {
  chainId: 5042002,
  hook: "0xb7343fC8aA0Aaa583E3929B8De70D8e5751d2A88",
  router: "0xC30819b8ac12B5d12751b83cFfebD6F0bFa0b53E",
  quoter: "0x17684C1C522E7cCD9a38E1Ab5994BB294Bf1ef90",
  explorer: "https://testnet.arcscan.app",
  deployBlock: 61855148n,
  rateSource: {
    label: "Chainlink EUR / USD (Ethereum mainnet, mirrored to Arc testnet)",
    href: "https://data.chain.link/feeds/ethereum/mainnet/eur-usd",
  },
  assets: [
    { symbol: "EURe", name: "Monerium EUR", address: "0x09972c389552E02747336b87c557127fA0f6A385", decimals: 6, index: 0, feed: ARC_TESTNET_EUR_USD },
    { symbol: "USDC", name: "USD Coin", address: "0x18033E198A2b0af2AfA75aFcc520f42179955a68", decimals: 6, index: 1, feed: null },
    { symbol: "EURC", name: "Euro Coin", address: "0x2d59F25e42B396B25a9d4F474Ec1E230CEe02D82", decimals: 6, index: 2, feed: ARC_TESTNET_EUR_USD },
    { symbol: "USDT", name: "Tether USD", address: "0x7d1c2f283811A0aa7D538e3C859DA8BB45330e35", decimals: 6, index: 3, feed: null },
  ],
};

/// Assets in the hook's index order, which is the order its events and views use.
export function fxAssetsByIndex(pool: FxPool): FxAsset[] {
  return [...pool.assets].sort((a, b) => a.index - b.index);
}

// ─── ABIs ────────────────────────────────────────────────────────────────────

export const FX_HOOK_ABI = [
  { type: "function", name: "scaleOf", stateMutability: "view", inputs: [{ type: "uint8" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "oracleScaleOf", stateMutability: "view", inputs: [{ type: "uint8" }], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "priceDeviation",
    stateMutability: "view",
    inputs: [{ type: "uint8" }, { type: "uint8" }],
    outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "maxPriceAge", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maxDeviationBps", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;

/// Chainlink's AggregatorV3Interface, the surface the hook itself reads.
export const AGGREGATOR_V3_ABI = [
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
] as const;

// ─── Revert explanation ──────────────────────────────────────────────────────
// A swap or quote that the hook rejects reaches the client wrapped in up to two
// layers: the PoolManager wraps every hook revert as `WrappedError`, and the
// V4Quoter wraps anything that is not a quote as `UnexpectedRevertBytes`. The
// useful part is the innermost error, so unwrap until it is reached.

const FX_ERRORS_ABI = [
  // Wrappers
  { type: "error", name: "UnexpectedRevertBytes", inputs: [{ name: "revertData", type: "bytes" }] },
  {
    type: "error",
    name: "WrappedError",
    inputs: [
      { name: "target", type: "address" },
      { name: "selector", type: "bytes4" },
      { name: "reason", type: "bytes" },
      { name: "details", type: "bytes" },
    ],
  },
  // OrbitalFXHook
  {
    type: "error",
    name: "FxPriceBeyondBand",
    inputs: [{ type: "uint8" }, { type: "uint8" }, { name: "deviationWad", type: "uint256" }],
  },
  { type: "error", name: "StalePrice", inputs: [{ type: "uint8" }, { name: "updatedAt", type: "uint256" }] },
  { type: "error", name: "InvalidOraclePrice", inputs: [{ type: "uint8" }, { name: "answer", type: "int256" }] },
  // OrbitalHook engine
  { type: "error", name: "NotEnoughLiquidity", inputs: [] },
  { type: "error", name: "SwapAmountTooSmall", inputs: [{ type: "uint256" }] },
  { type: "error", name: "SwapAmountTooLarge", inputs: [{ type: "uint256" }] },
  { type: "error", name: "TooManyCrossings", inputs: [] },
  { type: "error", name: "SwapExceedsLiquidity", inputs: [] },
  { type: "error", name: "InsufficientRealReserves", inputs: [{ type: "uint8" }] },
  { type: "error", name: "EnforcedPause", inputs: [] },
  // Liquidity
  { type: "error", name: "TickOutsideItsBand", inputs: [] },
  { type: "error", name: "MintBlockedByBoundaryTicks", inputs: [] },
  { type: "error", name: "BurnBlockedByBoundaryTicks", inputs: [] },
  { type: "error", name: "SlippageExceeded", inputs: [{ type: "uint8" }, { type: "uint256" }, { type: "uint256" }] },
] as const;

const MESSAGES: Record<string, string> = {
  FxPriceBeyondBand: "This trade would push the pool more than the band past the market rate. Try a smaller amount.",
  StalePrice: "The oracle rate is out of date, so FX swaps are paused until the feed updates.",
  InvalidOraclePrice: "The oracle returned an invalid rate, so FX swaps are paused.",
  NotEnoughLiquidity: "The pool has no active liquidity.",
  SwapAmountTooSmall: "Amount too small to trade.",
  SwapAmountTooLarge: "Amount too large for a single trade.",
  TooManyCrossings: "This trade crosses too many liquidity bands at once. Split it into smaller trades.",
  SwapExceedsLiquidity: "This trade is larger than the pool can fill in this direction. Try a smaller amount.",
  InsufficientRealReserves: "The pool doesn't hold enough of that token to fill this. Try a smaller amount.",
  TickOutsideItsBand: "The pool's price is already outside this band. Choose a wider band.",
  MintBlockedByBoundaryTicks: "Liquidity can't be added while a band is at its limit. Try again once the pool moves back.",
  BurnBlockedByBoundaryTicks: "Liquidity can't be removed while a band is at its limit. Try again once the pool moves back.",
  SlippageExceeded: "The pool moved since the quote. Try again.",
  EnforcedPause: "Swaps are paused by the pool admin.",
};

/// The innermost named error in `data`, following the known wrappers.
function innermostError(data: Hex): string | undefined {
  for (let depth = 0; depth < 4; depth++) {
    let decoded;
    try {
      decoded = decodeErrorResult({ abi: FX_ERRORS_ABI, data });
    } catch {
      return undefined;
    }
    if (decoded.errorName === "UnexpectedRevertBytes") data = decoded.args[0] as Hex;
    else if (decoded.errorName === "WrappedError") data = decoded.args[2] as Hex;
    else return decoded.errorName;
  }
  return undefined;
}

/// Human explanation for a failed quote, swap or liquidity action on any
/// Orbital pool, or undefined if the error is not one we recognise (callers
/// fall back to the raw message).
export function explainPoolError(error: unknown): string | undefined {
  if (!(error instanceof BaseError)) return undefined;
  const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
  if (!(reverted instanceof ContractFunctionRevertedError) || !reverted.raw) return undefined;
  const name = innermostError(reverted.raw);
  return name ? MESSAGES[name] : undefined;
}

// ─── Formatting ──────────────────────────────────────────────────────────────

/// Feed answer as a plain number.
export function feedToNumber(answer: bigint, decimals: number): number {
  return Number(answer) / 10 ** decimals;
}

/// Deviation (WAD, 1e18 = at market) as signed basis points.
export function deviationBps(deviationWad: bigint): number {
  return (Number(deviationWad) / 1e18 - 1) * 10_000;
}
