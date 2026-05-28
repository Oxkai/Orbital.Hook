# Orbital — X (Twitter) launch thread

Required tags: @XLayerOfficial, @Uniswap, @flapdotsh — in tweet 1 and tweet 7 so they land at submission. Every tweet is under 280 characters. No emojis. Declarative leads, no question/label format.

---

## Submission — one-line description & highlights

**One-line:** Orbital is an N-asset stableswap built as a Uniswap v4 hook — one pool that holds every stablecoin, with concentrated liquidity and automatic depeg isolation, live on X Layer testnet.

**What makes it stand out:**

- **We replace the swap curve itself, not bolt onto it.** Most AMMs price trades with x·y=k. Orbital instead places all reserves on an N-dimensional sphere and prices on that surface. We implemented the whole engine — the sphere invariant, per-LP "ticks", a torus that consolidates them, and a quartic solver — and run it inside the hook's `beforeSwap`, so the pool quotes on Orbital's curve while still using all of Uniswap v4's plumbing.

- **One pool holds every stablecoin — no fragmentation.** Normally four stablecoins need six separate pairwise pools, each shallow. Here every pair is just a view onto a single shared reserve vector inside one hook, so a USDC/FRAX trade draws on the exact same liquidity as USDC/USDT. Depth compounds instead of splitting.

- **Concentrated liquidity, generalized to N assets.** Like Uniswap v3, LPs concentrate capital where trading actually happens — but each LP also picks their own depeg tolerance (how far off $1 they'll keep providing). Concentrating near peg makes one dollar behave like ~154 in a flat pool.

- **Near-zero slippage at peg.** Because that depth piles up right around $1 where stablecoins trade, ordinary swaps barely move the price — roughly 1/154th the impact of a flat pool at p=0.99. Large trades stay tight too: the solver walks the full depth of the book, not just the first few basis points.

- **Automatic depeg isolation.** If a stablecoin loses its peg, its tick "exits" to the boundary and stops trading that coin, while the rest keep trading 1:1. The pool doesn't bleed into the bad asset — and it happens from the math itself, no admin action or pause needed.

- **Constant-time swaps at any size.** No matter how many coins or ticks exist, the pool tracks only a few running sums (the "torus" state in slot0), so a swap is O(1) on-chain — it never loops over every position. A full solver handles large trades that cross tick boundaries.

- **Built the way a real v4 protocol would be.** Token custody stays in Uniswap's PoolManager; LP positions are ERC-6909 claim tokens; deposits support Permit2; the owner can pause in an emergency (Ownable2Step + Pausable). 100 tests cover the engine end to end.

- **Live and usable today.** Deployed and seeded with ~$20M of test liquidity across 5 ticks on X Layer testnet, behind a full web app — swap, pools, positions, and a live liquidity-depth chart.

---

**1/ One pool for every stablecoin.**

Orbital is an N-asset stableswap — the full Paradigm Orbital paper, implemented as a @Uniswap v4 hook and live on @XLayerOfficial testnet.

USDC, USDT, DAI, FRAX, all in one shared sphere of liquidity.

Here's how it works.
@flapdotsh

---

**2/ Stablecoins force a tradeoff today.**

Curve pools many coins, but spreads liquidity thin. Uniswap v3 concentrates it, but only across 2 tokens.

So four stables means six shallow, fragmented pools.

Orbital removes the tradeoff: many coins, concentrated, one book.

---

**3/ The trick is geometry.**

Reserves sit on an N-dimensional sphere. Each LP picks a plane — their depeg bound — concentrating capital in the narrow band where stables actually trade.

Every tick folds into one torus, so swaps stay O(1) no matter how many coins or ticks.

---

**4/ Deep liquidity, isolated risk.**

- ~154x capital efficiency near peg vs a flat sphere
- One shared book — no fragmentation across pairs
- Depeg isolation: a broken coin's tick exits, the other N−1 keep trading 1:1
- Near-1:1 quotes at peg

Each LP sets their own depeg tolerance.

---

**5/ One hook replaces the curve.**

A single Uniswap v4 hook. beforeSwap runs the sphere/torus solver and returns the trade, fully replacing the constant-product curve.

v4's PoolManager holds custody. LP positions are ERC-6909 shares.

4 stables → 6 v4 pools → 1 shared sphere.

---

**6/ Live and seeded on X Layer.**

- X Layer Testnet (chainId 1952)
- ~$20M TVL across 5 ticks
- 100 tests passing
- Full tick-crossing solver, admin pause, Permit2 LP path

Try it: https://orbital-hook.vercel.app/

---

**7/ Swap, provide liquidity, watch the sphere move.**

Concentrated liquidity for the whole dollar basket — built on @Uniswap v4, live on @XLayerOfficial.

Built for @flapdotsh. Feedback welcome.

---

## Profile bio

Orbital — an N-asset stableswap built as a Uniswap v4 hook. Concentrated liquidity for the whole dollar basket, with depeg isolation. Live on X Layer testnet.
orbital-hook.vercel.app

---

## Short version (3 tweets)

**1/** Orbital: one pool for every stablecoin.

The full Paradigm Orbital paper, built as a @Uniswap v4 hook and live on @XLayerOfficial testnet. USDC, USDT, DAI, FRAX in one shared sphere — concentrated liquidity for N coins, not 2.
@flapdotsh

**2/** Reserves live on a sphere; each LP picks a depeg bound. Capital concentrates near peg, ticks fold into one torus, swaps stay O(1).

Result: ~154x efficiency near peg, no fragmentation, and depeg isolation when a coin breaks.

**3/** One v4 hook replaces the swap curve. PoolManager holds custody, LP positions are ERC-6909.

Live on X Layer: orbital-hook.vercel.app

---

## Standalone posts (space these out through the event)

**Launch day.** Orbital is live on @XLayerOfficial testnet. One pool, every stablecoin, concentrated liquidity — built as a @Uniswap v4 hook. Swap and provide liquidity now: orbital-hook.vercel.app

**One book, not six.** Four stablecoins normally fragment into six shallow pools. Orbital routes every pair through one shared sphere, so a USDC/FRAX trade taps the same depth as USDC/USDT.

**Depeg isolation, explained.** When a coin breaks peg, its tick exits to the boundary and is fenced off. No governance call, no pause — the geometry does it. The other N−1 stables keep trading 1:1.

**On capital efficiency.** Spreading liquidity flat across every price wastes most of it. Orbital stacks depth in the band where stables actually trade — roughly 154x more efficient near peg at N=5.

**Built on @Uniswap v4.** We don't fork — we hook. beforeSwap runs the Orbital sphere/torus solver and returns the trade, replacing the constant-product curve while v4 handles custody, settlement, and routing.

**By the numbers.** 100 tests passing. ~$20M TVL seeded across 5 ticks. Full tick-crossing solver, admin pause, and a Permit2 LP path. Live on @XLayerOfficial testnet.

**LP your way.** Every LP picks their own depeg tolerance per position — tight for max efficiency, wide as a volatility backstop. One pool, many risk profiles.

---

## Walkthrough thread (attach one screen per tweet)

Order of screens to attach: 1 swap, 2 pools, 3 pool depth, 4 add-liquidity range, 5 amount, 6 review, 7 positions. Tags in tweet 1 and the last tweet.

**1/ A quick walk through Orbital, live on @XLayerOfficial.**

Swap any two of four stablecoins from one shared pool — every pair routes through the same liquidity at near-1:1. If one depegs, the rest keep trading; the bad leg is fenced off.

Built as a @Uniswap v4 hook.
@flapdotsh

**2/ One pool holds every stablecoin.**

All four live in a single shared book, not separate pools. Each pair — USDC/USDT, DAI/FRAX, and the rest — is just a view onto the same reserves, so liquidity never fragments and depth compounds across the whole basket.

**3/ Liquidity sits where it's needed.**

It isn't spread flat across every price. Each LP's tick concentrates it in the tight band around the peg, where stablecoins actually trade — so the same capital quotes far deeper near $1 than a flat curve would.

**4/ Adding liquidity starts with your range.**

Pick a depeg threshold and your capital concentrates above it. Tighter earns more fees but its tick pauses sooner if a coin depegs; wider is a safer backstop. Every LP sets their own.

**5/ Then set your amount.**

The deposit splits across all four tokens at the current pool ratio, so you add balanced exposure to the whole basket in one step — no rebalancing across pairs, no idle legs.

**6/ Review and confirm.**

Check the full breakdown — tokens, your depeg threshold, fee tier, slippage — then confirm. It settles on-chain in one transaction as an ERC-6909 position the hook issues against your tick.

**7/ Manage it all from Positions.**

Every tick you hold is its own ERC-6909 share, earning fees independently. Increase, decrease, collect, or burn — each position on its own schedule.

Try it: orbital-hook.vercel.app
@Uniswap @XLayerOfficial @flapdotsh

---

## Core engine thread (sphere · ticks · torus)

For the technical audience. Formulas are plain unicode (Twitter doesn't render LaTeX). Tags in tweet 1 and the last tweet.

**1/ The core engine behind Orbital — in three shapes.**

A sphere for the reserves, a plane for every LP, and a torus that folds them into one O(1) swap. The full math from the Paradigm Orbital paper, implemented as a @Uniswap v4 hook.
@flapdotsh

**2/ Sphere.**

Reserves sit on an N-dimensional sphere: ‖r − x‖² = r².

All N coins share one surface. At the centre every pair trades exactly 1:1 — the curve only bends as the basket drifts off peg. The natural shape for a basket of dollars.

**3/ Ticks.**

Each LP picks a plane that slices the sphere at a depeg bound: k_min ≤ 1·x ≤ k_max.

Liquidity concentrates between that bound and the peg — capital sits in the band where stables actually trade, never idle on prices that never happen.

**4/ Torus.**

Summing ticks one by one would be costly. Instead they fold into a single torus: (α − r√n)² + (w − s)² = r_int².

The pool tracks just Σx and Σx² in slot0, so a swap stays O(1) no matter how many ticks or coins.

**5/ The solver.**

A swap walks that torus segment by segment — solving within each tick, crossing to the next when a bound is hit, flipping the tick interior↔boundary. Constant work per crossing, exact output, fully on-chain.

**6/ Why the geometry matters.**

This is what makes Orbital both multi-asset and concentrated at once: deep near-1:1 liquidity, high efficiency near peg, and depeg isolation — all from three pieces of geometry.

Live: orbital-hook.vercel.app
@Uniswap @XLayerOfficial @flapdotsh
