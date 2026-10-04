"use client";

import { useReadContract, useReadContracts, type Config } from "wagmi";
import { readContract, readContracts } from "wagmi/actions";
import { type Address } from "viem";

import { POOL_ABI } from "@/lib/contracts";
import { explainPoolError } from "@/lib/poolErrors";

/** Radius the hook is asked to price; deposits scale linearly from it. */
const PROBE_R = 10n ** 24n;

export interface DepositQuote {
  /** Radius to mint so the deposit is worth the requested value. */
  rWad: bigint;
  /** Per-asset deposit in the engine's WAD value units. */
  amountsWad: bigint[];
  /** Per-asset deposit in each token's raw units, rounded up as the hook pulls. */
  amountsRaw: bigint[];
  /** Why the pool would refuse this mint, if it would. */
  error?: string;
  loading: boolean;
}

/** Quote a deposit worth `valueWad` (engine value units: USD) into `band`
 *  (an index into the hook's band menu, see `lib/bands.ts`).
 *
 *  The hook is the single source of truth: `depositAmounts(band, r)` returns
 *  the exact real deposit (the position's share of the pool less its virtual
 *  part), and since that is linear in r, one probe gives the radius that
 *  deposits exactly the requested value. It also reverts where the mint would
 *  (the pool has already left the band, or the band is pinned), which
 *  surfaces here as `error`. With `valueWad` 0 it still reports that. */
export function useDepositQuote(
  pool: Address,
  chainId: number,
  n: number,
  band: number,
  valueWad: bigint,
  enabled: boolean,
): DepositQuote {
  const active = enabled && n > 0;

  const probe = useReadContract({
    address: pool,
    chainId,
    abi: POOL_ABI,
    functionName: "depositAmounts",
    args: [BigInt(band), PROBE_R],
    query: { enabled: active },
  });
  const scales = useReadContracts({
    contracts: Array.from({ length: n }, (_, i) => ({
      address: pool,
      chainId,
      abi: POOL_ABI,
      functionName: "scaleOf" as const,
      args: [i] as const,
    })),
    query: { enabled: active },
  });

  const sizing = sizeDeposit(
    probe.data as readonly bigint[] | undefined,
    scales.data?.map((r) => r.result as bigint | undefined) ?? [],
    valueWad,
  );
  return {
    ...sizing,
    error: probe.error ? (explainPoolError(probe.error) ?? REFUSED) : undefined,
    loading: active && (probe.isLoading || scales.isLoading),
  };
}

const REFUSED = "This position can't be opened right now.";

/** Same quote as `useDepositQuote`, fetched on demand (for flows where the
 *  amount is only known on submit). */
export async function fetchDepositQuote(
  config: Config,
  args: { pool: Address; chainId: number; n: number; band: number; valueWad: bigint },
): Promise<DepositQuote> {
  const { pool, chainId, n, band, valueWad } = args;
  try {
    const [perProbe, scales] = await Promise.all([
      readContract(config, {
        address: pool,
        chainId,
        abi: POOL_ABI,
        functionName: "depositAmounts",
        args: [BigInt(band), PROBE_R],
      }),
      readContracts(config, {
        contracts: Array.from({ length: n }, (_, i) => ({
          address: pool,
          chainId,
          abi: POOL_ABI,
          functionName: "scaleOf" as const,
          args: [i] as const,
        })),
      }),
    ]);
    return { ...sizeDeposit(perProbe, scales.map((r) => r.result as bigint | undefined), valueWad), loading: false };
  } catch (e) {
    return { rWad: 0n, amountsWad: [], amountsRaw: [], error: explainPoolError(e) ?? REFUSED, loading: false };
  }
}

/** Scale the probe quote to the radius that deposits `valueWad`, and convert
 *  each asset's deposit to raw units (rounded up, as the hook pulls). */
function sizeDeposit(
  perProbe: readonly bigint[] | undefined,
  scales: readonly (bigint | undefined)[],
  valueWad: bigint,
) {
  const total = perProbe?.reduce((a, b) => a + b, 0n) ?? 0n;
  const rWad = total > 0n ? (PROBE_R * valueWad) / total : 0n;
  const amountsWad = perProbe ? perProbe.map((a) => (a * rWad) / PROBE_R) : [];
  const amountsRaw = amountsWad.map((a, i) => {
    const s = scales[i];
    return s && s > 0n ? (a + s - 1n) / s : 0n;
  });
  return { rWad, amountsWad, amountsRaw };
}
