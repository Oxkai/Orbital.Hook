"use client";

import { useState, useCallback, use } from "react";
import Link from "next/link";
import {
  ArrowSquareOut,
  Copy,
  Check,
  Hash,
  CurrencyDollar,
  TrendUp,
  Coins,
  Percent,
  StackSimple,
  Pulse,
  Circle,
} from "@phosphor-icons/react";
import { color, typography } from "@/constants";

import { usePool }   from "@/lib/hooks/usePool";
import { useTransactions, type TxType } from "@/lib/hooks/useTransactions";
import { DepthChart } from "@/components/app/pool/DepthChart";
import { fmtUSD }   from "@/lib/mock/data";
import { type Address } from "viem";
import { explorerAddressUrl, explorerTxUrl } from "@/lib/wagmi";
import { TokenIcon } from "@/components/app/shared/TokenIcon";

const TABS = ["Overview", "Liquidity", "Transactions"] as const;
type Tab = typeof TABS[number];

// Section / kicker label — Roboto caption, uppercase
const LBL = {
  fontFamily: typography.caption.family,
  fontSize: typography.caption.size,
  letterSpacing: "0.12em",
  textTransform: "uppercase" as const,
  fontWeight: 500,
};

// Row body text — Roboto, tabular numerals for clean alignment
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

// Mono — reserved for hashes and on-chain identifiers only
function mono(size = "12px", c: string = color.textPrimary) {
  return {
    fontFamily: "var(--font-mono)" as const,
    fontSize: size,
    color: c,
    fontVariantNumeric: "tabular-nums" as const,
    letterSpacing: "0.02em",
  };
}

// ─── Row primitives ───────────────────────────────────────────────────────────

function SectionLabel({ children, meta }: { children: React.ReactNode; meta?: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-3 px-1 pb-3">
      <span style={{ ...LBL, color: color.textMuted }}>{children}</span>
      {meta}
    </div>
  );
}

function InfoRow({
  icon,
  label,
  children,
}: {
  icon?: React.ReactNode;
  label: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <div
      className="group flex items-center justify-between gap-3 px-5 py-3.5 hover:bg-(--color-surface-2) transition-colors"
      style={{ backgroundColor: color.surface1 }}
    >
      <div className="flex items-center gap-3 min-w-0">
        {icon && (
          <span
            className="flex items-center justify-center shrink-0"
            style={{ width: 16, height: 16, color: color.textMuted }}
          >
            {icon}
          </span>
        )}
        <span
          style={{
            fontFamily: typography.p2.family,
            fontSize: typography.p2.size,
            lineHeight: typography.p2.lineHeight,
            color: color.textSecondary,
            letterSpacing: "-0.005em",
          }}
        >
          {label}
        </span>
      </div>
      <div className="flex items-center gap-2.5 min-w-0">{children}</div>
    </div>
  );
}

function CopyIcon({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  const handleCopy = useCallback((e: React.MouseEvent) => {
    e.stopPropagation();
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  }, [text]);
  return (
    <button
      onClick={handleCopy}
      className="flex items-center justify-center shrink-0 hover:opacity-100 opacity-60"
      style={{ width: 16, height: 16, color: copied ? color.success : color.textMuted, cursor: "pointer", transition: "color 0.15s, opacity 0.15s" }}
      aria-label="Copy"
    >
      {copied ? <Check size={12} /> : <Copy size={12} />}
    </button>
  );
}

function StatusPill({ healthy, label }: { healthy: boolean; label: string }) {
  const c = healthy ? color.success : color.warning;
  return (
    <span
      className="inline-flex items-center gap-1.5"
      style={{
        backgroundColor: `${c}1a`,
        color: c,
        fontFamily: typography.caption.family,
        fontSize: "11px",
        fontWeight: 500,
        letterSpacing: "0.04em",
        padding: "4px 10px",
        borderRadius: 2,
        whiteSpace: "nowrap",
      }}
    >
      <Circle size={6} color={c} weight="fill" />
      {label}
    </span>
  );
}

function HashValue({ value, href }: { value: string; href?: string }) {
  const short = `${value.slice(0, 6)}…${value.slice(-4)}`;
  return (
    <span className="flex items-center gap-2.5">
      <span style={{ ...body("p3", color.textPrimary) }}>{short}</span>
      <CopyIcon text={value} />
      {href && (
        <a
          href={href}
          target="_blank"
          rel="noreferrer"
          className="flex items-center justify-center hover:opacity-100 opacity-60"
          style={{ width: 16, height: 16, color: color.textMuted, transition: "opacity 0.15s" }}
        >
          <ArrowSquareOut size={12} weight="regular" />
        </a>
      )}
    </span>
  );
}

// ─── Overview tab ─────────────────────────────────────────────────────────────

function OverviewTab({ pool }: { pool: NonNullable<ReturnType<typeof usePool>["pool"]> }) {
  const totalReserves = pool.reserves.reduce((a, b) => a + b, 0);
  const boundaryCount = pool.ticks.filter(t => !t.isInterior).length;
  const isHealthy     = boundaryCount === 0;
  const activeTicks   = pool.ticks.length - boundaryCount;
  const explorer      = explorerAddressUrl(pool.address);

  return (
    <div className="flex flex-col gap-8">
      {/* ── Liquidity Depth ────────────────────────────────────── */}
      <div>
        <SectionLabel
          meta={
            <div className="flex items-center gap-4">
              <div className="flex items-center gap-1.5">
                <span
                  style={{
                    width: 14,
                    height: 5,
                    backgroundColor: color.accent,
                    opacity: 0.35,
                    border: `1px solid ${color.accent}40`,
                    display: "inline-block",
                  }}
                />
                <span style={{ ...LBL, color: color.textMuted, letterSpacing: "0.06em" }}>
                  liquidity
                </span>
              </div>
              <div className="flex items-center gap-1.5">
                <span
                  style={{
                    width: 12,
                    borderTop: `1.5px dashed ${color.accent}`,
                    opacity: 0.8,
                    display: "inline-block",
                  }}
                />
                <span style={{ ...LBL, color: color.textMuted, letterSpacing: "0.06em" }}>
                  αNorm
                </span>
              </div>
            </div>
          }
        >
          Liquidity Depth
        </SectionLabel>
        <div style={{ backgroundColor: color.surface1, height: 360 }}>
          <DepthChart
            ticks={pool.ticks}
            n={pool.tokens.length}
            rInt={pool.rInt}
            kBound={pool.kBound}
            sumX={pool.sumX}
          />
        </div>
      </div>

      {/* ── Key metrics ─────────────────────────────────────────── */}
      <div>
        <SectionLabel>Key Metrics</SectionLabel>
        <div className="flex flex-col gap-px">
          <InfoRow icon={<CurrencyDollar size={14} weight="regular" />} label="TVL">
            <span style={body("p2", color.textPrimary)}>{fmtUSD(pool.tvl)}</span>
          </InfoRow>
          <InfoRow icon={<TrendUp size={14} weight="regular" />} label="Volume 24H">
            <span style={body("p2", color.textPrimary)}>
              {pool.volume24h > 0 ? fmtUSD(pool.volume24h) : "—"}
            </span>
          </InfoRow>
          <InfoRow icon={<Coins size={14} weight="regular" />} label="Fees 24H">
            <span style={body("p2", color.textPrimary)}>
              {pool.fees24h > 0 ? fmtUSD(pool.fees24h) : "—"}
            </span>
          </InfoRow>
          <InfoRow icon={<Percent size={14} weight="regular" />} label="Fee Tier">
            <span style={body("p2", color.textPrimary)}>
              {(pool.fee / 10000).toFixed(2)}%
            </span>
          </InfoRow>
        </div>
      </div>

      {/* ── Pool details ────────────────────────────────────────── */}
      <div>
        <SectionLabel>Pool Details</SectionLabel>
        <div className="flex flex-col gap-px">
          <InfoRow icon={<Hash size={14} weight="regular" />} label="Contract">
            <HashValue value={pool.address} href={explorer} />
          </InfoRow>
          <InfoRow icon={<StackSimple size={14} weight="regular" />} label="Assets">
            <span style={body("p2", color.textPrimary)}>
              {pool.tokens.length} tokens
            </span>
          </InfoRow>
          <InfoRow icon={<Pulse size={14} weight="regular" />} label="Active Ticks">
            <span style={body("p2", isHealthy ? color.textPrimary : color.warning)}>
              {activeTicks} / {pool.ticks.length}
            </span>
          </InfoRow>
        </div>
      </div>

      {/* ── Reserve Distribution ────────────────────────────────── */}
      <div>
        <SectionLabel
          meta={
            <span style={body("caption", color.textMuted)}>
              TVL {fmtUSD(pool.tvl, true)}
            </span>
          }
        >
          Reserve Distribution
        </SectionLabel>
        <div className="flex flex-col gap-px">
          {/* Bar row */}
          <div className="px-5 py-5" style={{ backgroundColor: color.surface1 }}>
            <div className="flex h-2 gap-px overflow-hidden">
              {pool.tokens.map((t, i) => (
                <div
                  key={`${t.address}-${i}`}
                  style={{
                    width: `${totalReserves > 0 ? (pool.reserves[i] / totalReserves) * 100 : 0}%`,
                    backgroundColor: t.color,
                    opacity: pool.depeggedTokenIndices.includes(i) ? 0.35 : 1,
                  }}
                />
              ))}
            </div>
          </div>

          {/* Token rows */}
          {pool.tokens.map((t, i) => {
            const pct = totalReserves > 0 ? (pool.reserves[i] / totalReserves) * 100 : 0;
            // Depeg reflects an actually-depleted token reserve, not a tick that
            // crossed to boundary (ticks are not 1:1 with tokens).
            const isDepegged = pool.depeggedTokenIndices.includes(i);
            return (
              <InfoRow
                key={`${t.address}-${i}`}
                icon={<TokenIcon symbol={t.symbol} size={16} />}
                label={t.symbol}
              >
                <span style={body("p2", color.textPrimary)}>
                  {fmtUSD(pool.reserves[i], true)}
                </span>
                <span
                  style={{
                    ...body("p3", color.textMuted),
                    minWidth: 52,
                    textAlign: "right",
                  }}
                >
                  {pct.toFixed(1)}%
                </span>
                {isDepegged && (
                  <StatusPill healthy={false} label="depegged" />
                )}
              </InfoRow>
            );
          })}
        </div>
      </div>
    </div>
  );
}

// ─── Liquidity tab ────────────────────────────────────────────────────────────

function LiquidityTab({ pool }: { pool: NonNullable<ReturnType<typeof usePool>["pool"]> }) {
  const maxR = Math.max(...pool.ticks.map(t => t.r), 1);
  const activeCount = pool.ticks.filter(t => t.isInterior).length;

  return (
    <div>
      <SectionLabel
        meta={
          <span style={body("caption", color.textMuted)}>
            {pool.ticks.length} ticks · {activeCount} active
          </span>
        }
      >
        Tick Map
      </SectionLabel>

      <div className="flex flex-col gap-px">
        {/* Column headers — desktop */}
        <div
          className="hidden sm:grid items-center px-5 py-2.5"
          style={{
            backgroundColor: color.surface1,
            gridTemplateColumns: "32px 1fr 160px 110px",
          }}
        >
          {["#", "Liquidity (r)", "k (WAD)", "Status"].map(h => (
            <span key={h} style={{ ...LBL, color: color.textMuted }}>{h}</span>
          ))}
        </div>

        {pool.ticks.map((tick, i) => {
          const tickColor = tick.isInterior ? color.success : color.warning;
          return (
            <div
              key={i}
              className="hover:bg-(--color-surface-2) transition-colors"
              style={{ backgroundColor: color.surface1 }}
            >
              {/* Desktop row */}
              <div
                className="hidden sm:grid items-center px-5"
                style={{
                  gridTemplateColumns: "32px 1fr 160px 110px",
                  minHeight: 56,
                }}
              >
                <span style={body("caption", color.textMuted)}>{i}</span>
                <div className="flex flex-col gap-1.5 py-3 pr-6">
                  <span style={body("p2", color.textPrimary)}>{fmtUSD(tick.r)}</span>
                  <div style={{ height: 2, backgroundColor: color.surface3, overflow: "hidden" }}>
                    <div
                      style={{
                        width: `${maxR > 0 ? (tick.r / maxR) * 100 : 0}%`,
                        height: "100%",
                        backgroundColor: tickColor,
                        opacity: 0.55,
                      }}
                    />
                  </div>
                </div>
                <span style={body("caption", color.textMuted)}>
                  {(Number(tick.kWad) / 1e18).toFixed(4)}
                </span>
                <StatusPill healthy={tick.isInterior} label={tick.isInterior ? "Active" : "Paused"} />
              </div>

              {/* Mobile row */}
              <div
                className="sm:hidden grid items-center px-5"
                style={{
                  gridTemplateColumns: "28px 1fr auto",
                  minHeight: 50,
                }}
              >
                <span style={body("caption", color.textMuted)}>{i}</span>
                <div className="flex flex-col gap-1 py-3 pr-3">
                  <span style={body("p3", color.textPrimary)}>{fmtUSD(tick.r)}</span>
                  <div style={{ height: 2, backgroundColor: color.surface3, overflow: "hidden" }}>
                    <div
                      style={{
                        width: `${maxR > 0 ? (tick.r / maxR) * 100 : 0}%`,
                        height: "100%",
                        backgroundColor: tickColor,
                        opacity: 0.55,
                      }}
                    />
                  </div>
                </div>
                <StatusPill healthy={tick.isInterior} label={tick.isInterior ? "Active" : "Paused"} />
              </div>
            </div>
          );
        })}

        {pool.ticks.length === 0 && (
          <div
            className="flex items-center justify-center py-16"
            style={{ backgroundColor: color.surface1 }}
          >
            <span style={body("p3", color.textMuted)}>No ticks found</span>
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Transactions tab ─────────────────────────────────────────────────────────

const TYPE_COLOR: Record<TxType, string> = {
  Swap:    "#60A5FA",
  Add:     color.success,
  Remove:  color.warning,
  Collect: color.textMuted,
};

function timeAgo(unix: number): string {
  if (!unix) return "—";
  const diff = Math.floor(Date.now() / 1000) - unix;
  if (diff < 60)    return `${diff}s ago`;
  if (diff < 3600)  return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

function TypePill({ type }: { type: TxType }) {
  const c = TYPE_COLOR[type];
  return (
    <span
      style={{
        fontFamily: typography.caption.family,
        fontSize: "10px",
        fontWeight: 500,
        letterSpacing: "0.06em",
        textTransform: "uppercase",
        color: c,
        backgroundColor: `${c}1a`,
        padding: "3px 9px",
        borderRadius: 2,
        display: "inline-block",
        whiteSpace: "nowrap",
        width: "fit-content",
      }}
    >
      {type}
    </span>
  );
}

function TransactionsTab({ pool }: { pool: NonNullable<ReturnType<typeof usePool>["pool"]> }) {
  const { txs, isLoading, isLoadingMore, hasMore, loadMore, error } = useTransactions(pool.tokens);

  return (
    <div>
      <SectionLabel
        meta={
          <span style={body("caption", color.textMuted)}>
            {isLoading ? "Loading…" : `${txs.length} loaded`}
          </span>
        }
      >
        Transaction History
      </SectionLabel>

      <div className="flex flex-col gap-px">
        {/* Column headers — desktop */}
        <div
          className="hidden sm:grid items-center px-5 py-2.5"
          style={{
            backgroundColor: color.surface1,
            gridTemplateColumns: "92px 1.2fr 1fr 1fr 90px 110px",
          }}
        >
          {["Type", "From", "Amount In", "Amount Out", "Time", "Tx Hash"].map(h => (
            <span key={h} style={{ ...LBL, color: color.textMuted }}>{h}</span>
          ))}
        </div>

        {isLoading && (
          <div
            className="flex items-center justify-center py-16"
            style={{ backgroundColor: color.surface1 }}
          >
            <span style={body("p3", color.textMuted)}>Scanning on-chain events…</span>
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

        {!isLoading && !error && txs.length === 0 && (
          <div
            className="flex items-center justify-center py-16"
            style={{ backgroundColor: color.surface1 }}
          >
            <span style={body("p3", color.textMuted)}>No transactions found</span>
          </div>
        )}

        {txs.map((tx, i) => (
          <div
            key={tx.hash + i}
            className="hover:bg-(--color-surface-2) transition-colors"
            style={{ backgroundColor: color.surface1 }}
          >
            {/* Desktop row */}
            <div
              className="hidden sm:grid items-center px-5 py-3"
              style={{ gridTemplateColumns: "92px 1.2fr 1fr 1fr 90px 110px" }}
            >
              <TypePill type={tx.type} />
              <span style={{ ...body("p3", color.textSecondary), overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {tx.actor.slice(0, 8)}…{tx.actor.slice(-4)}
              </span>
              <span style={{ ...body("p3", color.textPrimary), overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {tx.amountIn}
              </span>
              <span style={{ ...body("p3", tx.amountOut ? color.success : color.textMuted), overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {tx.amountOut || "—"}
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
                className="flex items-center gap-1 hover:opacity-100 opacity-70 transition-opacity"
                style={body("caption", color.textMuted)}
              >
                {tx.hash.slice(0, 10)}…
                <ArrowSquareOut size={11} weight="regular" />
              </a>
            </div>

            {/* Mobile card */}
            <div className="sm:hidden px-5 py-4 flex flex-col gap-2">
              <div className="flex items-center justify-between">
                <TypePill type={tx.type} />
                <div className="flex items-center gap-3">
                  <span style={body("caption", color.textMuted)} suppressHydrationWarning>
                    {timeAgo(tx.timestamp)}
                  </span>
                  <a
                    href={explorerTxUrl(tx.hash)}
                    target="_blank"
                    rel="noreferrer"
                    className="flex items-center gap-1"
                    style={body("caption", color.textMuted)}
                  >
                    {tx.hash.slice(0, 8)}…
                    <ArrowSquareOut size={11} weight="regular" />
                  </a>
                </div>
              </div>
              <div className="flex items-center gap-2 flex-wrap">
                <span style={body("p2", color.textPrimary)}>{tx.amountIn}</span>
                {tx.amountOut && (
                  <>
                    <span style={body("caption", color.textMuted)}>→</span>
                    <span style={body("p2", color.success)}>{tx.amountOut}</span>
                  </>
                )}
              </div>
              <span style={body("caption", color.textMuted)}>
                From {tx.actor.slice(0, 8)}…{tx.actor.slice(-4)}
              </span>
            </div>
          </div>
        ))}

        {!isLoading && (hasMore || isLoadingMore) && (
          <div
            className="flex items-center justify-center py-5"
            style={{ backgroundColor: color.surface1 }}
          >
            <button
              onClick={loadMore}
              disabled={isLoadingMore}
              style={{
                ...body("caption", isLoadingMore ? color.textMuted : color.textPrimary),
                border: `1px solid ${color.border}`,
                backgroundColor: "transparent",
                padding: "8px 18px",
                cursor: isLoadingMore ? "not-allowed" : "pointer",
                letterSpacing: "0.08em",
                textTransform: "uppercase",
              }}
            >
              {isLoadingMore ? "Loading…" : "Load more"}
            </button>
          </div>
        )}

        {!isLoading && !hasMore && txs.length > 0 && (
          <div
            className="flex items-center justify-center py-4"
            style={{ backgroundColor: color.surface1 }}
          >
            <span style={body("caption", color.textMuted)}>All transactions loaded</span>
          </div>
        )}
      </div>
    </div>
  );
}

function shortAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function PoolDetailPage({ params }: { params: Promise<{ address: string }> }) {
  const { address: poolAddr } = use(params);
  const [activeTab, setActiveTab] = useState<Tab>("Overview");
  const { pool, isLoading } = usePool(poolAddr as Address, { withVolume: true });

  const pairLabel = pool ? pool.tokens.map(t => t.symbol).join(" / ") : "Pool";

  return (
    <section className="flex-1 flex flex-col py-8 sm:py-10">
        {/* ── Hero ─────────────────────────────────────────────────── */}
        <header className="flex flex-col gap-3 pb-7">
          {/* Title row */}
          <div className="flex items-end justify-between gap-4 flex-wrap">
            <div className="flex flex-col gap-2 min-w-0">
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
                {pairLabel}
              </h1>
              {pool && (
                <div className="flex items-center gap-2.5 flex-wrap">
                  <a
                    href={explorerAddressUrl(poolAddr)}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex items-center gap-1.5 hover:opacity-100 opacity-80 transition-opacity"
                    style={body("p3", color.textMuted)}
                  >
                    {shortAddr(poolAddr)}
                    <ArrowSquareOut size={11} weight="regular" />
                  </a>
                  <span style={{ color: color.textMuted, opacity: 0.4 }}>·</span>
                  <span style={body("p3", color.textMuted)}>
                    {fmtUSD(pool.tvl)} TVL
                  </span>
                  <span style={{ color: color.textMuted, opacity: 0.4 }}>·</span>
                  <span style={body("p3", color.textMuted)}>
                    {(pool.fee / 10000).toFixed(2)}% fee
                  </span>
                  <span style={{ color: color.textMuted, opacity: 0.4 }}>·</span>
                  <span style={body("p3", color.textMuted)}>
                    {pool.tokens.length} assets
                  </span>
                </div>
              )}
            </div>

            {pool && (
              <div className="flex items-center gap-2 shrink-0">
                <Link
                  href="/app/swap"
                  className="flex items-center h-10 px-5 hover:opacity-90 transition-opacity"
                  style={{
                    backgroundColor: color.surface2,
                    color: color.textPrimary,
                    fontFamily: typography.p2.family,
                    fontSize: typography.p2.size,
                    letterSpacing: "-0.01em",
                  }}
                >
                  Swap
                </Link>
                <Link
                  href={`/app/pool/${pool.address}/add`}
                  className="flex items-center h-10 px-5 hover:opacity-90 transition-opacity"
                  style={{
                    backgroundColor: color.textPrimary,
                    color: color.bg,
                    fontFamily: typography.p2.family,
                    fontSize: typography.p2.size,
                    fontWeight: 500,
                    letterSpacing: "-0.01em",
                    whiteSpace: "nowrap",
                  }}
                >
                  + Add Liquidity
                </Link>
              </div>
            )}
          </div>
        </header>

        {/* ── Tab bar ─────────────────────────────────────────────── */}
        {pool && (
          <div
            className="flex shrink-0 mb-7"
            style={{ borderBottom: `1px solid ${color.borderSubtle}` }}
          >
            {TABS.map(tab => {
              const active = activeTab === tab;
              return (
                <button
                  key={tab}
                  onClick={() => setActiveTab(tab)}
                  className="px-1 sm:px-1 py-3 mr-6 hover:opacity-80 transition-opacity"
                  style={{
                    fontFamily: typography.p2.family,
                    fontSize: typography.p2.size,
                    letterSpacing: "-0.01em",
                    color: active ? color.textPrimary : color.textMuted,
                    borderBottom: active ? `2px solid ${color.textPrimary}` : "2px solid transparent",
                    marginBottom: -1,
                    cursor: "pointer",
                    background: "none",
                  }}
                >
                  {tab}
                </button>
              );
            })}
          </div>
        )}

        {/* ── Body ────────────────────────────────────────────────── */}
        <div className="flex-1 min-h-0">
          {isLoading && (
            <div
              className="py-20 text-center"
              style={{ fontFamily: "var(--font-mono)", fontSize: "12px", color: color.textMuted }}
            >
              Fetching on-chain data…
            </div>
          )}
          {!isLoading && !pool && (
            <div className="flex flex-col items-center justify-center py-20 gap-3">
              <span style={body("p2", color.textMuted)}>Pool not found</span>
              <span style={body("caption", color.textMuted)}>{poolAddr}</span>
            </div>
          )}
          {pool && activeTab === "Overview"      && <OverviewTab      pool={pool} />}
          {pool && activeTab === "Liquidity"     && <LiquidityTab     pool={pool} />}
          {pool && activeTab === "Transactions"  && <TransactionsTab  pool={pool} />}
        </div>
    </section>
  );
}
