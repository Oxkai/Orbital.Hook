"use client";

import {
  ComposedChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
} from "recharts";
import { color } from "@/constants";

// ── Math ──────────────────────────────────────────────────────────────────────

/** Depeg price at which a band of plane constant `kNorm` (k / r) ends: the
 *  inverse of the hook's `kFromDepegPrice`. Null for a plane past the
 *  single-asset limit (a full-range tick), which never leaves the pool.
 *
 *  Near the peg the plane sits only (n-1)/2n·(1-p)² above kMin (about 1e-7
 *  for a 0.1% band), so the peg test must be far tighter than that or narrow
 *  bands all collapse onto $1. */
function kNormToDepegNum(n: number, kNorm: number): number | null {
  const kMin       = Math.sqrt(n) - 1;
  const kSingleMax = Math.sqrt(n) - (n - 1) / Math.sqrt(n * (n - 1));
  if (kNorm <= kMin * (1 + 1e-13)) return 1.0;
  if (kNorm >= kSingleMax)         return null;
  let lo = 0, hi = 1;
  for (let i = 0; i < 64; i++) {
    const mid = (lo + hi) / 2;
    const val = Math.sqrt(n) - (mid + n - 1) / Math.sqrt(n * (mid * mid + n - 1));
    if (val < kNorm) hi = mid; else lo = mid;
  }
  return (lo + hi) / 2;
}

/** Bands holding less than this share of the depth don't set the x-axis:
 *  a sliver of wide liquidity would otherwise stretch the axis and squeeze
 *  every visible step against the peg. It is still drawn. */
const FRAME_MIN_SHARE = 0.02;

/** Liquidity is the ticks' radius: the depth they quote with (like Uniswap
 *  v3's L), not dollars. A concentrated band's radius is far larger than the
 *  capital behind it, since most of its reserves are virtual. */
function fmtR(v: number): string {
  if (v >= 1e9) return `${(v / 1e9).toFixed(1)}B`;
  if (v >= 1e6) return `${(v / 1e6).toFixed(1)}M`;
  if (v >= 1e3) return `${(v / 1e3).toFixed(0)}K`;
  return v.toFixed(0);
}

// ── Types ─────────────────────────────────────────────────────────────────────

type Props = {
  ticks:  { kWad: bigint; r: number; isInterior: boolean }[];
  n:      number;
  rInt:   number;
  kBound: number;
  sumX:   bigint;
};

const FONT = "var(--font-mono), Menlo, Monaco, monospace";
const TICK_STYLE = { fontFamily: FONT, fontSize: 10, fill: color.textMuted, letterSpacing: "0.04em" };

// ── Component ─────────────────────────────────────────────────────────────────

export function DepthChart({ ticks, n, rInt, kBound, sumX }: Props) {
  // Each live tick and the depeg price its band ends at (0 for full range,
  // which is active at every price).
  const bands = ticks
    .filter((t) => t.r > 0)
    .map((t) => ({ r: t.r, bound: kNormToDepegNum(n, Number(t.kWad) / 1e18 / t.r) ?? 0 }));
  const totalR = bands.reduce((s, b) => s + b.r, 0);
  if (totalR === 0) return null;

  // x-axis: frame the bands that carry the depth, with a small margin.
  const framed   = bands.filter((b) => b.bound > 0 && b.r >= totalR * FRAME_MIN_SHARE);
  const minBound = framed.length > 0 ? Math.min(...framed.map((b) => b.bound)) : 0.99;
  const spread   = 1 - minBound;
  const xMin     = parseFloat(Math.max(0, minBound - spread * 0.15).toFixed(4));
  const xMax     = parseFloat((1 + spread * 0.02).toFixed(4));
  const step     = (xMax - xMin) / 5;
  const xTicks   = Array.from({ length: 6 }, (_, i) => parseFloat((xMin + i * step).toFixed(4)));

  // Liquidity active at price p: every tick whose band reaches below p. A
  // step down at each band's end, from the peg outward.
  const pts: { x: number; y: number }[] = [{ x: xMax, y: totalR }];
  let cumY = totalR;
  for (const b of [...bands].sort((a, c) => c.bound - a.bound)) {
    if (b.bound < xMin) break;
    pts.push({ x: b.bound, y: cumY });
    cumY -= b.r;
    pts.push({ x: b.bound, y: Math.max(0, cumY) });
  }
  pts.push({ x: xMin, y: Math.max(0, cumY) });

  // Needle: the pool sits on the boundary of a band whose plane is today's
  // αNorm, so that band's depeg price is where the pool is (the peg when
  // balanced, moving outward as it imbalances).
  const alphaNorm = rInt > 0 ? (Number(sumX) / 1e18 / Math.sqrt(n) - kBound / 1e18) / rInt : Math.sqrt(n) - 1;
  const needleX   = Math.min(xMax, Math.max(xMin, kNormToDepegNum(n, alphaNorm) ?? xMin));

  const yMax = totalR * 1.18;

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      {/* Chart canvas: parent panel provides surface + header */}
      <div style={{ flex: 1, minHeight: 0, padding: "16px 16px 14px 4px" }}>
        <ResponsiveContainer width="100%" height="100%">
          <ComposedChart data={pts} margin={{ top: 6, right: 8, bottom: 20, left: 10 }}>
            <defs>
              <linearGradient id="depthFill" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%"   stopColor={color.accent} stopOpacity={0.28} />
                <stop offset="100%" stopColor={color.accent} stopOpacity={0.03} />
              </linearGradient>
            </defs>

            <CartesianGrid
              vertical={false}
              stroke={color.borderSubtle}
              strokeWidth={0.6}
            />

            <XAxis
              dataKey="x"
              type="number"
              domain={[xMin, xMax]}
              ticks={xTicks}
              tickFormatter={(v: number) => `$${v.toFixed(4)}`}
              tick={TICK_STYLE}
              axisLine={{ stroke: color.border, strokeWidth: 0.75 }}
              tickLine={false}
              label={{
                value: "depeg price →",
                position: "insideBottom",
                offset: -12,
                style: { fontFamily: FONT, fontSize: 9, fill: color.textMuted, letterSpacing: "0.04em" },
              }}
            />

            <YAxis
              type="number"
              domain={[0, yMax]}
              tickFormatter={fmtR}
              tick={TICK_STYLE}
              axisLine={false}
              tickLine={false}
              width={48}
            />

            <Tooltip
              contentStyle={{
                backgroundColor: color.surface2,
                border: `1px solid ${color.border}`,
                borderRadius: 2,
                fontFamily: FONT,
                fontSize: 11,
                color: color.textSecondary,
              }}
              formatter={(val) => [fmtR(Number(val)), "Liquidity"]}
              labelFormatter={(v) => `Price: $${Number(v).toFixed(3)}`}
              cursor={{ stroke: color.borderSubtle, strokeWidth: 1 }}
            />

            <Area
              dataKey="y"
              type="stepBefore"
              fill="url(#depthFill)"
              stroke={color.accent}
              strokeWidth={1.5}
              dot={false}
              isAnimationActive={false}
            />

            {/* αNorm needle */}
            <ReferenceLine
              x={needleX}
              stroke={color.accent}
              strokeWidth={1.2}
              strokeDasharray="3 2.5"
              label={{
                value: "NOW",
                position: "top",
                style: {
                  fontFamily: FONT,
                  fontSize: 9,
                  fill: color.accent,
                  letterSpacing: "0.07em",
                },
              }}
            />
          </ComposedChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}
