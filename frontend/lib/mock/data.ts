// ─── Shared types ─────────────────────────────────────────────────────────────

export type Token = {
  symbol:  string;
  name:    string;
  address: string;
  color:   string;
  balance: number;  // human-readable (WAD / 1e18)
};

export type Tick = {
  kWad:              bigint;
  r:                 number;   // WAD / 1e18
  isInterior:        boolean;
  feeGrowthInside?:  bigint;
  liquidityGross?:   bigint;
  // display compat (not computed — kept at 0 when from chain)
  depegPrice:        number;
  capitalEfficiency: number;
};

export type Pool = {
  address:             string;
  name:                string;
  tokens:              Token[];
  fee:                 number;
  rInt:                number;
  reserves:            number[];  // WAD / 1e18
  ticks:               Tick[];
  tvl:                 number;
  volume24h:           number;
  fees24h:             number;
  kBound:              number;
  sumX:                bigint;
  depeggedTokenIndices: number[];
};

export type Position = {
  tokenId:           number;
  pool:              Pool;
  tickDepegPrice:    number;
  capitalEfficiency: number;
  r:                 number;
  isInterior:        boolean;
  feesOwed:          number[];
};

export type TxRecord = {
  hash:         string;
  type:         "swap" | "mint" | "burn" | "collect";
  secondsAgo:   number;
  tokenInIdx?:  number;
  tokenOutIdx?: number;
  amountIn?:    number;
  amountOut?:   number;
  priceImpact?: number;
  address:      string;
};

// ─── Utility formatters ───────────────────────────────────────────────────────

export function fmtAmount(n: number, dp = 4): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(2) + "M";
  if (n >= 1_000)     return (n / 1_000).toFixed(1) + "K";
  return n.toFixed(dp);
}

export function fmtUSD(n: number, precise = false): string {
  if (n >= 1_000_000) return "$" + (n / 1_000_000).toFixed(precise ? 4 : 2) + "M";
  if (n >= 1_000)     return "$" + (n / 1_000).toFixed(precise ? 3 : 1) + "K";
  return "$" + n.toFixed(2);
}

export function timeAgo(s: number): string {
  if (s < 60)   return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  return `${Math.floor(s / 3600)}h ago`;
}
