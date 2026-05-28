"use client";

import Link from "next/link";
import { useState, useCallback } from "react";
import { ArrowRight, CurrencyDollar, TrendUp, Coins, Pulse, Copy, Check, ArrowSquareOut } from "@phosphor-icons/react";
import { TokenDAI, TokenUSDT, TokenUSDC, TokenFRAX, NetworkXLayer } from "@token-icons/react";
import { color, typography } from "@/constants";
import { fmtUSD, type Pool } from "@/lib/mock/data";

const TOKEN_ICON_MAP: Record<string, React.ElementType> = {
  DAI: TokenDAI, USDT: TokenUSDT, USDC: TokenUSDC, FRAX: TokenFRAX,
};
const TOKEN_COLOR_MAP: Record<string, string> = {
  CRVUSD: "#FF6B35",
};

function TokenIcon({ symbol, size = 22 }: { symbol: string; size?: number }) {
  const Icon = TOKEN_ICON_MAP[symbol.toUpperCase()];
  if (Icon) return <Icon size={size} variant="branded" />;
  const bg = TOKEN_COLOR_MAP[symbol.toUpperCase()] ?? "#555";
  return (
    <span
      style={{
        width: size,
        height: size,
        borderRadius: "50%",
        backgroundColor: bg,
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        flexShrink: 0,
        fontSize: Math.max(6, size * 0.38),
        color: "#fff",
        fontFamily: typography.caption.family,
        fontWeight: 700,
      }}
    >
      {symbol.slice(0, 2).toUpperCase()}
    </span>
  );
}

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

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  const handleCopy = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
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
      {copied ? <Check size={12} weight="regular" /> : <Copy size={12} weight="regular" />}
    </button>
  );
}

function StatItem({ icon, label, value, accent }: {
  icon: React.ReactNode;
  label: string;
  value: string;
  accent?: string;
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center gap-1.5">
        <span style={{ color: color.textMuted, lineHeight: 0 }}>{icon}</span>
        <span style={{ ...LBL, color: color.textMuted }}>{label}</span>
      </div>
      <span
        style={{
          ...body("p1", accent ?? color.textPrimary),
          fontWeight: 500,
        }}
      >
        {value}
      </span>
    </div>
  );
}

interface PoolCardProps {
  pool: Pool;
}

export function PoolCard({ pool }: PoolCardProps) {
  const boundaryCount = pool.ticks.filter(t => !t.isInterior).length;
  const isHealthy     = boundaryCount === 0;
  const totalReserves = pool.reserves.reduce((a, b) => a + b, 0);
  const pairLabel     = pool.tokens.map(t => t.symbol).join(" / ");
  const activeTicks   = pool.ticks.length - boundaryCount;

  return (
    <div className="flex flex-col gap-px">
      {/* ── Identity row (clickable) ─────────────────────────────────── */}
      <Link
        href={`/app/pool/${pool.address}`}
        className="group flex items-center justify-between gap-3 px-5 py-4 hover:bg-(--color-surface-2) transition-colors"
        style={{ backgroundColor: color.surface1 }}
      >
        <div className="flex items-center gap-3.5 min-w-0">
          <div className="flex shrink-0 items-center">
            {pool.tokens.map((t, i) => (
              <span
                key={t.address}
                style={{
                  marginLeft: i === 0 ? 0 : -8,
                  outline: `2px solid ${color.surface1}`,
                  borderRadius: "50%",
                  lineHeight: 0,
                  position: "relative",
                  zIndex: pool.tokens.length - i,
                }}
              >
                <TokenIcon symbol={t.symbol} size={24} />
              </span>
            ))}
          </div>
          <div className="flex flex-col gap-0.5 min-w-0">
            <span
              style={{
                fontFamily: typography.h3.family,
                fontSize: "17px",
                fontWeight: 500,
                letterSpacing: "-0.02em",
                color: color.textPrimary,
                whiteSpace: "nowrap",
                overflow: "hidden",
                textOverflow: "ellipsis",
                lineHeight: 1.2,
              }}
            >
              {pairLabel}
            </span>
            <span style={body("caption", color.textMuted)}>
              {pool.tokens.length}-asset pool · {(pool.fee / 10000).toFixed(2)}% fee
            </span>
          </div>
        </div>
        <span
          className="flex items-center gap-1.5 shrink-0 group-hover:opacity-100 opacity-60 transition-opacity"
          style={body("caption", color.textMuted)}
        >
          Details
          <ArrowRight size={13} weight="regular" />
        </span>
      </Link>

      {/* ── Address row ──────────────────────────────────────────────── */}
      <div
        className="flex items-center justify-between gap-3 px-5 py-3"
        style={{ backgroundColor: color.surface1 }}
      >
        <div className="flex items-center gap-2.5 min-w-0">
          <span
            className="inline-flex items-center justify-center shrink-0"
            style={{ width: 18, height: 18, borderRadius: "50%", backgroundColor: "#fff" }}
          >
            <NetworkXLayer size={13} variant="branded" />
          </span>
          <span style={body("p3", color.textSecondary)}>
            {pool.address.slice(0, 8)}…{pool.address.slice(-6)}
          </span>
          <CopyButton text={pool.address} />
          <a
            href={`https://www.okx.com/web3/explorer/xlayer-test/address/${pool.address}`}
            target="_blank"
            rel="noreferrer"
            onClick={(e) => e.stopPropagation()}
            className="flex items-center justify-center hover:opacity-100 opacity-60"
            style={{ width: 16, height: 16, color: color.textMuted, transition: "opacity 0.15s" }}
            aria-label="Open in explorer"
          >
            <ArrowSquareOut size={12} weight="regular" />
          </a>
        </div>
        <span style={body("caption", color.textMuted)}>X Layer Testnet</span>
      </div>

      {/* ── Stats row ────────────────────────────────────────────────── */}
      <div
        className="grid grid-cols-2 sm:grid-cols-4 px-5 py-4 gap-x-6 gap-y-4"
        style={{ backgroundColor: color.surface1 }}
      >
        <StatItem
          icon={<CurrencyDollar size={11} weight="regular" />}
          label="TVL"
          value={fmtUSD(pool.tvl)}
        />
        <StatItem
          icon={<TrendUp size={11} weight="regular" />}
          label="Vol 24H"
          value={pool.volume24h > 0 ? fmtUSD(pool.volume24h) : "—"}
          accent={pool.volume24h > 0 ? color.textPrimary : color.textMuted}
        />
        <StatItem
          icon={<Coins size={11} weight="regular" />}
          label="Fees 24H"
          value={pool.fees24h > 0 ? fmtUSD(pool.fees24h) : "—"}
          accent={pool.fees24h > 0 ? color.textPrimary : color.textMuted}
        />
        <StatItem
          icon={<Pulse size={11} weight="regular" />}
          label="Active"
          value={`${activeTicks}/${pool.ticks.length}`}
          accent={isHealthy ? color.textPrimary : color.warning}
        />
      </div>

      {/* ── Reserve distribution row ─────────────────────────────────── */}
      <div
        className="px-5 py-4 flex flex-col gap-3"
        style={{ backgroundColor: color.surface1 }}
      >
        <div className="flex items-center justify-between">
          <span style={{ ...LBL, color: color.textMuted }}>Reserve Distribution</span>
          <span style={body("caption", color.textMuted)}>
            {fmtUSD(totalReserves, true)}
          </span>
        </div>
        <div className="flex h-1.5 gap-px overflow-hidden">
          {pool.tokens.map((t, i) => {
            const pct = totalReserves > 0 ? (pool.reserves[i] / totalReserves) * 100 : 0;
            return (
              <div
                key={t.address}
                style={{
                  width: `${pct}%`,
                  backgroundColor: t.color,
                  opacity: pool.depeggedTokenIndices.includes(i) ? 0.35 : 1,
                }}
              />
            );
          })}
        </div>
        <div className="flex flex-wrap gap-x-5 gap-y-1.5">
          {pool.tokens.map((t, i) => {
            const pct = (totalReserves > 0 ? (pool.reserves[i] / totalReserves) * 100 : 0).toFixed(1);
            // A TOKEN is depegged only if its reserve is actually depleted —
            // not because some tick crossed to boundary (ticks ≠ tokens).
            const depegged = pool.depeggedTokenIndices.includes(i);
            return (
              <span
                key={t.address}
                className="flex items-center gap-1.5"
                style={body("caption", depegged ? color.warning : color.textMuted)}
              >
                <span
                  style={{
                    width: 6,
                    height: 6,
                    borderRadius: "50%",
                    backgroundColor: t.color,
                    display: "inline-block",
                    opacity: depegged ? 0.5 : 1,
                  }}
                />
                {t.symbol} {pct}%
              </span>
            );
          })}
        </div>
      </div>

      {/* ── Actions row ──────────────────────────────────────────────── */}
      <div
        className="flex items-center justify-end gap-2 px-5 py-3"
        style={{ backgroundColor: color.surface1 }}
      >
        <Link
          href="/app/swap"
          className="flex items-center justify-center h-9 px-4 hover:opacity-90 transition-opacity"
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
          className="flex items-center justify-center h-9 px-4 hover:opacity-90 transition-opacity"
          style={{
            backgroundColor: color.textPrimary,
            color: color.bg,
            fontFamily: typography.p2.family,
            fontSize: typography.p2.size,
            fontWeight: 500,
            letterSpacing: "-0.01em",
          }}
        >
          + Add Liquidity
        </Link>
      </div>
    </div>
  );
}
