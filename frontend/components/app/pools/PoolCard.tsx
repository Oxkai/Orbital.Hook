"use client";

import Link from "next/link";
import { useState, useCallback } from "react";
import { Copy, Check, ArrowSquareOut } from "@phosphor-icons/react";
import { color, typography } from "@/constants";
import { fmtUSD, type Pool } from "@/lib/mock/data";
import { ChainBadge } from "@/components/app/shared/ChainBadge";
import { DEPLOYMENTS } from "@/lib/crosschain";
import { TokenIcon } from "@/components/app/shared/TokenIcon";

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

interface PoolCardProps {
  pool: Pool;
}

export function PoolCard({ pool }: PoolCardProps) {
  const totalReserves = pool.reserves.reduce((a, b) => a + b, 0);
  const pairLabel     = pool.tokens.map(t => t.symbol).join(" / ");

  return (
    <div className="flex flex-col gap-px">
      {/* ── Header: identity + TVL (clickable) ──────────────────────── */}
      <Link
        href={`/app/pool/${pool.address}`}
        className="group flex items-center justify-between gap-3 px-5 py-4 hover:bg-(--color-surface-2) transition-colors"
        style={{ backgroundColor: color.surface1 }}
      >
        <div className="flex items-center gap-3.5 min-w-0">
          <div className="flex shrink-0 items-center">
            {pool.tokens.map((t, i) => (
              <span
                key={`${t.address}-${i}`}
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
              {pool.tokens.length}-asset · {(pool.fee / 10000).toFixed(2)}% fee
            </span>
          </div>
        </div>

        <div className="flex flex-col items-end gap-0.5 shrink-0">
          <span style={{ ...LBL, color: color.textMuted, fontSize: "9px" }}>TVL</span>
          <span style={{ ...body("p1", color.textPrimary), fontWeight: 500 }}>{fmtUSD(pool.tvl)}</span>
        </div>
      </Link>

      {/* ── Reserve distribution ────────────────────────────────────── */}
      <div
        className="px-5 py-4 flex flex-col gap-2.5"
        style={{ backgroundColor: color.surface1 }}
      >
        <div className="flex h-1.5 gap-px overflow-hidden">
          {pool.tokens.map((t, i) => {
            const pct = totalReserves > 0 ? (pool.reserves[i] / totalReserves) * 100 : 0;
            return (
              <div
                key={`${t.address}-${i}`}
                style={{
                  width: `${pct}%`,
                  backgroundColor: t.color,
                  opacity: pool.depeggedTokenIndices.includes(i) ? 0.35 : 1,
                }}
              />
            );
          })}
        </div>
        <div className="flex flex-wrap gap-x-4 gap-y-1.5">
          {pool.tokens.map((t, i) => {
            const pct = (totalReserves > 0 ? (pool.reserves[i] / totalReserves) * 100 : 0).toFixed(1);
            // A TOKEN is depegged only if its reserve is actually depleted 
            // not because some tick crossed to boundary (ticks ≠ tokens).
            const depegged = pool.depeggedTokenIndices.includes(i);
            return (
              <span
                key={`${t.address}-${i}`}
                className="flex items-center gap-1.5"
                style={body("caption", depegged ? color.warning : color.textMuted)}
              >
                <span
                  style={{
                    width: 6,
                    height: 6,
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

      {/* ── Footer: address + actions ───────────────────────────────── */}
      <div
        className="flex flex-wrap items-center justify-between gap-x-3 gap-y-2.5 px-5 py-3"
        style={{ backgroundColor: color.surface1 }}
      >
        <div className="flex items-center gap-2.5 min-w-0">
          <span style={body("p3", color.textSecondary)}>
            {pool.address.slice(0, 6)}…{pool.address.slice(-4)}
          </span>
          <CopyButton text={pool.address} />
          <a
            href={`${DEPLOYMENTS[pool.chainId]?.explorer ?? ""}/address/${pool.address}`}
            target="_blank"
            rel="noreferrer"
            onClick={(e) => e.stopPropagation()}
            className="flex items-center justify-center hover:opacity-100 opacity-60"
            style={{ width: 16, height: 16, color: color.textMuted, transition: "opacity 0.15s" }}
            aria-label="Open in explorer"
          >
            <ArrowSquareOut size={12} weight="regular" />
          </a>
          <span className="flex items-center gap-1.5 shrink-0 pl-1" style={body("caption", color.textMuted)}>
            <ChainBadge chainId={pool.chainId} size={11} />
            {DEPLOYMENTS[pool.chainId]?.name ?? "Unknown chain"}
          </span>
        </div>

        <div className="flex items-center gap-2">
          <Link
            href={`/app/pool/${pool.address}`}
            className="flex items-center justify-center h-8 px-4 hover:opacity-90 transition-opacity"
            style={{
              backgroundColor: color.surface2,
              color: color.textPrimary,
              fontFamily: typography.p2.family,
              fontSize: typography.p2.size,
              letterSpacing: "-0.01em",
            }}
          >
            Details
          </Link>
          <Link
            href="/app/swap"
            className="flex items-center justify-center h-8 px-4 hover:opacity-90 transition-opacity"
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
            className="flex items-center justify-center h-8 px-4 hover:opacity-90 transition-opacity"
            style={{
              backgroundColor: color.textPrimary,
              color: color.bg,
              fontFamily: typography.p2.family,
              fontSize: typography.p2.size,
              fontWeight: 500,
              letterSpacing: "-0.01em",
            }}
          >
            + Add
          </Link>
        </div>
      </div>
    </div>
  );
}
