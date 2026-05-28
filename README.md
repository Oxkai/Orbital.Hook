<img src="frontend/public/orbital.jpg" width="76" height="76" alt="Orbital logo" />

# Orbital Hook

A Uniswap v4 hook that turns a single pool into an N-asset stablecoin AMM. Every stablecoin (USDC / USDT / DAI / FRAX) shares one reserve book inside the hook, and the hook replaces Uniswap's swap curve with the Orbital sphere/torus math — concentrated liquidity, generalized to N coins, on top of v4's infrastructure.

Live app → <https://orbital-hook.vercel.app/> · X Layer Testnet · 100 tests passing

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

## Deployed — X Layer Testnet (chainId 1952)

| Contract | Address |
|---|---|
| OrbitalHook | `0x4024911A26B5BF5160D156eccBAc148bd55c6a88` |
| PoolManager (v4) | `0x9BEACCac4e0358Cc276703dcE7341B9B9fEfd5f7` |
| SwapRouter (v4) | `0xC30819b8ac12B5d12751b83cFfebD6F0bFa0b53E` |
| Quoter (v4) | `0x77442de670D723Db1Ae17fa9cA887c9426eBb41f` |
| Permit2 (canonical) | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| USDC | `0xBe272Bcb1Fa1d99616F53Ce7d7703589C92bb33b` |
| USDT | `0x3a2bCfc287b8106774Ec85533d821D3604cB7DC5` |
| DAI | `0x78340e3C5169b6DF15F13a8d627Db2C0e23cf921` |
| FRAX | `0x17c868495deF240091E95410e2B2D5a6cEabf6f0` |

Seeded with ~$20M TVL across 5 ticks, all interior.

- Live app — <https://orbital-hook.vercel.app/>
- Hook explorer — <https://www.okx.com/web3/explorer/xlayer-test/address/0x4024911A26B5BF5160D156eccBAc148bd55c6a88>

---

## Getting started

```bash
# Contracts
cd orbitalHook
forge test                       # 100 passing

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
