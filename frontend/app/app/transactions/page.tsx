"use client";

import { useState, useRef, useEffect } from "react";
import { color, typography } from "@/constants";
import { useTransactions } from "@/lib/hooks/useTransactions";
import {
  TransactionListHeader,
  TransactionListNotice,
  TransactionRow,
} from "@/components/app/transactions/TransactionRow";

const TYPE_FILTERS = ["All", "Swap", "Add", "Remove", "Collect"] as const;
type Filter = typeof TYPE_FILTERS[number];

function FilterChip({
  active,
  count,
  onClick,
  children,
}: {
  active: boolean;
  count: number;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      className="inline-flex items-center gap-2 px-3 h-9 hover:opacity-90 transition-opacity"
      style={{
        backgroundColor: active ? color.surface2 : color.surface1,
        color: active ? color.textPrimary : color.textMuted,
        fontFamily: typography.p2.family,
        fontSize: typography.p2.size,
        letterSpacing: "-0.01em",
        cursor: "pointer",
        borderRadius: 2,
      }}
    >
      {children}
      <span
        style={{
          fontFamily: typography.caption.family,
          fontSize: typography.caption.size,
          lineHeight: typography.caption.lineHeight,
          fontVariantNumeric: "tabular-nums",
          color: active ? color.textPrimary : color.textMuted,
          backgroundColor: active ? color.surface3 : color.surface2,
          padding: "1px 6px",
          borderRadius: 2,
        }}
      >
        {count}
      </span>
    </button>
  );
}

export default function TransactionsPage() {
  const [filter, setFilter] = useState<Filter>("All");
  const sentinelRef = useRef<HTMLDivElement>(null);

  const { txs, isLoading, isLoadingMore, hasMore, loadMore, error } = useTransactions();

  const visible = filter === "All" ? txs : txs.filter((t) => t.type === filter);

  const counts: Record<Filter, number> = {
    All: txs.length,
    Swap: txs.filter((t) => t.type === "Swap").length,
    Add: txs.filter((t) => t.type === "Add").length,
    Remove: txs.filter((t) => t.type === "Remove").length,
    Collect: txs.filter((t) => t.type === "Collect").length,
  };

  // Infinite scroll against the viewport (the page itself scrolls), asking
  // for the next page a little before the end is reached.
  useEffect(() => {
    const el = sentinelRef.current;
    if (!el) return;
    const obs = new IntersectionObserver(
      (entries) => {
        if (entries[0].isIntersecting && hasMore && !isLoadingMore) loadMore();
      },
      { rootMargin: "600px 0px" }
    );
    obs.observe(el);
    return () => obs.disconnect();
  }, [hasMore, isLoadingMore, loadMore]);

  return (
    <section className="flex-1 flex flex-col pb-8 sm:pb-10">
      {/* ── Title, filters and column labels ─────────────────────────
          Pinned under the nav (h-14) while the list scrolls beneath, on an
          opaque page-colored ground so rows don't show through. Only from md
          up: on a phone it would take half the screen. */}
      <div className="md:sticky md:top-14 z-30 pt-8 sm:pt-10" style={{ backgroundColor: color.bg }}>
        <header className="flex items-end justify-between gap-6 flex-wrap mb-7">
          <div className="flex flex-col gap-1.5 min-w-0">
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
              Transactions
            </h1>
            <p
              style={{
                fontFamily: typography.p2.family,
                fontSize: typography.p2.size,
                color: color.textMuted,
                lineHeight: typography.p2.lineHeight,
              }}
            >
              Live on-chain swap and liquidity activity across all pools.
            </p>
          </div>
          <div className="flex items-center gap-2 flex-wrap">
            {TYPE_FILTERS.map((f) => (
              <FilterChip key={f} active={filter === f} count={counts[f]} onClick={() => setFilter(f)}>
                {f}
              </FilterChip>
            ))}
          </div>
        </header>
        <TransactionListHeader scope="all" />
      </div>

      {/* ── List ─────────────────────────────────────────────────── */}
      <div className="flex flex-col gap-px">
        {isLoading && <TransactionListNotice>Loading latest transactions…</TransactionListNotice>}
        {error && !isLoading && <TransactionListNotice tone="warning">{error}</TransactionListNotice>}
        {!isLoading && !error && visible.length === 0 && <TransactionListNotice>No transactions found</TransactionListNotice>}

        {!isLoading &&
          visible.map((tx) => (
            // One transaction can emit several events; the event id is the identity.
            <TransactionRow key={`${tx.chainId}:${tx.eventId}`} tx={tx} scope="all" />
          ))}

        <div ref={sentinelRef} className="flex items-center justify-center py-4">
          {isLoadingMore && (
            <span style={{ fontFamily: typography.p3.family, fontSize: typography.p3.size, color: color.textMuted }}>
              Loading more…
            </span>
          )}
          {!isLoading && !isLoadingMore && !hasMore && txs.length > 0 && (
            <span style={{ fontFamily: typography.p3.family, fontSize: typography.p3.size, color: color.textMuted }}>
              All transactions loaded
            </span>
          )}
        </div>
      </div>
    </section>
  );
}
