"use client";

import { useReadContract, useReadContracts } from "wagmi";
import { type Address } from "viem";
import { HOOK_ADDRESS, HOOK_LP_ABI, POOL_ABI } from "@/lib/contracts";

export type OnChainPosition = {
  tokenId: bigint; // == tickIdx (ERC-6909 share id)
  poolAddress: Address;
  tickIndex: number;
  kWad: bigint;
  rWad: bigint; // current ERC-6909 share balance
};

const WAD = 1e18;

// Positions are soulbound ERC-6909 shares with tokenId == tickIdx. Rather than
// scan Mint events (the public RPC caps getLogs at 100 blocks), we read
// the hook's tick count and check the account's share balance at each tick.
export function usePositions(account: Address | undefined) {
  const { data: numTicksData } = useReadContract({
    address: HOOK_ADDRESS,
    abi: POOL_ABI,
    functionName: "numTicks",
  });
  const numTicks = Number(numTicksData ?? 0n);

  const balanceReads = useReadContracts({
    contracts: Array.from({ length: numTicks }, (_, i) => ({
      address: HOOK_ADDRESS,
      abi: HOOK_LP_ABI,
      functionName: "balanceOf" as const,
      args: [account ?? "0x0000000000000000000000000000000000000000", BigInt(i)] as const,
    })),
    query: { enabled: numTicks > 0 && !!account },
  });

  const tickReads = useReadContracts({
    contracts: Array.from({ length: numTicks }, (_, i) => ({
      address: HOOK_ADDRESS,
      abi: POOL_ABI,
      functionName: "ticks" as const,
      args: [BigInt(i)] as const,
    })),
    query: { enabled: numTicks > 0 },
  });

  const positions: OnChainPosition[] = Array.from({ length: numTicks }, (_, i) => {
    const bal = balanceReads.data?.[i]?.result as bigint | undefined;
    if (!bal || bal === 0n) return null;
    const tick = tickReads.data?.[i]?.result as readonly [bigint, bigint, boolean, bigint, bigint] | undefined;
    return {
      tokenId: BigInt(i),
      poolAddress: HOOK_ADDRESS,
      tickIndex: i,
      kWad: tick?.[0] ?? 0n,
      rWad: bal,
    };
  }).filter(Boolean) as OnChainPosition[];

  return {
    positions,
    isLoading: balanceReads.isLoading || tickReads.isLoading,
    refetch: () => {
      balanceReads.refetch();
      tickReads.refetch();
    },
  };
}

// Read tick isInterior for a given pool + tickIndex.
export function useTickStatus(poolAddress: Address, tickIndex: number, enabled = true) {
  const { data } = useReadContracts({
    contracts: [
      {
        address: poolAddress,
        abi: POOL_ABI,
        functionName: "ticks" as const,
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
  };
}

export function fmtWad(n: bigint): string {
  const v = Number(n) / WAD;
  if (v >= 1_000_000) return "$" + (v / 1_000_000).toFixed(2) + "M";
  if (v >= 1_000) return "$" + (v / 1_000).toFixed(1) + "K";
  return "$" + v.toFixed(2);
}
