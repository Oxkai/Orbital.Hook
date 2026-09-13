"use client";

import { color, typography } from "@/constants";
import { PoolListHeader, PoolRow, PoolRowPlaceholder } from "@/components/app/pools/PoolRow";
import { usePool } from "@/lib/hooks/usePool";
import { ALL_POOLS, type PoolEntry } from "@/lib/crosschain";

/// One row per deployed pool, each loading independently.
///
/// Within a chain, Orbital is a single N-asset book that many LPs share through
/// ticks, which is why there is one row per pool and not one per pair. Across
/// chains it is not: each chain has its own hook holding its own reserves, and
/// the cross-chain settlers move orders between them without merging the books.
///
/// Each row owns its reads, so a slow or unreachable RPC delays only its own
/// row instead of blanking the list.
function PoolListItem({ entry }: { entry: PoolEntry }) {
  const { pool, isError } = usePool(entry.address, { chainId: entry.chainId, withVolume: true });
  if (pool) return <PoolRow pool={pool} />;
  return <PoolRowPlaceholder entry={entry} failed={isError} />;
}

export default function PoolsPage() {
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
          Multi-asset liquidity pools with capital-efficient ticks: stablecoins at parity, and FX pairs at oracle rates.
        </p>
      </header>

      {/* ── List ─────────────────────────────────────────────────── */}
      <div className="flex flex-col">
        <PoolListHeader />
        <div className="flex flex-col gap-px">
          {/* Address alone is not unique across chains; key on both. */}
          {ALL_POOLS.map((p) => (
            <PoolListItem key={`${p.chainId}:${p.address}`} entry={p} />
          ))}
        </div>
      </div>
    </section>
  );
}
