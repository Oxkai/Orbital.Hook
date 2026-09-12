"use client";

import { color, typography } from "@/constants";
import { PoolCard } from "@/components/app/pools/PoolCard";
import { usePool } from "@/lib/hooks/usePool";
import { ALL_POOLS } from "@/lib/crosschain";

export default function PoolsPage() {
  // One card per DEPLOYMENT.
  //
  // Within a chain, Orbital really is a single N-asset book that many LPs share
  // through ticks, which is why there is one card per chain and not one per
  // pair. Across chains it is not: each chain has its own OrbitalHook holding
  // its own reserves. The cross-chain settlers move orders between them, they
  // do not merge the books. Arc makes that plainest, since it has no relay at
  // all and its liquidity is reachable only from Arc.
  //
  // Showing only the primary chain hid three live deployments and understated
  // total liquidity by the whole of Base, Arbitrum and Arc.
  //
  // ALL_POOLS is a module constant, so this array's length never changes
  // between renders and calling a hook per entry is safe.
  const poolHooks = ALL_POOLS.map((p) => usePool(p.address, { chainId: p.chainId }));

  const pools = poolHooks.map(p => p.pool).filter(Boolean) as NonNullable<ReturnType<typeof usePool>["pool"]>[];

  // Render whatever has arrived rather than gating on every chain. With four
  // RPCs in play, `some(isLoading)` meant the slowest one blanked the entire
  // page, and a single unreachable endpoint would have hidden three healthy
  // pools behind a spinner. Only an empty result is worth a loading state, and
  // only a total failure is worth an error.
  const isLoading = pools.length === 0 && poolHooks.some(p => p.isLoading);
  const isError   = pools.length === 0 && poolHooks.every(p => p.isError);

  return (
    <section className="flex-1 flex flex-col py-8 sm:py-10">
      {/* ── Hero ─────────────────────────────────────────────────── */}
      <header className="flex flex-col gap-1.5 mb-7">
        <h1
          style={{
            fontFamily: typography.h2.family,
            fontSize: typography.h2.size,
            lineHeight: typography.h2.lineHeight,
            letterSpacing: typography.h2.letterSpacing,
            fontWeight: 500,
            color: color.textPrimary,
          }}
        >
          Pools
        </h1>
        <p
          style={{
            fontFamily: typography.p2.family,
            fontSize: typography.p2.size,
            color: color.textMuted,
            lineHeight: typography.p2.lineHeight,
          }}
        >
          Multi-asset stable liquidity pools with capital-efficient ticks.
        </p>
      </header>

        {/* ── List ─────────────────────────────────────────────────── */}
        {isLoading && (
          <div
            className="py-20 text-center"
            style={{
              fontFamily: typography.p3.family,
              fontSize: typography.p3.size,
              color: color.textMuted,
            }}
          >
            Fetching on-chain data…
          </div>
        )}

        {isError && !isLoading && (
          <div
            className="py-20 text-center"
            style={{
              fontFamily: typography.p3.family,
              fontSize: typography.p3.size,
              color: color.error,
            }}
          >
            Failed to load pool data. Check RPC connection.
          </div>
        )}

        {!isLoading && !isError && (
          <div className="flex flex-col gap-3">
            {/* Address alone is not unique across chains; key on both. */}
            {pools.map(p => (
              <PoolCard key={`${p.chainId}:${p.address}`} pool={p} />
            ))}
          </div>
        )}
    </section>
  );
}
