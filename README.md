<img src="frontend/public/orbital.png" width="76" height="76" alt="Orbital logo" />

# Orbital Hook

A Uniswap v4 hook that turns a single pool into an N-asset stablecoin AMM. Every stablecoin (USDC / USDT / DAI / FRAX) shares one reserve book inside the hook, and the hook replaces Uniswap's swap curve with the Orbital sphere/torus math — concentrated liquidity, generalized to N coins, on top of v4's infrastructure.

> **UHI9 theme — Impermanent Loss & Yield Systems.** Orbital is an impermanent-loss-mitigation hook for stablecoin LPs: concentrating near the peg keeps IL ≈ 0 while earning more fees per dollar, and when a coin breaks peg its tick is automatically fenced off — capping the tail IL that drains Curve-style stable LPs. A Reactive Network circuit-breaker adds an oracle-driven safety net on top.

Live app → <https://orbital-hook.vercel.app/> · Unichain Sepolia · 121 tests passing

---

## The Orbital concept (Paradigm)

Stablecoins all target $1, but AMMs force a trade-off: Curve pools many stablecoins together yet spreads liquidity flatly across the whole curve, while Uniswap v3 concentrates liquidity but only for two tokens. Orbital ([Paradigm, 2025](https://www.paradigm.xyz/2025/06/orbital)) does both at once.

The whole idea is one swap of curve. Uniswap prices two tokens on a hyperbola; Orbital prices N tokens on a sphere:

$$x \cdot y = k \quad \longrightarrow \quad \|\mathbf{r} - \mathbf{x}\|^2 = \sum_{i=1}^{n}(r - x_i)^2 = r^2$$

- **Sphere** — the reserve vector $\mathbf{x} = (x_1, \dots, x_n)$ is a point on an N-sphere of radius $r$ centred at $\mathbf{r} = (r, \dots, r)$. The peg sits at the equal-price point $x_i = r\left(1 - \tfrac{1}{\sqrt{n}}\right)$, where every coin trades exactly 1:1; the curve only bends as the basket drifts off peg.
- **Ticks** — each LP picks a plane $\sum_i x_i = k$ that cuts the sphere at a depeg bound ("provide liquidity only while the price holds above \$0.95"). That's the concentration: capital sits in the narrow band near peg where stablecoins actually trade, instead of being wasted on prices that never happen.
- **Torus** — stacked ticks fold into a torus the pool tracks with just the running sums $\sum x_i$ and $\sum x_i^2$, so a swap stays O(1) no matter how many coins or ticks exist.

The payoff is the theme of this hook: **less impermanent loss for stablecoin LPs.** N stablecoins sit in one pool with concentrated liquidity for capital efficiency, and depeg isolation contains the tail risk — when one coin breaks peg its tick exits to the boundary and the rest keep trading 1:1, so the broken coin doesn't drain the LPs who provided the others.

---

## What we built

We implemented the full Orbital math from the paper — the N-sphere invariant, per-tick depeg planes, the torus consolidation, and the quartic tick-crossing solver — and run it inside a v4 hook. On a swap, `beforeSwap` evaluates that engine and returns the trade, so any pair prices on the Orbital curve instead of constant-product, while v4 keeps doing custody, settlement, and accounting.

The catch: a v4 pool is always two tokens. To get all four stablecoins into one book, we deploy the $\binom{4}{2} = 6$ pairs as six separate v4 pools and point every `PoolKey.hooks` at the same hook. The pairs are just views — the hook holds one shared reserve vector behind all of them. A trade on USDC/USDT and a trade on DAI/FRAX move the same reserves and the same price.

---

## Architecture

The 6 pairs are `PoolKey`s that live *inside* the one PoolManager; every key's `hooks` points at the same hook — [`OrbitalHook.sol`](orbitalHook/src/OrbitalHook.sol). The PoolManager holds all tokens and the lock; the hook holds the curve and the shared reserves.

![Orbital architecture — Trader/LP, the v4 PoolManager holding the 6 PoolKeys, and the OrbitalHook](frontend/public/archi.png)

**Three actors:**

- **PoolManager** — the v4 singleton. It owns the lock, custody of every real ERC-20, and the deferred-delta ("flash") accounting. The 6 `PoolKey`s are entries in this one contract, not separate deployments.
- **OrbitalHook** — our code. It holds the *abstract* state: the reserve vector $\mathbf{x}$ (the sphere), the ticks, the accrued fees, and the ERC-6909 LP shares it issues. It supplies the curve and the LP entry points — but it **never custodies real tokens**.
- **Trader / LP** — a trader reaches the pool through any v4 router (`unlock` → `swap`); an LP calls the hook **directly** (`addLiquidity` / `removeLiquidity` / `collect`), and the hook does the `unlock` for them.

### Token custody — flash accounting & two claim ledgers

This is the part that trips people up, so to be precise: there are **two separate ERC-6909 ledgers**, and they mean different things.

1. **PoolManager claim tokens — held by the hook.** Real ERC-20s always sit in the PoolManager. When value flows into the pool, the hook converts its positive balance-delta into PoolManager **claim tokens** (`poolManager.mint(address(this), …)`) — a redeemable IOU against the singleton's custody. So the hook's "ownership" of the pooled liquidity is just a claim-token balance; it holds zero raw ERC-20. To pay value out, it burns those claim tokens (`settle(..., claims=true)`) and the PoolManager releases the underlying to the recipient (`take(..., claims=false)`).
2. **OrbitalHook LP shares — held by the LP.** Separately, the hook is *itself* an ERC-6909, and `tokenId = tickIdx`. When you add liquidity it mints you a share of your tick (`_mint(you, tickIdx, rWad)`). These are **soulbound** in v1 (`transfer`/`transferFrom` revert) and are how the hook tracks who owns what, plus per-position fee checkpoints.

Everything happens inside a single `unlock` frame: the PoolManager hands control to the callback, balances move only as **deltas in transient storage**, and `unlock` refuses to return until every currency delta nets to **zero**. No tokens move until the books balance.

### LP path — `addLiquidity`

```
LP ─► hook.addLiquidity(k, r, maxAmounts)         (LP calls the hook, not the PoolManager)
        └─ poolManager.unlock(MINT, …)
             └─ unlockCallback (only callable by PoolManager):
                  • compute equal-price deposit amounts for radius r
                  • update reserves / sumX / sumXSq / rInt  (the torus)
                  • for each asset:
                       settle()  ← pull the LP's ERC-20 into the PoolManager
                       mint()    → convert the +delta into claim tokens held by the hook
                  • check the sphere invariant (revert if broken)
                  • _mint(LP, tickIdx, rWad)   → issue the ERC-6909 LP share
        unlock returns only once every delta == 0
```

`removeLiquidity` / `collect` run the mirror image: `take(..., claims=false)` sends real ERC-20 out of the PoolManager to the LP, the hook burns the matching claim tokens with `settle(..., claims=true)`, and the LP's shares are burned (or just the accrued fees are paid, for `collect`). Pausing the pool never blocks these — LPs can always exit.

---

## Runtime — one swap

A trader doesn't call `swap` directly. Any router calls `unlock`; the PoolManager calls back, the swap and settlement happen inside that locked frame, and no tokens move until the deltas net to zero.

```
caller.unlock(data)
└─ PoolManager unlocks, calls back ────────────────┐
   unlockCallback(data):                           │  runs inside the lock
     swap(poolKey, params)                         │
       ├─ beforeSwap → Orbital BeforeSwapDelta      │  (default x·y math bypassed)
       └─ records currency deltas (no tokens move) │
     settle()  ← trader pays input  (hook takes it as claim tokens)
     take()    ← trader pulls output (hook burns claim tokens to cover it)
└─ unlock returns ─────────────────────────────────┘
   PoolManager asserts every delta == 0  (else revert)
```

In `beforeSwap` the hook runs the Orbital engine, returns a `BeforeSwapDelta` that fully specifies the trade (so the PoolManager's default `x·y` math is bypassed), takes the trader's input as claim tokens, and burns claim tokens to release the output. Two invariants hold throughout: `swap` moves no tokens (it only writes deltas to transient storage), and `unlock` won't return until every currency delta nets to zero.

---

## Why it matters

- **No liquidity fragmentation.** Four stablecoins would normally need six separate pools, each with its own shallow depth. Here all six pairs share one book, so a USDC/FRAX trade draws on the same liquidity as USDC/USDT — one deep pool instead of six thin ones.
- **Capital efficiency via virtual reserves.** A tick removes the curve below its depeg bound, so a small amount of real capital behaves like a much larger reserve near peg — Uniswap v3's virtual liquidity, generalized to the N-sphere.
- **N coins, not 2.** One pool prices a whole basket of dollars off a single sphere — add a fifth or sixth stablecoin without standing up a new market.
- **Depeg isolation = impermanent-loss containment.** If one coin breaks peg, its tick exits to the boundary and the rest keep trading 1:1 — the bad coin doesn't drain the pool. This is the tail IL that wrecks flat stable LPs (a depeg dumps the whole pool into the broken coin); Orbital caps it by construction.
- **Automatic circuit-breaker.** A Reactive Network watcher pauses the pool the instant an external oracle reports a depeg — before the on-pool price even catches up (see below).
- **Built on v4, not beside it.** We only supply the curve; custody, accounting, and the unlock/settle flow are all v4's — so the pools are reachable by any v4 router or aggregator.

---

## Depeg circuit-breaker — Reactive Network

The pool already isolates a depegged coin *geometrically* — but it only "learns" of a depeg once trades have pushed its internal price there, which is exactly the window LPs bleed value. So we added an external, oracle-driven safety net using **[Reactive Network](https://reactive.network/)**.

```
 Origin chain                 Reactive Lasna                 Unichain Sepolia (1301)
 Chainlink feed   ──log──▶   OrbitalDepegReactive  ──callback──▶  OrbitalDepegCallback
 AnswerUpdated              price out of peg band?               └─▶ hook.guardianPause()
```

1. **`OrbitalDepegReactive`** (on Reactive Lasna) subscribes to a Chainlink feed's `AnswerUpdated` event for a constituent stablecoin. When the price leaves the peg band, it emits a cross-chain `Callback`.
2. The Reactive callback proxy on Unichain Sepolia invokes **`OrbitalDepegCallback`**, which is registered as the hook's **guardian** and calls `OrbitalHook.guardianPause()`.
3. The pool pauses — faster than any human or keeper. The breaker can **only pause** (a fail-safe); `unpause()` stays owner-only so a human reviews before liquidity resumes.

`reactive-lib` is kept *out* of the audited core: the only hook change is a `guardian` role. Contracts and a two-step deploy script live in [`orbitalHook/src/reactive/`](orbitalHook/src/reactive/README.md).

**Reactive infrastructure (testnet).** A testnet origin/destination must pair with the Reactive Lasna testnet — mainnets and testnets can't be mixed.

| Role | Chain | Address |
|---|---|---|
| Destination — callback proxy | Unichain Sepolia (1301) | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` |
| Reactive chain — system contract | Reactive Lasna (5318007) | `0x0000000000000000000000000000000000fffFfF` |
| [`OrbitalDepegCallback`](orbitalHook/src/reactive/OrbitalDepegCallback.sol) (destination receiver → `guardianPause`) | Unichain Sepolia (1301) | deploy via [`DeployReactive.s.sol`](orbitalHook/script/DeployReactive.s.sol)`:deployCallback` |
| [`OrbitalDepegReactive`](orbitalHook/src/reactive/OrbitalDepegReactive.sol) (watcher → emits `Callback`) | Reactive Lasna (5318007) | deploy via [`DeployReactive.s.sol`](orbitalHook/script/DeployReactive.s.sol)`:deployReactive` |

Reactive Lasna RPC: `https://lasna-rpc.rnk.dev/`. The two breaker contracts ship in the repo and deploy from the script above (one chosen Chainlink feed + a funded key).

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
├── orbitalHook/        Solidity — the v4 hook + Reactive depeg breaker (see orbitalHook/README.md)
│   └── src/reactive/   Reactive Network circuit-breaker contracts
└── frontend/           Next.js app — swap, pools, positions, sim (see frontend/README.md)
```

---

## Deployed — Unichain Sepolia (chainId 1301)

Uniswap v4 is canonically deployed on Unichain, so the hook plugs into the official `PoolManager`, `SwapRouter`, and `V4Quoter` instead of a self-hosted stack.

| Contract | Address |
|---|---|
| [OrbitalHook](orbitalHook/src/OrbitalHook.sol) | `0x405E3C4541077C501854082cf3256926BeF6AA88` |
| PoolManager (v4, canonical) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| V4Quoter (canonical) | `0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472` |
| SwapRouter (v4) | `0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540` |
| Permit2 (canonical) | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| USDC (mock) | `0x3f53c9ae1ae5D34D8A89986ea456da8e69916725` |
| USDT (mock) | `0x17684C1C522E7cCD9a38E1Ab5994BB294Bf1ef90` |
| DAI (mock) | `0x345581C18e6b15D02b303A4E7Cc2F0671591acbE` |
| FRAX (mock) | `0x1D49545CccDA551d5f5b2Ec95Fc53C34432016cF` |
| Admin / owner | `0xb29e1ddDfc73E00dEE3EaA7EA102990ADca78b39` |

Seeded with **~$24M TVL across 5 ticks**, all interior. Initial seed places 4 tiers at depeg bounds 0.95 / 0.90 / 0.85 / 0.80; the activity simulation adds a fifth tick after a balanced swap wave.

- Live app — <https://orbital-hook.vercel.app/>
- Hook explorer — <https://sepolia.uniscan.xyz/address/0x405E3C4541077C501854082cf3256926BeF6AA88>

---

## Getting started

```bash
# Contracts
cd orbitalHook
forge test                       # 121 passing

# Frontend
cd frontend
npm install && npm run dev       # http://localhost:3000
```

Foundry uses `via_ir = true` (required by the Orbital math libraries). Clone with `--recurse-submodules`, or run `git submodule update --init --recursive` afterwards.

---

## References

- Paradigm Orbital paper — <https://www.paradigm.xyz/2025/06/orbital>
- Uniswap v4 — <https://docs.uniswap.org/contracts/v4/overview>
- Reactive Network — <https://dev.reactive.network/>
- Our standalone Orbital AMM that shares the same engine: [`../contracts`](../contracts) (parent project)
