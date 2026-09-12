"use client";

import { useState, useRef, useCallback, useEffect, useMemo } from "react";
import { useConfig } from "wagmi";
import { getPublicClient } from "wagmi/actions";
import { parseAbiItem, type Address, type AbiEvent } from "viem";
import { deployBlockFor } from "@/lib/contracts";
import { CHAIN_IDS, DEPLOYMENTS, assetsByIndex } from "@/lib/crosschain";
import { fetchActivityAll, hasSubgraph, type SubgraphTx } from "@/lib/subgraph";

// Wide ranges work on a dedicated RPC (NEXT_PUBLIC_RPC_URL → Alchemy). The
// public node caps eth_getLogs at 100 blocks; Alchemy handles 10k comfortably,
// which is the whole reason this used to crawl.
const CHUNK = 10_000n;
const PAGE_SIZE = 20;
const POLL_MS = 15_000;
const TS_BATCH = 8;

const WAD = 1e18;
/// Radius/`rWad` quantities really are WAD.
const fmtWadAmt = (raw: bigint) => (Number(raw) / WAD).toFixed(2);
/// Token amounts are in the token's RAW units. Dividing every one by 1e18
/// rendered a 6-decimal asset as "0.00", which is what the Swap rows showed.
const fmtUnits = (raw: bigint, decimals: number) =>
  (Number(raw) / 10 ** decimals).toFixed(2);

export type TxType = "Swap" | "Add" | "Remove" | "Collect";

export interface TxRecord {
  type: TxType;
  /** Realised slippage in bps. Only the subgraph carries this: the raw Swap
   *  event has no notion of a fair price, so an RPC-scanned row leaves it
   *  undefined rather than guessing. */
  slippageBps?: number;
  hash: `0x${string}`;
  /// Which deployment this came from. Rows are merged across chains, so the
  /// explorer link, the chain badge and the asset decoding all key off this.
  chainId: number;
  blockNumber: bigint;
  timestamp: number; // unix seconds
  actor: Address;
  amountIn: string;
  amountOut: string;
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
// full page reload.
let snapshot: {
  records: TxRecord[];
  backCursor: Record<number, bigint | null>;
  headBlock: Record<number, bigint>;
  hasMore: boolean;
} | null = null;

type Client = NonNullable<ReturnType<typeof getPublicClient>>;
type AssetFn = (i: number) => { symbol: string; decimals: number };

/// Map a subgraph row onto the shared record shape.
function fromSubgraph(t: SubgraphTx): TxRecord {
  return {
    type: t.type,
    hash: t.hash,
    chainId: t.chainId,
    blockNumber: t.blockNumber,
    timestamp: t.timestamp,
    actor: t.actor,
    amountIn: t.amountIn,
    amountOut: t.amountOut,
    slippageBps: t.slippageBps,
  };
}

/// Newest first. Ordering is by TIMESTAMP, never by block number: heights are
/// per-chain and not comparable, so sorting merged rows by block would
/// interleave a 300M-block Arbitrum row against a 60M-block Arc row as though
/// one preceded the other.
const byNewest = (a: { timestamp: number }, b: { timestamp: number }) => b.timestamp - a.timestamp;

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

// One ≤CHUNK-block window on ONE chain: pull all four events from that chain's
// hook in parallel.
async function fetchChunk(
  client: Client,
  chainId: number,
  hook: Address,
  from: bigint,
  to: bigint,
  asset: AssetFn
): Promise<RawTx[]> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const [s, m, b, c]: any[][] = await Promise.all([
    client.getLogs({ address: hook, event: SWAP, fromBlock: from, toBlock: to }),
    client.getLogs({ address: hook, event: MINT, fromBlock: from, toBlock: to }),
    client.getLogs({ address: hook, event: BURN, fromBlock: from, toBlock: to }),
    client.getLogs({ address: hook, event: COLLECT, fromBlock: from, toBlock: to }),
  ]);
  const out: RawTx[] = [];
  for (const log of s) {
    const a = log.args;
    const ai = asset(Number(a.assetIn));
    const ao = asset(Number(a.assetOut));
    out.push({ type: "Swap", chainId, hash: log.transactionHash, blockNumber: log.blockNumber, actor: a.sender,
      amountIn: `${fmtUnits(a.amountIn, ai.decimals)} ${ai.symbol}`,
      amountOut: `${fmtUnits(a.amountOut, ao.decimals)} ${ao.symbol}` });
  }
  for (const log of m) {
    const a = log.args;
    out.push({ type: "Add", chainId, hash: log.transactionHash, blockNumber: log.blockNumber, actor: a.recipient, amountIn: `$${fmtWadAmt(a.rWad)}`, amountOut: "" });
  }
  for (const log of b) {
    const a = log.args;
    out.push({ type: "Remove", chainId, hash: log.transactionHash, blockNumber: log.blockNumber, actor: a.owner, amountIn: `$${fmtWadAmt(a.rWad)} tick #${a.tickIdx}`, amountOut: "" });
  }
  for (const log of c) {
    const a = log.args;
    out.push({ type: "Collect", chainId, hash: log.transactionHash, blockNumber: log.blockNumber, actor: a.owner, amountIn: `tick #${a.tickIdx}`, amountOut: "" });
  }
  return out;
}

/// Activity across EVERY deployment, merged into one feed.
///
/// This used to be pinned to the primary chain, which meant the page showed
/// Unichain only and silently omitted Base, Arbitrum and Arc. Each chain is
/// scanned independently (own client, own hook, own deploy block, own asset
/// index order) and the results are merged on timestamp.
export function useTransactions() {
  // Clients come from the config rather than `usePublicClient` per chain.
  // Calling a hook inside a `.map` over the chain list only works while that
  // list is a fixed-length constant, and breaks the rules of hooks the moment
  // it is not. `getPublicClient` is a plain function, so the number of chains
  // can change freely without disturbing hook order.
  const config = useConfig();

  const chains = useMemo(
    () =>
      CHAIN_IDS.map((chainId) => ({
        chainId,
        client: getPublicClient(config, { chainId }) as Client | undefined,
        hook: DEPLOYMENTS[chainId]?.orbitalHook as Address | undefined,
        deployBlock: deployBlockFor(chainId),
        // Events carry indices into that chain's OWN asset array, so the
        // decoder must come from that chain's registry entry in index order.
        indexed: assetsByIndex(chainId),
      })).filter((c) => c.client && c.hook && c.indexed.length > 0),
    [config]
  );

  const [txs, setTxs] = useState<TxRecord[]>(() => snapshot?.records ?? []);
  const [isLoading, setIsLoading] = useState(!snapshot);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(snapshot?.hasMore ?? true);
  const [error, setError] = useState<string | null>(null);

  /// Per-chain cursors. A single shared cursor cannot work: the chains are at
  /// wildly different heights and each has its own deploy block, so "how far
  /// back have we scanned" is only meaningful per chain.
  const backCursor = useRef<Record<number, bigint | null>>(snapshot?.backCursor ?? {});
  const headBlock = useRef<Record<number, bigint>>(snapshot?.headBlock ?? {});

  const assetFor = useCallback(
    (indexed: { symbol: string; decimals: number }[]): AssetFn =>
      (idx: number) => indexed[idx] ?? { symbol: `Asset#${idx}`, decimals: 18 },
    []
  );

  /// Scan one chain backward from `startTo` until it has `limit` rows or hits
  /// that chain's deploy block.
  const scanChainBack = useCallback(
    async (
      c: (typeof chains)[number],
      startTo: bigint,
      limit: number
    ): Promise<{ records: TxRecord[]; nextCursor: bigint | null }> => {
      const asset = assetFor(c.indexed);
      const acc: RawTx[] = [];
      let to = startTo;
      const floor = c.deployBlock;
      while (acc.length < limit && to >= floor) {
        const from = to - CHUNK + 1n < floor ? floor : to - CHUNK + 1n;
        acc.push(...(await fetchChunk(c.client!, c.chainId, c.hook!, from, to, asset)));
        if (from === floor) { to = floor - 1n; break; }
        to = from - 1n;
      }
      const tsMap = await fetchTimestamps(c.client!, c.chainId, acc.map((r) => r.blockNumber));
      const records = acc.map((r) => ({ ...r, timestamp: tsMap.get(r.blockNumber) ?? 0 }));
      return { records, nextCursor: to >= floor ? to : null };
    },
    [assetFor]
  );

  /// One backward page across every chain, run in parallel.
  ///
  /// A chain that errors (dead RPC, unsupported log range) yields nothing
  /// instead of rejecting the batch, so one unreachable endpoint cannot blank
  /// the feed for the others.
  const scanAllBack = useCallback(
    async (starts: Record<number, bigint | null>, limit: number) => {
      const results = await Promise.all(
        chains.map(async (c) => {
          const start = starts[c.chainId];
          if (start === null || start === undefined) return { chainId: c.chainId, records: [] as TxRecord[], nextCursor: null };
          try {
            const r = await scanChainBack(c, start, limit);
            return { chainId: c.chainId, ...r };
          } catch {
            return { chainId: c.chainId, records: [] as TxRecord[], nextCursor: null };
          }
        })
      );
      const records = results.flatMap((r) => r.records).sort(byNewest);
      const cursors: Record<number, bigint | null> = {};
      results.forEach((r) => { cursors[r.chainId] = r.nextCursor; });
      return { records, cursors };
    },
    [chains, scanChainBack]
  );

  // Initial load + tail-only poll (only fetches blocks newer than headBlock).
  useEffect(() => {
    if (chains.length === 0) return;
    let cancelled = false;

    /// Subgraph first, RPC only for chains without one.
    ///
    /// One round trip per chain with timestamps already attached, versus
    /// scanning `eth_getLogs` backwards in 10,000-block windows and then
    /// fetching a block per record. Chains with no deployed subgraph (currently
    /// Arbitrum) fall through to the scanner below, so the feed stays complete.
    async function initFromSubgraph(): Promise<boolean> {
      const indexed = CHAIN_IDS.filter(hasSubgraph);
      if (indexed.length === 0) return false;
      try {
        const { rows } = await fetchActivityAll(indexed, PAGE_SIZE, 0);
        if (cancelled || rows.length === 0) return false;
        setTxs(rows.map(fromSubgraph));
        // Chains served by the subgraph need no backward cursor; the remaining
        // RPC chains keep theirs and `loadMore` still walks those.
        indexed.forEach((id) => { backCursor.current[id] = null; });
        setHasMore(indexed.length < CHAIN_IDS.length);
        return true;
      } catch {
        return false;
      }
    }

    async function init() {
      // Already scanned this session → show instantly, just refresh the tail.
      if (snapshot && snapshot.records.length) { setIsLoading(false); await poll(); return; }
      setIsLoading(true);
      setError(null);

      if (await initFromSubgraph()) { setIsLoading(false); return; }

      try {
        const heads = await Promise.all(
          chains.map(async (c) => {
            try { return { chainId: c.chainId, latest: await c.client!.getBlockNumber() }; }
            catch { return { chainId: c.chainId, latest: null }; }
          })
        );
        if (cancelled) return;
        const starts: Record<number, bigint | null> = {};
        heads.forEach((h) => { starts[h.chainId] = h.latest; });

        const { records, cursors } = await scanAllBack(starts, PAGE_SIZE);
        if (cancelled) return;

        setTxs(records);
        backCursor.current = cursors;
        heads.forEach((h) => { if (h.latest !== null) headBlock.current[h.chainId] = h.latest; });
        setHasMore(Object.values(cursors).some((v) => v !== null));
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
        chains.map(async (c) => {
          try {
            const latest = await c.client!.getBlockNumber();
            const head = headBlock.current[c.chainId];
            if (head === undefined || latest <= head) { headBlock.current[c.chainId] = head ?? latest; return; }
            const asset = assetFor(c.indexed);
            const raw: RawTx[] = [];
            let from = head + 1n;
            while (from <= latest) {
              const to = from + CHUNK - 1n > latest ? latest : from + CHUNK - 1n;
              raw.push(...(await fetchChunk(c.client!, c.chainId, c.hook!, from, to, asset)));
              from = to + 1n;
            }
            headBlock.current[c.chainId] = latest;
            if (raw.length === 0) return;
            const tsMap = await fetchTimestamps(c.client!, c.chainId, raw.map((r) => r.blockNumber));
            fresh.push(...raw.map((r) => ({ ...r, timestamp: tsMap.get(r.blockNumber) ?? 0 })));
          } catch {
            // one chain's transient poll failure must not stall the others
          }
        })
      );
      if (fresh.length === 0 || cancelled) return;
      setTxs((prev) => {
        // Dedupe on chain too: hashes are only unique within a chain.
        const seen = new Set(prev.map((t) => `${t.chainId}-${t.hash}-${t.blockNumber}`));
        const merged = [...fresh.filter((t) => !seen.has(`${t.chainId}-${t.hash}-${t.blockNumber}`)), ...prev];
        merged.sort(byNewest);
        return merged;
      });
    }

    init();
    const interval = setInterval(poll, POLL_MS);
    return () => { cancelled = true; clearInterval(interval); };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chains.length]);

  // Keep the session snapshot current so revisiting the route is instant.
  useEffect(() => {
    if (txs.length) snapshot = { records: txs, backCursor: backCursor.current, headBlock: headBlock.current, hasMore };
  }, [txs, hasMore]);

  const loadMore = useCallback(async () => {
    if (isLoadingMore || !hasMore) return;
    if (!Object.values(backCursor.current).some((v) => v !== null)) return;
    setIsLoadingMore(true);
    try {
      const { records, cursors } = await scanAllBack(backCursor.current, PAGE_SIZE);
      setTxs((prev) => {
        const seen = new Set(prev.map((t) => `${t.chainId}-${t.hash}-${t.blockNumber}`));
        return [...prev, ...records.filter((t) => !seen.has(`${t.chainId}-${t.hash}-${t.blockNumber}`))].sort(byNewest);
      });
      backCursor.current = cursors;
      setHasMore(Object.values(cursors).some((v) => v !== null));
    } catch {
      // ignore
    } finally {
      setIsLoadingMore(false);
    }
  }, [isLoadingMore, hasMore, scanAllBack]);

  const refetch = useCallback(async () => {
    if (chains.length === 0) return;
    try {
      const heads = await Promise.all(
        chains.map(async (c) => {
          try { return { chainId: c.chainId, latest: await c.client!.getBlockNumber() }; }
          catch { return { chainId: c.chainId, latest: null }; }
        })
      );
      const starts: Record<number, bigint | null> = {};
      heads.forEach((h) => { starts[h.chainId] = h.latest; });
      const { records, cursors } = await scanAllBack(starts, PAGE_SIZE);
      setTxs(records);
      backCursor.current = cursors;
      heads.forEach((h) => { if (h.latest !== null) headBlock.current[h.chainId] = h.latest; });
      setHasMore(Object.values(cursors).some((v) => v !== null));
    } catch {
      // ignore
    }
  }, [chains, scanAllBack]);

  return { txs, isLoading, isLoadingMore, hasMore, loadMore, error, refetch };
}
