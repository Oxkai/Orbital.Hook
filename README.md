<img src="frontend/public/orbital.jpg" width="76" height="76" alt="Orbital logo" />

# Orbital Hook

A Uniswap v4 hook that turns a single pool into an N-asset stablecoin AMM. Every stablecoin (USDC / USDT / DAI / FRAX) shares one reserve book inside the hook, and the hook replaces Uniswap's swap curve with the Orbital sphere/torus math — concentrated liquidity, generalized to N coins, on top of v4's infrastructure.

Live app → <https://orbital-hook.vercel.app/> · Unichain Sepolia · 115 tests passing

---

## The Orbital concept (Paradigm)

Stablecoins all target $1, but AMMs force a trade-off: Curve pools many stablecoins together yet spreads liquidity flatly across the whole curve, while Uniswap v3 concentrates liquidity but only for two tokens. Orbital ([Paradigm, 2025](https://www.paradigm.xyz/2025/06/orbital)) does both at once.

The whole idea is one swap of curve. Uniswap prices two tokens on a hyperbola; Orbital prices N tokens on a sphere:

$$x \cdot y = k \quad \longrightarrow \quad \|\mathbf{r} - \mathbf{x}\|^2 = \sum_{i=1}^{n}(r - x_i)^2 = r^2$$

- **Sphere** — the reserve vector $\mathbf{x} = (x_1, \dots, x_n)$ is a point on an N-sphere of radius $r$ centred at $\mathbf{r} = (r, \dots, r)$. The peg sits at the equal-price point $x_i = r\left(1 - \tfrac{1}{\sqrt{n}}\right)$, where every coin trades exactly 1:1; the curve only bends as the basket drifts off peg.
- **Ticks** — each LP picks a plane $\sum_i x_i = k$ that cuts the sphere at a depeg bound ("provide liquidity only while the price holds above \$0.95"). That's the concentration: capital sits in the narrow band near peg where stablecoins actually trade, instead of being wasted on prices that never happen.
- **Torus** — stacked ticks fold into a torus the pool tracks with just the running sums $\sum x_i$ and $\sum x_i^2$, so a swap stays O(1) no matter how many coins or ticks exist.

The payoff: N stablecoins in one pool, concentrated liquidity for capital efficiency, and depeg isolation — when one coin breaks peg its tick exits to the boundary and the rest keep trading 1:1.

---

## What we built

We implemented the full Orbital math from the paper — the N-sphere invariant, per-tick depeg planes, the torus consolidation, and the quartic tick-crossing solver — and run it inside a v4 hook. On a swap, `beforeSwap` evaluates that engine and returns the trade, so any pair prices on the Orbital curve instead of constant-product, while v4 keeps doing custody, settlement, and accounting.

The catch: a v4 pool is always two tokens. To get all four stablecoins into one book, we deploy the $\binom{4}{2} = 6$ pairs as six separate v4 pools and point every `PoolKey.hooks` at the same hook. The pairs are just views — the hook holds one shared reserve vector behind all of them. A trade on USDC/USDT and a trade on DAI/FRAX move the same reserves and the same price.

---

## Architecture

The 6 pairs are `PoolKey`s that live *inside* the one PoolManager; every key's `hooks` points at the same OrbitalHook. The PoolManager holds all tokens and the lock; the hook holds the curve and the shared reserves.

![Orbital architecture — Trader/LP, the v4 PoolManager holding the 6 PoolKeys, and the OrbitalHook](frontend/public/archi.png)

- **PoolManager** — singleton: owns the lock, custody of every ERC-20, and the deferred-delta accounting. The 6 `PoolKey`s are registered here, not separate contracts.
- **OrbitalHook** — our code: holds the reserve vector (the sphere), the ticks, the fees, and the ERC-6909 LP shares. It only supplies the curve; it never holds tokens.
- **LP** calls the hook directly; the hook settles through the PoolManager.

---

## Runtime — one swap

A trader doesn't call `swap` directly. Any contract calls `unlock`; the PoolManager calls back, the swap and settlement happen inside that locked frame, and no tokens move until the deltas net to zero.

```
caller.unlock(data)
└─ PoolManager unlocks, calls back ────────────────┐
   unlockCallback(data):                           │  runs inside the lock
     swap(poolKey, params)                         │
       ├─ beforeSwap → Orbital BeforeSwapDelta      │  (default x·y math bypassed)
       └─ records currency deltas (no tokens move) │
     sync + transfer + settle()   ← pay input      │
     take()                        ← pull output    │
└─ unlock returns ─────────────────────────────────┘
   PoolManager asserts every delta == 0  (else revert)
```

Two invariants: `swap` moves no tokens (it only writes deltas to transient storage), and `unlock` won't return until every currency delta nets to zero.

---

## Why it matters

- **No liquidity fragmentation.** Four stablecoins would normally need six separate pools, each with its own shallow depth. Here all six pairs share one book, so a USDC/FRAX trade draws on the same liquidity as USDC/USDT — one deep pool instead of six thin ones.
- **Capital efficiency via virtual reserves.** A tick removes the curve below its depeg bound, so a small amount of real capital behaves like a much larger reserve near peg — Uniswap v3's virtual liquidity, generalized to the N-sphere.
- **N coins, not 2.** One pool prices a whole basket of dollars off a single sphere — add a fifth or sixth stablecoin without standing up a new market.
- **Depeg isolation.** If one coin breaks peg, its tick exits to the boundary and the rest keep trading 1:1 — the bad coin doesn't drain the pool.
- **Built on v4, not beside it.** We only supply the curve; custody, accounting, and the unlock/settle flow are all v4's — so the pools are reachable by any v4 router or aggregator.

---

## How it compares

| Property | Uniswap V3 | Curve Stable | Balancer | Orbital |
|---|---|---|---|---|
| Assets per pool | 2 | 2–8 (fixed) | 2–8 (fixed) | N (≥ 2) |
| Concentrated liquidity | Yes | No | No | Yes |
| Per-LP depeg range | n/a | No | No | Yes |
| Depeg drains pool | n/a | Yes | Yes | Isolated |
| Capital efficiency at peg | High (pair) | ~1–2× flat | ~1–2× flat | ~154× flat, N=5 |
| TWAP oracle | Yes | No | Yes | Roadmap |
| LP position type | NFT (721) | LP token | LP token | ERC-6909 |
| Venue | Standalone | Standalone | Standalone | Uniswap v4 hook |

---

## Walkthrough

<table>
<tr>
<td width="50%" valign="middle">

**Swap**

Trade any two of four stablecoins from one shared pool, at near-1:1. Every pair routes through the same liquidity — and if one coin depegs, the rest keep trading while the bad leg is fenced off.

</td>
<td width="50%"><img src="frontend/public/screens/swap.png" width="100%" alt="Swap" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Pools**

All four stablecoins live in a single shared book — every pair is a view onto the same reserves, so liquidity never fragments and depth compounds across the whole basket.

</td>
<td width="50%"><img src="frontend/public/screens/pools.png" width="100%" alt="Pools" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Liquidity depth**

Depth concentrates against the $1 peg where stablecoins actually trade, instead of spreading flat across prices that never happen — that's where the capital efficiency comes from.

</td>
<td width="50%"><img src="frontend/public/screens/pool-depth.png" width="100%" alt="Liquidity depth chart" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Add liquidity — range**

Pick a depeg threshold and your capital concentrates above it. Tighter earns more fees but its tick pauses sooner if a coin depegs; wider is a safer backstop. Every LP sets their own.

</td>
<td width="50%"><img src="frontend/public/screens/add-range.png" width="100%" alt="Add liquidity: range" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Add liquidity — amount**

Your deposit splits across all four tokens at the current pool ratio, so you add balanced exposure to the whole basket in one step — no rebalancing across pairs.

</td>
<td width="50%"><img src="frontend/public/screens/add-amount.png" width="100%" alt="Add liquidity: amount" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Add liquidity — review**

Check the full breakdown — tokens, depeg threshold, fee tier, slippage — then confirm. It settles on-chain in one transaction as an ERC-6909 position the hook issues against your tick.

</td>
<td width="50%"><img src="frontend/public/screens/add-review.png" width="100%" alt="Add liquidity: review" /></td>
</tr>

<tr>
<td width="50%" valign="middle">

**Positions**

Manage everything from one place — each tick you hold is its own ERC-6909 share, earning fees independently. Increase, decrease, collect, or burn anytime.

</td>
<td width="50%"><img src="frontend/public/screens/positions.png" width="100%" alt="Positions" /></td>
</tr>
</table>

---

## Repo layout

```
UHI/
├── orbitalHook/        Solidity — the v4 hook (see orbitalHook/README.md)
└── frontend/           Next.js app — swap, pools, positions (see frontend/README.md)
```

---

## Deployed — Unichain Sepolia (chainId 1301)

Uniswap v4 is canonically deployed on Unichain, so the hook plugs into the official `PoolManager`, `SwapRouter`, and `V4Quoter` instead of a self-hosted stack.

| Contract | Address |
|---|---|
| OrbitalHook | `0x405E3C4541077C501854082cf3256926BeF6AA88` |
| PoolManager (v4, canonical) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| V4Quoter (canonical) | `0x56DcD40A3F2D466F48E7F48BdBe5cc9b92aE4472` |
| SwapRouter (v4) | `0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540` |
| Permit2 (canonical) | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| USDC (mock) | `0x3f53c9ae1ae5D34D8A89986ea456da8e69916725` |
| USDT (mock) | `0x17684C1C522E7cCD9a38E1Ab5994BB294Bf1ef90` |
| DAI (mock) | `0x345581C18e6b15D02b303A4E7Cc2F0671591acbE` |
| FRAX (mock) | `0x1D49545CccDA551d5f5b2Ec95Fc53C34432016cF` |

Seeded with **~$24M TVL across 5 ticks**, all interior. Initial seed places 4 tiers at depeg bounds 0.95 / 0.90 / 0.85 / 0.80; the activity simulation adds a fifth tick after a balanced swap wave.

- Live app — <https://orbital-hook.vercel.app/>
- Hook explorer — <https://sepolia.uniscan.xyz/address/0x405E3C4541077C501854082cf3256926BeF6AA88>

---

## Getting started

```bash
# Contracts
cd orbitalHook
forge test                       # 115 passing

# Frontend
cd frontend
npm install && npm run dev       # http://localhost:3000
```

Foundry uses `via_ir = true` (required by the Orbital math libraries). Clone with `--recurse-submodules`, or run `git submodule update --init --recursive` afterwards.

---

## References

- Paradigm Orbital paper — <https://www.paradigm.xyz/2025/06/orbital>
- Uniswap v4 — <https://docs.uniswap.org/contracts/v4/overview>
- Our standalone Orbital AMM that shares the same engine: [`../contracts`](../contracts) (parent project)
