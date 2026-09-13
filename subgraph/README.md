# Orbital Subgraph

Indexes the [Orbital Hook](../orbitalHook) across **three chains**, including Circle's Arc.

| Network | graph-cli name | chainId | Hook | Subgraph |
|---|---|---|---|---|
| Unichain Sepolia | `unichain-testnet` | 1301 | `0xB9cD5ccF…fE6A88` | live, `v0.2.0` |
| **Arc Testnet** | `arc-testnet` | 5042002 | `0x1D922FB9…01aa88` | live, `v0.2.0` |
| Arbitrum Sepolia | `arbitrum-sepolia` | 421614 | `0x8e7BEf43…842a88` | live, `v0.2.0` |

All three are supported by The Graph, confirmed against its networks registry: Arc
offers `subgraphs` only, the other two also have `firehose` and `substreams`.

Each indexes that chain's stable pool; the frontend reads the FX pool on Arc
directly from the chain.

---

## A leading indicator, not a log mirror

Orbital's real risk is not volume, it is **tick crossings**.

Each LP picks a depeg bound. Cross it and that tick flips to *boundary*, stops
quoting, and leaves the book. If every interior tick crosses, `kBound` goes
non-zero and the engine **refuses mint and burn for the entire pool**, not just
the tick that crossed. That is the failure mode the whole tick design exists to
contain, and it is the thing worth monitoring.

The contract emits `TickCrossed` — but only *after* a boundary has already been
hit, too late to act on as a risk signal: by the time it fires, the liquidity
has already left.

So every handler here also reads live engine state (`slot0`, `reserves`,
`ticks`) at its own block and stores **`distanceToBoundaryWad`** per tick, plus
a `PoolSnapshot` holding the minimum across the book. That converts the feed
from a record of what happened into a leading indicator of what is about to.

`PoolSnapshot` is what makes trend questions answerable: *"has the nearest tick
been closing on its boundary over the last N swaps?"* One distance reading in
isolation says nothing.

---

## Setup

```bash
npm install
npm run codegen
npm run build:arc          # or :unichain / :arbitrum
```

`subgraph.yaml` carries a placeholder network and address. The real values come
from `networks.json` via `graph build --network <name>`, so one manifest serves
all three deployments.

## Deploy

Requires a deploy key from [Subgraph Studio](https://thegraph.com/studio/).
Create **one subgraph per network** (they are separate indexes) in the Studio UI first,
then:

```bash
npx graph auth <DEPLOY_KEY>      # or pass --deploy-key to each deploy

npx graph deploy orbital-arc       --network arc-testnet       --version-label v0.2.0
npx graph deploy orbital-unichain  --network unichain-testnet  --version-label v0.2.0
npx graph deploy orbital-arbitrum  --network arbitrum-sepolia  --version-label v0.2.0
```

---

## Queries

**Book health, the headline question**

```graphql
{
  pools {
    network
    frozen                 # engine-wide: mint and burn are blocked while true
    rInt
    virtualReserveWad      # per-asset virtual floor of the concentrated ticks
    interiorTickCount
    tickCount
    swapCount
    crossCount
    assets { symbol reserveWad realReserveWad }
  }
}
```

TVL is the sum of `realReserveWad`, the tokens the pool holds. `reserveWad` is
the engine's reserve, which includes the virtual floor concentrated bands quote
on but never deposit, and is many times larger.

**Which tick is closest to exiting**

```graphql
{
  ticks(
    where: { isInterior: true }
    orderBy: distanceToBoundaryWad
    orderDirection: asc
    first: 5
  ) {
    id
    pool { network }
    k
    r
    kNorm                  # k*WAD/r: what the engine actually tests
    distanceToBoundaryWad  # kNorm - alphaNorm; crosses at zero
    boundaryProgressBps    # 0 = at parity, 10000 = crossing now
    shareOfRIntBps         # how much of the book leaves with it
    crossCount
  }
}
```

The pairing matters: a tick one basis point from its bound holding 2% of the
book is noise; the same tick holding 40% is the whole pool about to thin out.

**Slippage, measured rather than modelled**

```graphql
{
  swaps(orderBy: timestamp, orderDirection: desc, first: 20) {
    pool { network }
    assetIn  { symbol decimals }
    assetOut { symbol decimals }
    amountInWad
    amountOutWad
    slippageBps
  }
}
```

Same-peg assets, so 1:1 is the fair price and any shortfall is fee plus curve
slippage. This is the number the design exists to shrink.

**Crossings that froze the book**

```graphql
{
  tickCrosses(where: { causedFreeze: true }, orderBy: timestamp, orderDirection: desc) {
    pool { network }
    tick { id k }
    nowInterior
    rIntAfter
    txHash
  }
}
```

---

## Notes for querying

**Asset indices are per chain.** The hook sorts its basket ascending by address,
and addresses are unrelated across chains, so USDC is index 0 on Arc, 3 on
Unichain and 2 on Arbitrum. Events carry the **index**, never the symbol. Always resolve through
`Asset` for the chain the event came from — indexing a cross-chain symbol table
by a per-chain index silently returns the wrong token.

**Decimals are mixed.** USDC and USDT are 6dp, DAI and FRAX are 18dp. Raw
`amountIn` / `amountOut` are not comparable across legs; use the `*Wad` fields,
which are pre-scaled by the hook's own `scaleOf`.

**Everything is WAD.** `sumX`, `rInt`, `k`, `r` and `distanceToBoundaryWad` are
all 1e18-scaled. Divide before displaying.

**`distanceToBoundaryWad` can be negative.** The sign is deliberately kept. A
negative value means the tick should already have crossed, which is worth
surfacing rather than clamping to zero.
