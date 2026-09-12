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

/** Studio query endpoints, overridable per deployment. */
const ENDPOINTS: Record<number, string | undefined> = {
  1301:
    process.env.NEXT_PUBLIC_SUBGRAPH_UNICHAIN ??
    "https://api.studio.thegraph.com/query/107768/orbital-unichain/v0.1.0",
  5042002:
    process.env.NEXT_PUBLIC_SUBGRAPH_ARC ??
    "https://api.studio.thegraph.com/query/107768/orbital-arc/v0.1.0",
  // Not yet deployed (Studio caps free accounts at 3 subgraphs). Falls back to
  // RPC scanning until it is, which is exactly why the fallback still exists.
  421614: process.env.NEXT_PUBLIC_SUBGRAPH_ARBITRUM,
};

export function subgraphFor(chainId: number): string | undefined {
  return ENDPOINTS[chainId];
}

export function hasSubgraph(chainId: number): boolean {
  return typeof ENDPOINTS[chainId] === "string" && ENDPOINTS[chainId]!.length > 0;
}

export const SUBGRAPH_CHAINS = CHAIN_IDS.filter(hasSubgraph);

export class SubgraphError extends Error {}

async function gql<T>(chainId: number, query: string, variables: Record<string, unknown> = {}): Promise<T> {
  const url = ENDPOINTS[chainId];
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

// ─────────────────────────── activity feed ───────────────────────────

const ACTIVITY = /* GraphQL */ `
  query Activity($first: Int!, $skip: Int!) {
    swaps(orderBy: timestamp, orderDirection: desc, first: $first, skip: $skip) {
      id
      sender
      amountIn
      amountOut
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
  blockNumber: string;
  timestamp: string;
  txHash: `0x${string}`;
  tick: { tickIdx: string };
}

export type SubgraphTxType = "Swap" | "Add" | "Remove" | "Collect";

export interface SubgraphTx {
  type: SubgraphTxType;
  hash: `0x${string}`;
  chainId: number;
  blockNumber: bigint;
  timestamp: number;
  actor: `0x${string}`;
  amountIn: string;
  amountOut: string;
  /** Only present on swaps. Realised slippage against a 1:1 reference. */
  slippageBps?: number;
}

const WAD = 1e18;
const fmtUnits = (raw: string, decimals: number) => (Number(raw) / 10 ** decimals).toFixed(2);
const fmtWad = (raw: string) => (Number(raw) / WAD).toFixed(2);

const ACTION_LABEL: Record<RawLiquidity["action"], SubgraphTxType> = {
  MINT: "Add",
  BURN: "Remove",
  COLLECT: "Collect",
};

/** One page of activity for one chain. */
export async function fetchActivity(chainId: number, first: number, skip: number): Promise<SubgraphTx[]> {
  const data = await gql<{ swaps: RawSwap[]; liquidityEvents: RawLiquidity[] }>(
    chainId,
    ACTIVITY,
    { first, skip }
  );

  const out: SubgraphTx[] = [];

  for (const s of data.swaps) {
    out.push({
      type: "Swap",
      hash: s.txHash,
      chainId,
      blockNumber: BigInt(s.blockNumber),
      timestamp: Number(s.timestamp),
      actor: s.sender as `0x${string}`,
      amountIn: `${fmtUnits(s.amountIn, s.assetIn.decimals)} ${s.assetIn.symbol}`,
      amountOut: `${fmtUnits(s.amountOut, s.assetOut.decimals)} ${s.assetOut.symbol}`,
      slippageBps: s.slippageBps,
    });
  }

  for (const l of data.liquidityEvents) {
    const type = ACTION_LABEL[l.action];
    out.push({
      type,
      hash: l.txHash,
      chainId,
      blockNumber: BigInt(l.blockNumber),
      timestamp: Number(l.timestamp),
      actor: l.account as `0x${string}`,
      amountIn:
        type === "Collect"
          ? `tick #${l.tick.tickIdx}`
          : type === "Remove"
            ? `$${fmtWad(l.rWad)} tick #${l.tick.tickIdx}`
            : `$${fmtWad(l.rWad)}`,
      amountOut: "",
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
  const data = await gql<{ pools: PoolState[]; ticks: PoolState["ticks"] }>(chainId, POOL_STATE);
  const pool = data.pools[0];
  if (!pool) return null;
  return { ...pool, chainId, ticks: data.ticks };
}

/** Deployment label for a chain, for UI that mixes sources. */
export function chainLabel(chainId: number): string {
  return DEPLOYMENTS[chainId]?.short ?? String(chainId);
}
