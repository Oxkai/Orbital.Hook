"use client";

import { useReadContracts } from "wagmi";
import { type Address } from "viem";
import { POOL_ABI, TOKEN_META } from "@/lib/contracts";
import { type Pool } from "@/lib/mock/data";
import { useVolume24h } from "@/lib/hooks/useVolume24h";

const WAD = 1e18;

export function usePool(poolAddress: Address) {
  // Step 1 — static pool scalars
  const step1 = useReadContracts({
    contracts: [
      { address: poolAddress, abi: POOL_ABI, functionName: "N"        },
      { address: poolAddress, abi: POOL_ABI, functionName: "fee"      },
      { address: poolAddress, abi: POOL_ABI, functionName: "numTicks" },
      { address: poolAddress, abi: POOL_ABI, functionName: "slot0"    },
    ],
  });

  const n         = Number(step1.data?.[0]?.result ?? 0n);
  const fee       = Number(step1.data?.[1]?.result ?? 0n);
  const numTicks  = Number(step1.data?.[2]?.result ?? 0n);
  const slot0     = step1.data?.[3]?.result as readonly [bigint, bigint, bigint, bigint, bigint] | undefined;

  const ready = n > 0 && numTicks > 0;

  // Step 2 — per-asset and per-tick reads
  const step2 = useReadContracts({
    contracts: ready ? [
      ...Array.from({ length: n },        (_, i) => ({ address: poolAddress, abi: POOL_ABI, functionName: "assetAt"  as const, args: [BigInt(i)] as const })),
      ...Array.from({ length: n },        (_, i) => ({ address: poolAddress, abi: POOL_ABI, functionName: "reserves" as const, args: [BigInt(i)] as const })),
      ...Array.from({ length: numTicks }, (_, i) => ({ address: poolAddress, abi: POOL_ABI, functionName: "ticks"    as const, args: [BigInt(i)] as const })),
    ] : [],
    query: { enabled: ready },
  });

  // Parse step2
  const tokenAddrs = Array.from({ length: n }, (_, i) =>
    (step2.data?.[i]?.result as Address | undefined) ?? ("0x" as Address)
  );
  const reservesBig = Array.from({ length: n }, (_, i) =>
    (step2.data?.[n + i]?.result as bigint | undefined) ?? 0n
  );
  const ticksRaw = Array.from({ length: numTicks }, (_, i) => {
    const r = step2.data?.[2 * n + i]?.result as readonly [bigint, bigint, boolean, bigint, bigint] | undefined;
    return r;
  });

  const tokens = tokenAddrs.map(addr => {
    const meta = TOKEN_META[addr.toLowerCase()] ?? { symbol: addr.slice(0, 6), name: addr, color: "#888", decimals: 18 };
    return { address: addr, symbol: meta.symbol, name: meta.name, color: meta.color, balance: 0 };
  });

  const reserves = reservesBig.map(b => Number(b) / WAD);
  const tvl      = reserves.reduce((a, b) => a + b, 0);

  const ticks = ticksRaw.map(t => ({
    kWad:             t?.[0] ?? 0n,
    r:                Number(t?.[1] ?? 0n) / WAD,
    isInterior:       t?.[2] ?? true,
    feeGrowthInside:  t?.[3] ?? 0n,
    liquidityGross:   t?.[4] ?? 0n,
    // compat fields expected by existing components
    depegPrice:       0,
    capitalEfficiency:0,
  }));

  const kBound = Number(slot0?.[3] ?? 0n);
  const rInt   = Number(slot0?.[2] ?? 0n) / WAD;
  const sumX   = slot0?.[0] ?? 0n;

  const { volume24h, fees24h } = useVolume24h(fee);

  const pool: Pool | null = ready && step2.data ? {
    address:             poolAddress,
    name:                tokens.map(t => t.symbol).join(" / "),
    tokens,
    fee,
    rInt,
    reserves,
    ticks,
    tvl,
    volume24h,
    fees24h,
    kBound,
    sumX,
    depeggedTokenIndices: (() => {
      if (kBound === 0 || reserves.length === 0) return [];
      const mean = reserves.reduce((a, b) => a + b, 0) / reserves.length;
      // A token is depegged if its reserve has dropped to less than 10% of the mean
      return reserves
        .map((r, i) => (mean > 0 && r < mean * 0.1 ? i : -1))
        .filter(i => i >= 0);
    })(),
  } : null;

  return {
    pool,
    isLoading: step1.isLoading || step2.isLoading,
    isError:   step1.isError   || step2.isError,
    refetch:   () => { step1.refetch(); step2.refetch(); },
  };
}
