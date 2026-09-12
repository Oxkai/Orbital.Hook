#!/usr/bin/env node
/**
 * Orbital MCP server.
 *
 * Exposes the Orbital Hook subgraph to AI environments (Claude, Cursor,
 * ChatGPT) as reusable tooling rather than a single-purpose app.
 *
 * The design rule throughout: a tool returns an ANSWER, not a result set. An
 * MCP tool that forwards GraphQL and hands back JSON just moves the reasoning
 * burden into the model's context window, where it is done worse and paid for
 * twice. So the risk maths, the cross-chain fan-out and the unit conversions
 * all happen here, and the model receives prose it can act on.
 *
 * `orbital_graphql` is the deliberate exception, for questions these tools do
 * not anticipate.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

import {
  FREEZE_HISTORY,
  POOL_HEALTH,
  RECENT_SWAPS,
  SNAPSHOT_TREND,
  TICKS_AT_RISK,
  configuredNetworks,
  query,
  queryAll,
  resolveNetworks,
  usd,
  type CrossRow,
  type PoolRow,
  type SnapshotRow,
  type SwapRow,
  type TickRow,
} from "./graph.js";
import {
  assessTick,
  bookAtRisk,
  formatPool,
  formatRisk,
  pct,
  slippageSummary,
  trend,
} from "./analysis.js";

const server = new McpServer({ name: "orbital-mcp", version: "1.0.0" });

const NETWORK_ARG = z
  .enum(["all", "arc", "unichain", "base", "arbitrum"])
  .default("all")
  .describe("Which deployment to inspect. 'all' fans out across every configured chain.");

function text(s: string) {
  return { content: [{ type: "text" as const, text: s }] };
}

/** Shared guard: without endpoints every tool would fail with an opaque
 *  network error, so say plainly what is missing instead. */
function ensureConfigured(): string | null {
  if (configuredNetworks().length > 0) return null;
  return [
    "No subgraph endpoints are configured.",
    "",
    "Set at least one of these environment variables to a Subgraph Studio or",
    "decentralised-network query URL:",
    "  ORBITAL_SUBGRAPH_ARC",
    "  ORBITAL_SUBGRAPH_UNICHAIN",
    "  ORBITAL_SUBGRAPH_BASE",
    "  ORBITAL_SUBGRAPH_ARBITRUM",
  ].join("\n");
}

// ─────────────────────────── tools ───────────────────────────

server.registerTool(
  "orbital_book_health",
  {
    title: "Orbital book health",
    description:
      "Overall health of every Orbital pool: TVL, interior tick count, and whether the engine is frozen. " +
      "Start here. A pool is FROZEN when kBound is non-zero, which blocks mint and burn for the entire book, " +
      "not merely the tick that crossed.",
    inputSchema: { network: NETWORK_ARG },
  },
  async ({ network }) => {
    const missing = ensureConfigured();
    if (missing) return text(missing);

    const nets = resolveNetworks(network);
    const results = await queryAll<{ pools: PoolRow[] }>(nets, POOL_HEALTH);
    const out: string[] = [];

    for (const r of results) {
      if (r.error) {
        out.push(`[UNREACHABLE] ${r.net.label}: ${r.error}`);
        continue;
      }
      const pools = r.data!.pools;
      if (pools.length === 0) {
        out.push(`[NO DATA] ${r.net.label}: subgraph reachable but has indexed no pool yet (still syncing?)`);
        continue;
      }
      for (const pool of pools) {
        const t = await query<{ ticks: TickRow[] }>(r.net, TICKS_AT_RISK, { first: 50 }).catch(() => ({ ticks: [] }));
        out.push(formatPool(pool, t.ticks.map(assessTick)));
      }
    }
    return text(out.join("\n\n"));
  }
);

server.registerTool(
  "orbital_ticks_at_risk",
  {
    title: "Ticks near their depeg bound",
    description:
      "Rank interior ticks by how close they are to crossing, weighted by how much liquidity leaves when they do. " +
      "This is the question the raw events cannot answer: TickCrossed only fires AFTER a bound is hit, by which " +
      "point the liquidity is already gone.",
    inputSchema: {
      network: NETWORK_ARG,
      limit: z.number().int().min(1).max(50).default(10).describe("How many ticks to rank."),
    },
  },
  async ({ network, limit }) => {
    const missing = ensureConfigured();
    if (missing) return text(missing);

    const nets = resolveNetworks(network);
    const results = await queryAll<{ ticks: TickRow[] }>(nets, TICKS_AT_RISK, { first: limit });
    const out: string[] = [];

    for (const r of results) {
      if (r.error) {
        out.push(`[UNREACHABLE] ${r.net.label}: ${r.error}`);
        continue;
      }
      const risks = r.data!.ticks.map(assessTick);
      if (risks.length === 0) {
        out.push(`${r.net.label}: no interior ticks indexed.`);
        continue;
      }
      const exposed = bookAtRisk(risks);
      out.push(
        `${r.net.label}: ${pct(exposed * 10000)} of interior radius inside the risk horizon\n` +
          risks
            .sort((a, b) => b.score - a.score)
            .slice(0, limit)
            .map(formatRisk)
            .join("\n")
      );
    }
    return text(out.join("\n\n"));
  }
);

server.registerTool(
  "orbital_freeze_risk",
  {
    title: "Explain freeze risk",
    description:
      "Answer 'could this pool stop accepting liquidity', with reasoning. Combines the current tick ranking with " +
      "the recent direction of the nearest tick, because a single distance reading has no meaning without a trend.",
    inputSchema: {
      network: NETWORK_ARG,
      history: z.number().int().min(2).max(200).default(30).describe("Snapshots to read when establishing direction."),
    },
  },
  async ({ network, history }) => {
    const missing = ensureConfigured();
    if (missing) return text(missing);

    const nets = resolveNetworks(network);
    const out: string[] = [];

    for (const net of nets) {
      try {
        const [pools, ticks, snaps] = await Promise.all([
          query<{ pools: PoolRow[] }>(net, POOL_HEALTH),
          query<{ ticks: TickRow[] }>(net, TICKS_AT_RISK, { first: 50 }),
          query<{ poolSnapshots: SnapshotRow[] }>(net, SNAPSHOT_TREND, { first: history }),
        ]);

        const pool = pools.pools[0];
        if (!pool) {
          out.push(`${net.label}: nothing indexed yet.`);
          continue;
        }

        const risks = ticks.ticks.map(assessTick);
        const exposed = bookAtRisk(risks);
        const worst = [...risks].sort((a, b) => b.score - a.score)[0];

        const lines = [formatPool(pool, risks)];
        lines.push(`  trend: ${trend(snaps.poolSnapshots)}`);

        if (pool.frozen) {
          lines.push(
            "  verdict: ALREADY FROZEN. Mint and burn are blocked pool-wide until a crossing returns kBound to zero."
          );
        } else if (pool.interiorTickCount === 1) {
          lines.push(
            "  verdict: one interior tick left. It is the only thing holding kBound at zero, so its crossing freezes the book."
          );
        } else if (exposed >= 0.5) {
          lines.push(
            `  verdict: ${pct(exposed * 10000)} of radius is within the horizon. A single correlated move could take out most of the book at once.`
          );
        } else if (worst && worst.severity !== "ok") {
          lines.push(
            `  verdict: contained. Worst case is tick #${worst.tickIdx}, whose crossing removes ${pct(worst.impactShare * 10000)} of radius and leaves the rest quoting.`
          );
        } else {
          lines.push("  verdict: no tick is near a bound. The book absorbs a normal move without losing liquidity.");
        }
        out.push(lines.join("\n"));
      } catch (e) {
        out.push(`[UNREACHABLE] ${net.label}: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    return text(out.join("\n\n"));
  }
);

server.registerTool(
  "orbital_slippage_report",
  {
    title: "Realised slippage",
    description:
      "Measured slippage on recent swaps, in basis points. These are same-peg assets, so 1:1 is the fair price and " +
      "any shortfall is fee plus curve slippage. This is the number the Orbital curve exists to shrink, measured " +
      "rather than modelled.",
    inputSchema: {
      network: NETWORK_ARG,
      limit: z.number().int().min(1).max(200).default(25).describe("Recent swaps to sample."),
    },
  },
  async ({ network, limit }) => {
    const missing = ensureConfigured();
    if (missing) return text(missing);

    const nets = resolveNetworks(network);
    const results = await queryAll<{ swaps: SwapRow[] }>(nets, RECENT_SWAPS, { first: limit });
    const out: string[] = [];

    for (const r of results) {
      if (r.error) {
        out.push(`[UNREACHABLE] ${r.net.label}: ${r.error}`);
        continue;
      }
      const swaps = r.data!.swaps;
      if (swaps.length === 0) {
        out.push(`${r.net.label}: no swaps indexed.`);
        continue;
      }
      const lines = [`${r.net.label}: ${slippageSummary(swaps.map((s) => s.slippageBps))}`];
      for (const s of swaps.slice(0, 5)) {
        lines.push(
          `    ${usd(s.amountInWad)} ${s.assetIn.symbol} -> ${usd(s.amountOutWad)} ${s.assetOut.symbol}  (${s.slippageBps}bps)`
        );
      }
      out.push(lines.join("\n"));
    }
    return text(out.join("\n\n"));
  }
);

server.registerTool(
  "orbital_crossing_history",
  {
    title: "Tick crossing history",
    description:
      "Past interior<->boundary flips, flagging any that froze the book. A crossing with nowInterior=false is the " +
      "depeg protection doing its job: that LP's tick stopped quoting so a broken asset could not drain the LPs " +
      "who supplied the healthy ones.",
    inputSchema: {
      network: NETWORK_ARG,
      limit: z.number().int().min(1).max(100).default(20).describe("Crossings to return."),
    },
  },
  async ({ network, limit }) => {
    const missing = ensureConfigured();
    if (missing) return text(missing);

    const nets = resolveNetworks(network);
    const results = await queryAll<{ tickCrosses: CrossRow[] }>(nets, FREEZE_HISTORY, { first: limit });
    const out: string[] = [];

    for (const r of results) {
      if (r.error) {
        out.push(`[UNREACHABLE] ${r.net.label}: ${r.error}`);
        continue;
      }
      const xs = r.data!.tickCrosses;
      if (xs.length === 0) {
        out.push(`${r.net.label}: no crossings. Every tick has stayed interior since deployment.`);
        continue;
      }
      const froze = xs.filter((x) => x.causedFreeze).length;
      const lines = [`${r.net.label}: ${xs.length} crossings, ${froze} of which froze the book`];
      for (const x of xs.slice(0, 10)) {
        const dir = x.nowInterior ? "-> interior (re-entered)" : "-> BOUNDARY (stopped quoting)";
        const when = new Date(Number(x.timestamp) * 1000).toISOString().replace("T", " ").slice(0, 19);
        lines.push(
          `    tick #${x.tick.tickIdx} ${dir}${x.causedFreeze ? " [FROZE BOOK]" : ""}  rInt after ${usd(x.rIntAfter)}  ${when}`
        );
      }
      out.push(lines.join("\n"));
    }
    return text(out.join("\n\n"));
  }
);

server.registerTool(
  "orbital_graphql",
  {
    title: "Raw subgraph query",
    description:
      "Escape hatch for questions the analytic tools do not cover. Runs an arbitrary GraphQL query against one " +
      "network's subgraph and returns raw JSON. Prefer the specific tools where they apply: they do the unit " +
      "conversion and risk maths that raw rows leave to you.",
    inputSchema: {
      network: z.enum(["arc", "unichain", "base", "arbitrum"]).describe("Exactly one network; raw queries do not fan out."),
      query: z.string().describe("A GraphQL query string. See subgraph/schema.graphql for the entities."),
    },
  },
  async ({ network, query: gql }) => {
    const missing = ensureConfigured();
    if (missing) return text(missing);

    const net = resolveNetworks(network)[0];
    try {
      const data = await query<unknown>(net, gql);
      return text(JSON.stringify(data, null, 2));
    } catch (e) {
      return text(`Query failed on ${net.label}: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
);

server.registerTool(
  "orbital_networks",
  {
    title: "Configured networks",
    description: "Which Orbital deployments this server can reach, and which are missing an endpoint.",
    inputSchema: {},
  },
  async () => {
    const all = [
      { key: "arc", env: "ORBITAL_SUBGRAPH_ARC" },
      { key: "unichain", env: "ORBITAL_SUBGRAPH_UNICHAIN" },
      { key: "base", env: "ORBITAL_SUBGRAPH_BASE" },
      { key: "arbitrum", env: "ORBITAL_SUBGRAPH_ARBITRUM" },
    ];
    const live = new Set(configuredNetworks().map((n) => n.key));
    return text(
      all.map((a) => `${live.has(a.key) ? "[configured]" : "[missing]   "} ${a.key.padEnd(9)} ${a.env}`).join("\n")
    );
  }
);

// ─────────────────────────── boot ───────────────────────────

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // stdout is the MCP transport; anything logged there corrupts the protocol.
  console.error("orbital-mcp ready");
}

main().catch((e) => {
  console.error("orbital-mcp failed to start:", e);
  process.exit(1);
});
