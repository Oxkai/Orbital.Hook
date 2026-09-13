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
  Broadcast,
} from "@phosphor-icons/react";
import { color, typography } from "@/constants";

import { usePool }   from "@/lib/hooks/usePool";
import { useTransactions } from "@/lib/hooks/useTransactions";
import { DepthChart } from "@/components/app/pool/DepthChart";
import { fmtUSD }   from "@/lib/mock/data";
import { type Address } from "viem";
import { chainIdForPool, explorerAddress, poolByAddress } from "@/lib/crosschain";
import { PoolTypeTag } from "@/components/app/shared/PoolTypeTag";
import { FX_POOL, type FxPool } from "@/lib/fx";
import { ageLabel, useFxRates, type FxStatus } from "@/lib/hooks/useFxRates";
import { TokenIcon } from "@/components/app/shared/TokenIcon";
import {
  TransactionListHeader,
  TransactionListNotice,
  TransactionRow,
} from "@/components/app/transactions/TransactionRow";

const TABS = ["Overview", "Liquidity", "Transactions"] as const;
type Tab = typeof TABS[number];

// Section / kicker label: Roboto caption, uppercase
const LBL = {
  fontFamily: typography.caption.family,
  fontSize: typography.caption.size,
  letterSpacing: "0.12em",
  textTransform: "uppercase" as const,
  fontWeight: 500,
};

// Row body text: Roboto, tabular numerals for clean alignment
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

// Mono: reserved for hashes and on-chain identifiers only
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

// ─── FX: oracle rates ─────────────────────────────────────────────────────────

const FX_STATUS: Record<FxStatus, { healthy: boolean; label: string } | undefined> = {
  live: { healthy: true, label: "Live" },
  stale: { healthy: false, label: "Feed stale · swaps paused" },
  paused: { healthy: false, label: "Paused by admin" },
  loading: undefined,
};

function OracleRatesSection({ fx }: { fx: FxPool }) {
  const { rates, status, bandBps } = useFxRates(fx);
  const pill = FX_STATUS[status];

  return (
    <div>
      <SectionLabel
        meta={
          <div className="flex items-center gap-3">
            {bandBps !== undefined && (
              <span style={body("caption", color.textMuted)}>band ±{(bandBps / 100).toFixed(2)}%</span>
            )}
            {pill && <StatusPill healthy={pill.healthy} label={pill.label} />}
          </div>
        }
      >
        Oracle Rates
      </SectionLabel>
      <div className="flex flex-col gap-px">
        {rates.map((r) => (
          <InfoRow
            key={r.asset.address}
            icon={<TokenIcon symbol={r.asset.symbol} size={16} />}
            label={`${r.asset.symbol} / USD`}
          >
            <span style={body("p2", color.textPrimary)}>
              {r.market !== undefined ? r.market.toFixed(5) : "…"}
            </span>
            <span style={{ ...body("p3", color.textMuted), minWidth: 96, textAlign: "right" }}>
              {r.poolVsMarketBps !== undefined
                ? `pool ${r.poolVsMarketBps >= 0 ? "+" : ""}${r.poolVsMarketBps.toFixed(1)} bps`
                : ""}
            </span>
            <span style={{ ...body("p3", color.textMuted), minWidth: 64, textAlign: "right" }}>
              {r.ageSeconds !== undefined ? `${ageLabel(r.ageSeconds)} ago` : ""}
            </span>
          </InfoRow>
        ))}
        <InfoRow icon={<Broadcast size={14} weight="regular" />} label="Source">
          <a
            href={fx.rateSource.href}
            target="_blank"
            rel="noreferrer"
            className="flex items-center gap-2.5 hover:opacity-100 opacity-80 transition-opacity"
            style={body("p3", color.textPrimary)}
          >
            {fx.rateSource.label}
            <ArrowSquareOut size={12} weight="regular" color={color.textMuted} />
          </a>
        </InfoRow>
      </div>
    </div>
  );
}

// ─── Overview tab ─────────────────────────────────────────────────────────────

function OverviewTab({ pool, fx }: { pool: NonNullable<ReturnType<typeof usePool>["pool"]>; fx?: FxPool }) {
  const totalReserves = pool.reserves.reduce((a, b) => a + b, 0);
  const boundaryCount = pool.ticks.filter(t => !t.isInterior).length;
  const isHealthy     = boundaryCount === 0;
  const activeTicks   = pool.ticks.length - boundaryCount;
  // Per-chain explorer: `explorerAddressUrl` is hardcoded to the primary chain
  // and would point an Arc or Base address at Uniscan.
  const explorer      = explorerAddress(pool.chainId, pool.address);

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

      {/* ── Oracle rates (FX pools) ─────────────────────────────── */}
      {fx && <OracleRatesSection fx={fx} />}

      {/* ── Key metrics ─────────────────────────────────────────── */}
      <div>
        <SectionLabel>Key Metrics</SectionLabel>
        <div className="flex flex-col gap-px">
          <InfoRow icon={<CurrencyDollar size={14} weight="regular" />} label="TVL">
            <span style={body("p2", color.textPrimary)}>{fmtUSD(pool.tvl)}</span>
          </InfoRow>
          <InfoRow icon={<TrendUp size={14} weight="regular" />} label="Volume 24H">
            <span style={body("p2", color.textPrimary)}>
              {pool.volume24h !== undefined ? fmtUSD(pool.volume24h) : "…"}
            </span>
          </InfoRow>
          <InfoRow icon={<Coins size={14} weight="regular" />} label="Fees 24H">
            <span style={body("p2", color.textPrimary)}>
              {pool.fees24h !== undefined ? fmtUSD(pool.fees24h) : "…"}
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
        {/* Column headers: desktop */}
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

function TransactionsTab({ pool }: { pool: NonNullable<ReturnType<typeof usePool>["pool"]> }) {
  const { txs, isLoading, isLoadingMore, hasMoreFor, loadMore, error } = useTransactions();
  // The feed covers every pool (and is shared with the Transactions page);
  // this tab is this pool's history only.
  const mine = txs.filter((t) => t.pool.toLowerCase() === pool.address.toLowerCase());
  const hasMore = hasMoreFor(pool.address);

  return (
    <div>
      <SectionLabel
        meta={
          <span style={body("caption", color.textMuted)}>
            {isLoading ? "Loading…" : `${mine.length} loaded`}
          </span>
        }
      >
        Transaction History
      </SectionLabel>

      <TransactionListHeader scope="pool" />
      <div className="flex flex-col gap-px">
        {isLoading && <TransactionListNotice>Scanning on-chain events…</TransactionListNotice>}
        {error && !isLoading && <TransactionListNotice tone="warning">{error}</TransactionListNotice>}
        {!isLoading && !error && mine.length === 0 && <TransactionListNotice>No transactions found</TransactionListNotice>}

        {mine.map((tx) => (
          <TransactionRow key={`${tx.chainId}:${tx.eventId}`} tx={tx} scope="pool" />
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

        {!isLoading && !hasMore && mine.length > 0 && (
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
  // The route carries only an address, so the chain has to be recovered from
  // the registry. Without this every non-primary pool (Base, Arbitrum, Arc)
  // would be read off the Unichain RPC and render as an empty pool.
  const poolChainId = chainIdForPool(poolAddr);
  const poolType = poolByAddress(poolAddr)?.type ?? "stable";
  const fxPool = FX_POOL && FX_POOL.hook.toLowerCase() === poolAddr.toLowerCase() ? FX_POOL : undefined;
  const { pool, isLoading } = usePool(poolAddr as Address, { withVolume: true, chainId: poolChainId });

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
                  <PoolTypeTag type={poolType} />
                  <a
                    href={explorerAddress(poolChainId, poolAddr)}
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
          {pool && activeTab === "Overview"      && <OverviewTab      pool={pool} fx={fxPool} />}
          {pool && activeTab === "Liquidity"     && <LiquidityTab     pool={pool} />}
          {pool && activeTab === "Transactions"  && <TransactionsTab  pool={pool} />}
        </div>
    </section>
  );
}
