"use client";

import { useReadContracts } from "wagmi";
import { type Address } from "viem";
import { POOL_ABI, TOKEN_META } from "@/lib/contracts";
import { PRIMARY_CHAIN_ID } from "@/lib/crosschain";
import { type Pool } from "@/lib/mock/data";
import { usePoolVolume24h } from "@/lib/hooks/usePoolVolume24h";

const WAD = 1e18;

/** `withVolume` also loads the pool's 24h swap volume: one subgraph query
 *  where the pool is indexed, otherwise a log scan over the last day. Off by
 *  default so pages that don't show volume don't pay for it. */
export function usePool(
  poolAddress: Address,
  opts: { withVolume?: boolean; chainId?: number } = {}
) {
  // Every read is pinned to the pool's OWN chain. Hardcoding one chain here
  // meant a pool address from a different deployment was queried against the
  // wrong RPC and silently came back empty.
  const chainId = opts.chainId ?? PRIMARY_CHAIN_ID;
  // Step 1: static pool scalars
  const step1 = useReadContracts({
    contracts: [
      { address: poolAddress, chainId, abi: POOL_ABI, functionName: "N"        },
      { address: poolAddress, chainId, abi: POOL_ABI, functionName: "fee"      },
      { address: poolAddress, chainId, abi: POOL_ABI, functionName: "numTicks" },
      { address: poolAddress, chainId, abi: POOL_ABI, functionName: "slot0"    },
      { address: poolAddress, chainId, abi: POOL_ABI, functionName: "virtualReserve" },
    ],
  });

  const n         = Number(step1.data?.[0]?.result ?? 0n);
  const fee       = Number(step1.data?.[1]?.result ?? 0n);
  const numTicks  = Number(step1.data?.[2]?.result ?? 0n);
  const slot0     = step1.data?.[3]?.result as readonly [bigint, bigint, bigint, bigint, bigint] | undefined;
  const virtualReserve = (step1.data?.[4]?.result as bigint | undefined) ?? 0n;

  const ready = n > 0 && numTicks > 0;

  // Step 2: per-asset and per-tick reads
  const step2 = useReadContracts({
    contracts: ready ? [
      ...Array.from({ length: n },        (_, i) => ({ address: poolAddress, chainId, abi: POOL_ABI, functionName: "assetAt"  as const, args: [BigInt(i)] as const })),
      ...Array.from({ length: n },        (_, i) => ({ address: poolAddress, chainId, abi: POOL_ABI, functionName: "reserves" as const, args: [BigInt(i)] as const })),
      ...Array.from({ length: numTicks }, (_, i) => ({ address: poolAddress, chainId, abi: POOL_ABI, functionName: "ticks"    as const, args: [BigInt(i)] as const })),
    ] : [],
    query: { enabled: ready },
  });

  // Parse step2. `step2.data` can be present while individual calls inside the
  // multicall failed, so each entry is checked rather than assumed.
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

  // Every asset address must have resolved before the pool is usable. Without
  // this the unresolved ones all collapse to the "0x" placeholder, which both
  // renders ghost tokens and gives React duplicate keys.
  const addressesResolved = tokenAddrs.length > 0 && tokenAddrs.every(a => a.length === 42);

  const tokens = tokenAddrs.map(addr => {
    const meta = TOKEN_META[addr.toLowerCase()] ?? { symbol: addr.slice(0, 6), name: addr, color: "#888", decimals: 18 };
    return { address: addr, symbol: meta.symbol, name: meta.name, color: meta.color, balance: 0 };
  });

  // The engine quotes on the full (virtual) reserves; the tokens held are
  // those less the virtual floor concentrated liquidity never pays out.
  const reserves = reservesBig.map(b => Number(b > virtualReserve ? b - virtualReserve : 0n) / WAD);
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

  const { volume24h, fees24h } = usePoolVolume24h(poolAddress, fee, opts.withVolume === true);

  const pool: Pool | null = ready && step2.data && addressesResolved ? {
    address: poolAddress,
    chainId,
    name:                tokens.map(t => t.symbol).join(" / "),
    tokens,
    fee,
    rInt,
    reserves,
    reservesVirtual: reservesBig,
    virtualReserve,
    rIntWad: slot0?.[2] ?? 0n,
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
    isLoading: step1.isLoading || step2.isLoading || (ready && !addressesResolved && !step2.isError),
    isError:   step1.isError   || step2.isError,
    refetch:   () => { step1.refetch(); step2.refetch(); },
  };
}
