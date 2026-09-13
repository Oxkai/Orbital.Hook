"use client";

import { useState, useRef, useCallback, useEffect, useMemo } from "react";
import { useConfig } from "wagmi";
import { getPublicClient } from "wagmi/actions";
import { parseAbiItem, type Address, type AbiEvent } from "viem";
import { POOL_ABI } from "@/lib/contracts";
import { ALL_POOLS, type PoolEntry, type PoolType } from "@/lib/crosschain";
import { fetchActivityAll, hasSubgraph, type SubgraphTx, type TokenAmount } from "@/lib/subgraph";

// Wide ranges work on a dedicated RPC (NEXT_PUBLIC_RPC_URL → Alchemy). The
// public node caps eth_getLogs at 100 blocks; Alchemy handles 10k comfortably,
// which is the whole reason this used to crawl.
const CHUNK = 10_000n;
const PAGE_SIZE = 20;
const POLL_MS = 15_000;
const TS_BATCH = 8;

const WAD = 1e18;
/** Value of a liquidity event: the sum of its per-asset WAD amounts (not its
 *  radius, most of which is virtual for a concentrated band). */
const wadSum = (amounts: readonly bigint[]) => Number(amounts.reduce((s, a) => s + a, 0n)) / WAD;
/// Token amounts are in the token's RAW units, so each divides by its own
/// decimals (dividing a 6-decimal asset by 1e18 would read as zero).
const units = (raw: bigint, decimals: number) => Number(raw) / 10 ** decimals;

export type TxType = "Swap" | "Add" | "Remove" | "Collect";
export type { TokenAmount };

export interface TxRecord {
  type: TxType;
  /** Swaps: what went in and what came out. */
  tokenIn?: TokenAmount;
  tokenOut?: TokenAmount;
  /** Liquidity events: the position's tick. */
  tick?: number;
  /** USD moved, in the pool's value units: a swap's input, a deposit or
   *  withdrawal's real amounts, or the fees collected. Undefined when a swap
   *  could not be priced (its pool's scales failed to load). */
  valueUsd?: number;
  /** Realised slippage in bps. Only the subgraph carries this: the raw Swap
   *  event has no notion of a fair price, so an RPC-scanned row leaves it
   *  undefined rather than guessing. */
  slippageBps?: number;
  /// `txHash-logIndex`, lowercased. One transaction can emit several events
  /// (a mint and a swap, say), so the hash alone is not an identity; this is,
  /// and it is the same whether the row came from the subgraph or from RPC.
  eventId: string;
  hash: `0x${string}`;
  /// Which chain and which pool the row came from. One chain can host both a
  /// stable and an FX pool, so the chain alone does not identify the source.
  chainId: number;
  pool: Address;
  poolType: PoolType;
  blockNumber: bigint;
  timestamp: number; // unix seconds
  actor: Address;
}
type RawTx = Omit<TxRecord, "timestamp">;

const SWAP = parseAbiItem("event Swap(address indexed sender, uint8 assetIn, uint8 assetOut, uint256 amountIn, uint256 amountOut)") as AbiEvent;
const MINT = parseAbiItem("event Mint(address indexed recipient, uint256 indexed tickIdx, uint256 kWad, uint256 rWad, uint256[] amounts)") as AbiEvent;
const BURN = parseAbiItem("event Burn(address indexed owner, uint256 indexed tickIdx, uint256 rWad, uint256[] amounts)") as AbiEvent;
const COLLECT = parseAbiItem("event Collect(address indexed owner, uint256 indexed tickIdx, uint256[] fees)") as AbiEvent;

/// Timestamps are immutable, so they cache across renders and pages.
///
/// Keyed by `chainId:block`, NOT by block number alone. Every chain starts at
/// block 1, so a bare-number cache collides constantly once more than one chain
/// is scanned: Arc block 60,634,293 and an Arbitrum block of the same height
/// would share an entry and stamp each other's rows with the wrong time.
const tsCache = new Map<string, number>();

// Session snapshot: keeps the scanned page alive across route changes so
// revisiting the transactions page is instant: only the new tail is polled.
// Lives outside React, so unmount/remount doesn't discard it. Cleared on a
// full page reload. Cursors are keyed by pool address.
let snapshot: {
  records: TxRecord[];
  backCursor: Record<string, bigint | null>;
  headBlock: Record<string, bigint>;
  open: ReadonlySet<string>;
} | null = null;

type Client = NonNullable<ReturnType<typeof getPublicClient>>;

/// One pool being scanned.
interface Source {
  key: string; // lowercased pool address
  pool: PoolEntry;
  client: Client;
  /// Served by the subgraph rather than RPC. Only stable pools are indexed.
  subgraph: boolean;
}

const rowKey = (t: { chainId: number; eventId: string }) => `${t.chainId}:${t.eventId}`;

/// Pools whose history has not yet been scanned back to their deploy block.
const openPools = (cursors: Record<string, bigint | null>): ReadonlySet<string> =>
  new Set(Object.entries(cursors).filter(([, c]) => c !== null).map(([k]) => k));

/// Newest first. Ordering is by TIMESTAMP, never by block number: heights are
/// per-chain and not comparable, so sorting merged rows by block would
/// interleave a 300M-block Arbitrum row against a 60M-block Arc row as though
/// one preceded the other.
const byNewest = (a: { timestamp: number }, b: { timestamp: number }) => b.timestamp - a.timestamp;

/// Merge `incoming` into `existing`, dropping rows already present.
function mergeRows(existing: TxRecord[], incoming: TxRecord[]): TxRecord[] {
  const seen = new Set(existing.map(rowKey));
  return [...existing, ...incoming.filter((t) => !seen.has(rowKey(t)))].sort(byNewest);
}

/// Map a subgraph row onto the shared record shape. The subgraph indexes each
/// chain's stable pool, so that is the pool the row belongs to.
function fromSubgraph(t: SubgraphTx): TxRecord | undefined {
  const pool = ALL_POOLS.find((p) => p.chainId === t.chainId && p.type === "stable");
  if (!pool) return undefined;
  return {
    type: t.type,
    eventId: t.eventId,
    hash: t.hash,
    chainId: t.chainId,
    pool: pool.address,
    poolType: pool.type,
    blockNumber: t.blockNumber,
    timestamp: t.timestamp,
    actor: t.actor,
    tokenIn: t.tokenIn,
    tokenOut: t.tokenOut,
    tick: t.tick,
    valueUsd: t.valueUsd,
    slippageBps: t.slippageBps,
  };
}

/// Each pool's per-asset scale (raw units -> WAD value units), read from the
/// hook once per session: immutable, and the only exact way to value a swap.
/// A stable asset's is just its decimals, but an FX pool folds its oracle
/// centre into each priced asset's scale, so EURC is worth more than a USDC.
/// A failed read is not cached, so the next page retries it.
const scaleCache = new Map<string, readonly bigint[]>();

async function scalesOf(src: Source): Promise<readonly bigint[] | undefined> {
  const cached = scaleCache.get(src.key);
  if (cached) return cached;
  try {
    const scales = await Promise.all(
      src.pool.assets.map((_, i) =>
        src.client.readContract({ address: src.pool.address, abi: POOL_ABI, functionName: "scaleOf", args: [i] })
      )
    );
    scaleCache.set(src.key, scales);
    return scales;
  } catch {
    return undefined;
  }
}

async function fetchTimestamps(client: Client, chainId: number, blocks: bigint[]): Promise<Map<bigint, number>> {
  const key = (n: bigint) => `${chainId}:${n}`;
  const unique = [...new Set(blocks)].filter((n) => !tsCache.has(key(n)));
  for (let i = 0; i < unique.length; i += TS_BATCH) {
    const batch = unique.slice(i, i + TS_BATCH);
    const res = await Promise.all(batch.map((n) => client.getBlock({ blockNumber: n })));
    res.forEach((b) => { if (b.timestamp) tsCache.set(key(b.number!), Number(b.timestamp)); });
  }
  const map = new Map<bigint, number>();
  blocks.forEach((n) => { const t = tsCache.get(key(n)); if (t) map.set(n, t); });
  return map;
}

// One ≤CHUNK-block window on ONE pool: pull all four events from its hook in
// parallel, decoding asset indices through that pool's own asset order.
async function fetchChunk(src: Source, from: bigint, to: bigint): Promise<RawTx[]> {
  const { pool, client } = src;
  const asset = (idx: number) => pool.assets[idx] ?? { symbol: `Asset#${idx}`, decimals: 18 };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const [s, m, b, c, scales]: [any[], any[], any[], any[], readonly bigint[] | undefined] = await Promise.all([
    client.getLogs({ address: pool.address, event: SWAP, fromBlock: from, toBlock: to }),
    client.getLogs({ address: pool.address, event: MINT, fromBlock: from, toBlock: to }),
    client.getLogs({ address: pool.address, event: BURN, fromBlock: from, toBlock: to }),
    client.getLogs({ address: pool.address, event: COLLECT, fromBlock: from, toBlock: to }),
    scalesOf(src),
  ]);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const base = (log: any) => ({
    eventId: `${String(log.transactionHash).toLowerCase()}-${log.logIndex}`,
    hash: log.transactionHash,
    chainId: pool.chainId,
    pool: pool.address,
    poolType: pool.type,
    blockNumber: log.blockNumber,
  });
  const out: RawTx[] = [];
  for (const log of s) {
    const a = log.args;
    const iIn = Number(a.assetIn);
    const ai = asset(iIn);
    const ao = asset(Number(a.assetOut));
    const scaleIn = scales?.[iIn];
    out.push({
      ...base(log),
      type: "Swap",
      actor: a.sender,
      tokenIn: { symbol: ai.symbol, amount: units(a.amountIn, ai.decimals) },
      tokenOut: { symbol: ao.symbol, amount: units(a.amountOut, ao.decimals) },
      valueUsd: scaleIn === undefined ? undefined : Number(a.amountIn * scaleIn) / WAD,
    });
  }
  // Liquidity events carry WAD value amounts (for a collect, the fees).
  for (const log of m) {
    const a = log.args;
    out.push({ ...base(log), type: "Add", actor: a.recipient, tick: Number(a.tickIdx), valueUsd: wadSum(a.amounts) });
  }
  for (const log of b) {
    const a = log.args;
    out.push({ ...base(log), type: "Remove", actor: a.owner, tick: Number(a.tickIdx), valueUsd: wadSum(a.amounts) });
  }
  for (const log of c) {
    const a = log.args;
    out.push({ ...base(log), type: "Collect", actor: a.owner, tick: Number(a.tickIdx), valueUsd: wadSum(a.fees) });
  }
  return out;
}

async function withTimestamps(src: Source, raw: RawTx[]): Promise<TxRecord[]> {
  const tsMap = await fetchTimestamps(src.client, src.pool.chainId, raw.map((r) => r.blockNumber));
  return raw.map((r) => ({ ...r, timestamp: tsMap.get(r.blockNumber) ?? 0 }));
}

/// Scan one pool backward from `startTo` until it has `limit` rows or hits the
/// pool's deploy block.
async function scanPoolBack(src: Source, startTo: bigint, limit: number) {
  const acc: RawTx[] = [];
  let to = startTo;
  const floor = src.pool.deployBlock;
  while (acc.length < limit && to >= floor) {
    const from = to - CHUNK + 1n < floor ? floor : to - CHUNK + 1n;
    acc.push(...(await fetchChunk(src, from, to)));
    if (from === floor) { to = floor - 1n; break; }
    to = from - 1n;
  }
  return { records: await withTimestamps(src, acc), nextCursor: to >= floor ? to : null };
}

/// One backward page across every RPC-scanned pool with a cursor, in parallel.
///
/// A pool that errors (dead RPC, unsupported log range) yields nothing instead
/// of rejecting the batch, so one unreachable endpoint cannot blank the feed.
async function scanAllBack(sources: Source[], starts: Record<string, bigint | null>, limit: number) {
  const results = await Promise.all(
    sources.map(async (src) => {
      const start = starts[src.key];
      if (start === null || start === undefined) return { key: src.key, records: [] as TxRecord[], nextCursor: null };
      try {
        return { key: src.key, ...(await scanPoolBack(src, start, limit)) };
      } catch {
        return { key: src.key, records: [] as TxRecord[], nextCursor: null };
      }
    })
  );
  const cursors: Record<string, bigint | null> = {};
  results.forEach((r) => { cursors[r.key] = r.nextCursor; });
  return { records: results.flatMap((r) => r.records).sort(byNewest), cursors };
}

/// Latest block per pool; a pool whose RPC is unreachable maps to null.
async function headsOf(sources: Source[]): Promise<Record<string, bigint | null>> {
  const out: Record<string, bigint | null> = {};
  await Promise.all(
    sources.map(async (src) => {
      try { out[src.key] = await src.client.getBlockNumber(); }
      catch { out[src.key] = null; }
    })
  );
  return out;
}

/// Activity across EVERY pool, of either type, merged into one feed.
///
/// Pools with a subgraph are read from it (one round trip, timestamps and
/// realised slippage included); every other pool is scanned over RPC. Both
/// kinds are loaded on the FIRST page: a pool without a subgraph must not stay
/// invisible until the user thinks to press "load more".
export function useTransactions() {
  // Clients come from the config rather than `usePublicClient` per pool:
  // calling a hook inside a `.map` breaks the rules of hooks the moment the
  // list length changes. `getPublicClient` is a plain function.
  const config = useConfig();

  const sources = useMemo<Source[]>(
    () =>
      ALL_POOLS.flatMap((pool) => {
        const client = getPublicClient(config, { chainId: pool.chainId }) as Client | undefined;
        if (!client || pool.assets.length === 0) return [];
        return [{ key: pool.address.toLowerCase(), pool, client, subgraph: pool.type === "stable" && hasSubgraph(pool.chainId) }];
      }),
    [config]
  );

  const [txs, setTxs] = useState<TxRecord[]>(() => snapshot?.records ?? []);
  const [isLoading, setIsLoading] = useState(!snapshot);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  /// Nothing is scanned before the first load, so every pool starts open.
  const [open, setOpen] = useState<ReadonlySet<string>>(() => snapshot?.open ?? new Set(sources.map((s) => s.key)));
  const hasMore = open.size > 0;
  const [error, setError] = useState<string | null>(null);

  /// Per-POOL cursors: pools sit at different heights with different deploy
  /// blocks, so "how far back have we scanned" only means something per pool.
  const backCursor = useRef<Record<string, bigint | null>>(snapshot?.backCursor ?? {});
  const headBlock = useRef<Record<string, bigint>>(snapshot?.headBlock ?? {});

  /// A full first page: subgraph rows for indexed pools, an RPC page for the
  /// rest, merged. A pool whose subgraph request fails falls back to RPC.
  const loadFirstPage = useCallback(async () => {
    const heads = await headsOf(sources);

    let subgraphRows: TxRecord[] = [];
    const indexedChains = [...new Set(sources.filter((s) => s.subgraph).map((s) => s.pool.chainId))];
    const servedBySubgraph = new Set<string>();
    if (indexedChains.length > 0) {
      try {
        const { rows, failed } = await fetchActivityAll(indexedChains, PAGE_SIZE, 0);
        subgraphRows = rows.map(fromSubgraph).filter((r): r is TxRecord => !!r);
        for (const s of sources) {
          if (s.subgraph && !failed.includes(s.pool.chainId)) servedBySubgraph.add(s.key);
        }
      } catch {
        // every indexed pool falls back to RPC below
      }
    }

    const starts: Record<string, bigint | null> = {};
    for (const s of sources) starts[s.key] = servedBySubgraph.has(s.key) ? null : heads[s.key];
    const rpc = await scanAllBack(sources, starts, PAGE_SIZE);

    return { records: mergeRows(subgraphRows, rpc.records), cursors: rpc.cursors, heads };
  }, [sources]);

  // Initial load + tail-only poll (only fetches blocks newer than headBlock).
  useEffect(() => {
    if (sources.length === 0) return;
    let cancelled = false;

    async function init() {
      // Already scanned this session → show instantly, just refresh the tail.
      if (snapshot && snapshot.records.length) { setIsLoading(false); await poll(); return; }
      setIsLoading(true);
      setError(null);
      try {
        const { records, cursors, heads } = await loadFirstPage();
        if (cancelled) return;
        setTxs(records);
        backCursor.current = cursors;
        for (const [k, h] of Object.entries(heads)) if (h !== null) headBlock.current[k] = h;
        setOpen(openPools(cursors));
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : "Failed to load");
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    }

    async function poll() {
      if (cancelled) return;
      const fresh: TxRecord[] = [];
      await Promise.all(
        sources.map(async (src) => {
          try {
            const latest = await src.client.getBlockNumber();
            const head = headBlock.current[src.key];
            if (head === undefined || latest <= head) { headBlock.current[src.key] = head ?? latest; return; }
            const raw: RawTx[] = [];
            let from = head + 1n;
            while (from <= latest) {
              const to = from + CHUNK - 1n > latest ? latest : from + CHUNK - 1n;
              raw.push(...(await fetchChunk(src, from, to)));
              from = to + 1n;
            }
            headBlock.current[src.key] = latest;
            if (raw.length > 0) fresh.push(...(await withTimestamps(src, raw)));
          } catch {
            // one pool's transient poll failure must not stall the others
          }
        })
      );
      if (fresh.length === 0 || cancelled) return;
      setTxs((prev) => mergeRows(prev, fresh));
    }

    init();
    const interval = setInterval(poll, POLL_MS);
    return () => { cancelled = true; clearInterval(interval); };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sources.length]);

  // Keep the session snapshot current so revisiting the route is instant.
  useEffect(() => {
    if (txs.length) snapshot = { records: txs, backCursor: backCursor.current, headBlock: headBlock.current, open };
  }, [txs, open]);

  const loadMore = useCallback(async () => {
    if (isLoadingMore || !hasMore) return;
    if (!Object.values(backCursor.current).some((v) => v !== null)) return;
    setIsLoadingMore(true);
    try {
      const { records, cursors } = await scanAllBack(sources, backCursor.current, PAGE_SIZE);
      setTxs((prev) => mergeRows(prev, records));
      backCursor.current = cursors;
      setOpen(openPools(cursors));
    } catch {
      // a failed page leaves the feed as it was; the button stays available
    } finally {
      setIsLoadingMore(false);
    }
  }, [isLoadingMore, hasMore, sources]);

  const refetch = useCallback(async () => {
    if (sources.length === 0) return;
    try {
      const { records, cursors, heads } = await loadFirstPage();
      setTxs(records);
      backCursor.current = cursors;
      for (const [k, h] of Object.entries(heads)) if (h !== null) headBlock.current[k] = h;
      setOpen(openPools(cursors));
    } catch {
      // keep the current feed on a failed refresh
    }
  }, [sources.length, loadFirstPage]);

  /** Whether `pool` has older history still to load. */
  const hasMoreFor = useCallback((pool: string) => open.has(pool.toLowerCase()), [open]);

  return { txs, isLoading, isLoadingMore, hasMore, hasMoreFor, loadMore, error, refetch };
}
