"use client";

import { useReadContracts, useSimulateContract } from "wagmi";
import { type Address, maxUint256, zeroAddress } from "viem";
import { HOOK_LP_ABI, POOL_ABI } from "@/lib/contracts";
import { ALL_POOLS } from "@/lib/crosschain";

export type OnChainPosition = {
  /// ERC-6909 share id, which is the band (see lib/bands.ts): every deposit an
  /// account makes into one band is one position. Unique only WITHIN a pool,
  /// so identity is (poolAddress, tokenId).
  tokenId: bigint;
  poolAddress: Address;
  chainId: number;
  tickIndex: number;
  kWad: bigint;
  rWad: bigint; // current ERC-6909 share balance
};

const WAD = 1e18;

/// The account's positions across EVERY pool, of either type.
///
/// Positions are soulbound ERC-6909 shares with tokenId == band. Rather than
/// scan Mint events (public RPCs cap getLogs ranges), read each pool's band
/// count, then the account's share balance in every band. Each read carries its
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
    const tick = ticks.data?.[i]?.result as readonly [bigint, bigint, boolean] | undefined;
    return [
      {
        tokenId: BigInt(s.tick),
        poolAddress: s.pool.address,
        chainId: s.pool.chainId,
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

export type HeldPayout = {
  poolAddress: Address;
  chainId: number;
  asset: number;
  token: Address;
  /** Raw token units. */
  amount: bigint;
};

/// Payouts each pool held back for `account` because the token could not be
/// transferred at the time (its issuer paused it, or froze the account or the
/// PoolManager). They stay the account's until claimed with `claimOwed`.
export function useHeldPayouts(account: Address | undefined) {
  const counts = useReadContracts({
    contracts: ALL_POOLS.map((p) => ({
      address: p.address,
      chainId: p.chainId,
      abi: POOL_ABI,
      functionName: "N" as const,
    })),
  });

  const slots = ALL_POOLS.flatMap((pool, pi) => {
    const r = counts.data?.[pi];
    const n = r?.status === "success" ? Number(r.result) : 0;
    return Array.from({ length: n }, (_, asset) => ({ pool, asset }));
  });

  const reads = useReadContracts({
    contracts: slots.flatMap((s) => [
      {
        address: s.pool.address,
        chainId: s.pool.chainId,
        abi: HOOK_LP_ABI,
        functionName: "owed" as const,
        args: [account ?? zeroAddress, s.asset] as const,
      },
      {
        address: s.pool.address,
        chainId: s.pool.chainId,
        abi: POOL_ABI,
        functionName: "assetAt" as const,
        args: [s.asset] as const,
      },
    ]),
    query: { enabled: slots.length > 0 && !!account },
  });

  const held: HeldPayout[] = slots.flatMap((s, i) => {
    const amount = reads.data?.[2 * i]?.result as bigint | undefined;
    const token = reads.data?.[2 * i + 1]?.result as Address | undefined;
    if (!amount || !token) return [];
    return [{ poolAddress: s.pool.address, chainId: s.pool.chainId, asset: s.asset, token, amount }];
  });

  return {
    held,
    refetch: () => {
      counts.refetch();
      reads.refetch();
    },
  };
}

/// Tick state for one position's band, read from the position's own chain.
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
    ],
    query: { enabled },
  });

  const raw = data?.[0]?.result as readonly [bigint, bigint, boolean] | undefined;
  return {
    kWad: raw?.[0] ?? 0n,
    rWad: raw?.[1] ?? 0n,
    isInterior: raw?.[2] ?? true,
  };
}

/// What withdrawing `rWad` of `owner`'s position in `band` pays right now:
/// per asset (WAD, the engine's USD value units) and in total.
///
/// This is the hook's own `removeLiquidity` simulated for the owner, so it is
/// exact in every state the burn handles: an active band is paid its share of
/// the interior reserves, and a band pinned by a depeg its boundary holding.
/// No pro-rata estimate gets the pinned case right.
export function usePositionValue(
  poolAddress: Address,
  chainId: number,
  band: number,
  n: number,
  owner: Address | undefined,
  rWad: bigint,
  enabled = true,
) {
  const sim = useSimulateContract({
    address: poolAddress,
    chainId,
    abi: HOOK_LP_ABI,
    functionName: "removeLiquidity",
    args: [BigInt(band), rWad, Array<bigint>(n).fill(0n), maxUint256],
    account: owner,
    query: { enabled: enabled && !!owner && rWad > 0n && n > 0 },
  });
  const amountsWad = (sim.data?.result as readonly bigint[] | undefined) ?? [];
  return {
    amountsWad,
    valueWad: amountsWad.reduce((a, b) => a + b, 0n),
    refetch: sim.refetch,
  };
}

export function fmtWad(n: bigint): string {
  const v = Number(n) / WAD;
  if (v >= 1_000_000) return "$" + (v / 1_000_000).toFixed(2) + "M";
  if (v >= 1_000) return "$" + (v / 1_000).toFixed(1) + "K";
  return "$" + v.toFixed(2);
}
