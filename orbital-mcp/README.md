# orbital-mcp

An MCP server that exposes the [Orbital subgraph](../subgraph) to AI environments —
Claude, Cursor, ChatGPT — as reusable tooling rather than a one-off script.

Covers the stable pool on each of the three deployments of the [Orbital Hook](../orbitalHook):
Unichain Sepolia, Arbitrum Sepolia and **Circle's Arc**, all indexed and live on
subgraph `v0.2.0`. Each chain is queried independently, so one unreachable endpoint
degrades an answer instead of failing it. (The FX pool on Arc is not indexed.)

---

## The design rule

**A tool returns an answer, not a result set.**

An MCP server that forwards GraphQL and hands back JSON moves the reasoning into the
model's context window, where it is done worse and paid for twice. So the risk maths,
the cross-chain fan-out, and the WAD conversions all happen here:

```
"tick 2 distanceToBoundaryWad: 41000000000000000000000"     ← data

[CRITICAL] arc-testnet tick #2 | DEFECT | 28.57% of radius
    kNorm 0.500716 sits BELOW parity 1, so a rising alphaNorm can never
    reach it. This tick will not cross, meaning its depeg protection is
    inert while it holds 28.57% of interior radius.                ← an answer
```

`orbital_graphql` is the deliberate exception, for questions the analytic tools do not
anticipate.

---

## Tools

| Tool | Answers |
|---|---|
| `orbital_book_health` | Is any pool frozen? TVL (tokens held, not the engine's virtual total), interior tick count, volume, fees. Start here. |
| `orbital_ticks_at_risk` | Which tick crosses first, weighted by how much liquidity leaves with it |
| `orbital_freeze_risk` | Could this pool stop accepting liquidity, with direction over recent snapshots |
| `orbital_slippage_report` | Realised slippage in bps, measured against 1:1 |
| `orbital_crossing_history` | Past interior↔boundary flips, flagging any that froze the book |
| `orbital_graphql` | Raw query escape hatch, single chain |
| `orbital_networks` | Which endpoints are configured |

Each takes `network`: `all` (default), `arc`, `unichain`, `arbitrum`.

---

## Why not just read the events

The contract emits `TickCrossed`, but only **after** a bound has been hit. As a risk
signal that is worthless — the liquidity is already gone.

So every subgraph handler also reads live engine state (`slot0`, `reserves`, `ticks`)
at its own block and reproduces the engine's own crossing condition:

```
alphaNorm = ((sumX·WAD/√N) − kBound)·WAD / rInt
kNorm     = k·WAD / r
```

A tick crosses when `alphaNorm` rises to meet its `kNorm`. Storing both turns the feed
from a record of what happened into a leading indicator of what is about to.

`√N` is recomputed with a Newton integer sqrt because `sqrtN` is `internal immutable`
in the hook and not callable — reproducing the condition exactly matters more than
approximating it cheaply.

---

## Risk model

```
score = boundaryProgressBps/10000 × shareOfRIntBps/10000
```

**`boundaryProgressBps`** is progress from parity to *that tick's own* bound, so no
arbitrary distance threshold is invented. A 0.97 tick and a 0.80 tick sit at different
absolute distances by construction; only tick-relative progress makes them comparable.

**`shareOfRIntBps`** is what leaves the book if it crosses. Proximity alone is not
risk: 1bp from the bound holding 2% is noise, holding 40% is not.

`[OK] → [WATCH] → [ELEVATED] → [CRITICAL]` at 0.02 / 0.10 / 0.25.

A **`DEFECT`** is separated out entirely: a bound at or behind parity can never be
reached, so the tick will never cross. That is the opposite conclusion to "about to
cross" and gets its own path rather than being scored.

---

## Setup

```bash
npm install
npm run build
```

```
ORBITAL_SUBGRAPH_ARC=https://api.studio.thegraph.com/query/107768/orbital-arc/v0.2.0
ORBITAL_SUBGRAPH_UNICHAIN=https://api.studio.thegraph.com/query/107768/orbital-unichain/v0.2.0
ORBITAL_SUBGRAPH_ARBITRUM=https://api.studio.thegraph.com/query/107768/orbital-arbitrum/v0.2.0
```

Any subset works. An unreachable chain degrades to a partial answer — reporting
"2 of 3 healthy, Arbitrum unreachable" is more useful, and more honest, than failing
the whole call.

```json
{
  "mcpServers": {
    "orbital": {
      "command": "node",
      "args": ["/absolute/path/to/orbital-mcp/dist/index.js"],
      "env": {
        "ORBITAL_SUBGRAPH_ARC": "https://api.studio.thegraph.com/query/107768/orbital-arc/v0.2.0"
      }
    }
  }
}
```

`stdout` is the MCP transport — logs go to `stderr`, never `stdout`.

See [SKILL.md](SKILL.md) for agent-facing usage guidance.

---

## What it found

First run against live data, on all three chains:

```
[CRITICAL] arc-testnet (chain 5042002)
  1 tick(s) holding 28.57% of interior radius have a bound at or behind parity
  and can never cross. Their depeg protection is inert.
```

A tick-merge in the hook was adding radius without adding `k`, halving `kNorm` and
silently moving an LP's chosen depeg bound. Written up in
[the hook README](../orbitalHook/README.md#a-bug-the-indexing-found-and-the-fix);
fixed, redeployed, and the same tools now report `0 defective ticks`.
