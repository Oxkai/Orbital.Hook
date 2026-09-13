# orbital-mcp

An MCP server that exposes the [Orbital subgraph](../subgraph) to AI environments —
Claude, Cursor, ChatGPT — as reusable tooling rather than a one-off script.

Covers the stable pool on each of the three deployments of the [Orbital Hook](../orbitalHook):
Unichain Sepolia, Arbitrum Sepolia and **Circle's Arc**, all indexed and live on
subgraph `v0.2.0`. Each chain is queried independently, so one unreachable endpoint
degrades an answer instead of failing it.

---

## The design rule

**A tool returns an answer, not a result set.**

An MCP server that forwards GraphQL and hands back JSON moves the reasoning into the
model's context window, where it is done worse and paid for twice. So the risk maths,
the cross-chain fan-out, and the WAD conversions all happen here:

```
{ "sumX": "587100000000000000000000000", "rInt": "293540000000000000000000000", ... }   ← data

[OK] arc-testnet (chain 5042002)
  Healthy. 13 interior ticks, none near a bound.
  TVL $5.25M | interior radius $293.54M | ticks 13/13 interior                     ← an answer
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
signal it arrives too late to act on: by then the liquidity has left.

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

## Live output

`orbital_book_health` against the live pools:

```
[OK] arc-testnet (chain 5042002)
  Healthy. 13 interior ticks, none near a bound.
  TVL $5.25M | interior radius $293.54M | ticks 13/13 interior
  47 swaps, 0 crossings, volume $255.9k, fees $25.59
  basket: USDC(6dp) FRAX(18dp) USDT(6dp) DAI(18dp)

[OK] unichain-testnet (chain 1301)
  Healthy. 13 interior ticks, none near a bound.
  TVL $5.70M | interior radius $298.37M | ticks 13/13 interior
  42 swaps, 0 crossings, volume $213.5k, fees $21.35
  basket: FRAX(18dp) USDT(6dp) DAI(18dp) USDC(6dp)

[OK] arbitrum-sepolia (chain 421614)
  Healthy. 14 interior ticks, none near a bound.
  TVL $5.83M | interior radius $293.17M | ticks 14/14 interior
  46 swaps, 0 crossings, volume $231.8k, fees $23.18
  basket: FRAX(18dp) DAI(18dp) USDC(6dp) USDT(6dp)
```

TVL is the tokens each pool holds, not the engine's `sumX`, which includes the
virtual floor concentrated ticks quote on.
