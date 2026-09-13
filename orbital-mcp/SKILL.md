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

The contract emits `TickCrossed`, but only *after* a bound is hit, too late to act on
as a risk signal. So the subgraph reads live engine
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
ORBITAL_SUBGRAPH_ARC=https://api.studio.thegraph.com/query/107768/orbital-arc/v0.2.0
ORBITAL_SUBGRAPH_UNICHAIN=https://api.studio.thegraph.com/query/107768/orbital-unichain/v0.2.0
ORBITAL_SUBGRAPH_ARBITRUM=https://api.studio.thegraph.com/query/107768/orbital-arbitrum/v0.2.0
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
      "env": { "ORBITAL_SUBGRAPH_ARC": "https://api.studio.thegraph.com/query/107768/orbital-arc/v0.2.0" }
    }
  }
}
```

## Worked example

Asked "is anything wrong with the Orbital pools?", call `orbital_book_health` with
`network: "all"`. Live output:

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

Every chain is `[OK]`: no tick is near its bound and nothing is frozen. Report that
plainly, with TVL and volume per chain, and drill into `orbital_ticks_at_risk` only
when a chain is not `[OK]`.
