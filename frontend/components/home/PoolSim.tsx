"use client";

import { Fragment, useMemo, useState } from "react";
import { color, typography } from "@/constants";
import { SectionLabel } from "./SectionLabel";
import { Emphasized } from "./Emphasized";
import {
  TOKENS,
  TICK_DEPEGS,
  initState,
  applySwap,
  quoteSwap,
  prices,
  maxAmountIn,
  tvl,
  ticks as computeTicks,
  tickPlanePoint,
  AXIS_PROJ,
  pairArc,
  arcXj,
  equalPricePoint,
  type PoolState,
} from "@/lib/orbital/sim";

const MONO = "var(--font-mono)";

// Section A (polar disk)
const A = 360;
const ACX = A / 2;
const ACY = A / 2;
const RIM = 120;
const DEPEG_FULL = 0.12;
const ringR = (d: number) => Math.min(d / DEPEG_FULL, 1) * RIM;

// Section B (cartesian chart)
const BW = 400;
const BH = 360;
const PL = 56;
const PR = 16;
const PT = 24;
const PB = 40;

const fmtM = (v: number) => `$${(v / 1e6).toFixed(2)}M`;
const fmtMs = (v: number) => `${(v / 1e6).toFixed(1)}M`;
const fmtX = (v: number) => `${v >= 100 ? v.toFixed(0) : v.toFixed(1)}×`;
const fmtPct = (d: number) => `${(d * 100).toFixed(d < 0.01 ? 1 : 0)}%`;

function Mono({ children, dim, hot }: { children: React.ReactNode; dim?: boolean; hot?: boolean }) {
  return (
    <span style={{ fontFamily: MONO, fontSize: "10px", letterSpacing: "0.1em", color: hot ? color.accent : dim ? color.textMuted : color.textSecondary, textTransform: "uppercase" }}>
      {children}
    </span>
  );
}

// ── Section A: looking down the equal-price axis ──
function SectionA({ state }: { state: PoolState }) {
  const { angle, depeg } = tickPlanePoint(state);
  const tk = computeTicks(state);
  const dotR = ringR(depeg);
  const dx = ACX + Math.cos(angle) * dotR;
  const dy = ACY + Math.sin(angle) * dotR;
  const breached = depeg >= TICK_DEPEGS[0];

  return (
    <svg viewBox={`0 0 ${A} ${A}`} width="100%" height="100%" preserveAspectRatio="xMidYMid meet" style={{ display: "block" }}>
      {tk.map((t) => {
        const rr = ringR(t.depeg);
        return (
          <g key={t.depeg}>
            <circle cx={ACX} cy={ACY} r={rr} fill="none" stroke={t.interior ? color.border : color.accent} strokeWidth={t.interior ? 1 : 1.4} strokeDasharray="2 4" strokeOpacity={t.interior ? 0.5 : 0.9} style={{ transition: "stroke 200ms, stroke-opacity 200ms" }} />
            <text x={ACX + 5} y={ACY - rr - 3} fill={t.interior ? color.textMuted : color.accent} style={{ fontFamily: MONO, fontSize: 9, letterSpacing: "0.04em", transition: "fill 200ms" }}>
              {fmtPct(t.depeg)} · {fmtX(t.capEff)}
            </text>
          </g>
        );
      })}

      {AXIS_PROJ.map((p, k) => {
        const m = Math.hypot(p.x, p.y);
        const ux = p.x / m;
        const uy = p.y / m;
        return (
          <g key={TOKENS[k]}>
            <line x1={ACX} y1={ACY} x2={ACX + ux * RIM} y2={ACY + uy * RIM} stroke={color.border} strokeWidth={1} strokeOpacity={0.35} />
            <text x={ACX + ux * (RIM + 16)} y={ACY + uy * (RIM + 16)} fill={color.textMuted} textAnchor="middle" dominantBaseline="middle" style={{ fontFamily: MONO, fontSize: 11, letterSpacing: "0.06em" }}>
              {TOKENS[k]}
            </text>
          </g>
        );
      })}

      <circle cx={ACX} cy={ACY} r={2.5} fill={color.textMuted} />
      <text x={ACX} y={ACY + 15} fill={color.textMuted} textAnchor="middle" style={{ fontFamily: MONO, fontSize: 8, letterSpacing: "0.06em" }}>PEG</text>
      <line x1={ACX} y1={ACY} x2={dx} y2={dy} stroke={breached ? color.accent : color.textSecondary} strokeWidth={1.4} style={{ transition: "x2 280ms ease-out, y2 280ms ease-out, stroke 200ms" }} />
      <circle cx={dx} cy={dy} r={5} fill={breached ? color.accent : color.textPrimary} stroke={color.bg} strokeWidth={1.5} style={{ transition: "cx 280ms ease-out, cy 280ms ease-out, fill 200ms" }} />
    </svg>
  );
}

// ── Section B: two-token plane — fully-marked cartesian chart ──
function SectionB({ committed, preview, i, j, tickIdx }: { committed: PoolState; preview: PoolState; i: number; j: number; tickIdx: number }) {
  const arc = pairArc(preview, i, j);
  const arc0 = pairArc(committed, i, j);
  const tk = computeTicks(preview)[tickIdx];
  const lo = Math.min(arc.low, arc0.low);
  const hi = arc.r;
  const span = hi - lo || 1;

  const sx = (v: number) => PL + ((v - lo) / span) * (BW - PL - PR);
  const sy = (v: number) => BH - PB - ((v - lo) / span) * (BH - PT - PB);

  const axisVals = [0, 1, 2, 3, 4].map((t) => lo + (t * span) / 4);

  const curve: string[] = [];
  for (let t = 0; t <= 80; t++) {
    const xi = lo + (span * t) / 80;
    curve.push(`${sx(xi).toFixed(1)},${sy(arcXj(arc, xi)).toFixed(1)}`);
  }

  const bLo = Math.max(lo, tk.xMin);
  const bHi = Math.min(hi, tk.xMax);
  const band: string[] = [];
  if (bHi > bLo) for (let t = 0; t <= 32; t++) {
    const xi = bLo + ((bHi - bLo) * t) / 32;
    band.push(`${sx(xi).toFixed(1)},${sy(arcXj(arc, xi)).toFixed(1)}`);
  }

  const q = equalPricePoint(arc.r);
  const cur = { x: sx(arc.xi), y: sy(arc.xj) };

  return (
    <svg viewBox={`0 0 ${BW} ${BH}`} width="100%" height="100%" preserveAspectRatio="xMidYMid meet" style={{ display: "block" }}>
      {axisVals.map((v, idx) => (
        <g key={idx}>
          <line x1={sx(v)} y1={PT} x2={sx(v)} y2={BH - PB} stroke={color.borderSubtle} strokeWidth={1} strokeOpacity={0.4} />
          <line x1={PL} y1={sy(v)} x2={BW - PR} y2={sy(v)} stroke={color.borderSubtle} strokeWidth={1} strokeOpacity={0.4} />
          <text x={sx(v)} y={BH - PB + 14} fill={color.textMuted} textAnchor="middle" style={{ fontFamily: MONO, fontSize: 9 }}>{fmtMs(v)}</text>
          <text x={PL - 6} y={sy(v) + 3} fill={color.textMuted} textAnchor="end" style={{ fontFamily: MONO, fontSize: 9 }}>{fmtMs(v)}</text>
        </g>
      ))}

      <line x1={PL} y1={BH - PB} x2={BW - PR} y2={BH - PB} stroke={color.border} strokeWidth={1} />
      <line x1={PL} y1={PT} x2={PL} y2={BH - PB} stroke={color.border} strokeWidth={1} />

      <polyline points={curve.join(" ")} fill="none" stroke={color.textSecondary} strokeWidth={1.3} strokeOpacity={0.7} />
      {band.length > 0 && <polyline points={band.join(" ")} fill="none" stroke={color.accent} strokeWidth={3} />}

      {[tk.xMin, tk.xMax].map((v, idx) =>
        v > lo && v < hi ? (
          <g key={idx}>
            <line x1={sx(v)} y1={sy(arcXj(arc, v))} x2={sx(v)} y2={BH - PB} stroke={color.accent} strokeWidth={1} strokeDasharray="2 3" strokeOpacity={0.6} />
            <text x={sx(v)} y={BH - PB + 26} fill={color.accent} textAnchor="middle" style={{ fontFamily: MONO, fontSize: 9 }}>{fmtMs(v)}</text>
          </g>
        ) : null,
      )}

      <circle cx={sx(q)} cy={sy(q)} r={2.5} fill={color.textMuted} />
      <circle cx={sx(arc0.xi)} cy={sy(arc0.xj)} r={4} fill="none" stroke={color.textMuted} strokeWidth={1.3} />
      <line x1={cur.x} y1={cur.y} x2={cur.x} y2={BH - PB} stroke={color.textPrimary} strokeWidth={1} strokeDasharray="2 3" strokeOpacity={0.5} />
      <line x1={PL} y1={cur.y} x2={cur.x} y2={cur.y} stroke={color.textPrimary} strokeWidth={1} strokeDasharray="2 3" strokeOpacity={0.5} />
      <circle cx={cur.x} cy={cur.y} r={5} fill={color.textPrimary} stroke={color.bg} strokeWidth={1.5} style={{ transition: "cx 280ms ease-out, cy 280ms ease-out" }} />
      <text x={cur.x + 9} y={cur.y - 7} fill={color.textPrimary} style={{ fontFamily: MONO, fontSize: 9.5 }}>
        ({fmtMs(arc.xi)}, {fmtMs(arc.xj)})
      </text>

      <text x={BW - PR} y={BH - 6} fill={color.textSecondary} textAnchor="end" style={{ fontFamily: MONO, fontSize: 10, letterSpacing: "0.05em" }}>{TOKENS[i]} reserve →</text>
      <text x={PL - 48} y={PT + 2} fill={color.textSecondary} textAnchor="start" style={{ fontFamily: MONO, fontSize: 10, letterSpacing: "0.05em" }}>↑ {TOKENS[j]}</text>
    </svg>
  );
}

function PanelHead({ caption, meta }: { caption: string; meta?: string }) {
  return (
    <div className="flex items-center justify-between px-5 pt-3 pb-1">
      <Mono>{caption}</Mono>
      {meta ? <Mono dim>{meta}</Mono> : null}
    </div>
  );
}

function VizPanel({ caption, meta, children }: { caption: string; meta: string; children: React.ReactNode }) {
  return (
    <div className="border border-dashed flex flex-col" style={{ borderColor: color.border, backgroundColor: color.surface1, minHeight: 360 }}>
      <PanelHead caption={caption} meta={meta} />
      <div className="flex-1 grid place-items-center p-5 pt-2 min-h-0">{children}</div>
    </div>
  );
}

// Compact token chips — the active one is filled; picking a conflicting token
// auto-resolves the other side, so there's no greyed/disabled state.
function TokChips({ active, onPick }: { active: number; onPick: (i: number) => void }) {
  return (
    <div className="flex gap-1">
      {TOKENS.map((t, i) => {
        const on = i === active;
        return (
          <button
            key={t}
            type="button"
            onClick={() => onPick(i)}
            style={{
              fontFamily: MONO,
              fontSize: 11,
              letterSpacing: "0.04em",
              padding: "4px 11px",
              color: on ? color.bg : color.textSecondary,
              backgroundColor: on ? color.accent : "transparent",
              border: `1px solid ${on ? color.accent : color.border}`,
              cursor: "pointer",
              transition: "all 150ms",
            }}
          >
            {t}
          </button>
        );
      })}
    </div>
  );
}

export function PoolSim() {
  const [state, setState] = useState<PoolState>(() => initState());
  const [inTok, setInTok] = useState(0);
  const [outTok, setOutTok] = useState(2);
  const [amountStr, setAmountStr] = useState("");
  const [tickIdx, setTickIdx] = useState(1);

  const maxIn = useMemo(() => maxAmountIn(state, inTok), [state, inTok]);
  const maxInM = maxIn / 1e6;
  const amount = Math.max(0, Math.min(maxIn, (parseFloat(amountStr) || 0) * 1e6));

  const out = useMemo(() => quoteSwap(state, inTok, outTok, amount), [state, inTok, outTok, amount]);
  const preview = useMemo(() => (amount > 0 ? applySwap(state, inTok, outTok, amount) : state), [state, inTok, outTok, amount]);

  const px = prices(preview);
  const tk = computeTicks(preview);
  const effPrice = amount > 0 && out > 0 ? out / amount : 1;

  const pickIn = (k: number) => { setInTok(k); if (k === outTok) setOutTok((k + 1) % 3); setAmountStr(""); };
  const pickOut = (k: number) => { setOutTok(k); if (k === inTok) setInTok((k + 1) % 3); setAmountStr(""); };
  const swapDir = () => { setInTok(outTok); setOutTok(inTok); setAmountStr(""); };
  const commit = () => { if (amount <= 0) return; setState(applySwap(state, inTok, outTok, amount)); setAmountStr(""); };
  const reset = () => { setState(initState()); setAmountStr(""); };

  const inputBorder = `1px solid ${color.border}`;
  const divider = { borderColor: color.borderSubtle };

  return (
    <section className="mx-6 my-1">
      <style>{`.psim-num::-webkit-outer-spin-button,.psim-num::-webkit-inner-spin-button{-webkit-appearance:none;margin:0}.psim-num{-moz-appearance:textfield}`}</style>
      <SectionLabel border chapter="V" section="04" path="ORBITAL / SIMULATION" />

      <div className="pb-12 pt-20">
        <Emphasized
          size="clamp(40px, 5vw, 72px)"
          lineHeight="1.05"
          letterSpacing="-0.04em"
          fontFamily={typography.h1.family}
          segments={[
            { t: "See the pool in motion", v: "on" },
            { t: ".", v: "green" },
            " ",
            { t: "A ", v: "off" },
            { t: "$30M pool", v: "on" },
            { t: " of three stablecoins", v: "off" },
            { t: ".", v: "green" },
            " ",
            { t: "Make a swap", v: "on" },
            { t: " and watch it two ways — ", v: "off" },
            { t: "looking down the tick planes", v: "on" },
            { t: ", and ", v: "off" },
            { t: "along the curve", v: "on" },
            { t: " between the two coins you trade", v: "off" },
            { t: ".", v: "green" },
          ]}
        />
      </div>

      {/* A | B | C */}
      <div className="grid grid-cols-1 gap-1 lg:grid-cols-3 mb-24 items-stretch">
        {/* Section A */}
        <VizPanel caption="// SECTION A · ∥ TICK PLANES" meta="rings = ticks · dot = x⃗">
          <SectionA state={preview} />
        </VizPanel>

        {/* Section B */}
        <VizPanel caption="// SECTION B · ∥ TWO-TOKEN PLANE" meta={`${TOKENS[inTok]}/${TOKENS[outTok]} · ${fmtPct(tk[tickIdx].depeg)} tick`}>
          <SectionB committed={state} preview={preview} i={inTok} j={outTok} tickIdx={tickIdx} />
        </VizPanel>

        {/* Section C: swap + all readouts */}
        <div className="border border-dashed flex flex-col" style={{ borderColor: color.border, backgroundColor: color.surface1, minHeight: 360 }}>
          <PanelHead caption="// SECTION C · SWAP" />

          {/* swap card */}
          <div className="px-5 pt-3 pb-5 flex flex-col gap-2">
            {/* PAY */}
            <div className="flex items-center justify-between">
              <Mono dim>PAY</Mono>
              <TokChips active={inTok} onPick={pickIn} />
            </div>
            <div className="flex items-stretch" style={{ border: inputBorder, backgroundColor: color.bg }}>
              <input
                className="psim-num"
                type="number"
                inputMode="decimal"
                min={0}
                max={maxInM}
                step={0.1}
                placeholder="0.00"
                value={amountStr}
                onChange={(e) => setAmountStr(e.target.value)}
                style={{ flex: 1, minWidth: 0, fontFamily: MONO, fontSize: 20, color: color.textPrimary, backgroundColor: "transparent", border: "none", padding: "13px 14px", outline: "none" }}
              />
              <span style={{ fontFamily: MONO, fontSize: 11, color: color.textMuted, alignSelf: "center", padding: "0 6px" }}>$M</span>
              <button type="button" onClick={() => setAmountStr(maxInM.toFixed(2))} style={{ fontFamily: MONO, fontSize: 11, letterSpacing: "0.06em", padding: "0 16px", color: color.textSecondary, backgroundColor: "transparent", border: "none", borderLeft: inputBorder, cursor: "pointer" }}>
                MAX
              </button>
            </div>
            <input type="range" min={0} max={maxInM || 1} step={(maxInM || 1) / 300} value={amount / 1e6} onChange={(e) => setAmountStr(e.target.value)} style={{ accentColor: color.accent, width: "100%" }} />

            {/* direction */}
            <div className="flex justify-center my-0.5">
              <button type="button" onClick={swapDir} title="Flip direction" style={{ fontFamily: MONO, fontSize: 14, lineHeight: 1, width: 36, height: 30, color: color.textSecondary, backgroundColor: color.surface2, border: inputBorder, cursor: "pointer", transition: "all 150ms" }}>
                ⇅
              </button>
            </div>

            {/* RECEIVE */}
            <div className="flex items-center justify-between">
              <Mono dim>RECEIVE</Mono>
              <TokChips active={outTok} onPick={pickOut} />
            </div>
            <div className="flex items-baseline justify-between" style={{ border: inputBorder, backgroundColor: color.surface2, padding: "13px 14px" }}>
              <span style={{ fontFamily: MONO, fontSize: 20, color: out > 0 ? color.textPrimary : color.textMuted }}>{fmtM(out)}</span>
              <span style={{ fontFamily: MONO, fontSize: 10, letterSpacing: "0.04em", color: effPrice < 1 - TICK_DEPEGS[0] ? color.accent : color.textMuted, transition: "color 200ms" }}>
                1 {TOKENS[inTok]} ≈ {effPrice.toFixed(5)} {TOKENS[outTok]}
              </span>
            </div>

            {/* actions */}
            <div className="flex gap-1 mt-2">
              <button type="button" onClick={commit} disabled={amount <= 0} className="flex-1" style={{ fontFamily: MONO, fontSize: "12px", letterSpacing: "0.08em", padding: "12px", textTransform: "uppercase", color: amount > 0 ? color.bg : color.textMuted, backgroundColor: amount > 0 ? color.accent : "transparent", border: `1px solid ${amount > 0 ? color.accent : color.border}`, cursor: amount > 0 ? "pointer" : "not-allowed", transition: "all 150ms" }}>
                Commit swap
              </button>
              <button type="button" onClick={reset} style={{ fontFamily: MONO, fontSize: "12px", letterSpacing: "0.08em", padding: "12px 16px", textTransform: "uppercase", color: color.textSecondary, backgroundColor: "transparent", border: `1px solid ${color.border}`, cursor: "pointer" }}>
                Reset
              </button>
            </div>
          </div>

          {/* virtual reserves */}
          <div className="px-5 py-4 border-t border-dashed" style={divider}>
            <div className="flex items-center justify-between">
              <Mono dim>{"//"} VIRTUAL RESERVES x⃗</Mono>
              <Mono dim>RESERVE · PRICE</Mono>
            </div>
            <div className="mt-3 grid grid-cols-[1fr_auto_56px] gap-x-4 gap-y-2 items-baseline">
              {TOKENS.map((t, k) => {
                const off = Math.abs(px[k] - 1) >= TICK_DEPEGS[0];
                return (
                  <Fragment key={t}>
                    <span style={{ fontFamily: MONO, fontSize: 12, color: color.textMuted }}>{t}</span>
                    <span style={{ fontFamily: MONO, fontSize: 13, color: color.textPrimary, textAlign: "right" }}>{fmtM(preview.x[k])}</span>
                    <span style={{ fontFamily: MONO, fontSize: 11, textAlign: "right", color: off ? color.accent : color.textMuted, transition: "color 200ms" }}>{px[k].toFixed(4)}</span>
                  </Fragment>
                );
              })}
              <span className="border-t border-dashed pt-2" style={{ ...divider, fontFamily: MONO, fontSize: 10, letterSpacing: "0.1em", color: color.textMuted, textTransform: "uppercase" }}>TVL</span>
              <span className="border-t border-dashed pt-2" style={{ ...divider, fontFamily: MONO, fontSize: 13, color: color.textPrimary, textAlign: "right" }}>{fmtM(tvl(preview))}</span>
              <span className="border-t border-dashed pt-2" style={divider} />
            </div>
          </div>

          {/* ticks */}
          <div className="px-5 py-4 border-t border-dashed" style={divider}>
            <div className="flex items-center justify-between">
              <Mono dim>{"//"} TICKS</Mono>
              <Mono dim>select → section B</Mono>
            </div>
            <div className="mt-3 grid grid-cols-[48px_1fr_84px] gap-x-2 items-baseline" style={{ fontFamily: MONO, fontSize: 9, color: color.textMuted, letterSpacing: "0.06em" }}>
              <span>DEPEG</span>
              <span>CAP. EFF.</span>
              <span className="text-right">STATE</span>
            </div>
            <div className="mt-2 flex flex-col gap-0.5">
              {tk.map((t, idx) => {
                const sel = idx === tickIdx;
                return (
                  <button key={t.depeg} type="button" onClick={() => setTickIdx(idx)} className="grid grid-cols-[48px_1fr_84px] gap-x-2 items-baseline text-left" style={{ background: sel ? color.surface2 : "transparent", border: "none", cursor: "pointer", padding: "5px 4px", margin: "0 -4px" }}>
                    <span style={{ fontFamily: MONO, fontSize: 12, color: sel ? color.accent : color.textPrimary }}>{sel ? "▸ " : "  "}{fmtPct(t.depeg)}</span>
                    <span style={{ fontFamily: MONO, fontSize: 12, color: color.textSecondary }}>{fmtX(t.capEff)}</span>
                    <span style={{ fontFamily: MONO, fontSize: 11, letterSpacing: "0.05em", textAlign: "right", color: t.interior ? color.textSecondary : color.accent, transition: "color 200ms" }}>{t.interior ? "INTERIOR" : "BOUNDARY"}</span>
                  </button>
                );
              })}
            </div>
            <div className="flex items-baseline justify-between border-t border-dashed pt-2 mt-2" style={divider}>
              <Mono dim>{fmtPct(tk[tickIdx].depeg)} BAND → B</Mono>
              <span style={{ fontFamily: MONO, fontSize: 12, color: color.accent }}>{fmtMs(tk[tickIdx].xMin)}–{fmtMs(tk[tickIdx].xMax)}</span>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
