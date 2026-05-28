"use client";

import { useReadContracts } from "wagmi";
import { type Address } from "viem";
import { ERC20_ABI } from "@/lib/contracts";

const WAD = 10n ** 18n;

function wadToNumber(raw: bigint): number {
  // Divide bigint first to avoid float precision loss on large values
  return Number(raw / WAD) + Number(raw % WAD) / 1e18;
}

export function useTokenBalances(tokenAddresses: Address[], account: Address | undefined) {
  const { data, isLoading, refetch } = useReadContracts({
    contracts: tokenAddresses.map(addr => ({
      address: addr,
      abi: ERC20_ABI,
      functionName: "balanceOf" as const,
      args: [account ?? "0x0000000000000000000000000000000000000000"] as const,
    })),
    query: { enabled: !!account && tokenAddresses.length > 0 },
  });

  const balances = tokenAddresses.map((_, i) => {
    const raw = data?.[i]?.result as bigint | undefined;
    return raw !== undefined ? wadToNumber(raw) : 0;
  });

  return { balances, isLoading, refetch };
}

export function useTokenAllowances(
  tokenAddresses: Address[],
  owner: Address | undefined,
  spender: Address,
) {
  const { data, isLoading, refetch } = useReadContracts({
    contracts: tokenAddresses.map(addr => ({
      address: addr,
      abi: ERC20_ABI,
      functionName: "allowance" as const,
      args: [owner ?? "0x0000000000000000000000000000000000000000", spender] as const,
    })),
    query: { enabled: !!owner && tokenAddresses.length > 0 },
  });

  const allowances = tokenAddresses.map((_, i) => {
    const raw = data?.[i]?.result as bigint | undefined;
    return raw ?? 0n;
  });

  return { allowances, isLoading, refetch };
}
