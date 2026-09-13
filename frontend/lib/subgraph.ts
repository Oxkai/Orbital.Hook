"use client";

/**
 * Subgraph data source.
 *
 * The transactions feed used to be built by scanning `eth_getLogs` backwards in
 * 10,000-block windows, per chain, four event types at a time, then fetching a
 * block per record just to get a timestamp. That is slow, hammers public RPCs,
 * and hits their log-range caps: Unichain rejects anything over 10,000 blocks
 * and Base over 10,000, so the window size was already pinned to the limit.
 *
 * The subgraph answers the same question in one round trip per chain, with
 * timestamps already attached, and adds fields the logs simply do not carry:
 * realised slippage per swap and each tick's distance to its depeg bound.
 *
 * RPC scanning is kept as a per-chain fallback. Arbitrum currently has no
 * deployed subgraph, so it exercises that path for real rather than in theory.
 */

import { CHAIN_IDS, DEPLOYMENTS } from "@/lib/crosschain";

/** Studio query endpoints, with the hook each one indexes.
 *
 *  A subgraph is pinned to one hook address. After a redeploy the old subgraph
 *  keeps answering, for the RETIRED hook, so an endpoint is used only while its
 *  `hook` matches the chain's live hook; otherwise the chain falls back to RPC
 *  until the subgraph is redeployed and this entry updated. */
const ENDPOINTS: Record<number, { url?: string; hook: string } | undefined> = {
  1301: {
    url:
      process.env.NEXT_PUBLIC_SUBGRAPH_UNICHAIN ??
      "https://api.studio.thegraph.com/query/107768/orbital-unichain/v0.2.0",
    hook: "0xB9cD5ccF597e49F87C9c73eFABb5410195fE6A88",
  },
  5042002: {
    url: process.env.NEXT_PUBLIC_SUBGRAPH_ARC ?? "https://api.studio.thegraph.com/query/107768/orbital-arc/v0.2.0",
    hook: "0x1D922FB97c92b00706A449ba78EEFc0D3E01aa88",
  },
  421614: {
    url:
      process.env.NEXT_PUBLIC_SUBGRAPH_ARBITRUM ??
      "https://api.studio.thegraph.com/query/107768/orbital-arbitrum/v0.2.0",
    hook: "0x8e7BEf4320f73a39100C42325Fc426CBD1842a88",
  },
};

/** The chain's subgraph URL, if it indexes the chain's live hook. */
export function subgraphFor(chainId: number): string | undefined {
  const e = ENDPOINTS[chainId];
  const live = DEPLOYMENTS[chainId]?.orbitalHook;
  if (!e?.url || !live || e.hook.toLowerCase() !== live.toLowerCase()) return undefined;
  return e.url;
}

export function hasSubgraph(chainId: number): boolean {
  return subgraphFor(chainId) !== undefined;
}

export const SUBGRAPH_CHAINS = CHAIN_IDS.filter(hasSubgraph);

/** Whether the chain's subgraph indexes `pool`. Each subgraph tracks that
 *  chain's stable OrbitalHook only; any other pool (an FX pool) is not in it. */
export function subgraphIndexes(chainId: number, pool: string): boolean {
  return hasSubgraph(chainId) && DEPLOYMENTS[chainId]?.orbitalHook.toLowerCase() === pool.toLowerCase();
}

export class SubgraphError extends Error {}

async function gql<T>(chainId: number, query: string, variables: Record<string, unknown> = {}): Promise<T> {
  const url = subgraphFor(chainId);
  if (!url) throw new SubgraphError(`No subgraph for chain ${chainId}`);

  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) throw new SubgraphError(`HTTP ${res.status} from chain ${chainId} subgraph`);

  const body = (await res.json()) as { data?: T; errors?: { message: string }[] };
  if (body.errors?.length) throw new SubgraphError(body.errors.map((e) => e.message).join("; "));
  if (!body.data) throw new SubgraphError("empty response");
  return body.data;
}

// ─────────────────────────── freshness ───────────────────────────

/** A subgraph further behind its chain than this is treated as unavailable,
 *  so callers fall back to RPC rather than serve stale or partial data: a
 *  freshly deployed subgraph is still indexing up from its start block, and
 *  Studio can fall behind at any time. */
const MAX_LAG_S = 300;
/** How long one freshness check is trusted before it is repeated. */
const FRESHNESS_TTL_MS = 30_000;

const META = /* GraphQL */ `
  query Meta {
    _meta {
      hasIndexingErrors
      block { timestamp }
    }
  }
`;

const freshness = new Map<number, { checkedAt: number; result: Promise<void> }>();

/** Throws unless `chainId`'s subgraph has indexed to within MAX_LAG_S of now,
 *  without errors. One check per chain per FRESHNESS_TTL_MS, shared by every
 *  query in that window, so the guard costs one small request, not one per
 *  query. */
function assertFresh(chainId: number): Promise<void> {
  const cached = freshness.get(chainId);
  if (cached && Date.now() - cached.checkedAt < FRESHNESS_TTL_MS) return cached.result;
  const result = gql<{ _meta: { hasIndexingErrors: boolean; block: { timestamp: number | null } } }>(chainId, META).then(
    ({ _meta }) => {
      if (_meta.hasIndexingErrors) throw new SubgraphError(`chain ${chainId} subgraph has indexing errors`);
      const ts = _meta.block.timestamp;
      const lag = ts === null ? Infinity : Math.floor(Date.now() / 1000) - ts;
      if (lag > MAX_LAG_S) {
        throw new SubgraphError(
          `chain ${chainId} subgraph is ${Number.isFinite(lag) ? `${Math.round(lag / 60)} min` : "far"} behind`
        );
      }
    }
  );
  freshness.set(chainId, { checkedAt: Date.now(), result });
  return result;
}

// ─────────────────────────── activity feed ───────────────────────────

const ACTIVITY = /* GraphQL */ `
  query Activity($first: Int!, $skip: Int!) {
    swaps(orderBy: timestamp, orderDirection: desc, first: $first, skip: $skip) {
      id
      sender
      amountIn
      amountOut
      amountInWad
      slippageBps
      blockNumber
      timestamp
      txHash
      assetIn { symbol decimals }
      assetOut { symbol decimals }
    }
    liquidityEvents(orderBy: timestamp, orderDirection: desc, first: $first, skip: $skip) {
      id
      action
      account
      rWad
      amounts
      blockNumber
      timestamp
      txHash
      tick { tickIdx }
    }
  }
`;

interface RawSwap {
  id: string;
  sender: string;
  amountIn: string;
  amountOut: string;
  /** The input in the pool's value units (WAD, USD). */
  amountInWad: string;
  slippageBps: number;
  blockNumber: string;
  timestamp: string;
  txHash: `0x${string}`;
  assetIn: { symbol: string; decimals: number };
  assetOut: { symbol: string; decimals: number };
}

interface RawLiquidity {
  id: string;
  action: "MINT" | "BURN" | "COLLECT";
  account: string;
  rWad: string;
  /** Per-asset amounts as the hook emitted them: WAD, in value units. */
  amounts: string[];
  blockNumber: string;
  timestamp: string;
  txHash: `0x${string}`;
  tick: { tickIdx: string };
}

export type SubgraphTxType = "Swap" | "Add" | "Remove" | "Collect";

/** A token amount as it moved, in the token's own units. */
export interface TokenAmount {
  symbol: string;
  amount: number;
}

export interface SubgraphTx {
  type: SubgraphTxType;
  /** `txHash-logIndex`, lowercased: the entity id, and the same identity an
   *  RPC-scanned log produces, so rows from either source dedupe together. */
  eventId: string;
  hash: `0x${string}`;
  chainId: number;
  blockNumber: bigint;
  timestamp: number;
  actor: `0x${string}`;
  /** Swaps: what went in and what came out. */
  tokenIn?: TokenAmount;
  tokenOut?: TokenAmount;
  /** Liquidity events: the position's tick. */
  tick?: number;
  /** USD moved: a swap's input, a deposit or withdrawal's real amounts, or
   *  the fees collected, all in the pool's value units. */
  valueUsd: number;
  /** Only present on swaps. Realised slippage against a 1:1 reference. */
  slippageBps?: number;
}

const WAD = 1e18;
const units = (raw: string, decimals: number) => Number(raw) / 10 ** decimals;
/** Value of a liquidity event: the sum of the per-asset WAD amounts it moved.
 *  (Not its radius: a concentrated band's radius is far larger than the
 *  capital behind it, most of it being virtual.) */
const wadSum = (amounts: string[]) => Number(amounts.reduce((s, a) => s + BigInt(a), 0n)) / WAD;

const ACTION_LABEL: Record<RawLiquidity["action"], SubgraphTxType> = {
  MINT: "Add",
  BURN: "Remove",
  COLLECT: "Collect",
};

/** One page of activity for one chain. */
export async function fetchActivity(chainId: number, first: number, skip: number): Promise<SubgraphTx[]> {
  await assertFresh(chainId);
  const data = await gql<{ swaps: RawSwap[]; liquidityEvents: RawLiquidity[] }>(
    chainId,
    ACTIVITY,
    { first, skip }
  );

  const out: SubgraphTx[] = [];

  for (const s of data.swaps) {
    out.push({
      type: "Swap",
      eventId: s.id.toLowerCase(),
      hash: s.txHash,
      chainId,
      blockNumber: BigInt(s.blockNumber),
      timestamp: Number(s.timestamp),
      actor: s.sender as `0x${string}`,
      tokenIn: { symbol: s.assetIn.symbol, amount: units(s.amountIn, s.assetIn.decimals) },
      tokenOut: { symbol: s.assetOut.symbol, amount: units(s.amountOut, s.assetOut.decimals) },
      valueUsd: Number(s.amountInWad) / WAD,
      slippageBps: s.slippageBps,
    });
  }

  for (const l of data.liquidityEvents) {
    const type = ACTION_LABEL[l.action];
    out.push({
      type,
      eventId: l.id.toLowerCase(),
      hash: l.txHash,
      chainId,
      blockNumber: BigInt(l.blockNumber),
      timestamp: Number(l.timestamp),
      actor: l.account as `0x${string}`,
      tick: Number(l.tick.tickIdx),
      // For a collect, `amounts` are the fees paid.
      valueUsd: wadSum(l.amounts),
    });
  }

  return out;
}

/**
 * Activity across every chain that has a subgraph.
 *
 * Ordered by TIMESTAMP, never block number: heights are per-chain and not
 * comparable, so sorting merged rows by block would interleave a 306M-block
 * Arbitrum row against a 60M-block Arc row as though one preceded the other.
 *
 * A failing chain yields nothing rather than rejecting the batch, and is
 * reported separately so the caller can fall back for just that chain.
 */
export async function fetchActivityAll(
  chainIds: readonly number[],
  first: number,
  skip: number
): Promise<{ rows: SubgraphTx[]; failed: number[] }> {
  const results = await Promise.all(
    chainIds.map(async (chainId) => {
      try {
        return { chainId, rows: await fetchActivity(chainId, first, skip) };
      } catch {
        return { chainId, rows: [] as SubgraphTx[], failed: true };
      }
    })
  );

  return {
    rows: results.flatMap((r) => r.rows).sort((a, b) => b.timestamp - a.timestamp),
    failed: results.filter((r) => "failed" in r && r.failed).map((r) => r.chainId),
  };
}

// ─────────────────────────── pool + tick health ───────────────────────────

const POOL_STATE = /* GraphQL */ `
  query PoolState {
    pools(first: 1) {
      id
      network
      chainId
      sumX
      rInt
      alphaNorm
      alphaParity
      frozen
      tickCount
      interiorTickCount
      swapCount
      crossCount
      volumeWad
      feesWad
      assets(orderBy: index) { index symbol decimals reserveWad }
    }
    ticks(where: { isInterior: true }, orderBy: boundaryProgressBps, orderDirection: desc) {
      tickIdx
      k
      r
      kNorm
      distanceToBoundaryWad
      boundaryProgressBps
      shareOfRIntBps
      crossCount
    }
  }
`;

export interface PoolState {
  chainId: number;
  network: string;
  sumX: string;
  rInt: string;
  frozen: boolean;
  tickCount: number;
  interiorTickCount: number;
  swapCount: string;
  crossCount: string;
  volumeWad: string;
  feesWad: string;
  assets: { index: number; symbol: string; decimals: number; reserveWad: string }[];
  ticks: {
    tickIdx: string;
    k: string;
    r: string;
    kNorm: string | null;
    distanceToBoundaryWad: string | null;
    boundaryProgressBps: number;
    shareOfRIntBps: number;
    crossCount: string;
  }[];
}

/** Live pool + tick health for one chain, straight from the index. */
export async function fetchPoolState(chainId: number): Promise<PoolState | null> {
  await assertFresh(chainId);
  const data = await gql<{ pools: PoolState[]; ticks: PoolState["ticks"] }>(chainId, POOL_STATE);
  const pool = data.pools[0];
  if (!pool) return null;
  return { ...pool, chainId, ticks: data.ticks };
}

/** Deployment label for a chain, for UI that mixes sources. */
export function chainLabel(chainId: number): string {
  return DEPLOYMENTS[chainId]?.short ?? String(chainId);
}

// ─────────────────────────── volume ───────────────────────────

const SWAPS_SINCE = /* GraphQL */ `
  query SwapsSince($pool: String!, $since: BigInt!, $after: String!) {
    swaps(
      first: 1000
      orderBy: id
      orderDirection: asc
      where: { pool: $pool, timestamp_gt: $since, id_gt: $after }
    ) {
      id
      amountInWad
    }
  }
`;

/** Sum of `amountInWad` over `pool`'s swaps after `since` (unix seconds): its
 *  volume in WAD value, i.e. USD for a stable pool. Pages by id, so it is exact
 *  however many swaps there are; `maxPages` bounds a runaway. */
export async function fetchSwapVolumeWadSince(
  chainId: number,
  pool: string,
  since: number,
  maxPages = 20,
): Promise<bigint> {
  await assertFresh(chainId);
  let total = 0n;
  let after = "";
  for (let page = 0; page < maxPages; page++) {
    const data = await gql<{ swaps: { id: string; amountInWad: string }[] }>(chainId, SWAPS_SINCE, {
      pool: pool.toLowerCase(),
      since: String(since),
      after,
    });
    for (const s of data.swaps) total += BigInt(s.amountInWad);
    if (data.swaps.length < 1000) return total;
    after = data.swaps[data.swaps.length - 1].id;
  }
  throw new SubgraphError(`more than ${maxPages * 1000} swaps in the window`);
}
