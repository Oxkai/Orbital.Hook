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

function kNormToDepegNum(n: number, kNorm: number): number | null {
  const kMin       = Math.sqrt(n) - 1;
  const kSingleMax = Math.sqrt(n) - (n - 1) / Math.sqrt(n * (n - 1));
  if (kNorm <= kMin + 1e-6)        return 1.0;
  if (kNorm >= kSingleMax - 1e-6)  return null;
  let lo = 0.0001, hi = 0.9999;
  for (let i = 0; i < 48; i++) {
    const mid = (lo + hi) / 2;
    const val = Math.sqrt(n) - (mid + n - 1) / Math.sqrt(n * (mid * mid + n - 1));
    if (val < kNorm) hi = mid; else lo = mid;
  }
  return (lo + hi) / 2;
}

function fmtR(v: number): string {
  if (v >= 1e6) return `$${(v / 1e6).toFixed(1)}M`;
  if (v >= 1e3) return `$${(v / 1e3).toFixed(0)}K`;
  return `$${v.toFixed(0)}`;
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
  if (ticks.length === 0) return null;

  // Per-tick info
  const tickInfos = ticks.map((t) => {
    const kNorm    = t.r > 0 ? (Number(t.kWad) / 1e18) / t.r : 0;
    const depegNum = kNormToDepegNum(n, kNorm);
    return {
      r:          t.r,
      depeg:      depegNum ?? 0,
      isMulti:    depegNum === null,
      isInterior: t.isInterior,
    };
  });

  // Only valid ticks (depeg > 0.5) — filter degenerate seed ticks with kNorm > kSingleMax
  const validTicks = tickInfos.filter(t => t.depeg > 0.5);
  const sorted     = [...validTicks].sort((a, b) => b.depeg - a.depeg);
  const totalR     = validTicks.reduce((s, t) => s + t.r, 0);

  // x-axis: zoom to where liquidity lives
  const minDepeg = validTicks.length > 0 ? Math.min(...validTicks.map(t => t.depeg)) : 0.98;
  const spread   = 1 - minDepeg;
  const xMin     = parseFloat(Math.max(0, minDepeg - spread * 2).toFixed(4));
  const xMax     = 1.001;
  const step     = parseFloat(((xMax - xMin) / 5).toFixed(4));
  const xTicks   = Array.from({ length: 6 }, (_, i) => parseFloat((xMin + i * step).toFixed(4)));

  // Build step-curve — only between xMin and xMax
  const pts: { x: number; y: number }[] = [];
  let cumY = totalR;
  pts.push({ x: xMax, y: cumY });
  for (const t of sorted) {
    pts.push({ x: t.depeg, y: cumY });
    cumY -= t.r;
    pts.push({ x: t.depeg, y: Math.max(0, cumY) });
  }
  pts.push({ x: xMin, y: Math.max(0, cumY) });

  // αNorm needle position
  const sumXf     = Number(sumX) / 1e18;
  const kBoundf   = kBound / 1e18;
  const alphaNorm = rInt > 0
    ? Math.min(xMax, Math.max(xMin, (sumXf / Math.sqrt(n) - kBoundf) / rInt))
    : xMax;

  const yMax = totalR * 1.18;

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      {/* Chart canvas — parent panel provides surface + header */}
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
              x={alphaNorm}
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
