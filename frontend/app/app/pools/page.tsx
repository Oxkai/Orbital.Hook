"use client";

import { color, typography } from "@/constants";
import { PoolCard } from "@/components/app/pools/PoolCard";
import { usePool } from "@/lib/hooks/usePool";
import { POOL_ADDRESS, PRIMARY_CHAIN } from "@/lib/contracts";

export default function PoolsPage() {
  // ONE pool. Orbital is a single N-asset book that many LPs share through
  // ticks: not several pools. The same engine is deployed on Base and
  // Arbitrum as well, but those exist so cross-chain orders have a settler at
  // each end; they are the same pool, not additional ones, and listing them
  // separately implied liquidity was split three ways when it is not.
  const poolHooks = [usePool(POOL_ADDRESS, { chainId: PRIMARY_CHAIN })];

  const isLoading = poolHooks.some(p => p.isLoading);
  const isError   = poolHooks.every(p => p.isError);
  const pools     = poolHooks.map(p => p.pool).filter(Boolean) as NonNullable<ReturnType<typeof usePool>["pool"]>[];

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
            {pools.map(p => (
              <PoolCard key={p.address} pool={p} />
            ))}
          </div>
        )}
    </section>
  );
}
