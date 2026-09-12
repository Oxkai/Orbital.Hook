---
name: orbital-monitoring
description: Monitor Orbital Hook stableswap pools across Unichain, Arbitrum and Circle's Arc via The Graph. Use when asked about pool health, depeg/tick risk, whether a pool could freeze, realised slippage, or tick crossing history for Orbital.
---

# Orbital pool monitoring

Reads live Orbital Hook state from three subgraphs and answers risk questions about
it. Orbital is a Uniswap v4 hook that replaces constant-product with a sphere/torus
curve, so N stablecoins trade out of one shared reserve book.

## The one concept that matters

Each LP picks a **depeg bound**. Cross it and that tick flips to *boundary*, stops
quoting, and leaves the book. That is the protection working: a broken stablecoin
cannot drain the LPs who supplied the healthy ones.

The failure mode is losing too many at once. When every interior tick has crossed,
`kBound` goes non-zero and the engine **refuses mint and burn for the entire pool** —
not just the tick that crossed. That is what "frozen" means here, and it is the thing
worth monitoring.

The contract emits `TickCrossed`, but only *after* a bound is hit. As a risk signal
that is useless: the liquidity is already gone. So the subgraph reads live engine
state at every event and stores how much slack each tick has left.

## Which tool to reach for

| Question | Tool |
|---|---|
| "Is anything wrong?" — always start here | `orbital_book_health` |
| "Which tick gives way first?" | `orbital_ticks_at_risk` |
| "Could this pool freeze?" | `orbital_freeze_risk` |
| "How good are the prices?" | `orbital_slippage_report` |
| "Has protection ever triggered?" | `orbital_crossing_history` |
| Anything not covered above | `orbital_graphql` |
| "Which chains can you see?" | `orbital_networks` |

All accept `network`: `all` (default), `arc`, `unichain`, `arbitrum`.

## Reading the output

**Severity** is `[OK]` → `[WATCH]` → `[ELEVATED]` → `[CRITICAL]`, scored as
`progress × share of interior radius`. Both halves matter: a tick 1bp from its bound
holding 2% of the book is noise; the same tick holding 40% is the pool about to thin
out. Never report proximity without the share.

**`boundaryProgressBps`** is how far the book has travelled from parity to *that
tick's own* bound. It is tick-relative on purpose — a 0.97 tick and a 0.80 tick sit at
different absolute distances by construction, so only progress makes them comparable.
0 = at parity, 10000 = crossing now.

**`DEFECT`** is not a near-crossing. It means the tick's bound sits at or behind
parity, so a rising `alphaNorm` can never reach it and the tick will never cross —
its depeg protection is inert. Opposite conclusion to "about to cross", so say so
explicitly rather than folding it in with the rest.

**Negative slippage is normal.** A swap that crosses into a deeper tick can come out
ahead of 1:1. Do not report it as an error.

## Interpreting well

- One distance reading means nothing. `orbital_freeze_risk` includes direction over
  recent snapshots; quote the trend, not just the current number.
- "Only one interior tick left" is a serious finding even at `[OK]` severity: there is
  nothing left to hold `kBound` at zero.
- Asset **indices differ per chain** — the hook sorts by address, and addresses are
  unrelated across chains. USDC is index 2 on Arc and index 3 on Unichain. Always
  resolve by symbol.
- Amounts are WAD (1e18). The tools convert; raw `orbital_graphql` output does not.

## Setup

```bash
npm install && npm run build
```

Point it at the subgraphs:

```
ORBITAL_SUBGRAPH_ARC=https://api.studio.thegraph.com/query/107768/orbital-arc/v0.1.0
ORBITAL_SUBGRAPH_UNICHAIN=https://api.studio.thegraph.com/query/107768/orbital-unichain/v0.1.0
ORBITAL_SUBGRAPH_ARBITRUM=https://api.studio.thegraph.com/query/107768/orbital-arbitrum/v0.1.0   # not yet deployed
```

Any subset works — `orbital_networks` reports what is configured, and an unreachable
chain degrades to a partial answer rather than failing the call.

MCP client config:

```json
{
  "mcpServers": {
    "orbital": {
      "command": "node",
      "args": ["/absolute/path/to/orbital-mcp/dist/index.js"],
      "env": { "ORBITAL_SUBGRAPH_ARC": "https://api.studio.thegraph.com/query/107768/orbital-arc/v0.1.0" }
    }
  }
}
```

## Worked example

This tooling's first run against live data found a real bug. Every chain reported one
tick with `kNorm ≈ 0.5007` against a parity of `1.0`:

```
[CRITICAL] arc-testnet tick #2 | DEFECT | 28.57% of radius | score 0.286
    DEFECTIVE BOUND: kNorm 0.500716 sits BELOW parity 1, so a rising alphaNorm
    can never reach it. This tick will not cross, meaning its depeg protection
    is inert while it holds 28.57% of interior radius.
```

The cause was a tick-merge in the hook adding radius without adding `k`, halving
`kNorm` and silently moving an LP's depeg bound. Fixed in `_findOrCreateTick`; the
same tools now report `0 defective ticks`.
