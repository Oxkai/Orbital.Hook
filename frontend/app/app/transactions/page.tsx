"use client";

import { useState, useRef, useEffect, useCallback } from "react";
import { ArrowSquareOut, ArrowsLeftRight, Plus, Minus, Tray } from "@phosphor-icons/react";
import { color, typography } from "@/constants";
import { useTransactions, type TxType } from "@/lib/hooks/useTransactions";
import { TOKEN_META } from "@/lib/contracts";
import { explorerTxUrl } from "@/lib/wagmi";
import { TokenIcon } from "@/components/app/shared/TokenIcon";

// eslint-disable-next-line @typescript-eslint/no-explicit-any

const TYPE_FILTERS = ["All", "Swap", "Add", "Remove", "Collect"] as const;
type Filter = typeof TYPE_FILTERS[number];

const LBL = {
  fontFamily: typography.caption.family,
  fontSize: typography.caption.size,
  letterSpacing: "0.12em",
  textTransform: "uppercase" as const,
  fontWeight: 500,
};

function body(size: "p1" | "p2" | "p3" | "caption" = "p2", c: string = color.textPrimary) {
  const t = typography[size];
  return {
    fontFamily: t.family,
    fontSize: t.size,
    lineHeight: t.lineHeight,
    letterSpacing: t.letterSpacing,
    color: c,
    fontVariantNumeric: "tabular-nums" as const,
  };
}

function shortAddr(a: string) {
  return a.slice(0, 6) + "…" + a.slice(-4);
}

function timeAgo(unix: number): string {
  if (!unix) return "—";
  const diff = Math.floor(Date.now() / 1000) - unix;
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

// ─── Type pill ────────────────────────────────────────────────────────────────

const TYPE_STYLE: Record<TxType, { color: string; icon: React.ElementType }> = {
  Swap:    { color: "#60A5FA",     icon: ArrowsLeftRight },
  Add:     { color: color.success, icon: Plus },
  Remove:  { color: color.warning, icon: Minus },
  Collect: { color: color.textMuted, icon: Tray },
};

function TypePill({ type }: { type: TxType }) {
  const { color: c, icon: Icon } = TYPE_STYLE[type];
  return (
    <span
      className="inline-flex items-center gap-1.5"
      style={{
        backgroundColor: `${c}1f`,
        color: c,
        fontFamily: typography.caption.family,
        fontSize: "11px",
        fontWeight: 500,
        letterSpacing: "0.04em",
        padding: "4px 10px",
        borderRadius: 999,
        whiteSpace: "nowrap",
        width: "fit-content",
      }}
    >
      <Icon size={11} weight="bold" />
      {type}
    </span>
  );
}

// ─── Filter chip ──────────────────────────────────────────────────────────────

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
          ...body("caption", active ? color.textPrimary : color.textMuted),
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

// ─── Page ─────────────────────────────────────────────────────────────────────

const COLS = "92px 1fr 1fr 1fr 90px 100px 110px";
const COL_HEADERS = ["Type", "From", "Pair", "Amount In", "Amount Out", "Time", "Tx Hash"];

export default function TransactionsPage() {
  const [filter, setFilter] = useState<Filter>("All");
  const scrollRef = useRef<HTMLDivElement>(null);
  const sentinelRef = useRef<HTMLDivElement>(null);

  const { txs, isLoading, isLoadingMore, hasMore, loadMore, error } = useTransactions();

  const visible = filter === "All" ? txs : txs.filter(t => t.type === filter);

  const counts: Record<Filter, number> = {
    All:     txs.length,
    Swap:    txs.filter(t => t.type === "Swap").length,
    Add:     txs.filter(t => t.type === "Add").length,
    Remove:  txs.filter(t => t.type === "Remove").length,
    Collect: txs.filter(t => t.type === "Collect").length,
  };

  const handleIntersect = useCallback((entries: IntersectionObserverEntry[]) => {
    if (entries[0].isIntersecting && hasMore && !isLoadingMore) {
      loadMore();
    }
  }, [hasMore, isLoadingMore, loadMore]);

  useEffect(() => {
    const el = sentinelRef.current;
    if (!el) return;
    const obs = new IntersectionObserver(handleIntersect, { root: scrollRef.current, threshold: 0.1 });
    obs.observe(el);
    return () => obs.disconnect();
  }, [handleIntersect]);

  return (
    <section className="flex-1 flex flex-col py-8 sm:py-10 min-h-0">
        {/* ── Hero ─────────────────────────────────────────────────── */}
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
            {TYPE_FILTERS.map(f => (
              <FilterChip
                key={f}
                active={filter === f}
                count={counts[f]}
                onClick={() => setFilter(f)}
              >
                {f}
              </FilterChip>
            ))}
          </div>
        </header>

        {/* ── Table ────────────────────────────────────────────────── */}
        <div ref={scrollRef} className="flex-1 min-h-0">
          <div className="flex flex-col gap-px">
            {/* Column headers: desktop */}
            <div
              className="hidden md:grid items-center px-5 py-2.5"
              style={{
                backgroundColor: color.surface1,
                gridTemplateColumns: COLS,
              }}
            >
              {COL_HEADERS.map((h, i) => (
                <span
                  key={h}
                  style={{
                    ...LBL,
                    color: color.textMuted,
                    textAlign: i === COL_HEADERS.length - 1 ? "right" : "left",
                  }}
                >
                  {h}
                </span>
              ))}
            </div>

            {isLoading && (
              <div
                className="flex items-center justify-center py-16"
                style={{ backgroundColor: color.surface1 }}
              >
                <span style={body("p3", color.textMuted)}>Loading latest transactions…</span>
              </div>
            )}

            {error && !isLoading && (
              <div
                className="flex items-center justify-center py-16"
                style={{ backgroundColor: color.surface1 }}
              >
                <span style={body("p3", color.warning)}>{error}</span>
              </div>
            )}

            {!isLoading && !error && visible.length === 0 && (
              <div
                className="flex items-center justify-center py-16"
                style={{ backgroundColor: color.surface1 }}
              >
                <span style={body("p3", color.textMuted)}>No transactions found</span>
              </div>
            )}

            {!isLoading && visible.map((tx) => {
              const inSym  = tx.amountIn.split(" ")[1] ?? "";
              const inAmt  = tx.amountIn.split(" ")[0] ?? tx.amountIn;
              const outSym = tx.amountOut?.split(" ")[1] ?? "";
              const outAmt = tx.amountOut?.split(" ")[0] ?? "";

              return (
                <div
                  key={`${tx.hash}-${tx.blockNumber}`}
                  className="hover:bg-(--color-surface-2) transition-colors"
                  style={{ backgroundColor: color.surface1 }}
                >
                  {/* ── Desktop row ── */}
                  <div
                    className="hidden md:grid items-center px-5 py-3"
                    style={{ gridTemplateColumns: COLS }}
                  >
                    <TypePill type={tx.type} />

                    <span style={{ ...body("p3", color.textSecondary), overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", paddingRight: 12 }}>
                      {shortAddr(tx.actor)}
                    </span>

                    <div className="flex items-center gap-1.5 min-w-0" style={{ paddingRight: 12 }}>
                      {outSym ? (
                        <>
                          <TokenIcon symbol={inSym} size={14} />
                          <span style={body("caption", color.textSecondary)}>{inSym}</span>
                          <span style={body("caption", color.textMuted)}>→</span>
                          <TokenIcon symbol={outSym} size={14} />
                          <span style={body("caption", color.textSecondary)}>{outSym}</span>
                        </>
                      ) : (
                        <span style={body("caption", color.textMuted)}>—</span>
                      )}
                    </div>

                    <span style={{ ...body("p3", color.textPrimary), overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", paddingRight: 12 }}>
                      {inAmt}
                    </span>

                    <span style={{ ...body("p3", outSym ? color.success : color.textMuted), overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                      {outSym ? outAmt : "—"}
                    </span>

                    <span
                      style={body("caption", color.textMuted)}
                      title={tx.timestamp ? new Date(tx.timestamp * 1000).toLocaleString() : ""}
                      suppressHydrationWarning
                    >
                      {timeAgo(tx.timestamp)}
                    </span>

                    <a
                      href={explorerTxUrl(tx.hash)}
                      target="_blank"
                      rel="noreferrer"
                      className="inline-flex items-center justify-end gap-1.5 hover:opacity-100 opacity-70 transition-opacity"
                      style={body("caption", color.textMuted)}
                    >
                      {tx.hash.slice(0, 8)}…{tx.hash.slice(-4)}
                      <ArrowSquareOut size={11} weight="regular" />
                    </a>
                  </div>

                  {/* ── Mobile card ── */}
                  <div className="md:hidden px-5 py-4 flex flex-col gap-2.5">
                    <div className="flex items-center justify-between">
                      <TypePill type={tx.type} />
                      <span style={body("caption", color.textMuted)} suppressHydrationWarning>
                        {timeAgo(tx.timestamp)}
                      </span>
                    </div>

                    {outSym ? (
                      <div className="flex items-center gap-2 flex-wrap">
                        <TokenIcon symbol={inSym} size={16} />
                        <span style={body("p2", color.textPrimary)}>{inAmt}</span>
                        <span style={body("caption", color.textMuted)}>{inSym}</span>
                        <span style={body("caption", color.textMuted)}>→</span>
                        <TokenIcon symbol={outSym} size={16} />
                        <span style={body("p2", color.success)}>{outAmt}</span>
                        <span style={body("caption", color.textMuted)}>{outSym}</span>
                      </div>
                    ) : (
                      <span style={body("p2", color.textPrimary)}>{tx.amountIn}</span>
                    )}

                    <div className="flex items-center justify-between">
                      <span style={body("caption", color.textMuted)}>
                        From {shortAddr(tx.actor)}
                      </span>
                      <a
                        href={explorerTxUrl(tx.hash)}
                        target="_blank"
                        rel="noreferrer"
                        className="inline-flex items-center gap-1"
                        style={body("caption", color.textMuted)}
                      >
                        {tx.hash.slice(0, 8)}…
                        <ArrowSquareOut size={11} weight="regular" />
                      </a>
                    </div>
                  </div>
                </div>
              );
            })}

            {/* Sentinel for infinite scroll */}
            <div
              ref={sentinelRef}
              className="flex items-center justify-center py-4"
              style={{ backgroundColor: color.surface1 }}
            >
              {isLoadingMore && (
                <span style={body("caption", color.textMuted)}>Loading more…</span>
              )}
              {!isLoading && !isLoadingMore && !hasMore && txs.length > 0 && (
                <span style={body("caption", color.textMuted)}>All transactions loaded</span>
              )}
            </div>
          </div>
        </div>
    </section>
  );
}
