"use client";

import Link from "next/link";
import { useCallback, useState } from "react";
import { CaretRight, Check, Copy } from "@phosphor-icons/react";
import { color, typography } from "@/constants";
import { fmtUSD, type Pool } from "@/lib/mock/data";
import { ChainBadge } from "@/components/app/shared/ChainBadge";
import { DEPLOYMENTS, poolByAddress, type PoolEntry } from "@/lib/crosschain";
import { PoolTypeTag } from "@/components/app/shared/PoolTypeTag";
import { TokenIcon } from "@/components/app/shared/TokenIcon";

/// Column template shared by the header and every row, so they line up. Every
/// column has a floor that fits its content (no truncated pair names) and
/// free width is shared in proportion, so the gaps stay even as the viewport
/// grows. Columns appear as width allows:
///   base  Pool · TVL
///   md    Pool · Network · TVL
///   xl    Pool · Network · Address · Volume 24H · TVL
const GRID = [
  "grid items-center gap-x-4 grid-cols-[minmax(0,1fr)_auto_16px]",
  "md:gap-x-6 md:grid-cols-[minmax(0,2fr)_minmax(160px,1fr)_minmax(104px,0.7fr)_16px]",
  "xl:grid-cols-[minmax(360px,2.2fr)_minmax(176px,1fr)_minmax(152px,1fr)_minmax(112px,0.8fr)_minmax(112px,0.8fr)_16px]",
].join(" ");
const MD = "hidden md:flex";
const XL = "hidden xl:block";

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

const LBL = {
  fontFamily: typography.caption.family,
  fontSize: typography.caption.size,
  letterSpacing: "0.12em",
  textTransform: "uppercase" as const,
  fontWeight: 500,
  color: color.textMuted,
};

/// Column labels for a list of `PoolRow`s.
export function PoolListHeader() {
  return (
    <div className={`${GRID} px-6 pb-3`}>
      <span style={LBL}>Pool</span>
      <span className={MD} style={LBL}>Network</span>
      <span className={XL} style={LBL}>Address</span>
      <span className={`${XL} text-right`} style={LBL}>Volume 24H</span>
      <span className="text-right" style={LBL}>TVL</span>
      <span />
    </div>
  );
}

function CopyAddress({ address }: { address: string }) {
  const [copied, setCopied] = useState(false);
  const handleCopy = useCallback(() => {
    navigator.clipboard.writeText(address).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  }, [address]);
  return (
    <button
      type="button"
      onClick={handleCopy}
      className="relative z-10 flex items-center gap-2 min-w-0 hover:opacity-100 opacity-80 transition-opacity"
      style={{ ...body("p2", color.textSecondary), cursor: "pointer" }}
      aria-label={`Copy pool address ${address}`}
    >
      <span className="truncate">
        {address.slice(0, 6)}…{address.slice(-4)}
      </span>
      {copied ? <Check size={13} color={color.success} /> : <Copy size={13} color={color.textMuted} />}
    </button>
  );
}

/// A pool's row before its on-chain data has arrived (or when its chain is
/// unreachable): what the registry already knows, with the numbers pending.
export function PoolRowPlaceholder({ entry, failed }: { entry: PoolEntry; failed: boolean }) {
  const pending = failed ? "unavailable" : "…";
  return (
    <div className={`${GRID} px-6 py-5`} style={{ backgroundColor: color.surface1 }}>
      <div className="flex items-center gap-3.5 min-w-0">
        <div className="flex shrink-0 items-center">
          {entry.assets.map((a, i) => (
            <span key={a.address} style={{ marginLeft: i === 0 ? 0 : -9, lineHeight: 0, opacity: 0.5 }}>
              <TokenIcon symbol={a.symbol} size={28} />
            </span>
          ))}
        </div>
        <div className="flex items-center gap-2.5 min-w-0">
          <span className="truncate" style={{ ...body("p2", color.textMuted), fontSize: "17px" }}>
            {entry.assets.map((a) => a.symbol).join(" / ")}
          </span>
          <PoolTypeTag type={entry.type} />
        </div>
      </div>
      <span className={`${MD} items-center gap-2 min-w-0`} style={body("p2", color.textMuted)}>
        <ChainBadge chainId={entry.chainId} size={16} />
        <span className="truncate">{entry.name}</span>
      </span>
      <span className={XL} style={body("p2", color.textMuted)}>
        {entry.address.slice(0, 6)}…{entry.address.slice(-4)}
      </span>
      <span className={XL} />
      <span className="text-right" style={body("p3", failed ? color.warning : color.textMuted)}>{pending}</span>
      <span />
    </div>
  );
}

/// One pool as a single row: assets and type, network, address, 24h volume and
/// TVL. The whole row opens the pool's page.
export function PoolRow({ pool }: { pool: Pool }) {
  const pairLabel = pool.tokens.map((t) => t.symbol).join(" / ");
  const poolType = poolByAddress(pool.address)?.type ?? "stable";
  const chainName = DEPLOYMENTS[pool.chainId]?.name ?? "Unknown chain";

  return (
    <div
      className={`group relative ${GRID} px-6 py-5 hover:bg-(--color-surface-2) transition-colors`}
      style={{ backgroundColor: color.surface1 }}
    >
      {/* Full-row link underneath; interactive cells sit above it (z-10). */}
      <Link href={`/app/pool/${pool.address}`} className="absolute inset-0" aria-label={`Open ${pairLabel} pool`} />

      <div className="flex items-center gap-3.5 min-w-0">
        <div className="flex shrink-0 items-center">
          {pool.tokens.map((t, i) => (
            <span
              key={`${t.address}-${i}`}
              style={{
                marginLeft: i === 0 ? 0 : -9,
                outline: `2px solid ${color.surface1}`,
                borderRadius: "50%",
                lineHeight: 0,
                position: "relative",
                zIndex: pool.tokens.length - i,
              }}
            >
              <TokenIcon symbol={t.symbol} size={28} />
            </span>
          ))}
        </div>
        <div className="flex items-center gap-3 min-w-0">
          <span
            className="truncate"
            style={{
              fontFamily: typography.h3.family,
              fontSize: "17px",
              fontWeight: 500,
              letterSpacing: "-0.02em",
              color: color.textPrimary,
              lineHeight: 1.25,
            }}
          >
            {pairLabel}
          </span>
          <PoolTypeTag type={poolType} />
        </div>
      </div>

      <span className={`${MD} items-center gap-2 min-w-0`} style={body("p2", color.textSecondary)}>
        <ChainBadge chainId={pool.chainId} size={16} />
        <span className="truncate">{chainName}</span>
      </span>

      <div className="hidden xl:flex min-w-0">
        <CopyAddress address={pool.address} />
      </div>

      <span
        className={`${XL} text-right`}
        style={body("p2", pool.volume24h ? color.textPrimary : color.textMuted)}
      >
        {pool.volume24h === undefined ? "…" : pool.volume24h === 0 ? "$0" : fmtUSD(pool.volume24h)}
      </span>

      <span className="text-right" style={{ ...body("p1", color.textPrimary), fontWeight: 500 }}>
        {fmtUSD(pool.tvl)}
      </span>

      <CaretRight
        size={16}
        weight="regular"
        className="opacity-40 group-hover:opacity-100 group-hover:translate-x-0.5 transition-all"
        color={color.textMuted}
      />
    </div>
  );
}
