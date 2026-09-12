/**
 * Risk reasoning over indexed Orbital state.
 *
 * The subgraph supplies facts; this file turns them into a judgement. That
 * split matters: "tick 2 has distanceToBoundaryWad 41000000000000000000000" is
 * data, whereas "tick 2 holds 38% of the book and sits 0.4% from its bound, so
 * a 0.4% move thins the pool by more than a third" is an answer.
 */

import { fromWad, pct, usd, type PoolRow, type SnapshotRow, type TickRow } from "./graph.js";

export type Severity = "critical" | "elevated" | "watch" | "ok";

export interface TickRisk {
  id: string;
  network: string;
  tickIdx: string;
  /** 0..1. How far the book has travelled from parity to this tick's bound. */
  progress: number;
  /** Fraction of interior radius that leaves the book if this tick crosses. */
  impactShare: number;
  /** 0..1. Progress weighted by how much liquidity the crossing removes. */
  score: number;
  severity: Severity;
  /** True when the tick's bound sits at or behind parity, so it can never be
   *  reached on a rising path. That is a defect, not a near-crossing. */
  defectiveBound: boolean;
  note: string;
}

function classify(score: number): Severity {
  if (score >= 0.25) return "critical";
  if (score >= 0.1) return "elevated";
  if (score >= 0.02) return "watch";
  return "ok";
}

/**
 * Grade one tick.
 *
 * `boundaryProgressBps` already normalises by each tick's own span, so no
 * arbitrary distance threshold is invented here: a 0.97 tick and a 0.80 tick
 * sit at different absolute distances by construction, and only progress makes
 * them comparable.
 *
 * The one case progress cannot express is a bound at or behind parity. The
 * subgraph reports that as 100% with NEGATIVE slack, which would otherwise read
 * as "about to cross" when it actually means "this tick has no working depeg
 * protection at all". They are opposite conclusions, so they are separated.
 */
export function assessTick(t: TickRow): TickRisk {
  const network = t.pool.network;
  const impactShare = t.shareOfRIntBps / 10000;
  const progress = t.boundaryProgressBps / 10000;
  const slack = t.distanceToBoundaryWad === null ? null : BigInt(t.distanceToBoundaryWad);
  const defective = slack !== null && slack < 0n;

  if (defective) {
    return {
      id: t.id, network, tickIdx: t.tickIdx, progress: 1, impactShare, score: impactShare,
      severity: impactShare >= 0.1 ? "critical" : "elevated",
      defectiveBound: true,
      note:
        `DEFECTIVE BOUND: kNorm ${fromWad(t.kNorm ?? "0", 6)} sits BELOW parity ` +
        `${fromWad(t.pool.alphaParity, 6)}, so a rising alphaNorm can never reach it. ` +
        `This tick will not cross, meaning its depeg protection is inert while it holds ` +
        `${pct(t.shareOfRIntBps)} of interior radius.`,
    };
  }

  if (t.distanceToBoundaryWad === null) {
    return {
      id: t.id, network, tickIdx: t.tickIdx, progress: 0, impactShare, score: 0,
      severity: "ok", defectiveBound: false,
      note: "no live distance (boundary tick, or pool not yet initialised)",
    };
  }

  const score = progress * impactShare;
  return {
    id: t.id, network, tickIdx: t.tickIdx, progress, impactShare, score,
    severity: classify(score), defectiveBound: false,
    note: `${pct(t.boundaryProgressBps)} of the way from parity to its bound, holding ${pct(t.shareOfRIntBps)} of interior radius`,
  };
}

/** Share of the book sitting inside the risk horizon. This, not any single
 *  tick, is what predicts a freeze: the pool locks mint and burn only when
 *  every interior tick has gone. */
export function bookAtRisk(risks: TickRisk[]): number {
  return risks
    .filter((r) => r.severity !== "ok")
    .reduce((acc, r) => acc + r.impactShare, 0);
}

export function poolVerdict(pool: PoolRow, risks: TickRisk[]): { severity: Severity; headline: string } {
  const defects = risks.filter((r) => r.defectiveBound);
  if (defects.length > 0) {
    const share = defects.reduce((a, r) => a + r.impactShare, 0);
    return {
      severity: "critical",
      headline:
        `${defects.length} tick(s) holding ${pct(share * 10000)} of interior radius have a bound at or behind parity ` +
        `and can never cross. Their depeg protection is inert.`,
    };
  }
  if (pool.frozen) {
    return {
      severity: "critical",
      headline:
        "FROZEN. kBound is non-zero, so at least one tick sits on its boundary and the engine is refusing mint and burn for the whole book, not just that tick.",
    };
  }
  if (pool.interiorTickCount === 0) {
    return { severity: "critical", headline: "No interior ticks: the book cannot quote." };
  }

  const atRisk = bookAtRisk(risks);
  const worst = risks.reduce<Severity>((w, r) => (rank(r.severity) > rank(w) ? r.severity : w), "ok");

  if (worst === "critical") {
    return { severity: "critical", headline: `A tick is at or past its bound; ${pct(atRisk * 10000)} of interior radius is exposed.` };
  }
  if (worst === "elevated") {
    return { severity: "elevated", headline: `${pct(atRisk * 10000)} of interior radius sits within the risk horizon.` };
  }
  if (worst === "watch") {
    return { severity: "watch", headline: `Healthy, with ${pct(atRisk * 10000)} of radius worth watching.` };
  }
  if (pool.interiorTickCount === 1) {
    return {
      severity: "watch",
      headline:
        "Healthy, but only ONE interior tick remains. If it crosses there is nothing left to keep kBound at zero, and the book freezes.",
    };
  }
  return { severity: "ok", headline: `Healthy. ${pool.interiorTickCount} interior ticks, none near a bound.` };
}

function rank(s: Severity): number {
  return s === "critical" ? 3 : s === "elevated" ? 2 : s === "watch" ? 1 : 0;
}

export const ICON: Record<Severity, string> = {
  critical: "[CRITICAL]",
  elevated: "[ELEVATED]",
  watch: "[WATCH]",
  ok: "[OK]",
};

// ─────────────────────────── trend ───────────────────────────

/** Is the nearest tick closing on its bound, or backing away?
 *
 *  A single distance reading says nothing. Direction over recent events is the
 *  actual signal, which is why the subgraph stores a snapshot per event. */
export function trend(snaps: SnapshotRow[]): string {
  const usable = snaps.filter((s) => s.minDistanceToBoundaryWad !== null);
  if (usable.length < 2) return "insufficient history to establish a direction";

  // Snapshots arrive newest-first.
  const newest = usable[0].maxBoundaryProgressBps;
  const oldest = usable[usable.length - 1].maxBoundaryProgressBps;
  const delta = newest - oldest;
  const span = usable.length;

  if (delta === 0) return `flat at ${pct(newest)} across the last ${span} snapshots`;
  const dir = delta > 0 ? "CLOSING ON" : "backing away from";
  return `nearest tick is ${dir} its bound: progress moved ${delta > 0 ? "+" : ""}${pct(delta)} to ${pct(newest)} across the last ${span} snapshots`;
}

// ─────────────────────────── formatting ───────────────────────────

export function formatPool(pool: PoolRow, risks: TickRisk[]): string {
  const v = poolVerdict(pool, risks);
  const lines: string[] = [];

  lines.push(`${ICON[v.severity]} ${pool.network} (chain ${pool.chainId})`);
  lines.push(`  ${v.headline}`);
  lines.push(
    `  TVL ${usd(pool.sumX)} | interior radius ${usd(pool.rInt)} | ticks ${pool.interiorTickCount}/${pool.tickCount} interior`
  );
  lines.push(
    `  ${pool.swapCount} swaps, ${pool.crossCount} crossings, volume ${usd(pool.volumeWad)}, fees ${usd(pool.feesWad)}`
  );
  const basket = pool.assets.map((a) => `${a.symbol}(${a.decimals}dp)`).join(" ");
  lines.push(`  basket: ${basket}`);
  return lines.join("\n");
}

export function formatRisk(r: TickRisk): string {
  const tag = r.defectiveBound ? "DEFECT" : `${pct(r.progress * 10000)} to bound`;
  return `${ICON[r.severity]} ${r.network} tick #${r.tickIdx} | ${tag} | ${pct(r.impactShare * 10000)} of radius | score ${r.score.toFixed(3)}\n    ${r.note}`;
}

export function slippageSummary(bpsList: number[]): string {
  if (bpsList.length === 0) return "no swaps indexed yet";
  const sorted = [...bpsList].sort((a, b) => a - b);
  const mean = bpsList.reduce((a, b) => a + b, 0) / bpsList.length;
  const median = sorted[Math.floor(sorted.length / 2)];
  return `n=${bpsList.length} | median ${median}bps | mean ${mean.toFixed(1)}bps | best ${sorted[0]}bps | worst ${sorted[sorted.length - 1]}bps`;
}

export { fromWad, usd, pct };
