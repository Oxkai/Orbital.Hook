"use client";

import { useReadContracts } from "wagmi";
import { type Address, zeroAddress } from "viem";
import { HOOK_LP_ABI, POOL_ABI } from "@/lib/contracts";
import { ALL_POOLS, type PoolType } from "@/lib/crosschain";

export type OnChainPosition = {
  /// ERC-6909 share id, which is the tick index. Unique only WITHIN a pool:
  /// every pool has a tick #0, so identity is (poolAddress, tokenId).
  tokenId: bigint;
  poolAddress: Address;
  chainId: number;
  poolType: PoolType;
  tickIndex: number;
  kWad: bigint;
  rWad: bigint; // current ERC-6909 share balance
};

const WAD = 1e18;

/// The account's positions across EVERY pool, of either type.
///
/// Positions are soulbound ERC-6909 shares with tokenId == tickIdx. Rather than
/// scan Mint events (public RPCs cap getLogs ranges), read each pool's tick
/// count, then the account's share balance at every tick. Each read carries its
/// pool's chain: reading without one queries whatever chain the wallet is on.
export function usePositions(account: Address | undefined) {
  const counts = useReadContracts({
    contracts: ALL_POOLS.map((p) => ({
      address: p.address,
      chainId: p.chainId,
      abi: POOL_ABI,
      functionName: "numTicks" as const,
    })),
  });

  // Every (pool, tick) slot that could hold a position.
  const slots = ALL_POOLS.flatMap((pool, pi) => {
    const r = counts.data?.[pi];
    const n = r?.status === "success" ? Number(r.result) : 0;
    return Array.from({ length: n }, (_, tick) => ({ pool, tick }));
  });

  const balances = useReadContracts({
    contracts: slots.map((s) => ({
      address: s.pool.address,
      chainId: s.pool.chainId,
      abi: HOOK_LP_ABI,
      functionName: "balanceOf" as const,
      args: [account ?? zeroAddress, BigInt(s.tick)] as const,
    })),
    query: { enabled: slots.length > 0 && !!account },
  });

  const ticks = useReadContracts({
    contracts: slots.map((s) => ({
      address: s.pool.address,
      chainId: s.pool.chainId,
      abi: POOL_ABI,
      functionName: "ticks" as const,
      args: [BigInt(s.tick)] as const,
    })),
    query: { enabled: slots.length > 0 },
  });

  const positions: OnChainPosition[] = slots.flatMap((s, i) => {
    const bal = balances.data?.[i]?.result as bigint | undefined;
    if (!bal) return [];
    const tick = ticks.data?.[i]?.result as readonly [bigint, bigint, boolean, bigint, bigint] | undefined;
    return [
      {
        tokenId: BigInt(s.tick),
        poolAddress: s.pool.address,
        chainId: s.pool.chainId,
        poolType: s.pool.type,
        tickIndex: s.tick,
        kWad: tick?.[0] ?? 0n,
        rWad: bal,
      },
    ];
  });

  return {
    positions,
    isLoading: counts.isLoading || balances.isLoading || ticks.isLoading,
    refetch: () => {
      counts.refetch();
      balances.refetch();
      ticks.refetch();
    },
  };
}

/// Tick state for one position, read from the position's own chain.
export function useTickStatus(poolAddress: Address, tickIndex: number, chainId: number, enabled = true) {
  const { data } = useReadContracts({
    contracts: [
      {
        address: poolAddress,
        chainId,
        abi: POOL_ABI,
        functionName: "ticks" as const,
        args: [BigInt(tickIndex)] as const,
      },
      {
        address: poolAddress,
        chainId,
        abi: POOL_ABI,
        functionName: "tickVirtual" as const,
        args: [BigInt(tickIndex)] as const,
      },
    ],
    query: { enabled },
  });

  const raw = data?.[0]?.result as readonly [bigint, bigint, boolean, bigint, bigint] | undefined;
  return {
    kWad: raw?.[0] ?? 0n,
    rWad: raw?.[1] ?? 0n,
    isInterior: raw?.[2] ?? true,
    /** Per-asset virtual reserve of the whole tick, WAD. */
    virtualWad: (data?.[1]?.result as bigint | undefined) ?? 0n,
  };
}

export function fmtWad(n: bigint): string {
  const v = Number(n) / WAD;
  if (v >= 1_000_000) return "$" + (v / 1_000_000).toFixed(2) + "M";
  if (v >= 1_000) return "$" + (v / 1_000).toFixed(1) + "K";
  return "$" + v.toFixed(2);
}
