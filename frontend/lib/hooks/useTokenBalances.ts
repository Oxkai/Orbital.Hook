"use client";

import { useReadContracts } from "wagmi";
import { type Address } from "viem";
import { ERC20_ABI } from "@/lib/contracts";
import { PRIMARY_CHAIN_ID } from "@/lib/crosschain";

const WAD = 10n ** 18n;

function wadToNumber(raw: bigint): number {
  // Divide bigint first to avoid float precision loss on large values
  return Number(raw / WAD) + Number(raw % WAD) / 1e18;
}

// Module scope, not a ref: a ref dies with the component, so every route
// change wiped the cache and balances flashed back to 0 until the reads
// landed again. Keyed by account so switching wallets can't show stale values.
const lastGood: Record<string, number> = {};
const key = (account: string | undefined, token: string) =>
  `${(account ?? "0x").toLowerCase()}:${token.toLowerCase()}`;

export function useTokenBalances(tokenAddresses: Address[], account: Address | undefined, chainId: number = PRIMARY_CHAIN_ID) {
  const { data, isLoading, refetch } = useReadContracts({
    contracts: tokenAddresses.map(addr => ({
      address: addr,
      chainId,
      abi: ERC20_ABI,
      functionName: "balanceOf" as const,
      args: [account ?? "0x0000000000000000000000000000000000000000"] as const,
    })),
    query: { enabled: !!account && tokenAddresses.length > 0 },
  });

  // A failed read is not a zero balance. The public RPC drops calls under load,
  // and rendering 0 both misleads and disables the swap button: so the last
  // value that actually resolved is retained until a fresh one arrives.
  let anyResolved = false;

  const balances = tokenAddresses.map((addr, i) => {
    const raw = data?.[i]?.result as bigint | undefined;
    const k = key(account, addr);
    if (raw !== undefined) {
      anyResolved = true;
      const v = wadToNumber(raw);
      lastGood[k] = v;
      return v;
    }
    return lastGood[k] ?? 0;
  });

  // True once every requested balance has resolved at least once, so callers
  // can tell "still loading" apart from "genuinely holds nothing".
  const isReady =
    tokenAddresses.length > 0 &&
    tokenAddresses.every(a => lastGood[key(account, a)] !== undefined);

  return { balances, isLoading, isReady, anyResolved, refetch };
}

export function useTokenAllowances(
  tokenAddresses: Address[],
  owner: Address | undefined,
  spender: Address,
  chainId: number = PRIMARY_CHAIN_ID
) {
  const { data, isLoading, refetch } = useReadContracts({
    contracts: tokenAddresses.map(addr => ({
      address: addr,
      chainId,
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
