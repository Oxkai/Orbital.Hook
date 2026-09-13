"use client";

import { useState, useEffect, use } from "react";
import Link from "next/link";
import { ArrowLeft, Check, CaretDown, CaretUp, Info } from "@phosphor-icons/react";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { type Address, type Hash, maxUint256 } from "viem";
import { color, typography } from "@/constants";
import { fmtUSD } from "@/lib/mock/data";
import { usePool } from "@/lib/hooks/usePool";
import { useDepositQuote } from "@/lib/hooks/useDepositQuote";
import { useTokenBalances, useTokenAllowances } from "@/lib/hooks/useTokenBalances";
import { ERC20_ABI, HOOK_LP_ABI } from "@/lib/contracts";
import { chainIdForPool, poolByAddress, type PoolType } from "@/lib/crosschain";

// ─── Helpers ──────────────────────────────────────────────────────────────────

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

function mono(size: string = "12px", col: string = color.textSecondary) {
  return {
    fontFamily: "var(--font-mono)" as const,
    fontSize: size,
    color: col,
    fontVariantNumeric: "tabular-nums" as const,
  };
}

// ─── Tick math ────────────────────────────────────────────────────────────────

function kNormFromDepegPrice(n: number, p: number): number {
  if (p >= 1) return Math.sqrt(n) - 1;
  if (p <= 0) return (n - 1) / Math.sqrt(n);
  const sqrtN = Math.sqrt(n);
  const sqrtDenom = Math.sqrt(n * (p * p + n - 1));
  return sqrtN - (p + n - 1) / sqrtDenom;
}

// Compute the practical slider price bounds from pool n:
// pMax → tightest useful tick (high capital efficiency, depeg triggers early)
// pMin → widest useful tick (low efficiency, only triggers on large depeg)
// Price range for the slider: 0.80 (wide/safe) → 0.9999 (tight/efficient)
// This covers the full meaningful range of depeg thresholds for any n.
const SLIDER_PMIN = 0.80;
const SLIDER_PMAX = 0.9999;

function capitalEfficiency(n: number, kNorm: number): number {
  const sqrtN = Math.sqrt(n);
  const xBase = 1 - 1 / sqrtN;
  const kSqrtN = kNorm * sqrtN;
  const A = (n - 1) - kSqrtN;
  const disc = kNorm * kNorm * n - n * A * A;
  if (disc < 0) return 1;
  const xMin = (kSqrtN - Math.sqrt(disc)) / n;
  if (xBase <= xMin) return 1;
  return xBase / (xBase - xMin);
}

// ─── Step indicator ───────────────────────────────────────────────────────────

function StepBar({ step }: { step: 1 | 2 | 3 }) {
  const STEPS = [{ n: 1, label: "Range" }, { n: 2, label: "Amount" }, { n: 3, label: "Review" }] as const;
  return (
    <div className="flex items-center">
      {STEPS.map((s, i) => {
        const done   = step > s.n;
        const active = step === s.n;
        return (
          <div key={s.n} className="flex items-center">
            <div className="flex items-center gap-2">
              <div
                style={{
                  width: 22,
                  height: 22,
                  borderRadius: "50%",
                  border: `1px solid ${done || active ? color.textPrimary : color.border}`,
                  backgroundColor: done ? color.textPrimary : active ? `${color.textPrimary}1a` : "transparent",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  flexShrink: 0,
                  transition: "all 0.2s ease",
                }}
              >
                {done
                  ? <Check size={11} color={color.bg} weight="bold" />
                  : (
                    <span
                      style={{
                        ...body("caption", active ? color.textPrimary : color.textMuted),
                        fontWeight: 500,
                      }}
                    >
                      {s.n}
                    </span>
                  )}
              </div>
              <span
                style={{
                  ...LBL,
                  color: active ? color.textPrimary : done ? color.textSecondary : color.textMuted,
                }}
              >
                {s.label}
              </span>
            </div>
            {i < 2 && (
              <div
                style={{
                  width: 28,
                  height: 1,
                  backgroundColor: step > s.n ? color.textPrimary : color.border,
                  margin: "0 12px",
                  flexShrink: 0,
                  transition: "background-color 0.2s ease",
                }}
              />
            )}
          </div>
        );
      })}
    </div>
  );
}

// ─── Step 1: set range ───────────────────────────────────────────────────────

/// User-facing wording for the range control. The number is the same on both
/// pool types, the tick's depeg bound `p`, but it means different things: on a
/// stable pool it is a dollar price, on an FX pool the prices are dollar values
/// around a centre rate, so `p` reads as "an FX rate `1 − p` below the rest".
function rangeCopy(poolType: PoolType, p: number) {
  if (poolType === "fx") {
    const pct = (x: number) => `${((1 - x) * 100).toFixed(2)}%`;
    return {
      intro: "Choose an FX band around the pool's centre rate. Tighter bands earn more fees but pause sooner.",
      blocked: "A boundary tick is active. Deposits resume when every rate is back inside its band.",
      label: "FX Band",
      value: pct(p),
      valueNote: "Tick pauses when any currency trades this far below the rest",
      sliderMin: `${pct(SLIDER_PMIN)} · wider · safer`,
      sliderMax: `more efficient · tighter · ${pct(SLIDER_PMAX)}`,
      barMin: "−100%",
      barMark: `−${pct(p)}`,
      barMax: "centre",
      legendPaused: `paused beyond −${pct(p)}`,
      legendEarning: `earning fees within ${pct(p)} of the centre`,
    };
  }
  const usd = `$${p.toFixed(4)}`;
  return {
    intro: "Choose a depeg price threshold. Tighter ranges earn more fees but pause sooner.",
    blocked: "A boundary tick is active. Deposits resume when all assets return to peg.",
    label: "Depeg Price Threshold",
    value: usd,
    valueNote: "Tick pauses when any asset depegs below this price",
    sliderMin: `$${SLIDER_PMIN} · wider · safer`,
    sliderMax: `more efficient · tighter · $${SLIDER_PMAX}`,
    barMin: "$0",
    barMark: usd,
    barMax: "$1.00",
    legendPaused: `paused below ${usd}`,
    legendEarning: `earning fees ${usd} → $1.00`,
  };
}

function Step1({
  depegPrice, setDepegPrice,
  onContinue, kBound, n, poolType,
}: {
  depegPrice: number;
  setDepegPrice: (p: number) => void;
  onContinue: () => void;
  kBound: number;
  n: number;
  poolType: PoolType;
}) {
  const [explainerOpen, setExplainerOpen] = useState(false);
  const blocked  = kBound > 0;
  const copy     = rangeCopy(poolType, depegPrice);

  const kNorm    = kNormFromDepegPrice(n, depegPrice);
  const effMult  = capitalEfficiency(n, kNorm);
  const kNormMin = Math.sqrt(n) - 1;
  const kNormMax = (n - 1) / Math.sqrt(n);
  const sliderPct = ((depegPrice - SLIDER_PMIN) / (SLIDER_PMAX - SLIDER_PMIN)) * 100;

  return (
    <div className="flex flex-col gap-7">
      {/* Header */}
      <div className="flex flex-col gap-1.5">
        <h2 style={{ fontFamily: typography.h3.family, fontSize: typography.h3.size, lineHeight: typography.h3.lineHeight, fontWeight: 500, letterSpacing: typography.h3.letterSpacing, color: color.textPrimary }}>
          Set your range
        </h2>
        <p style={body("p2", color.textMuted)}>
          {copy.intro}
        </p>
      </div>

      {blocked && (
        <div
          className="flex items-start gap-3 px-5 py-3.5"
          style={{ backgroundColor: `${color.warning}0d` }}
        >
          <Info size={14} color={color.warning} weight="regular" style={{ marginTop: 1, flexShrink: 0 }} />
          <div>
            <div style={{ ...body("caption", color.warning), fontWeight: 500, letterSpacing: "0.02em", marginBottom: 3 }}>
              Deposits paused
            </div>
            <p style={{ ...body("caption", color.warning), opacity: 0.8 }}>
              {copy.blocked}
            </p>
          </div>
        </div>
      )}

      {/* ── Threshold + slider ───────────────────────────────────── */}
      <div>
        <div className="flex items-center justify-between gap-3 px-1 pb-3">
          <span style={{ ...LBL, color: color.textMuted }}>{copy.label}</span>
          <span style={body("caption", color.textMuted)}>
            Capital efficiency · <span style={{ color: color.accent, fontWeight: 500 }}>{effMult.toFixed(1)}×</span>
          </span>
        </div>

        <div className="flex flex-col gap-px">
          {/* Value display row */}
          <div className="px-5 py-5" style={{ backgroundColor: color.surface1 }}>
            <div className="flex items-end justify-between gap-4">
              <div>
                <div
                  style={{
                    fontFamily: typography.h1.family,
                    fontSize: "42px",
                    fontWeight: 500,
                    letterSpacing: "-0.03em",
                    lineHeight: 1,
                    color: color.textPrimary,
                    fontVariantNumeric: "tabular-nums",
                  }}
                >
                  {copy.value}
                </div>
                <div style={{ ...body("caption", color.textMuted), marginTop: 8 }}>
                  {copy.valueNote}
                </div>
              </div>
              <div
                style={{
                  fontFamily: typography.h2.family,
                  fontSize: "28px",
                  fontWeight: 500,
                  letterSpacing: "-0.02em",
                  lineHeight: 1,
                  color: color.accent,
                  fontVariantNumeric: "tabular-nums",
                }}
              >
                {effMult.toFixed(1)}×
              </div>
            </div>
          </div>

          {/* Slider row */}
          <div className="px-5 pt-3 pb-5" style={{ backgroundColor: color.surface1 }}>
            <div className="relative">
              <input
                type="range"
                min={0}
                max={100}
                step={0.01}
                value={sliderPct}
                onChange={e => {
                  const pct = parseFloat(e.target.value);
                  setDepegPrice(SLIDER_PMIN + (pct / 100) * (SLIDER_PMAX - SLIDER_PMIN));
                }}
                className="modern-slider"
                style={{
                  ["--slider-pct" as string]: `${sliderPct}%`,
                  ["--slider-accent" as string]: color.accent,
                  ["--slider-track" as string]: color.surface3,
                } as React.CSSProperties}
              />
              <div className="absolute inset-x-0 top-[18px] flex justify-between pointer-events-none px-[6px]">
                {[0, 25, 50, 75, 100].map(t => (
                  <span
                    key={t}
                    style={{
                      width: 1,
                      height: 4,
                      backgroundColor: t <= sliderPct ? color.accent : color.surface4,
                      opacity: t <= sliderPct ? 0.4 : 0.6,
                    }}
                  />
                ))}
              </div>
            </div>

            <div className="flex justify-between pt-4">
              <span style={body("caption", color.textMuted)}>
                {copy.sliderMin}
              </span>
              <span style={body("caption", color.textMuted)}>
                {copy.sliderMax}
              </span>
            </div>
          </div>
        </div>
      </div>

      {/* ── Active liquidity visualization ───────────────────────── */}
      <div>
        <span style={{ ...LBL, color: color.textMuted, paddingLeft: 4 }}>Active Liquidity Range</span>
        <div className="mt-3 px-5 py-5" style={{ backgroundColor: color.surface1 }}>
          {/* Bar */}
          <div style={{ position: "relative", height: 6, backgroundColor: color.surface3, marginBottom: 8 }}>
            <div style={{
              position: "absolute", left: `${depegPrice * 100}%`, top: 0, height: "100%",
              width: `${(1 - depegPrice) * 100}%`,
              backgroundColor: color.accent,
              opacity: 0.85,
            }} />
            <div style={{
              position: "absolute", left: `${depegPrice * 100}%`, top: -3, width: 2, height: 12,
              backgroundColor: color.accent, transform: "translateX(-1px)",
            }} />
          </div>
          {/* Position labels */}
          <div style={{ position: "relative", height: 18 }}>
            <span style={{ ...body("caption", color.textMuted), position: "absolute", left: 0 }}>{copy.barMin}</span>
            <span style={{
              ...body("caption", color.accent),
              fontWeight: 500,
              position: "absolute",
              left: `${depegPrice * 100}%`,
              transform: "translateX(-50%)",
              whiteSpace: "nowrap",
            }}>{copy.barMark}</span>
            <span style={{ ...body("caption", color.textMuted), position: "absolute", right: 0 }}>{copy.barMax}</span>
          </div>
          {/* Legend */}
          <div className="flex items-center justify-between pt-4 mt-4" style={{ borderTop: `1px dashed ${color.borderSubtle}` }}>
            <span className="flex items-center gap-2" style={body("caption", color.textMuted)}>
              <span style={{ width: 8, height: 8, backgroundColor: color.surface3, display: "inline-block" }} />
              {copy.legendPaused}
            </span>
            <span className="flex items-center gap-2" style={body("caption", color.textMuted)}>
              <span style={{ width: 8, height: 8, backgroundColor: color.accent, display: "inline-block", opacity: 0.85 }} />
              {copy.legendEarning}
            </span>
          </div>
        </div>

        {/* k_norm stats */}
        <div className="grid grid-cols-3 gap-px mt-px">
          {[
            { label: "k_norm",  value: kNorm.toFixed(5) },
            { label: "k_min",   value: kNormMin.toFixed(3) },
            { label: "k_max",   value: kNormMax.toFixed(3) },
          ].map(r => (
            <div key={r.label} className="px-5 py-3.5 flex flex-col gap-1" style={{ backgroundColor: color.surface1 }}>
              <span style={{ ...LBL, color: color.textMuted }}>{r.label}</span>
              <span style={body("p3", color.textSecondary)}>{r.value}</span>
            </div>
          ))}
        </div>
      </div>

      {/* Efficiency hint */}
      <div
        className="flex items-start gap-3 px-5 py-4"
        style={{ backgroundColor: `${color.accent}0d` }}
      >
        <Info size={14} color={color.accent} weight="regular" style={{ marginTop: 1, flexShrink: 0 }} />
        <p style={{ ...body("p3", color.textSecondary), lineHeight: 1.6 }}>
          At <strong style={{ color: color.textPrimary, fontWeight: 500 }}>${depegPrice.toFixed(4)}</strong> threshold
          you get <strong style={{ color: color.accent, fontWeight: 500 }}>{effMult.toFixed(1)}× capital efficiency</strong> vs a full-range position.
          Tighter ticks earn more fees but pause sooner during a depeg event.
        </p>
      </div>

      {/* Explainer */}
      <div style={{ backgroundColor: color.surface1 }}>
        <button
          onClick={() => setExplainerOpen(v => !v)}
          className="w-full flex items-center justify-between px-5 py-3 hover:bg-(--color-surface-2) transition-colors"
          style={{ cursor: "pointer" }}
        >
          <span style={body("p3", color.textSecondary)}>What is a tick?</span>
          {explainerOpen
            ? <CaretUp size={12} color={color.textMuted} weight="regular" />
            : <CaretDown size={12} color={color.textMuted} weight="regular" />}
        </button>
        {explainerOpen && (
          <div className="px-5 pb-4 pt-1" style={{ borderTop: `1px dashed ${color.borderSubtle}` }}>
            <p style={{ ...body("caption", color.textSecondary), lineHeight: 1.65, paddingTop: 12 }}>
              Each tick is an independent sphere AMM. When reserves reach its plane boundary (your depeg threshold),
              the tick pauses and stops accepting swaps until assets re-peg. Tighter ticks have higher capital
              efficiency but activate earlier. Your liquidity is never lost; it just earns no fees while paused.
            </p>
          </div>
        )}
      </div>

      <button
        disabled={blocked}
        onClick={() => !blocked && onContinue()}
        className="w-full flex items-center justify-center h-12 hover:opacity-90 transition-opacity"
        style={{
          backgroundColor: blocked ? color.surface2 : color.textPrimary,
          color: blocked ? color.textMuted : color.bg,
          fontFamily: typography.p1.family,
          fontSize: typography.p1.size,
          fontWeight: 500,
          letterSpacing: "-0.01em",
          cursor: blocked ? "not-allowed" : "pointer",
        }}
      >
        {blocked ? "Deposits paused" : "Continue →"}
      </button>
    </div>
  );
}

// ─── Step 2: amount ──────────────────────────────────────────────────────────

const QUICK_PCTS = [25, 50, 75, 100] as const;

/// Per-asset deposit (USD) and its share of the total, for display.
function depositSplits(tokens: { symbol: string; address: string; color: string }[], split: number[], n: number) {
  const total = split.reduce((a, b) => a + b, 0);
  return tokens.map((t, i) => ({
    token: t,
    pct:   total > 0 ? (split[i] ?? 0) / total : 1 / n,
    usd:   split[i] ?? 0,
  }));
}

function Step2({ depegPrice, n, tokens, split, quoteError, quoting, balances, usdAmount, setUsdAmount, onBack, onContinue }: {
  depegPrice: number;
  n: number;
  tokens: { symbol: string; address: string; color: string }[];
  /** Quoted deposit per asset, USD. */
  split: number[];
  quoteError?: string;
  quoting: boolean;
  balances: number[];
  usdAmount: string;
  setUsdAmount: (v: string) => void;
  onBack: () => void;
  onContinue: () => void;
}) {
  const num          = parseFloat(usdAmount) || 0;
  const walletUSD    = balances.reduce((a, b) => a + b, 0);
  const splits       = depositSplits(tokens, split, n);
  const canContinue  = num > 0 && !quoteError && !quoting;
  const activeQuick = QUICK_PCTS.find(p => usdAmount === ((walletUSD * p) / 100).toFixed(2));

  return (
    <div className="flex flex-col gap-7">
      {/* Header */}
      <div className="flex flex-col gap-1.5">
        <h2 style={{ fontFamily: typography.h3.family, fontSize: typography.h3.size, lineHeight: typography.h3.lineHeight, fontWeight: 500, letterSpacing: typography.h3.letterSpacing, color: color.textPrimary }}>
          Set deposit amount
        </h2>
        <p style={body("p2", color.textMuted)}>
          Tokens deposit at the current pool ratio.
        </p>
      </div>

      {/* Tick context */}
      <button
        onClick={onBack}
        className="flex items-center justify-between gap-3 px-5 py-3 hover:bg-(--color-surface-2) transition-colors"
        style={{ backgroundColor: color.surface1, cursor: "pointer" }}
      >
        <div className="flex items-center gap-2.5">
          <span style={{ ...LBL, color: color.textMuted }}>New Tick</span>
          <span style={body("p3", color.textPrimary)}>${depegPrice.toFixed(4)}</span>
        </div>
        <span className="flex items-center gap-1.5" style={body("caption", color.textMuted)}>
          <ArrowLeft size={11} weight="regular" /> Change
        </span>
      </button>

      {/* Amount input */}
      <div>
        <div className="flex items-center justify-between gap-3 px-1 pb-3">
          <span style={{ ...LBL, color: color.textMuted }}>Deposit Amount (USD)</span>
          <span style={body("caption", color.textMuted)}>
            Balance ≈ {fmtUSD(walletUSD)}
          </span>
        </div>

        <div className="flex flex-col gap-px">
          {/* Big input row */}
          <div className="px-5 py-5" style={{ backgroundColor: color.surface1 }}>
            <div className="flex items-baseline gap-2">
              <span
                style={{
                  fontFamily: typography.h1.family,
                  fontSize: "32px",
                  fontWeight: 500,
                  color: color.textMuted,
                  letterSpacing: "-0.02em",
                }}
              >
                $
              </span>
              <input
                type="text" inputMode="decimal" placeholder="0"
                value={usdAmount}
                onChange={e => { if (/^\d*(?:\.\d*)?$/.test(e.target.value)) setUsdAmount(e.target.value); }}
                className="flex-1 bg-transparent outline-none"
                style={{
                  fontFamily: typography.h1.family,
                  fontSize: "44px",
                  letterSpacing: "-0.03em",
                  color: usdAmount ? color.textPrimary : color.textMuted,
                  lineHeight: 1,
                  fontVariantNumeric: "tabular-nums",
                  fontWeight: 500,
                }}
              />
            </div>
          </div>

          {/* Quick pct row */}
          <div className="flex gap-2 px-5 py-3" style={{ backgroundColor: color.surface1 }}>
            {QUICK_PCTS.map(pct => {
              const active = activeQuick === pct;
              return (
                <button
                  key={pct}
                  onClick={() => setUsdAmount(((walletUSD * pct) / 100).toFixed(2))}
                  className="flex items-center justify-center h-9 px-4 hover:opacity-90 transition-opacity"
                  style={{
                    backgroundColor: active ? `${color.accent}1f` : color.surface2,
                    color: active ? color.accent : color.textSecondary,
                    fontFamily: typography.caption.family,
                    fontSize: "11px",
                    fontWeight: 500,
                    letterSpacing: "0.06em",
                    textTransform: "uppercase",
                    cursor: "pointer",
                  }}
                >
                  {pct === 100 ? "Max" : `${pct}%`}
                </button>
              );
            })}
          </div>
        </div>
      </div>

      {quoteError && (
        <div className="px-5 py-3" style={{ backgroundColor: color.surface1, borderLeft: `2px solid ${color.warning}` }}>
          <span style={body("p3", color.warning)}>{quoteError}</span>
        </div>
      )}

      {/* Token splits */}
      {num > 0 && !quoteError && (
        <div>
          <span style={{ ...LBL, color: color.textMuted, paddingLeft: 4 }}>Token Splits</span>
          <div className="flex flex-col gap-px mt-3">
            {splits.map(({ token, pct, usd }, i) => (
              <div
                key={`${token.address}-${i}`}
                className="px-5 py-3.5 flex flex-col gap-2"
                style={{ backgroundColor: color.surface1 }}
              >
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2.5">
                    <span style={{ width: 8, height: 8, backgroundColor: token.color, display: "inline-block" }} />
                    <span style={body("p3", color.textSecondary)}>{token.symbol}</span>
                  </div>
                  <div className="flex items-center gap-4">
                    <span style={body("caption", color.textMuted)}>{(pct * 100).toFixed(1)}%</span>
                    <span style={{ ...body("p3", color.textPrimary), fontWeight: 500, minWidth: 64, textAlign: "right" as const }}>
                      {fmtUSD(usd)}
                    </span>
                  </div>
                </div>
                <div style={{ height: 2, backgroundColor: color.surface3 }}>
                  <div style={{ width: `${pct * 100}%`, height: "100%", backgroundColor: token.color }} />
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      <button
        disabled={!canContinue}
        onClick={() => canContinue && onContinue()}
        className="w-full flex items-center justify-center h-12 hover:opacity-90 transition-opacity"
        style={{
          backgroundColor: !canContinue ? color.surface2 : color.textPrimary,
          color: !canContinue ? color.textMuted : color.bg,
          fontFamily: typography.p1.family,
          fontSize: typography.p1.size,
          fontWeight: 500,
          letterSpacing: "-0.01em",
          cursor: !canContinue ? "not-allowed" : "pointer",
        }}
      >
        {num <= 0 ? "Enter an amount" : quoting ? "Quoting…" : quoteError ? "Band unavailable" : "Review deposit →"}
      </button>
    </div>
  );
}

// ─── Step 3: review + submit ─────────────────────────────────────────────────

function Step3({ depegPrice, n, tokens, split, amountsRaw, amount, allowances, fee, slippage, onBack, onApprove, onMint, isTxPending, approveIdx, walletConnected }: {
  depegPrice: number;
  n: number;
  tokens: { symbol: string; address: string; color: string }[];
  /** Quoted deposit per asset, USD. */
  split: number[];
  /** Quoted deposit per asset in raw token units, what the approvals must cover. */
  amountsRaw: bigint[];
  amount: number;
  allowances: bigint[];
  fee: number;
  slippage: number;
  onBack: () => void;
  onApprove: (tokenIdx: number) => void;
  onMint: () => void;
  isTxPending: boolean;
  approveIdx: number;
  walletConnected: boolean;
}) {
  const splits = depositSplits(tokens, split, n);
  // Allowances are in raw token units, so compare against the raw deposit.
  const needsApproval = tokens.findIndex((_, i) => (allowances[i] ?? 0n) < (amountsRaw[i] ?? 0n));
  const allApproved   = needsApproval === -1;

  const kNorm = kNormFromDepegPrice(n, depegPrice);
  const eff   = capitalEfficiency(n, kNorm);

  return (
    <div className="flex flex-col gap-7">
      {/* Header */}
      <div className="flex flex-col gap-1.5">
        <h2 style={{ fontFamily: typography.h3.family, fontSize: typography.h3.size, lineHeight: typography.h3.lineHeight, fontWeight: 500, letterSpacing: typography.h3.letterSpacing, color: color.textPrimary }}>
          Review deposit
        </h2>
        <p style={body("p2", color.textMuted)}>
          Confirm before submitting on-chain.
        </p>
      </div>

      {/* Total */}
      <div>
        <span style={{ ...LBL, color: color.textMuted, paddingLeft: 4 }}>Total Deposit</span>
        <div className="mt-3 px-5 py-5" style={{ backgroundColor: color.surface1 }}>
          <div
            style={{
              fontFamily: typography.h1.family,
              fontSize: "36px",
              fontWeight: 500,
              letterSpacing: "-0.03em",
              lineHeight: 1,
              color: color.textPrimary,
              fontVariantNumeric: "tabular-nums",
            }}
          >
            {fmtUSD(amount)}
          </div>
        </div>
      </div>

      {/* Token breakdown */}
      <div>
        <span style={{ ...LBL, color: color.textMuted, paddingLeft: 4 }}>Token Breakdown</span>
        <div className="flex flex-col gap-px mt-3">
          {splits.map(({ token, pct, usd }, i) => (
            <div
              key={`${token.address}-${i}`}
              className="flex items-center justify-between gap-3 px-5 py-3.5"
              style={{ backgroundColor: color.surface1 }}
            >
              <div className="flex items-center gap-2.5">
                <span style={{ width: 8, height: 8, backgroundColor: token.color, display: "inline-block" }} />
                <span style={body("p3", color.textSecondary)}>{token.symbol}</span>
              </div>
              <div className="flex items-center gap-4">
                <div style={{ width: 80, height: 2, backgroundColor: color.surface3 }}>
                  <div style={{ width: `${pct * 100}%`, height: "100%", backgroundColor: token.color }} />
                </div>
                <span style={{ ...body("p3", color.textPrimary), fontWeight: 500, minWidth: 64, textAlign: "right" as const }}>
                  {fmtUSD(usd)}
                </span>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Position details */}
      <div>
        <span style={{ ...LBL, color: color.textMuted, paddingLeft: 4 }}>Position Details</span>
        <div className="flex flex-col gap-px mt-3">
          {([
            { label: "Type",               value: "New tick",                        accent: false },
            { label: "Depeg threshold",    value: `$${depegPrice.toFixed(4)}`,       accent: false },
            { label: "Capital efficiency", value: `${eff.toFixed(1)}×`,              accent: true  },
            { label: "Fee tier",           value: `${(fee / 10000).toFixed(2)}%`,    accent: false },
            { label: "Slippage",           value: `${slippage.toFixed(1)}%`,         accent: false },
          ] as { label: string; value: string; accent: boolean }[]).map(r => (
            <div
              key={r.label}
              className="flex items-center justify-between px-5 py-3"
              style={{ backgroundColor: color.surface1 }}
            >
              <span style={body("p3", color.textMuted)}>{r.label}</span>
              <span style={{ ...body("p3", r.accent ? color.accent : color.textPrimary), fontWeight: r.accent ? 500 : 400 }}>
                {r.value}
              </span>
            </div>
          ))}
        </div>
      </div>

      {/* Action buttons */}
      <div className="flex flex-col gap-2">
        {!allApproved ? (
          <button
            disabled={isTxPending}
            onClick={() => onApprove(needsApproval)}
            className="w-full flex items-center justify-center h-12 hover:opacity-90 transition-opacity"
            style={{
              backgroundColor: color.accent,
              color: color.bg,
              fontFamily: typography.p1.family,
              fontSize: typography.p1.size,
              fontWeight: 500,
              letterSpacing: "-0.01em",
              cursor: isTxPending ? "not-allowed" : "pointer",
              opacity: isTxPending ? 0.7 : 1,
            }}
          >
            {isTxPending && approveIdx === needsApproval ? "Approving…" : `Approve ${tokens[needsApproval]?.symbol}`}
          </button>
        ) : (
          <button
            disabled={isTxPending || !walletConnected}
            onClick={onMint}
            className="w-full flex items-center justify-center h-12 hover:opacity-90 transition-opacity"
            style={{
              backgroundColor: isTxPending || !walletConnected ? color.surface2 : color.textPrimary,
              color: isTxPending || !walletConnected ? color.textMuted : color.bg,
              fontFamily: typography.p1.family,
              fontSize: typography.p1.size,
              fontWeight: 500,
              letterSpacing: "-0.01em",
              cursor: isTxPending || !walletConnected ? "not-allowed" : "pointer",
            }}
          >
            {!walletConnected ? "Connect wallet" : isTxPending ? "Submitting…" : `Add ${fmtUSD(amount)} Liquidity`}
          </button>
        )}
        <button
          onClick={onBack}
          className="w-full flex items-center justify-center gap-1.5 h-10 hover:opacity-100 opacity-70 transition-opacity"
          style={{
            backgroundColor: "transparent",
            color: color.textMuted,
            fontFamily: typography.p2.family,
            fontSize: typography.p2.size,
            cursor: "pointer",
          }}
        >
          <ArrowLeft size={12} weight="regular" /> Back
        </button>
      </div>
    </div>
  );
}

// ─── Success ──────────────────────────────────────────────────────────────────

function SuccessState({ depegPrice, amount, tokens, split, n }: {
  depegPrice: number;
  amount: number;
  tokens: { symbol: string; address: string; color: string }[];
  split: number[];
  n: number;
}) {
  const splits = depositSplits(tokens, split, n);

  return (
    <div className="flex flex-col items-center gap-7 w-full max-w-md mx-auto py-16" style={{ textAlign: "center" as const }}>
      <div
        style={{
          width: 56,
          height: 56,
          borderRadius: "50%",
          backgroundColor: `${color.success}1f`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <Check size={24} color={color.success} weight="bold" />
      </div>
      <div className="flex flex-col gap-2">
        <h2
          style={{
            fontFamily: typography.h2.family,
            fontSize: typography.h2.size,
            lineHeight: typography.h2.lineHeight,
            fontWeight: 500,
            letterSpacing: typography.h2.letterSpacing,
            color: color.textPrimary,
          }}
        >
          Position created
        </h2>
        <p style={body("p2", color.textMuted)}>
          {fmtUSD(amount)} deposited · new tick @ ${depegPrice.toFixed(4)}
        </p>
      </div>

      <div className="w-full" style={{ textAlign: "left" as const }}>
        <span style={{ ...LBL, color: color.textMuted, paddingLeft: 4 }}>Deposited</span>
        <div className="flex flex-col gap-px mt-3">
          {splits.map(({ token, usd }, i) => (
            <div
              key={`${token.address}-${i}`}
              className="flex items-center justify-between px-5 py-3.5"
              style={{ backgroundColor: color.surface1 }}
            >
              <div className="flex items-center gap-2.5">
                <span style={{ width: 8, height: 8, backgroundColor: token.color, display: "inline-block" }} />
                <span style={body("p3", color.textSecondary)}>{token.symbol}</span>
              </div>
              <span style={{ ...body("p3", color.textPrimary), fontWeight: 500 }}>{fmtUSD(usd)}</span>
            </div>
          ))}
        </div>
      </div>

      <div className="flex gap-2 w-full">
        <Link
          href="/app/positions"
          className="flex-1 flex items-center justify-center h-12 hover:opacity-90 transition-opacity"
          style={{
            backgroundColor: color.textPrimary,
            color: color.bg,
            fontFamily: typography.p1.family,
            fontSize: typography.p1.size,
            fontWeight: 500,
            letterSpacing: "-0.01em",
          }}
        >
          View positions
        </Link>
        <Link
          href="/app/pools"
          className="flex-1 flex items-center justify-center h-12 hover:opacity-90 transition-opacity"
          style={{
            backgroundColor: color.surface2,
            color: color.textPrimary,
            fontFamily: typography.p1.family,
            fontSize: typography.p1.size,
            letterSpacing: "-0.01em",
          }}
        >
          Back to pools
        </Link>
      </div>
    </div>
  );
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function AddLiquidityPage({ params }: { params: Promise<{ address: string }> }) {
  const { address: poolAddr } = use(params);
  const poolAddress = poolAddr as Address;

  const [step,        setStep]       = useState<1 | 2 | 3 | 4>(1);
  const [depegPrice,  setDepegPrice] = useState(0.95);
  const [usdAmount,   setUsdAmount]  = useState("");
  const [approveIdx,  setApproveIdx] = useState(-1);
  const [slippage,    setSlippage]   = useState(0.5);
  const [mintHash,    setMintHash]   = useState<Hash | undefined>();

  const { address } = useAccount();
  // `poolAddress` from the route IS the hook: OrbitalHook is both the book and
  // the LP surface. Using the primary-chain HOOK_ADDRESS constant here approved
  // and minted against Unichain's hook no matter which pool was open, so on
  // Base, Arbitrum or Arc it would have targeted a contract that is not this
  // pool. Everything below routes through the pool's own address and chain.
  const poolChainId = chainIdForPool(poolAddress);
  const poolType    = poolByAddress(poolAddress)?.type ?? "stable";
  const { pool }    = usePool(poolAddress, { chainId: poolChainId });
  const tokenAddrs  = (pool?.tokens.map(t => t.address as Address)) ?? [];

  const { balances }   = useTokenBalances(tokenAddrs, address);
  const { allowances, refetch: refetchAllowances } = useTokenAllowances(tokenAddrs, address, poolAddress);
  const { writeContract, isPending } = useWriteContract();
  const { isSuccess: mintConfirmed } = useWaitForTransactionReceipt({ hash: mintHash, query: { enabled: !!mintHash } });

  useEffect(() => {
    if (mintConfirmed) setStep(4);
  }, [mintConfirmed]);

  const tokens   = pool?.tokens   ?? [];
  const kBound   = pool?.kBound   ?? 0;
  const fee      = pool?.fee      ?? 0;
  const n        = tokens.length || 4;
  const amount   = parseFloat(usdAmount) || 0;

  const clampedDepeg = Math.min(SLIDER_PMAX, Math.max(SLIDER_PMIN, depegPrice));

  // The contract prices the deposit: the radius that deposits exactly the
  // entered value at this band, and each token's share of it. A concentrated
  // band's reserves below its floor are virtual, so its deposit is far less
  // than its radius suggests; nothing here re-derives that geometry.
  const kNormWad = BigInt(Math.round(kNormFromDepegPrice(n, clampedDepeg) * 1e18));
  const valueWad = amount > 0 ? BigInt(Math.round(amount * 1e6)) * 10n ** 12n : 0n;
  const quote    = useDepositQuote(poolAddress, poolChainId, tokens.length, kNormWad, valueWad, step >= 2 && amount > 0);
  const split    = quote.amountsWad.map((a) => Number(a) / 1e18);

  function handleApprove(idx: number) {
    if (!address) return;
    setApproveIdx(idx);
    writeContract(
      { address: tokenAddrs[idx], abi: ERC20_ABI, functionName: "approve", args: [poolAddress, maxUint256], chainId: poolChainId },
      { onSuccess: () => refetchAllowances() }
    );
  }

  function handleMint() {
    if (!address || !pool || quote.rWad === 0n || quote.error) return;

    // Each asset may cost at most its quoted amount plus the slippage
    // tolerance, in case the pool moves between quote and inclusion.
    const tolBps = BigInt(Math.round(slippage * 100));
    const maxAmounts = quote.amountsWad.map((a) => a + (a * tolBps) / 10_000n + 1n);

    writeContract(
      {
        address: poolAddress,
        abi: HOOK_LP_ABI,
        functionName: "addLiquidity",
        args: [quote.kWad, quote.rWad, maxAmounts],
        chainId: poolChainId,
      },
      { onSuccess: (hash) => setMintHash(hash) }
    );
  }

  if (step === 4) {
    return (
      <div className="flex-1 overflow-y-auto" style={{ backgroundColor: color.bg }}>
        <SuccessState depegPrice={clampedDepeg} amount={amount} tokens={tokens} split={split} n={n} />
      </div>
    );
  }

  return (
    <section className="flex-1 flex flex-col py-8 sm:py-10">
      {/* ── Hero ─────────────────────────────────────────────────── */}
      <header className="flex flex-col gap-3 pb-7">
        <div className="flex items-end justify-between gap-4 flex-wrap">
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
            Add Liquidity
          </h1>
          <StepBar step={step as 1 | 2 | 3} />
        </div>
      </header>

      {/* ── Body ─────────────────────────────────────────────────── */}
      <div className="max-w-xl w-full mx-auto py-2">
        {step === 1 && (
          <Step1
            depegPrice={clampedDepeg} setDepegPrice={setDepegPrice}
            onContinue={() => setStep(2)} kBound={kBound} n={n} poolType={poolType}
          />
        )}
        {step === 2 && (
          <Step2
            depegPrice={clampedDepeg} n={n}
            tokens={tokens} split={split} quoteError={quote.error} quoting={quote.loading} balances={balances}
            usdAmount={usdAmount} setUsdAmount={setUsdAmount}
            onBack={() => setStep(1)} onContinue={() => setStep(3)}
          />
        )}
        {step === 3 && (
          <Step3
            depegPrice={clampedDepeg} n={n}
            tokens={tokens} split={split} amountsRaw={quote.amountsRaw} amount={amount} allowances={allowances}
            fee={fee} slippage={slippage}
            onBack={() => setStep(2)}
            onApprove={handleApprove}
            onMint={handleMint}
            isTxPending={isPending}
            approveIdx={approveIdx}
            walletConnected={!!address}
          />
        )}
      </div>
    </section>
  );
}
