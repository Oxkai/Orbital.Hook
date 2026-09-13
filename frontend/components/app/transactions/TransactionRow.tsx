"use client";

import { ArrowRight, ArrowSquareOut } from "@phosphor-icons/react";
import { color, typography } from "@/constants";
import { DEPLOYMENTS, explorerTx, poolByAddress } from "@/lib/crosschain";
import type { TokenAmount, TxRecord, TxType } from "@/lib/hooks/useTransactions";
import { ChainBadge } from "@/components/app/shared/ChainBadge";
import { PoolTypeTag } from "@/components/app/shared/PoolTypeTag";
import { TokenIcon } from "@/components/app/shared/TokenIcon";

/// Where a list is shown: the all-pools feed names each row's chain; a single
/// pool's history leaves it out, since every row shares it.
export type TransactionListScope = "all" | "pool";

/// Column templates shared by the header and every row, in the same shape as
/// the pools table: floors that fit their content, free width shared in
/// proportion, columns appearing as width allows.
///   base  Transaction · Time
///   md    Transaction · Amount In · Amount Out · Time
///   lg    + Chain (all-pools feed only)
///   xl    + Tx hash
/// Written out in full, not assembled, so Tailwind can see every class.
const GRID: Record<TransactionListScope, string> = {
  all: [
    "grid items-center gap-x-4 grid-cols-[minmax(0,1fr)_auto]",
    "md:gap-x-6 md:grid-cols-[minmax(0,1.6fr)_minmax(128px,1fr)_minmax(128px,1fr)_minmax(72px,0.45fr)]",
    "lg:grid-cols-[minmax(0,1.8fr)_minmax(136px,1fr)_minmax(136px,1fr)_minmax(76px,0.45fr)_minmax(160px,0.9fr)]",
    "xl:grid-cols-[minmax(300px,2fr)_minmax(144px,1fr)_minmax(144px,1fr)_minmax(80px,0.45fr)_minmax(176px,0.9fr)_minmax(136px,0.8fr)]",
  ].join(" "),
  pool: [
    "grid items-center gap-x-4 grid-cols-[minmax(0,1fr)_auto]",
    "md:gap-x-6 md:grid-cols-[minmax(0,1.6fr)_minmax(128px,1fr)_minmax(128px,1fr)_minmax(72px,0.45fr)]",
    "xl:grid-cols-[minmax(300px,2fr)_minmax(144px,1fr)_minmax(144px,1fr)_minmax(80px,0.45fr)_minmax(136px,0.8fr)]",
  ].join(" "),
};
const MD = "hidden md:block";
const LG_FLEX = "hidden lg:flex";
const XL_FLEX = "hidden xl:flex";

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

const TITLE: Record<Exclude<TxType, "Swap">, string> = {
  Add: "Add liquidity",
  Remove: "Remove liquidity",
  Collect: "Collect fees",
};

const AMOUNT = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const USD = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 });

function timeAgo(unix: number): string {
  if (!unix) return "—";
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - unix);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

/// Column labels for a list of `TransactionRow`s.
export function TransactionListHeader({ scope }: { scope: TransactionListScope }) {
  return (
    <div className={`${GRID[scope]} px-6 pb-3`}>
      <span style={LBL}>Transaction</span>
      <span className={MD} style={LBL}>Amount In</span>
      <span className={MD} style={LBL}>Amount Out</span>
      <span className="text-right md:text-left" style={LBL}>Time</span>
      {scope === "all" && <span className={LG_FLEX} style={LBL}>Chain</span>}
      <span className={`${XL_FLEX} justify-end`} style={LBL}>Tx Hash</span>
    </div>
  );
}

/// A full-width message in place of rows: loading, empty, or an error.
export function TransactionListNotice({ children, tone = "muted" }: { children: React.ReactNode; tone?: "muted" | "warning" }) {
  return (
    <div className="flex items-center justify-center px-6 py-16" style={{ backgroundColor: color.surface1 }}>
      <span style={body("p2", tone === "warning" ? color.warning : color.textMuted)}>{children}</span>
    </div>
  );
}

/// The tokens a row moved: a swap's input and output with its direction, or
/// every asset of the pool for a liquidity event. Fixed width, so every row's
/// title starts at the same place.
function TokenStack({ tx }: { tx: TxRecord }) {
  if (tx.tokenIn && tx.tokenOut) {
    return (
      <div className="flex w-21.25 shrink-0 items-center gap-1">
        <TokenIcon symbol={tx.tokenIn.symbol} size={28} />
        <ArrowRight size={12} color={color.textMuted} className="shrink-0" />
        <TokenIcon symbol={tx.tokenOut.symbol} size={28} />
      </div>
    );
  }
  const assets = poolByAddress(tx.pool)?.assets ?? [];
  return (
    <div className="flex w-21.25 shrink-0 items-center">
      {assets.map((a, i) => (
        <span
          key={a.address}
          style={{
            marginLeft: i === 0 ? 0 : -9,
            outline: `2px solid ${color.surface1}`,
            borderRadius: "50%",
            lineHeight: 0,
            position: "relative",
            zIndex: assets.length - i,
          }}
        >
          <TokenIcon symbol={a.symbol} size={28} />
        </span>
      ))}
    </div>
  );
}

/// An amount cell: a token amount with its symbol, a USD value for a
/// liquidity event (which moves every asset at once), or a dash.
function Amount({ token, usd, note }: { token?: TokenAmount; usd?: number; note?: string }) {
  if (token) {
    return (
      <span className="flex items-baseline gap-1.5 min-w-0" style={body("p2", color.textPrimary)}>
        <span className="truncate">{AMOUNT.format(token.amount)}</span>
        <span className="shrink-0" style={body("p3", color.textMuted)}>{token.symbol}</span>
        {note && <span className="shrink-0" style={body("caption", color.textMuted)}>{note}</span>}
      </span>
    );
  }
  if (usd !== undefined) {
    return <span className="truncate" style={body("p2", color.textPrimary)}>{USD.format(usd)}</span>;
  }
  return <span style={body("p2", color.textMuted)}>—</span>;
}

/// One transaction as a single row, sized like a pool row. The whole row
/// opens the transaction on its chain's explorer.
export function TransactionRow({ tx, scope }: { tx: TxRecord; scope: TransactionListScope }) {
  const swap = tx.type === "Swap" && tx.tokenIn && tx.tokenOut ? { tokenIn: tx.tokenIn, tokenOut: tx.tokenOut } : undefined;
  const title = swap ? `Swap ${swap.tokenIn.symbol} for ${swap.tokenOut.symbol}` : TITLE[tx.type as Exclude<TxType, "Swap">];
  // A deposit goes into the pool; a withdrawal or fee claim comes out of it.
  const valueIn = tx.type === "Add" ? tx.valueUsd : undefined;
  const valueOut = tx.type === "Remove" || tx.type === "Collect" ? tx.valueUsd : undefined;
  // Only the subgraph knows a swap's realised slippage.
  const slip = tx.slippageBps === undefined ? undefined : `${tx.slippageBps} bps`;
  const fullTime = tx.timestamp ? new Date(tx.timestamp * 1000).toLocaleString() : undefined;

  return (
    <div
      className={`group relative ${GRID[scope]} px-6 py-5 hover:bg-(--color-surface-2) transition-colors`}
      style={{ backgroundColor: color.surface1 }}
    >
      {/* Full-row link underneath. */}
      <a
        href={explorerTx(tx.chainId, tx.hash)}
        target="_blank"
        rel="noreferrer"
        className="absolute inset-0"
        aria-label={`View ${title} on the explorer`}
      />

      <div className="flex items-center gap-3.5 min-w-0">
        <TokenStack tx={tx} />
        <div className="flex flex-col gap-1 min-w-0">
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
              {title}
            </span>
            {tx.tick !== undefined && (
              <span className="shrink-0" style={body("p3", color.textMuted)}>
                tick #{tx.tick}
              </span>
            )}
            {scope === "all" && tx.poolType === "fx" && <PoolTypeTag type="fx" />}
          </div>
          {/* The amounts have their own columns from md up. */}
          {swap && (
            <span className="md:hidden truncate" style={body("p3", color.textMuted)}>
              {AMOUNT.format(swap.tokenIn.amount)} {swap.tokenIn.symbol} → {AMOUNT.format(swap.tokenOut.amount)} {swap.tokenOut.symbol}
            </span>
          )}
          {!swap && tx.valueUsd !== undefined && (
            <span className="md:hidden truncate" style={body("p3", color.textMuted)}>
              {USD.format(tx.valueUsd)}
            </span>
          )}
        </div>
      </div>

      <div className={`${MD} min-w-0`}>
        <Amount token={swap?.tokenIn} usd={valueIn} />
      </div>

      <div className={`${MD} min-w-0`}>
        <Amount token={swap?.tokenOut} usd={valueOut} note={swap ? slip : undefined} />
      </div>

      <span
        className="text-right md:text-left whitespace-nowrap"
        style={body("p2", color.textMuted)}
        title={fullTime}
        suppressHydrationWarning
      >
        {timeAgo(tx.timestamp)}
      </span>

      {scope === "all" && (
        <span className={`${LG_FLEX} items-center gap-2 min-w-0`} style={body("p2", color.textSecondary)}>
          <ChainBadge chainId={tx.chainId} size={16} />
          <span className="truncate">{DEPLOYMENTS[tx.chainId]?.name ?? tx.chainId}</span>
        </span>
      )}

      <span
        className={`${XL_FLEX} items-center justify-end gap-1.5 opacity-70 group-hover:opacity-100 transition-opacity`}
        style={body("p2", color.textMuted)}
      >
        {tx.hash.slice(0, 8)}…{tx.hash.slice(-4)}
        <ArrowSquareOut size={14} weight="regular" />
      </span>
    </div>
  );
}
