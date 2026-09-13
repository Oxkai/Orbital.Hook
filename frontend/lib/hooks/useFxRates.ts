"use client";

import { useEffect, useMemo, useState } from "react";
import { useReadContracts } from "wagmi";

import { AGGREGATOR_V3_ABI, FX_HOOK_ABI, deviationBps, feedToNumber, fxAssetsByIndex, type FxAsset, type FxPool } from "@/lib/fx";

export interface FxRate {
  asset: FxAsset;
  /// Feed rate in USD per token; undefined while loading or if the read failed.
  market?: number;
  /// Pool price relative to the feed, in signed bps; undefined if the hook's
  /// oracle checks fail (stale or invalid feed).
  poolVsMarketBps?: number;
  /// Seconds since the feed last updated.
  ageSeconds?: number;
}

export type FxStatus = "live" | "stale" | "paused" | "loading";

/// Live oracle state of an FX pool: each priced asset's feed rate, how far the
/// pool sits from it, feed age, and whether swaps can run. Numeraire assets
/// (exactly $1) have nothing to report and are omitted.
export function useFxRates(pool: FxPool) {
  const priced = useMemo(() => fxAssetsByIndex(pool).filter((a) => a.feed !== null), [pool]);
  const numeraire = useMemo(() => fxAssetsByIndex(pool).find((a) => a.feed === null), [pool]);

  // Ages are computed against a clock that ticks, not the render time, so a
  // feed visibly ages between polls.
  const [now, setNow] = useState(() => Date.now() / 1000);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now() / 1000), 30_000);
    return () => clearInterval(t);
  }, []);

  const poll = { refetchInterval: 15_000 };

  // Homogeneous reads rather than one mixed list, so each stays fully typed.
  // Every call may fail independently (`priceDeviation` reverts whenever the
  // oracle fails a check) without blanking the rest.
  const params = useReadContracts({
    allowFailure: true,
    contracts: [
      { chainId: pool.chainId, address: pool.hook, abi: FX_HOOK_ABI, functionName: "maxPriceAge" },
      { chainId: pool.chainId, address: pool.hook, abi: FX_HOOK_ABI, functionName: "maxDeviationBps" },
      { chainId: pool.chainId, address: pool.hook, abi: FX_HOOK_ABI, functionName: "paused" },
    ] as const,
    query: poll,
  });
  const rounds = useReadContracts({
    allowFailure: true,
    contracts: priced.map((a) => ({
      chainId: pool.chainId,
      address: a.feed!,
      abi: AGGREGATOR_V3_ABI,
      functionName: "latestRoundData" as const,
    })),
    query: poll,
  });
  const feedDecimals = useReadContracts({
    allowFailure: true,
    contracts: priced.map((a) => ({
      chainId: pool.chainId,
      address: a.feed!,
      abi: AGGREGATOR_V3_ABI,
      functionName: "decimals" as const,
    })),
  });
  const deviations = useReadContracts({
    allowFailure: true,
    contracts: priced.map((a) => ({
      chainId: pool.chainId,
      address: pool.hook,
      abi: FX_HOOK_ABI,
      functionName: "priceDeviation" as const,
      args: [numeraire?.index ?? 0, a.index] as const,
    })),
    query: { ...poll, enabled: numeraire !== undefined },
  });

  const [ageRead, bandRead, pausedRead] = params.data ?? [];
  const maxAgeSeconds = ageRead?.status === "success" ? Number(ageRead.result) : undefined;
  const bandBps = bandRead?.status === "success" ? Number(bandRead.result) : undefined;
  const paused = pausedRead?.status === "success" ? pausedRead.result : undefined;

  const rates: FxRate[] = priced.map((asset, k) => {
    const rd = rounds.data?.[k];
    const dc = feedDecimals.data?.[k];
    const dv = deviations.data?.[k];
    const round = rd?.status === "success" ? rd.result : undefined;
    const decimals = dc?.status === "success" ? dc.result : undefined;
    return {
      asset,
      market: round && decimals !== undefined ? feedToNumber(round[1], decimals) : undefined,
      poolVsMarketBps: dv?.status === "success" ? deviationBps(dv.result) : undefined,
      ageSeconds: round ? Math.max(0, now - Number(round[3])) : undefined,
    };
  });

  const stalest = Math.max(0, ...rates.map((r) => r.ageSeconds ?? 0));
  let status: FxStatus;
  if (paused === undefined || maxAgeSeconds === undefined) status = "loading";
  else if (paused) status = "paused";
  else if (stalest > maxAgeSeconds) status = "stale";
  else status = "live";

  return { rates, status, bandBps, maxAgeSeconds };
}

/// Compact age: "12m", "23h", "1.5d".
export function ageLabel(seconds: number): string {
  if (seconds < 3600) return `${Math.max(0, Math.floor(seconds / 60))}m`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h`;
  return `${(seconds / 86_400).toFixed(1)}d`;
}
