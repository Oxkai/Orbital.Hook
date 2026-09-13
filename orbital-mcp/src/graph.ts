/**
 * Subgraph access layer.
 *
 * Every network is a SEPARATE subgraph deployment, because The Graph indexes
 * one chain per subgraph. A question like "is any Orbital pool at risk" is
 * therefore a fan-out, not a single query, and the fan-out lives here so the
 * tool layer can stay about reasoning rather than transport.
 */

export interface NetworkConfig {
  key: string;
  label: string;
  chainId: number;
  explorer: string;
  endpoint: string | null;
}

/** Endpoints come from env so the same build works against Studio dev queries,
 *  the decentralised network, or a local graph-node. */
export function loadNetworks(): NetworkConfig[] {
  const defs = [
    { key: "arc", label: "Arc Testnet", chainId: 5042002, explorer: "https://testnet.arcscan.app", env: "ORBITAL_SUBGRAPH_ARC" },
    { key: "unichain", label: "Unichain Sepolia", chainId: 1301, explorer: "https://sepolia.uniscan.xyz", env: "ORBITAL_SUBGRAPH_UNICHAIN" },
    { key: "base", label: "Base Sepolia", chainId: 84532, explorer: "https://sepolia.basescan.org", env: "ORBITAL_SUBGRAPH_BASE" },
    { key: "arbitrum", label: "Arbitrum Sepolia", chainId: 421614, explorer: "https://sepolia.arbiscan.io", env: "ORBITAL_SUBGRAPH_ARBITRUM" },
  ];
  return defs.map((d) => ({
    key: d.key,
    label: d.label,
    chainId: d.chainId,
    explorer: d.explorer,
    endpoint: process.env[d.env] ?? null,
  }));
}

export function configuredNetworks(): NetworkConfig[] {
  return loadNetworks().filter((n) => n.endpoint !== null);
}

export function resolveNetworks(want?: string): NetworkConfig[] {
  const all = configuredNetworks();
  if (!want || want === "all") return all;
  const hit = all.filter((n) => n.key === want.toLowerCase());
  if (hit.length === 0) {
    const names = all.map((n) => n.key).join(", ") || "(none configured)";
    throw new Error(`Unknown or unconfigured network "${want}". Available: ${names}`);
  }
  return hit;
}

export class SubgraphError extends Error {}

/** POST a GraphQL query. Indexing errors are surfaced, not swallowed: data read
 *  from a subgraph that is still syncing is a real correctness trap. */
export async function query<T>(net: NetworkConfig, gql: string, variables: Record<string, unknown> = {}): Promise<T> {
  if (!net.endpoint) throw new SubgraphError(`No endpoint configured for ${net.key}`);

  const res = await fetch(net.endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query: gql, variables }),
  });

  if (!res.ok) {
    throw new SubgraphError(`${net.label}: HTTP ${res.status} ${res.statusText}`);
  }

  const body = (await res.json()) as { data?: T; errors?: { message: string }[] };
  if (body.errors?.length) {
    throw new SubgraphError(`${net.label}: ${body.errors.map((e) => e.message).join("; ")}`);
  }
  if (!body.data) throw new SubgraphError(`${net.label}: empty response`);
  return body.data;
}

/** Run the same query across networks, keeping partial results.
 *
 *  One unreachable endpoint must not blank the whole answer: reporting
 *  "3 of 4 chains healthy, Base unreachable" is more useful, and more honest,
 *  than failing the entire call. */
export async function queryAll<T>(
  nets: NetworkConfig[],
  gql: string,
  variables: Record<string, unknown> = {}
): Promise<{ net: NetworkConfig; data?: T; error?: string }[]> {
  return Promise.all(
    nets.map(async (net) => {
      try {
        return { net, data: await query<T>(net, gql, variables) };
      } catch (e) {
        return { net, error: e instanceof Error ? e.message : String(e) };
      }
    })
  );
}

// ─────────────────────────── units ───────────────────────────

const WAD = 10n ** 18n;

/** WAD bigint -> human number. Precision loss is fine for display; never feed
 *  the result back into arithmetic that needs exactness. */
export function fromWad(v: string | bigint, dp = 2): number {
  const b = typeof v === "string" ? BigInt(v) : v;
  const neg = b < 0n;
  const abs = neg ? -b : b;
  const whole = abs / WAD;
  const frac = abs % WAD;
  const n = Number(whole) + Number(frac) / 1e18;
  const out = Number(n.toFixed(dp));
  return neg ? -out : out;
}

export function usd(v: string | bigint): string {
  const n = fromWad(v, 2);
  if (Math.abs(n) >= 1e6) return `$${(n / 1e6).toFixed(2)}M`;
  if (Math.abs(n) >= 1e3) return `$${(n / 1e3).toFixed(1)}k`;
  return `$${n.toFixed(2)}`;
}

export function pct(bps: number): string {
  return `${(bps / 100).toFixed(2)}%`;
}

// ─────────────────────────── queries ───────────────────────────

export const POOL_HEALTH = /* GraphQL */ `
  query PoolHealth {
    pools(first: 10) {
      id
      network
      chainId
      assetCount
      feeBps
      sumX
      alphaNorm
      alphaParity
      rInt
      kBound
      frozen
      tickCount
      interiorTickCount
      swapCount
      crossCount
      volumeWad
      feesWad
      lastUpdatedAt
      assets(orderBy: index) { index symbol decimals reserveWad realReserveWad }
    }
  }
`;

export const TICKS_AT_RISK = /* GraphQL */ `
  query TicksAtRisk($first: Int!) {
    ticks(
      where: { isInterior: true }
      orderBy: distanceToBoundaryWad
      orderDirection: asc
      first: $first
    ) {
      id
      tickIdx
      k
      r
      kNorm
      distanceToBoundaryWad
      boundaryProgressBps
      shareOfRIntBps
      crossCount
      creator
      pool { network rInt sumX alphaNorm alphaParity frozen }
    }
  }
`;

export const RECENT_SWAPS = /* GraphQL */ `
  query RecentSwaps($first: Int!) {
    swaps(orderBy: timestamp, orderDirection: desc, first: $first) {
      id
      amountInWad
      amountOutWad
      slippageBps
      timestamp
      txHash
      frozenAfter
      assetIn { symbol decimals }
      assetOut { symbol decimals }
      pool { network }
    }
  }
`;

export const FREEZE_HISTORY = /* GraphQL */ `
  query FreezeHistory($first: Int!) {
    tickCrosses(orderBy: timestamp, orderDirection: desc, first: $first) {
      id
      nowInterior
      causedFreeze
      rIntAfter
      timestamp
      txHash
      tick { tickIdx k }
      pool { network }
    }
  }
`;

export const SNAPSHOT_TREND = /* GraphQL */ `
  query SnapshotTrend($first: Int!) {
    poolSnapshots(orderBy: blockNumber, orderDirection: desc, first: $first) {
      blockNumber
      timestamp
      sumX
      rInt
      frozen
      interiorTickCount
      minDistanceToBoundaryWad
      maxBoundaryProgressBps
      nearestTick
      pool { network }
    }
  }
`;

// ─────────────────────────── types ───────────────────────────

export interface PoolRow {
  id: string;
  network: string;
  chainId: number;
  assetCount: number;
  feeBps: string;
  sumX: string;
  alphaNorm: string;
  alphaParity: string;
  rInt: string;
  kBound: string;
  frozen: boolean;
  tickCount: number;
  interiorTickCount: number;
  swapCount: string;
  crossCount: string;
  volumeWad: string;
  feesWad: string;
  lastUpdatedAt: string;
  /** `reserveWad` is the engine's reserve, including the virtual floor
   *  concentrated ticks never deposit; `realReserveWad` is the tokens held. */
  assets: { index: number; symbol: string; decimals: number; reserveWad: string; realReserveWad: string }[];
}

export interface TickRow {
  id: string;
  tickIdx: string;
  k: string;
  r: string;
  kNorm: string | null;
  distanceToBoundaryWad: string | null;
  boundaryProgressBps: number;
  shareOfRIntBps: number;
  crossCount: string;
  creator: string;
  pool: { network: string; rInt: string; sumX: string; alphaNorm: string; alphaParity: string; frozen: boolean };
}

export interface SwapRow {
  id: string;
  amountInWad: string;
  amountOutWad: string;
  slippageBps: number;
  timestamp: string;
  txHash: string;
  frozenAfter: boolean;
  assetIn: { symbol: string; decimals: number };
  assetOut: { symbol: string; decimals: number };
  pool: { network: string };
}

export interface CrossRow {
  id: string;
  nowInterior: boolean;
  causedFreeze: boolean;
  rIntAfter: string;
  timestamp: string;
  txHash: string;
  tick: { tickIdx: string; k: string };
  pool: { network: string };
}

export interface SnapshotRow {
  blockNumber: string;
  timestamp: string;
  sumX: string;
  rInt: string;
  frozen: boolean;
  interiorTickCount: number;
  minDistanceToBoundaryWad: string | null;
  maxBoundaryProgressBps: number;
  nearestTick: string | null;
  pool: { network: string };
}
