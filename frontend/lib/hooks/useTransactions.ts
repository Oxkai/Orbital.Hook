"use client";

import { useState, useRef, useCallback, useEffect } from "react";
import { usePublicClient } from "wagmi";
import { parseAbiItem, type Address, type AbiEvent } from "viem";
import { POOL_ADDRESSES, TOKEN_META, DEPLOY_BLOCK } from "@/lib/contracts";

// Wide ranges work on a dedicated RPC (NEXT_PUBLIC_RPC_URL → Alchemy). The
// public node caps eth_getLogs at 100 blocks; Alchemy handles 10k comfortably,
// which is the whole reason this used to crawl.
const CHUNK = 10_000n;
const PAGE_SIZE = 20;
const POLL_MS = 15_000;
const TS_BATCH = 8;

const WAD = 1e18;
const fmt = (raw: bigint) => (Number(raw) / WAD).toFixed(2);

const HOOK = POOL_ADDRESSES[0] as Address;

export type TxType = "Swap" | "Add" | "Remove" | "Collect";

export interface TxRecord {
  type: TxType;
  hash: `0x${string}`;
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

// timestamps are immutable, so cache across renders/pages
const tsCache = new Map<bigint, number>();

// Session snapshot: keeps the scanned page alive across route changes so
// revisiting the transactions page is instant — only the new tail is polled.
// Lives outside React, so unmount/remount doesn't discard it. Cleared on a
// full page reload.
let snapshot: { records: TxRecord[]; backCursor: bigint | null; headBlock: bigint; hasMore: boolean } | null = null;

type Client = NonNullable<ReturnType<typeof usePublicClient>>;

async function fetchTimestamps(client: Client, blocks: bigint[]): Promise<Map<bigint, number>> {
  const unique = [...new Set(blocks)].filter((n) => !tsCache.has(n));
  for (let i = 0; i < unique.length; i += TS_BATCH) {
    const batch = unique.slice(i, i + TS_BATCH);
    const res = await Promise.all(batch.map((n) => client.getBlock({ blockNumber: n })));
    res.forEach((b) => { if (b.timestamp) tsCache.set(b.number!, Number(b.timestamp)); });
  }
  const map = new Map<bigint, number>();
  blocks.forEach((n) => { const t = tsCache.get(n); if (t) map.set(n, t); });
  return map;
}

// One ≤CHUNK-block window: pull all four events from the hook in parallel.
async function fetchChunk(client: Client, from: bigint, to: bigint, sym: (i: number) => string): Promise<RawTx[]> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const [s, m, b, c]: any[][] = await Promise.all([
    client.getLogs({ address: HOOK, event: SWAP, fromBlock: from, toBlock: to }),
    client.getLogs({ address: HOOK, event: MINT, fromBlock: from, toBlock: to }),
    client.getLogs({ address: HOOK, event: BURN, fromBlock: from, toBlock: to }),
    client.getLogs({ address: HOOK, event: COLLECT, fromBlock: from, toBlock: to }),
  ]);
  const out: RawTx[] = [];
  for (const log of s) {
    const a = log.args;
    out.push({ type: "Swap", hash: log.transactionHash, blockNumber: log.blockNumber, actor: a.sender,
      amountIn: `${fmt(a.amountIn)} ${sym(Number(a.assetIn))}`, amountOut: `${fmt(a.amountOut)} ${sym(Number(a.assetOut))}` });
  }
  for (const log of m) {
    const a = log.args;
    out.push({ type: "Add", hash: log.transactionHash, blockNumber: log.blockNumber, actor: a.recipient, amountIn: `$${fmt(a.rWad)}`, amountOut: "" });
  }
  for (const log of b) {
    const a = log.args;
    out.push({ type: "Remove", hash: log.transactionHash, blockNumber: log.blockNumber, actor: a.owner, amountIn: `$${fmt(a.rWad)} tick #${a.tickIdx}`, amountOut: "" });
  }
  for (const log of c) {
    const a = log.args;
    out.push({ type: "Collect", hash: log.transactionHash, blockNumber: log.blockNumber, actor: a.owner, amountIn: `tick #${a.tickIdx}`, amountOut: "" });
  }
  return out;
}

export function useTransactions(poolTokens: { symbol: string; address: string }[]) {
  const client = usePublicClient();
  const [txs, setTxs] = useState<TxRecord[]>(() => snapshot?.records ?? []);
  const [isLoading, setIsLoading] = useState(!snapshot);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(snapshot?.hasMore ?? true);
  const [error, setError] = useState<string | null>(null);

  const backCursor = useRef<bigint | null>(snapshot?.backCursor ?? null); // next toBlock to scan downward
  const headBlock = useRef<bigint>(snapshot?.headBlock ?? 0n); // highest block already covered (for tail poll)

  const sym = useCallback((idx: number) =>
    poolTokens[idx]?.symbol ?? TOKEN_META[poolTokens[idx]?.address?.toLowerCase() ?? ""]?.symbol ?? `Asset#${idx}`,
  [poolTokens]);

  const withTs = useCallback(async (raw: RawTx[]): Promise<TxRecord[]> => {
    const tsMap = await fetchTimestamps(client!, raw.map((r) => r.blockNumber));
    return raw.map((r) => ({ ...r, timestamp: tsMap.get(r.blockNumber) ?? 0 }));
  }, [client]);

  // Scan backward from `startTo` in CHUNK windows until ≥ limit records or deploy.
  const scanBack = useCallback(async (startTo: bigint, limit: number) => {
    const acc: RawTx[] = [];
    let to = startTo;
    while (acc.length < limit && to >= DEPLOY_BLOCK) {
      const from = to - CHUNK + 1n < DEPLOY_BLOCK ? DEPLOY_BLOCK : to - CHUNK + 1n;
      acc.push(...await fetchChunk(client!, from, to, sym));
      if (from === DEPLOY_BLOCK) { to = DEPLOY_BLOCK - 1n; break; }
      to = from - 1n;
    }
    acc.sort((a, b) => (a.blockNumber < b.blockNumber ? 1 : -1));
    return { records: await withTs(acc), nextCursor: to >= DEPLOY_BLOCK ? to : null };
  }, [client, sym, withTs]);

  // Initial load + tail-only poll (only fetches blocks newer than headBlock).
  useEffect(() => {
    if (!client || poolTokens.length === 0) return;
    let cancelled = false;

    async function init() {
      // Already scanned this session → show instantly, just refresh the tail.
      if (snapshot && snapshot.records.length) { setIsLoading(false); await poll(); return; }
      setIsLoading(true);
      setError(null);
      try {
        const latest = await client!.getBlockNumber();
        const { records, nextCursor } = await scanBack(latest, PAGE_SIZE);
        if (cancelled) return;
        setTxs(records);
        backCursor.current = nextCursor;
        headBlock.current = latest;
        setHasMore(nextCursor !== null);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : "Failed to load");
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    }

    async function poll() {
      if (cancelled) return;
      try {
        const latest = await client!.getBlockNumber();
        if (latest <= headBlock.current) return;
        let from = headBlock.current + 1n;
        const fresh: RawTx[] = [];
        while (from <= latest) {
          const to = from + CHUNK - 1n > latest ? latest : from + CHUNK - 1n;
          fresh.push(...await fetchChunk(client!, from, to, sym));
          from = to + 1n;
        }
        headBlock.current = latest;
        if (fresh.length === 0 || cancelled) return;
        const withTime = await withTs(fresh);
        setTxs((prev) => {
          const seen = new Set(prev.map((t) => `${t.hash}-${t.blockNumber}`));
          const merged = [...withTime.filter((t) => !seen.has(`${t.hash}-${t.blockNumber}`)), ...prev];
          merged.sort((a, b) => (a.blockNumber < b.blockNumber ? 1 : -1));
          return merged;
        });
      } catch {
        // ignore transient poll errors
      }
    }

    init();
    const interval = setInterval(poll, POLL_MS);
    return () => { cancelled = true; clearInterval(interval); };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, poolTokens.length]);

  // Keep the session snapshot current so revisiting the route is instant.
  useEffect(() => {
    if (txs.length) snapshot = { records: txs, backCursor: backCursor.current, headBlock: headBlock.current, hasMore };
  }, [txs, hasMore]);

  const loadMore = useCallback(async () => {
    if (backCursor.current === null || isLoadingMore || !hasMore) return;
    setIsLoadingMore(true);
    try {
      const { records, nextCursor } = await scanBack(backCursor.current, PAGE_SIZE);
      setTxs((prev) => [...prev, ...records]);
      backCursor.current = nextCursor;
      setHasMore(nextCursor !== null);
    } catch {
      // ignore
    } finally {
      setIsLoadingMore(false);
    }
  }, [isLoadingMore, hasMore, scanBack]);

  const refetch = useCallback(async () => {
    if (!client || poolTokens.length === 0) return;
    try {
      const latest = await client.getBlockNumber();
      const { records, nextCursor } = await scanBack(latest, PAGE_SIZE);
      setTxs(records);
      backCursor.current = nextCursor;
      headBlock.current = latest;
      setHasMore(nextCursor !== null);
    } catch {
      // ignore
    }
  }, [client, poolTokens.length, scanBack]);

  return { txs, isLoading, isLoadingMore, hasMore, loadMore, error, refetch };
}
