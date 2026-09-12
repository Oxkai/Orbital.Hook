<img src="frontend/public/orbital-mark.svg" width="80" height="80" alt="Orbital" />

# Orbital Hook

**One pool for every stablecoin.** A Uniswap v4 hook that replaces constant-product math with the Orbital sphere/torus curve, so USDC, USDT, DAI and FRAX all trade out of a single shared reserve book instead of six shallow pairs.

<p>
<a href="https://orbital-hook.vercel.app/"><b>Live app</b></a> &nbsp;·&nbsp;
Unichain &nbsp;·&nbsp; Arbitrum &nbsp;·&nbsp; <b>Circle's Arc</b> &nbsp;·&nbsp;
<b>152 tests passing</b> &nbsp;·&nbsp;
<b>$28M</b> seeded TVL &nbsp;·&nbsp;
<b>N assets, one book</b>
</p>

---

## What it gives you

<table>
<tr>
<td width="33%" valign="top">

### No fragmentation

Four stablecoins normally need **six separate pools**, each with its own shallow depth. Orbital keeps **one book**: a USDC/FRAX trade draws on exactly the same liquidity as USDC/USDT.

Adding a fifth coin adds a dimension, not a market.

</td>
<td width="33%" valign="top">

### Low slippage

Liquidity concentrates in the narrow band around $1 where dollars actually change hands, not spread across prices that never occur.

**7.7 bps** all-in on a 1,000-unit swap, measured on the live pool.

</td>
<td width="33%" valign="top">

### Deep liquidity

Depth compounds across the whole basket instead of splitting between pairs, and virtual reserves multiply what each real dollar does.

**~154x** the effective depth of a flat pool at N=5.

</td>
</tr>
<tr>
<td valign="top">

### Depeg isolation

Each LP sets the depeg they will hold. Cross it and that tick exits to the boundary and stops quoting, so a broken coin cannot drain the LPs who supplied the healthy ones.

This is the tail loss that wrecks flat stable pools.

</td>
<td valign="top">

### Real stablecoins

USDC and USDT are 6-decimal, DAI and FRAX are 18. The engine runs in WAD and converts only at the token boundary, rounding in the pool's favour every time.

Proven by a 128k-call solvency fuzz on a mixed-decimal pool.

</td>
<td valign="top">

### Travels well

Because one book holds every asset, any stablecoin is a single hop from any other. That makes the pool unusually cheap to fill against, which the ERC-7683 layer below builds on.

An extension, not the core.

</td>
</tr>
</table>

---

## The Orbital concept

Stablecoins all target $1, but AMMs make you choose. Curve holds many stablecoins together yet lays liquidity flatly along the whole curve. Uniswap v3 concentrates properly and then caps you at two tokens. Orbital ([Paradigm, 2025](https://www.paradigm.xyz/2025/06/orbital)) does both at once.

It comes down to the shape of the curve. Uniswap prices two tokens on a hyperbola; Orbital prices N tokens on a sphere:

$$x \cdot y = k \quad \longrightarrow \quad \|\mathbf{r} - \mathbf{x}\|^2 = \sum_{i=1}^{n}(r - x_i)^2 = r^2$$

| | |
|---|---|
| **Sphere** | The reserve vector $\mathbf{x} = (x_1, \dots, x_n)$ is a point on an N-sphere of radius $r$ centred at $\mathbf{r} = (r, \dots, r)$. The peg is the equal-price point $x_i = r(1 - 1/\sqrt{n})$, where every coin trades exactly 1:1. The curve only bends as the basket drifts off peg. |
| **Ticks** | Each LP picks a plane $\sum_i x_i = k$ cutting the sphere at a depeg bound, for example "provide liquidity only while the price holds above \$0.95". That is the concentration: capital sits where stablecoins actually trade. |
| **Torus** | Stacked ticks fold into a single torus the pool tracks with two running sums, $\sum x_i$ and $\sum x_i^2$. A swap stays O(1) however many coins or ticks exist. |

---

## What we built

We ported the full Orbital math from the paper (the N-sphere invariant, per-tick depeg planes, torus consolidation, and the quartic tick-crossing solver) and run it inside a v4 hook. On every swap `beforeSwap` evaluates that engine and hands back the trade, so any pair prices on the Orbital curve instead of constant-product. v4 still does custody, settlement and accounting.

There is one catch: a v4 pool is always exactly two tokens. To fit four stablecoins into a single book we register the $\binom{4}{2} = 6$ pairs as six v4 pools and point every `PoolKey.hooks` at the same hook. Those pairs are only views. Behind all of them the hook keeps **one** shared reserve vector, so a trade on USDC/USDT and a trade on DAI/FRAX move the same reserves and the same price.

---

## Architecture

Six pairs are `PoolKey`s inside the one PoolManager, and every key's `hooks` field points at the same contract, [`OrbitalHook.sol`](orbitalHook/src/OrbitalHook.sol). The PoolManager holds the tokens and the lock; the hook holds the curve and the shared reserves.

![Orbital architecture: Trader/LP, the v4 PoolManager holding the 6 PoolKeys, and the OrbitalHook](frontend/public/archi.png)

### The full system, across three chains

The diagram above is the on-chain core. The whole deployment adds two more layers:
the same engine running on three chains, and an indexing/monitoring path on top.

```mermaid
flowchart TB
    subgraph clients [" "]
        direction LR
        UI["Next.js app<br/>swap · pools · LP · activity"]
        AGENT["AI agent<br/>Claude / Cursor"]
    end

    MCP["orbital-mcp<br/>7 tools · risk reasoning"]

    subgraph graph ["The Graph"]
        direction LR
        SGU["orbital-unichain"]
        SGC["orbital-arc"]
        SGA["orbital-arbitrum"]
    end

    subgraph chains ["One engine, three deployments"]
        direction LR

        subgraph uni ["Unichain Sepolia · 1301"]
            PMU["v4 PoolManager<br/>canonical"]
            HU["OrbitalHook"]
            SU["IntentSettler"]
            PMU --- HU
        end

        subgraph arc ["Arc Testnet · 5042002 · gas = USDC"]
            PMC["v4 PoolManager<br/>SELF-DEPLOYED"]
            HC["OrbitalHook"]
            SC["IntentSettler"]
            PMC --- HC
        end

        subgraph arb ["Arbitrum Sepolia · 421614"]
            PMA["v4 PoolManager<br/>canonical"]
            HA["OrbitalHook"]
            SA["IntentSettler"]
            PMA --- HA
        end
    end

    HYP{{"Hyperlane"}}

    UI -->|"swap / LP"| PMU
    UI -->|"swap / LP"| PMC
    UI -->|"swap / LP"| PMA
    UI -->|"activity feed"| graph

    AGENT --> MCP
    MCP --> graph

    SGU -.->|"indexes events<br/>+ reads live slot0"| HU
    SGC -.-> HC
    SGA -.-> HA

    SU <-->|"ERC-7683 orders"| HYP
    SA <-->|"ERC-7683 orders"| HYP
    SC -.->|"shim mailbox:<br/>no Hyperlane on Arc testnet"| SC

    classDef gap fill:#3a2323,stroke:#a05252,color:#f0d0d0
    classDef arcbox fill:#232a3a,stroke:#5272a0,color:#d0dcf0
    class PMC,SC gap
    class arc arcbox
```

**What the diagram is saying.**

- **One engine, three deployments.** Each chain has its own `OrbitalHook` with its
  own reserves. The settlers move *orders* between them; they do not merge the books.
- **Arc needed its v4 core deployed.** Uniswap has no v4 on Arc testnet (verified: every
  canonical `PoolManager` address returns 0 bytes), so
  [`DeployArc.s.sol`](orbitalHook/script/DeployArc.s.sol) deploys the PoolManager,
  router and quoter itself. Arc **mainnet** has a canonical one, and the same script
  takes it via env with no code change.
- **Arc has no Hyperlane either**, so its settler sits behind a labelled
  [`TestnetMailbox`](orbitalHook/script/mocks/TestnetMailbox.sol) shim. Arc is
  same-chain only and is deliberately excluded from cross-chain routing in the UI, so
  it can never offer a route that would strand funds.
- **The subgraph does more than mirror events.** `TickCrossed` only fires *after* a
  depeg bound is hit, which is useless as a warning, so every handler also reads live
  `slot0` / `ticks` and stores each tick's distance to its bound. That is what makes
  the risk question answerable, and it is how the tick-merge bug was found.
- **The app reads the index, not the chain.** The activity feed was scanning
  `eth_getLogs` in 10,000-block windows per chain; it is now one round trip per chain
  (~350ms Arc, ~1.0s Unichain), with RPC scanning kept as a per-chain fallback for
  Arbitrum until its subgraph is deployed.

- **PoolManager** is the v4 singleton. It owns the lock, custody of every real ERC-20, and the deferred-delta ("flash") accounting. The six `PoolKey`s are entries in this one contract, not separate deployments.
- **OrbitalHook** is our code. It holds the abstract state: the reserve vector $\mathbf{x}$, the ticks, accrued fees, and the ERC-6909 LP shares it issues. It supplies the curve but never custodies real tokens.
- **Trader and LP.** A trader reaches the pool through any v4 router. An LP calls the hook directly (`addLiquidity`, `removeLiquidity`, `collect`) and the hook runs the `unlock` on their behalf.

### Token custody: two claim ledgers

This is the part that is easy to get wrong, so it is worth being precise. There are two separate ERC-6909 ledgers and they mean different things.

1. **PoolManager claim tokens, held by the hook.** Real ERC-20s always sit in the PoolManager. When value flows in, the hook turns its positive balance-delta into PoolManager claim tokens (`poolManager.mint(address(this), ...)`), a redeemable IOU against the singleton's custody. To pay out it burns them and the PoolManager releases the underlying.
2. **OrbitalHook LP shares, held by the LP.** The hook is itself an ERC-6909 with `tokenId = tickIdx`. Adding liquidity mints a share of your tick. These are soulbound in v1 and are how the hook tracks who owns what, alongside per-position fee checkpoints.

All of it happens inside one `unlock` frame. Balances move only as deltas in transient storage, and `unlock` refuses to return until every currency delta nets to zero.

### LP path

```
LP ─► hook.addLiquidity(k, r, maxAmounts)
        └─ poolManager.unlock(MINT, ...)
             └─ unlockCallback (only callable by PoolManager):
                  • compute deposit amounts for radius r
                  • update reserves / sumX / sumXSq / rInt   (the torus)
                  • per asset: settle()  ← pull the LP's ERC-20 in
                               mint()    → convert +delta to claim tokens
                  • verify the balance actually landed  (TokenTransferShortfall)
                  • check the sphere invariant           (revert if broken)
                  • _mint(LP, tickIdx, rWad)             → issue the LP share
        unlock returns only once every delta == 0
```

`removeLiquidity` and `collect` run the same flow in reverse. Pausing never blocks either path, so LPs can always exit.

---

## Runtime: one swap

```
caller.unlock(data)
└─ PoolManager unlocks, calls back ────────────────┐
   unlockCallback(data):                           │  runs inside the lock
     swap(poolKey, params)                         │
       ├─ beforeSwap → Orbital BeforeSwapDelta     │  (default x·y math bypassed)
       └─ records currency deltas (no tokens move) │
     settle()  ← trader pays input
     take()    ← trader pulls output
└─ unlock returns ─────────────────────────────────┘
   PoolManager asserts every delta == 0  (else revert)
```

`beforeSwap` runs the Orbital engine and returns a `BeforeSwapDelta` that fully specifies the trade, so the PoolManager's default `x·y` math never executes. Two invariants hold throughout: `swap` moves no tokens, and `unlock` will not return until every delta is zero.

---

## How it compares

| Property | Uniswap v3 | Curve Stable | Balancer | **Orbital** |
|---|---|---|---|---|
| Assets per pool | 2 | 2 to 8 (fixed) | 2 to 8 (fixed) | **N (≥ 2)** |
| Concentrated liquidity | Yes | No | No | **Yes** |
| Per-LP depeg range | n/a | No | No | **Yes** |
| Depeg drains pool | n/a | Yes | Yes | **Isolated** |
| Capital efficiency at peg | High (pair) | ~1 to 2x flat | ~1 to 2x flat | **~154x flat, N=5** |
| Mixed decimals (6dp + 18dp) | Yes | Yes | Yes | **Yes** |
| Cross-chain settlement | No | No | No | **ERC-7683** |
| LP position type | NFT (721) | LP token | LP token | **ERC-6909** |
| Venue | Standalone | Standalone | Standalone | **Uniswap v4 hook** |

---

## Extension: cross-chain settlement

Everything above is the hook. This part is built on top of it and is not required to use the pool.

The hook is deployed on Unichain, Base and Arbitrum Sepolia, each with an [`OrbitalIntentSettler`](orbitalHook/src/crosschain/OrbitalIntentSettler.sol) implementing [ERC-7683](https://eips.ethereum.org/EIPS/eip-7683), the cross-chain intents standard from Uniswap Labs and Across.

```
 user signs an intent            filler pays out                proof settles
 ──────────────────────          ────────────────               ─────────────
 escrow on origin        ──►     fill on destination     ──►    Hyperlane message
 (ERC-7683 open)                 routed through the             verified by handle(),
                                 local Orbital pool             escrow released
```

Two things make this work well with an N-asset book:

- **A filler needs inventory in only one asset per chain.** Because every stablecoin shares one book, any asset is a single hop from any other. A filler holding just USDC on Arbitrum can satisfy an order for DAI there. That collapses N x M inventory positions to 1 x M.
- **Settlement is cryptographic, not social.** The origin releases escrow only when its Hyperlane Mailbox delivers a message whose `(domain, sender)` matches a registered peer. There is no arbiter, no bond and no dispute game. The trust assumption is exactly Hyperlane's ISM for that route.

If the proof never arrives, the user reclaims the escrow after `fillDeadline + refundBuffer`.

---

## Walkthrough

<table>
<tr>
<td width="50%" valign="middle">

**Swap**

Trade any two of the four stablecoins from one shared pool at close to 1:1. Every pair routes through the same liquidity, and picking a token on another chain turns the same widget into a cross-chain order.

</td>
<td width="50%"><img src="frontend/public/screens/swap.png" width="100%" alt="Swap" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Pools**

All four stablecoins live in a single shared book. Every pair is a view onto the same reserves, so liquidity never fragments and depth compounds across the whole basket.

</td>
<td width="50%"><img src="frontend/public/screens/pools.png" width="100%" alt="Pools" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Liquidity depth**

Depth concentrates against the $1 peg where stablecoins actually trade, instead of spreading flat across prices that never happen. That concentration is where the capital efficiency comes from.

</td>
<td width="50%"><img src="frontend/public/screens/pool-depth.png" width="100%" alt="Liquidity depth chart" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Add liquidity: range**

Pick a depeg threshold and your capital concentrates above it. A tighter range earns more fees but pauses sooner if a coin depegs; a wider range is a safer backstop. Every LP sets their own.

</td>
<td width="50%"><img src="frontend/public/screens/add-range.png" width="100%" alt="Add liquidity: range" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Add liquidity: amount**

Your deposit splits across all four tokens at the current pool ratio, so you take balanced exposure to the whole basket in one step, with no rebalancing across pairs.

</td>
<td width="50%"><img src="frontend/public/screens/add-amount.png" width="100%" alt="Add liquidity: amount" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Add liquidity: review**

Check the full breakdown (tokens, depeg threshold, fee tier, slippage) and confirm. It settles on-chain in one transaction as an ERC-6909 position the hook issues against your tick.

</td>
<td width="50%"><img src="frontend/public/screens/add-review.png" width="100%" alt="Add liquidity: review" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Positions**

Manage everything in one place. Each tick you hold is its own ERC-6909 share that earns fees independently, and you can increase, decrease, collect, or burn it anytime.

</td>
<td width="50%"><img src="frontend/public/screens/positions.png" width="100%" alt="Positions" /></td>
</tr>
</table>

---

## Deployments

The same engine, live on three chains including **[Circle's Arc](https://docs.arc.io)**, where gas is paid in USDC. Each carries a realistic decimal mix (USDC/USDT 6dp, DAI/FRAX 18dp) and a four-tier seed at depeg bounds 0.97 / 0.93 / 0.88 / 0.80, plus a re-seed, for **14M rInt (~$28M TVL)** across 5 ticks.

Each chain is a separate book with its own reserves; the ERC-7683 settlers move orders between them rather than merging liquidity.

| Chain | OrbitalHook | OrbitalIntentSettler |
|---|---|---|
| **Unichain Sepolia** `1301` | `0xA4E98Ae00FdC5F62C53496a3B207632F4727aa88` | `0xF430302b0F8f70806feE5117f45DB019ddaA3a99` |
| **Arc Testnet** `5042002` | `0x9474a0Eff4d0501c472b29987925E03F69bd6a88` | `0xE82C3dFe38bb607E5c409C2b9b361a05855d8715` |
| Arbitrum Sepolia `421614` | `0x35C9D292768779E040e296AC20cf10b9D7A22a88` | `0xD8447BeAcf4a2768C4DCDb195b8D7122809a64e6` |

> Redeployed 2026-09-07 with the tick-merge fix. Base Sepolia was retired at the same time: it still runs the pre-fix contract.

Token addresses, canonical v4 infra (PoolManager, SwapRouter, V4Quoter), Hyperlane Mailboxes and the peer registry all live in [`orbitalHook/deployments.json`](orbitalHook/deployments.json), which the frontend config is generated from.

> **Asset index order differs per chain.** The hook sorts assets ascending by address, and addresses are unrelated across chains, so USDC is index 0 on Unichain and index 3 on Base. Always resolve by symbol, never by index.

- Live app: <https://orbital-hook.vercel.app/>
- Hook explorer: <https://sepolia.uniscan.xyz/address/0xA4E98Ae00FdC5F62C53496a3B207632F4727aa88>
- Arc explorer: <https://testnet.arcscan.app/address/0x9474a0Eff4d0501c472b29987925E03F69bd6a88>
- Subgraphs: `https://api.studio.thegraph.com/query/107768/orbital-{arc,unichain}/v0.1.0`

---

## Testing

**152 tests, 0 failures.** The ones that carry the weight, all on the engine:

| Suite | What it proves |
|---|---|
| `Solvency.invariant.t.sol` | Stateful fuzz, **256 runs / 128k calls**, on two decimal profiles. Real claim-token custody always covers reserves plus accrued fees, and rounding only ever favours the pool. The mixed-decimal profile (6/6/18) is the one that actually exercises the scaling layer; an all-18 run leaves every conversion a no-op and proves nothing about it. |
| `MixedDecimalsLifecycle.t.sol` | Deterministic add → swap → collect → partial burn → full burn on a 6dp book, so every operation is asserted to *succeed*, not merely to not break. Also asserts a fee-on-transfer token is refused at the deposit boundary. |
| `OrbitalHook.t.sol` | 57 tests over the hook surface: constructor guards, hook permissions, LP entry, swaps, tick crossings, boundary behaviour, pause and ownership. |
| Math libraries | `SphereMath`, `TorusMath`, `TickLib`, `QuadraticSolver`, including fuzzed solver residual and stability bounds. |

The cross-chain extension adds `OrbitalIntentSettler.t.sol` and `CrosschainFork.t.sol`, the latter running live forks of Base and Arbitrum Sepolia at once against real Hyperlane Mailboxes, with a forged-proof test asserting escrow does not move for a wrong `(domain, sender)`.

```bash
cd orbitalHook && forge test          # 152 passing
```

---

## Simulations

Every script is self-describing: it reads the asset set and decimals off the hook, so nothing goes stale on redeploy.

| Script | Purpose |
|---|---|
| `DeployTestnet.s.sol` | Tokens, hook, all six pools and the four-tier seed, on any chain |
| `SimulateMultiLPLive.s.sol` | Three independent LPs on three different ticks against a **live** pool, plus swaps, collects and partial burns |
| `Lifecycle.s.sol` | Full LP lifecycle, asserting the freed tick slot is recycled |
| `SeedActivity.s.sol` | Swap waves and a mid-run re-seed, kept near peg |
| `Simulate.s.sol`, `SimulateMultiLP.s.sol` | Local anvil equivalents |
| `CrosschainDemo.s.sol` | The extension: open → fill → Hyperlane proof → settle |

The live multi-LP run is a good correctness check on fee accounting:

```
alice  r=600k → 0.3577 wad      5.96e-7 per unit of radius
bob    r=400k → 0.2385 wad      5.96e-7
carol  r=250k → 0.1491 wad      5.96e-7
```

Exactly pro-rata by radius.

---

## Repo layout

```
UHI/
├── orbitalHook/            Solidity
│   ├── src/OrbitalHook.sol         the v4 hook and Orbital engine
│   ├── src/libraries/              SphereMath, TorusMath, TickLib, QuadraticSolver
│   ├── src/crosschain/             ERC-7683 settler + Hyperlane interfaces
│   ├── script/                     deploy and simulation scripts
│   │   ├── DeployArc.s.sol             Arc: self-deploys v4 core where absent
│   │   └── mocks/TestnetMailbox.sol    labelled shim, chains without Hyperlane
│   ├── FEEDBACK.md                 Uniswap v4 developer feedback
│   └── deployments.json            machine-readable address registry
├── subgraph/               The Graph: one manifest, three networks
│   ├── schema.graphql              Pool, Asset, Tick, Swap, TickCross, PoolSnapshot
│   ├── src/mapping.ts              reproduces the engine's own crossing condition
│   └── networks.json               per-chain address + start block
├── orbital-mcp/            MCP server exposing the subgraph to AI environments
│   ├── src/analysis.ts             risk model: progress x share of radius
│   └── SKILL.md                    agent-facing usage guide
└── frontend/               Next.js app: swap, pools, positions, transactions
    └── lib/subgraph.ts             activity feed, RPC scanning as fallback
```

## Indexing and monitoring

The three deployments are indexed by [`subgraph/`](subgraph) and read by
[`orbital-mcp/`](orbital-mcp), an MCP server that answers risk questions about the
pools from Claude, Cursor or any MCP client.

The point is not a dashboard. `TickCrossed` only fires *after* a depeg bound is hit,
so as a warning it arrives too late. Every handler therefore also reads live `slot0`
and `ticks` at its own block and reproduces the engine's crossing condition,

```
alphaNorm = ((sumX·WAD/√N) − kBound)·WAD / rInt      kNorm = k·WAD / r
```

storing how much slack each tick has left. That turns the feed into a leading
indicator, and it is how a real bug surfaced: one tick per chain reported a bound
*below* parity, meaning it could never cross and its depeg protection was inert. Cause
and fix are written up in
[the hook README](orbitalHook/README.md#a-bug-the-indexing-found-and-the-fix).

---

## Getting started

```bash
git clone --recurse-submodules <repo>

cd orbitalHook
forge test                       # 152 passing

cd ../frontend
npm install && npm run dev       # http://localhost:3000
```

Foundry uses `via_ir = true`, required by the Orbital math libraries. If you cloned without submodules, run `git submodule update --init --recursive`.

---

## References

- Paradigm Orbital paper: <https://www.paradigm.xyz/2025/06/orbital>
- ERC-7683 cross-chain intents: <https://eips.ethereum.org/EIPS/eip-7683>
- Uniswap v4 docs: <https://docs.uniswap.org/contracts/v4/overview>
- Hyperlane docs: <https://docs.hyperlane.xyz>
