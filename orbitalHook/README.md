# Orbital Hook: the engine

A Uniswap v4 hook implementing the Orbital N-asset stableswap from [Paradigm (2025)](https://www.paradigm.xyz/2025/06/orbital).

The hook ([`src/OrbitalHook.sol`](src/OrbitalHook.sol)) holds the abstract Orbital state (the sphere reserve vector, the LP ticks, the fees) and replaces Uniswap's swap curve inside `beforeSwap`. Token custody stays in v4's `PoolManager`, the hook only holds matching ERC-6909 claim tokens. Each of the $\tfrac{N(N-1)}{2}$ pairs among the registered assets is a separate v4 pool, all pointing at this one hook and sharing one engine state.

For the project overview and the frontend, see the [root README](../README.md).

---

## How the engine works

The hook keeps the pool as a point on an N-sphere and consolidates every LP tick into a single torus it can solve in O(1) per swap. A whole basket of stablecoins lives in one shared pool.

- **Sphere.** Reserves $\mathbf{x}$ satisfy $\|\mathbf{r} - \mathbf{x}\|^2 = r^2$, centred at $\mathbf{r} = (r, \dots, r)$. At the equal-price point $x_i = r\left(1 - \tfrac{1}{\sqrt{N}}\right)$ every coin trades 1:1; the curve only bends as the basket drifts off peg. ([`SphereMath.sol`](src/libraries/SphereMath.sol))
- **Ticks.** Each tick is a plane $\sum_i x_i = k$ that cuts the sphere at a depeg bound, concentrated liquidity in the band near \$1. A tick stays *interior* while the pool holds above its bound and snaps to its *boundary* if price crosses it, so a depegging coin's tick exits without draining the rest. Ticks come from a fixed menu of 31 bands, from \$0.9999 down to \$0.50 plus full range, and every position in a band shares that band's one tick. ([`TickLib.sol`](src/libraries/TickLib.sol), [`BandLib.sol`](src/libraries/BandLib.sol))
- **Torus (`slot0`).** Instead of iterating ticks on every swap, the hook tracks five running sums, `sumX, sumXSq, rInt, kBound, sBound`, that fold all interior + boundary ticks into one torus. A swap reads and writes only these, so cost is independent of how many ticks or coins exist. ([`TorusMath.sol`](src/libraries/TorusMath.sol))
- **Segmenting solver.** `beforeSwap` walks the trade segment by segment: solve within the current tick configuration, cross the next tick that reaches its boundary (flip it interior↔boundary and update `slot0`), then continue until the input is consumed. The within-configuration solve is a safeguarded Newton method (`TorusMath.solveSwapBounded`): it keeps a sign bracket inside the domain, takes the analytic Newton step when that stays inside, bisects otherwise, and returns the pool-favourable end. The result is returned as a `BeforeSwapDelta`. ([`TorusMath.sol`](src/libraries/TorusMath.sol), [`QuadraticSolver.sol`](src/libraries/QuadraticSolver.sol), in [`OrbitalHook.sol`](src/OrbitalHook.sol))
- **Either side of the trade.** v4 lets a swap fix what it pays or what it receives. `beforeSwap` serves both: an exact-output swap runs the same segment walk with the solve turned around, `TorusMath.solveSwapInputBounded` finding the input a wanted output costs. Routers and quoters that work by output — how a UI asks for "100 USDC" — use the pool like any other v4 pool.
- **The book never empties.** A trade is never allowed to cross the last interior tick; one that would reverts with `SwapExceedsLiquidity`, so the pool always keeps a live curve.
- **No trade past zero price.** Past the point where the pool values the input asset at zero, the surface still has solutions, but each pays *less* than stopping there would. A trade that would end past it reverts with `SwapBeyondZeroPrice` rather than filling for less.

### Concentrated liquidity

A band's reserves below its floor $x_{min}$ can never be traded out, so they are **virtual**: the engine quotes on them, but the LP never deposits them.

- A mint deposits the tick's share of the reserves less its virtual part (`xMin` less a 1e-9 haircut). [`depositAmounts(band, r)`](src/OrbitalHook.sol) returns the exact amounts before any transaction.
- `reserves(i)` is the engine's full reserve; the tokens the pool actually holds are `reserves(i) − virtualReserve()`.
- A burn pays the burned share less its virtual part. A swap that would take an asset below the virtual floor reverts with `InsufficientRealReserves`.
- Deposits and withdrawals keep working during a depeg. New liquidity joins the interior at its exact consolidated share (paper §4.10). A pinned tick is paid its own boundary holding, $k/\sqrt{N} + s\,w_i/\lVert w\rVert$ (§4.11), and an interior tick is paid its share of what remains.

The narrower the band, the larger its virtual part and the more depth each real dollar buys.

### When an issuer freezes a token

Every stablecoin on the pool's menu can be stopped by its issuer: paused outright (Paxos USDG, Circle USDC), or with one address frozen (Circle's blacklist, Tether's blocklist). A withdrawal pays out every asset, so with an all-or-nothing payout one frozen token would revert every withdrawal and fee collection in the pool, for everyone, healthy coins included.

Instead each asset is paid on its own ([`_payOrDefer`](src/OrbitalHook.sol)). If a token cannot be transferred, that payout is held for the recipient in `owed(account, asset)`, backed by claim tokens the hook keeps outside `reserves`, so no swap can spend them. The other assets are paid as usual, and `claimOwed(asset)` pays the held amount once the token moves again. A pause, a frozen LP and a frozen PoolManager are each covered in [`IssuerFreeze.t.sol`](test/IssuerFreeze.t.sol), and the solvency fuzz freezes assets at random mid-sequence.

---

## Why it matters

- **No liquidity fragmentation.** A basket of stablecoins would normally need a separate pool per pair, each shallow. Here every pair is a view onto one shared reserve vector, so a USDC/FRAX trade taps the same depth as USDC/USDT.
- **Deep, shared liquidity.** All LP capital lands in one book instead of being split across pools, more depth behind every quote.
- **Capital efficiency via virtual reserves.** A tick removes the curve below its depeg bound, so a small amount of real capital behaves like a much larger reserve near peg (Uniswap v3's virtual-liquidity idea, generalized to the N-sphere).
- **Low slippage near peg.** Concentrating depth in the band where stablecoins actually trade keeps quotes close to 1:1 for ordinary size.
- **Depeg isolation.** When one coin breaks peg its tick snaps to the boundary and exits; the remaining coins keep trading 1:1 instead of the bad coin draining the pool.
- **O(1) regardless of scale.** The torus `slot0` means swap cost doesn't grow with the number of coins or ticks.

### Measured on the live pool

Quoting $100k on every pair of the deployed 4-asset book, $5M of real capital:

| | USDC→USDT | USDC→DAI | USDC→FRAX | USDT→DAI | USDT→FRAX | DAI→FRAX |
|---|---:|---:|---:|---:|---:|---:|
| all-in cost | 1.21 bps | 1.22 bps | 1.22 bps | 1.23 bps | 1.23 bps | 1.22 bps |

One basis point of that is the pool's own fee, so the curve itself costs about 0.22 bps
on a $100k trade, and within 0.02 bps of that on every pair, because they are one book.

Calibrated against the live Uniswap v3 USDC/USDT0 0.01% pool on Arbitrum, read tick by
tick and scaled to the same $5M, Orbital quotes within a fifth of a basis point of it on
a single pair — and holds that on all six at once. Matching this depth pairwise would
take six v3 pools and roughly six times the capital, and pairs like DAI/FRAX have almost
no v3 market at all.

---

## Status

v1, working end-to-end (205 tests) and live on Robinhood Chain testnet, Arbitrum Sepolia, Base Sepolia and Ethereum Sepolia.

**Engine**
- [x] Asset registry, N tokens per pool, sorted, unique, immutable
- [x] Decimal scaling for ≤18-decimal tokens (6dp USDC/USDT supported; >18 rejected), proven by a mixed-decimal solvency invariant rather than assumed
- [x] `beforeSwap` full segmenting solver (within-tick + tick crossings), safeguarded against overshoot
- [x] Both halves of the v4 swap interface: exact input and exact output, same segment walk
- [x] Concentrated liquidity: virtual reserves below each band's floor
- [x] Per-tick fee growth + per-position checkpoints (v3-style)

**Liquidity**
- [x] `addLiquidity`, `unlock` → settle N tokens → mint the band's share
- [x] `removeLiquidity`, `unlock` → take N tokens → burn the share
- [x] Deposits **and** withdrawals work mid-depeg: a pinned band is paid its own boundary holding (paper §4.11), an interior one its share of the rest
- [x] `collect`, per-asset accrued fees
- [x] Soulbound LP shares; deposits into one band merge into one position
- [x] Every LP call takes a `deadline`
- [x] Native v4 `modifyLiquidity` blocked by `beforeAddLiquidity` / `beforeRemoveLiquidity`

**Safety & ops**
- [x] Admin pause, Ownable2Step + Pausable
- [x] Deposit boundary enforced: a short transfer reverts with `TokenTransferShortfall`, so a fee-on-transfer or negatively-rebasing token fails closed instead of leaving claim tokens unbacked
- [x] An issuer pausing or freezing one stablecoin cannot lock the pool: the other assets still pay out and the stuck one is held for its owner, claimable later
- [x] Deploy + seed + simulation scripts; CREATE2-mined hook
- [x] Live and seeded on three chains, six pair-views over one book on each

---

## Build & test

```bash
forge build
forge test          # 205 tests across 18 suites
```

| Suite | What it proves |
|---|---|
| `Solvency.invariant.t.sol` | Stateful fuzz, **256 runs / 128k calls**, run twice: once all-18-decimal and once mixed 6/6/18. Assets are frozen and unfrozen at random mid-sequence. Custody always covers reserves plus accrued fees plus held payouts, rounding only ever favours the pool, and the band maps always match the liquidity. The all-18 profile leaves every raw↔WAD conversion a no-op, so it says nothing about the scaling layer; the mixed profile is the one that exercises it. |
| `MixedDecimalsLifecycle.t.sol` | Deterministic add → swap → collect → partial burn → full burn on a 6dp book, with every step asserted to *succeed*. Also asserts a fee-on-transfer token is refused at the deposit boundary with `TokenTransferShortfall`. |
| `OrbitalHook.t.sol` | 67 tests over the hook surface: constructor guards, permissions, bands and deadlines, LP entry and exit during a depeg, swaps, tick crossings, boundary behaviour, pause, ownership. |
| `IssuerFreeze.t.sol` | A paused token, a frozen LP and a frozen PoolManager: withdrawals and fee collection still pay every other asset, and the frozen one is held and claimable. |
| `VirtualLiquidity.t.sol` | Deposits equal share over capital efficiency, full range has no virtual part, the same capital concentrated is far deeper, burns return the deposit, partial burns keep the band. |
| `SolverRobustness.t.sol` | Large swaps up to the edge of the book: the solver converges, and a trade that would empty the book reverts cleanly. |
| `SphereMath` · `TorusMath` · `TickLib` · `QuadraticSolver` | Library units, including fuzzed solver residual and stability bounds. |
| `Benchmark.t.sol` | Slippage against depth, swap size and N. Not assertions, a console study. |

`via_ir = true` (solc 0.8.30) is required, the `TorusMath` library hits stack-too-deep without it. We implemented the complete Orbital math from the paper: the sphere invariant, tick planes, torus consolidation, and the segmenting solver.

---

## Project layout

```
src/
├── OrbitalHook.sol          one contract: storage + v4 hook + LP entry + engine
├── libraries/               the Orbital math
│   ├── FullMath.sol         512-bit mulDiv, full-precision intermediate products
│   ├── SphereMath.sol       sphere invariant, radius, equal-price point
│   ├── TorusMath.sol        folds all ticks into the torus running sums
│   ├── TickLib.sol          tick = depeg-bound plane; kFromDepegPrice, kMin/kMax
│   ├── QuadraticSolver.sol  smallest non-negative root for tick crossings
│   └── PositionLib.sol      LP position struct + fee-checkpoint accounting
└── crosschain/              cross-chain settlement
    ├── IERC7683.sol         the cross-chain intents standard, verbatim
    ├── IHyperlane.sol       Mailbox + IMessageRecipient
    └── OrbitalIntentSettler.sol   escrow, Orbital-routed fill, proof settlement

test/
├── OrbitalHook.t.sol              constructor / hooks / LP / swap / crossing / admin
├── Solvency.invariant.t.sol       stateful fuzz, two decimal profiles, 128k calls
├── MixedDecimalsLifecycle.t.sol   6dp lifecycle + fee-on-transfer rejection
├── VirtualLiquidity.t.sol         concentrated deposits, depth, withdrawals
├── SolverRobustness.t.sol         swaps to the edge of the book
├── OrbitalIntentSettler.t.sol     ERC-7683 flow and proof authentication
├── CrosschainFork.t.sol           live Base + Arbitrum forks, forged-proof test
├── SphereMath.t.sol · TickLib.t.sol · TorusMath.t.sol
├── QuadraticSolver.t.sol          fuzzed solver residual / bounds / stability
└── Benchmark.t.sol                capital-efficiency / depth checks

script/
├── lib/TierLadder.sol       the liquidity ladder every deploy seeds
├── lib/Create2Factory.sol   CREATE2 deployer for chains without the canonical one
├── DeployTestnet.s.sol      tokens → CREATE2-mined hook → 6 pools → ladder seed → settler
├── ReshapeLiquidity.s.sol   move a live pool onto the current ladder in place
├── DeployCrosschain.s.sol   settler only, against an existing hook
├── DeployQuoter.s.sol       V4Quoter where no canonical one exists
├── SimulateSwaps.s.sol      seeded retail swap flow on a LIVE pool, dollar-capped per trade
├── CrosschainDemo.s.sol     open → fill → Hyperlane proof → settle
└── DeployV4Core.s.sol       PoolManager + router, for chains with no canonical v4
```

---

## Hook permissions

The hook address is CREATE2-mined so its low bits encode these flags:

`beforeInitialize` · `beforeAddLiquidity` · `beforeRemoveLiquidity` · `beforeSwap` · `beforeSwapReturnDelta`

`beforeSwap` + `beforeSwapReturnDelta` is the pair that lets the hook return a `BeforeSwapDelta` that fully specifies the trade, so the PoolManager's default constant-product math is bypassed. The two `before*Liquidity` flags exist only to revert native v4 liquidity, the hook's own `addLiquidity` is the only LP path.

---

## Constructor

```solidity
constructor(
    IPoolManager poolManager,
    Currency[] memory assets,    // N tokens, ascending by address, unique, ≤ 18 decimals
    uint24 fee,                  // hundredths of a bip (e.g. 100 = 1 bp)
    address admin                // Ownable2Step owner; can pause/unpause
)
```

After deployment, each pair `(assets[i], assets[j])` is registered as a v4 pool via `PoolManager.initialize` with `PoolKey.hooks = address(orbitalHook)` and `PoolKey.lpFee = 0`. Tokens with fewer than 18 decimals (e.g. 6dp USDC) are scaled to WAD internally; assets with more than 18 decimals revert at construction.

---

## LP interface

LPs call the hook directly (not the PoolManager):

```solidity
addLiquidity(uint256 band, uint256 rWad, uint256[] maxAmounts, uint256 deadline)           // → band, mints ERC-6909
removeLiquidity(uint256 band, uint256 rWad, uint256[] minAmounts, uint256 deadline)        // burns ERC-6909
collect(uint256 band)                                                                      // → per-asset fees
claimOwed(uint8 asset)                                                                     // → a payout held for a frozen token
depositAmounts(uint256 band, uint256 rWad)                                                 // view: exact deposit
```

`band` indexes the menu in [`BandLib`](src/libraries/BandLib.sol), and `bandKNorm(band)` exposes the plane constant it derives on-chain. `tokenId = band`, so every deposit an owner makes into one band is one position.

Shares are **soulbound**: `transfer`, `transferFrom`, `approve` and `setOperator` all revert, because fee checkpoints and contributed radius are keyed by the minter and a share that moved without them could neither burn nor collect. The ledger is therefore [`SoulboundShares`](src/SoulboundShares.sol) — ERC-6909's balance mapping and `Transfer` event, without the allowance and operator machinery that no call can ever reach. Per-position fee checkpoints live in engine storage keyed by `(owner, band)`. Each LP call takes a `deadline` and is refused once it has passed.

---

## Key design decisions

- **One contract on the swap path.** Engine logic is inlined as internal functions, so a swap never leaves the hook. `TickLib`'s band geometry, which runs only at deploy and on LP actions, is a deployed library, which keeps the hook under the 24KB limit at no cost to swap gas.
- **PoolManager holds tokens, hook holds claim tokens.** The hook tracks the abstract reserve vector $\mathbf{x}$; real ERC-20s sit in `PoolManager`, and the hook holds matching ERC-6909 claim tokens. Settlement uses the OZ `CurrencySettler` helper inside `unlock`.
- **Pair-view model.** $\tfrac{N(N-1)}{2}$ separate v4 `PoolKey`s all point at this hook; price coherence is guaranteed because every `beforeSwap` reads and writes the single shared engine state.
- **Native v4 liquidity disabled.** `beforeAddLiquidity` / `beforeRemoveLiquidity` revert; the hook's own `addLiquidity` is the only entry.
- **`via_ir = true`**, `TorusMath` hits stack-too-deep without it.

---

## Cross-chain extension

Optional, and not required to use the pool. [`src/crosschain/OrbitalIntentSettler.sol`](src/crosschain/OrbitalIntentSettler.sol) implements [ERC-7683](https://eips.ethereum.org/EIPS/eip-7683) so an order opened on one chain can be filled on another.

- **The fill routes through this hook.** A filler supplying a different stable than the order asks for gets converted in one hop through the local Orbital book. Because every asset shares one book, a filler needs inventory in only one asset per chain rather than all N.
- **Settlement is an authenticated Hyperlane message.** The origin releases escrow only when its Mailbox delivers a message whose `(domain, sender)` matches a registered peer. No arbiter, no bond, no dispute game. `handle` is idempotent, so redelivery cannot double-pay.
- **Liveness.** If the proof never arrives the user reclaims the escrow after `fillDeadline + refundBuffer`.

---

## Deploy

```bash
export HYPERLANE_MAILBOX=0x598facE78a4302f11E3de0bee1894Da0b2Cb71F8   # this chain's Mailbox, for the settler
export V4_ROUTER=0xcD8D7e10A7aA794C389d56A07d85d63E28780220         # optional; only where hookmate has no entry

forge script script/DeployTestnet.s.sol \
  --rpc-url arbitrum_sepolia --broadcast --slow \
  --private-key $PRIVATE_KEY
```

`DeployTestnet.s.sol` is chain-agnostic: it resolves the PoolManager and router by `chainId`, deploys four mock stables with a **realistic decimal mix** (USDC/USDT 6dp, DAI/FRAX 18dp), CREATE2-mines the hook address, initializes the 6 pair pools, seeds the liquidity ladder, and deploys the settler.

[`TickLib`](src/libraries/TickLib.sol) is a deployed library rather than an inlined one — its band geometry runs at deploy and on LP actions, never inside a swap, so keeping it out of the hook costs no swap gas and leaves the hook comfortably under the 24 KB limit. Forge deploys and links it before mining the hook address; no extra step.

`HYPERLANE_MAILBOX` is optional: leave it unset on a chain without Hyperlane (Robinhood Chain testnet) and the script skips the settler, so the pool is same-chain only. Where hookmate has no entry for the chain, pass `V4_POOL_MANAGER` as well.

Once every chain is deployed, register each settler with the others (the owner calls `setPeer(chainId, hyperlaneDomain, bytes32(settler))` once per remote chain):

```bash
cast send <settler> "setPeer(uint256,uint32,bytes32)" <remoteChainId> <remoteDomain> <remoteSettlerAsBytes32> \
  --rpc-url <rpc> --private-key $PRIVATE_KEY
```

### The liquidity ladder

Every deploy seeds [`TierLadder`](script/lib/TierLadder.sol): **$5M of real capital** (1.25M of each asset). Its shape is measured rather than chosen. It follows how LPs in the live Uniswap v3 USDC/USDT0 0.01% pool on Arbitrum One place their capital, read tick by tick on-chain. The distances are measured from the **peg**, which is what a band's bound measures: 66% of the capital sits within 5 bps of $1 and 87% within 10 bps. It adds a small tail so very large trades degrade gradually instead of hitting a wall.

| Band | 0.9999 | 0.9998 | 0.9995 | 0.999 | 0.998 | 0.995 | 0.99 | full range |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Capital | 11% | 12% | 41% | 20% | 9% | 2% | 2% | 3% |

The shape is what makes the depth competitive: replayed against real Arbitrum trades ([`script/realworld`](script/realworld)), a pool seeded this way quotes within a basis point of the live Uniswap v3 USDC/USDT0 pool holding the same capital — and does it on all six pairs at once. To move an existing pool onto the ladder without redeploying:

```bash
HOOK=<hook> forge script script/ReshapeLiquidity.s.sol \
  --rpc-url <rpc> --broadcast --slow --private-key $PRIVATE_KEY
```

---

## Design note: a fixed menu of bands

A tick's band is encoded in `kNorm = k·WAD/r`, and `_detectCrossing` tests `kNorm` against `alphaNorm`. With `k` chosen freely, every position would be a distinct tick. Ticks are a shared, bounded resource, because the swap path scans them and each distinct boundary the price passes costs a crossing. So a free choice would let anyone fill every tick with dust, or stack crossings to stall trades, for almost nothing.

The hook instead offers a fixed menu of 31 bands ([`BandLib`](src/libraries/BandLib.sol)), tightest first so `kNorm` ascends with the index. Each band's `kNorm` is computed once at construction (`bandKNorm`). A deposit joins its band's tick, and the tick's `k` is always `bandKNorm · r`, so merging positions can never move the band's boundary. This bounds the number of distinct ticks by construction:

- There are no slots to exhaust. Dust in every band still leaves every band open to everyone.
- A band crosses once however many positions share it.
- A band emptied by burns comes back to life on the next deposit, with a fresh fee history.

The [subgraph](../subgraph) watches `kNorm` against `alphaNorm` for every live band.

**Crossing detection is one read.** Which side of its plane each band is on lives in two 31-bit maps sharing one storage slot, one for interior bands and one for pinned. The next band a trade can cross is the lowest set interior bit (price rising) or the highest set pinned bit (falling). Scanning the bands instead cost one cold storage read per band, up to 31 per swap. The maps are the only record of a band's side, and the solvency fuzz checks them against the liquidity after every call. Swaps toward the peg dropped from about 225k to 166k gas.

**Fees follow the segment.** A swap's fee is split across its segments in proportion to each segment's input. Each segment's share goes to the ticks interior for that segment, and sub-wei remainders carry over between swaps. A tight band that crosses out early in a large trade earns only on the part it provided.

**Bounded by construction.** A swap crossing more than `MAX_CROSSINGS` (20) distinct bands reverts with `TooManyCrossings` and rolls back cleanly, which caps the worst-case gas a single swap can cost; a router splits such a trade and each part persists. Crossing is judged at each segment's ends, following the paper's rule that a tick is interior iff `kNorm > alphaNorm`. All pinned by tests:

| Test | What it pins |
|---|---|
| `test_addLiquidity_secondMint_same_band_merges` | a second deposit in a band grows the same position |
| `test_band_merges_keep_the_band_boundary` | merged positions keep the band's exact `kNorm` |
| `test_dust_in_every_band_cannot_block_new_lps` | dust in all 31 bands leaves every band open |
| `test_many_positions_in_one_band_cross_as_one_tick` | many LPs in one band cross in one event |
| `test_more_distinct_bands_than_MAX_CROSSINGS_reverts_cleanly` | 25 distinct bands revert `TooManyCrossings`, state rolls back |
| `test_boundary_tick_recovers_when_price_returns` | a pinned band comes back at peg |
| `test_mint_after_full_burn_revives_the_band` | an emptied band takes new liquidity |
| `test_mint_during_depeg_joins_the_interior_exactly` | a depeg-time deposit round-trips within wei |
| `test_burn_during_depeg_pays_each_tick_its_own_holding` | depeg-time exits sum to the real reserves |
| `test_swap_cannot_sell_past_zero_price` | trades stop at the input's zero-price point |
| `test_pinned_band_burned_out_leaves_no_stale_bit` | an emptied pinned band leaves no trace in the band maps |

---

## Uniswap v4 integration points

Exact contracts and lines, for verification.

| What | Where |
|---|---|
| Hook contract (extends `BaseHook`) | [`src/OrbitalHook.sol:64`](src/OrbitalHook.sol#L64) |
| Permission bitmap (must match the mined address) | [`src/OrbitalHook.sol:433`](src/OrbitalHook.sol#L433) |
| `_beforeInitialize`: validates each `PoolKey` is a legal pair of registered assets | [`src/OrbitalHook.sol:456-466`](src/OrbitalHook.sol#L456-L466) |
| `_beforeAddLiquidity` / `_beforeRemoveLiquidity`: pool-level LP is blocked, liquidity goes to the engine | [`src/OrbitalHook.sol:468-484`](src/OrbitalHook.sol#L468-L484) |
| **`_beforeSwap`: the curve replacement.** Segment-walking solver, exact input or exact output, returns a `BeforeSwapDelta` | [`src/OrbitalHook.sol:486-616`](src/OrbitalHook.sol#L486-L616) |
| `toBeforeSwapDelta` return, where the engine's result becomes v4 accounting | [`src/OrbitalHook.sol:613`](src/OrbitalHook.sol#L613) |
| Segment walk across tick crossings | [`src/OrbitalHook.sol:672`](src/OrbitalHook.sol#L672) |
| Engine-level LP entry (soulbound band shares, not per-pool liquidity) | [`src/OrbitalHook.sol:1097`](src/OrbitalHook.sol#L1097) |
| Safeguarded Newton solver, shared by both swap directions | [`src/libraries/TorusMath.sol:282`](src/libraries/TorusMath.sol#L282) |
| Crossing-point solver | [`src/libraries/QuadraticSolver.sol`](src/libraries/QuadraticSolver.sol) |
| Tick boundary maths (`kFromDepegPrice`, interior/boundary flips) | [`src/libraries/TickLib.sol`](src/libraries/TickLib.sol) |
| Hook address mining + pool registration | [`script/DeployTestnet.s.sol`](script/DeployTestnet.s.sol) |

Developer feedback on the Uniswap stack, as required by the track: [`FEEDBACK.md`](FEEDBACK.md).

---

## Deployed

Every address, per chain, is in [`deployments.json`](deployments.json). Owner of every hook: `0xb29e1ddDfc73E00dEE3EaA7EA102990ADca78b39`. Each hook's address is CREATE2-mined so its low bits encode its permission flags.

### Robinhood Chain testnet `46630` (primary)

Uniswap v4 and the V4Router are already deployed here, so the hook plugs into them.

| Contract | Address |
|---|---|
| OrbitalHook | [`0xe2cE434ABB1F2a939fA017f69CD5f7c19c36Aa88`](https://explorer.testnet.chain.robinhood.com/address/0xe2cE434ABB1F2a939fA017f69CD5f7c19c36Aa88) |
| PoolManager (v4, canonical) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| V4Quoter | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` |
| V4Router | `0x5911Ef6ABd9Cb84BFc78d78383d964c1e7ef12f2` |
| USDT (mock, 6dp) | `0x0a29619e8580d90b14200a734faad4677e9d1645` |
| USDC (mock, 6dp) | `0x2f7a2dc7d74645a31cabb5466219ccab70913377` |
| DAI (mock, 18dp) | `0x45dc287a307eccf7426cb2377ee2865457592fae` |
| FRAX (mock, 18dp) | `0xc79a946a0a8661cde0cc02a34d387c5b4ccab0e4` |

### Arbitrum Sepolia `421614`

Uniswap v4 is canonically deployed here, so the hook plugs into the official `PoolManager`.

| Contract | Address |
|---|---|
| OrbitalHook | [`0x3F09f9eCf71Cf78f346Eb2683D4a295D00e82A88`](https://sepolia.arbiscan.io/address/0x3F09f9eCf71Cf78f346Eb2683D4a295D00e82A88) |
| PoolManager (v4, canonical) | `0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317` |
| V4Quoter | `0xF0DB224d356dFF5cFF51D3d7295391bB2c9265FE` |
| V4Router | `0xcD8D7e10A7aA794C389d56A07d85d63E28780220` |
| FRAX (mock, 18dp) | `0x15aabbc1c571147f05b5f9d37690ca6843dee044` |
| USDC (mock, 6dp) | `0x36b5bc5998f1aae8754697e60314b8c5b6d435ff` |
| USDT (mock, 6dp) | `0x47936d9fa0bf4eee6f44ff6308cfe59a3f80913d` |
| DAI (mock, 18dp) | `0xc4fdb067adff5bc0d10886598ddc00fb432f9794` |

### Base Sepolia `84532`

Uniswap v4 is canonically deployed here; the V4Quoter is ours, deployed by `DeployQuoter.s.sol`.

| Contract | Address |
|---|---|
| OrbitalHook | [`0xa1685261278e44C12921a0f213daDfBF9Beb6A88`](https://sepolia.basescan.org/address/0xa1685261278e44C12921a0f213daDfBF9Beb6A88) |
| PoolManager (v4, canonical) | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| V4Quoter | `0xE584726a93f37177219F72b4BA76DE7fFA851664` |
| V4Router | `0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9` |
| USDC (mock, 6dp) | `0x2822852629b4ed8420da072cb40318cf1318537f` |
| USDT (mock, 6dp) | `0x8119fc1a13e2a69735de1c9a38d6ffa0c94e986d` |
| DAI (mock, 18dp) | `0x92d06018f07cea34f09a2aa2c8bcc47a6ade59b4` |
| FRAX (mock, 18dp) | `0xe6de3e3be032e391786754c824c5800ca010c54f` |

### Ethereum Sepolia `11155111`

Uniswap v4 is canonically deployed here; the V4Quoter is ours, deployed by `DeployQuoter.s.sol`.

| Contract | Address |
|---|---|
| OrbitalHook | [`0xd92022CB51f49D61261321836A7a7b2e1A332a88`](https://sepolia.etherscan.io/address/0xd92022CB51f49D61261321836A7a7b2e1A332a88) |
| PoolManager (v4, canonical) | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| V4Quoter | `0x58D48990408b4ba45dE08679de3921EbD6fA71b7` |
| V4Router | `0xf13D190e9117920c703d79B5F33732e10049b115` |
| FRAX (mock, 18dp) | `0x51fb24e0e855e8709a017f3acc69ec6aa42cf8d6` |
| USDT (mock, 6dp) | `0x7cd4e073fd118f2f1197c1c1aa450dd410ebdeef` |
| USDC (mock, 6dp) | `0xd289f244ac5fb4e372bea5f92f07fa6960ca4307` |
| DAI (mock, 18dp) | `0xf2dc831ee8e1400ce58f8c27427025cb91ec64cd` |
An earlier set of deployments on these chains, plus Unichain Sepolia, is retired; those carried the ERC-7683 settlers, which these same-chain pools do not.

### Live state

Each pool holds its $5M ladder across 8 seeded ticks, all interior (`kBound = 0`), with random retail
swap flow run on top by [`SimulateSwaps.s.sol`](script/SimulateSwaps.s.sol) interleaved across the four
chains by [`mixed-swaps.sh`](script/mixed-swaps.sh), each trade capped at $5,000:

| Pool | TVL | Seeded ticks | All interior |
|---|---|---|---|
| Robinhood | ~$5.00M | 8 | yes |
| Arbitrum | ~$5.00M | 8 | yes |
| Base | ~$5.00M | 8 | yes |
| Ethereum | ~$5.00M | 8 | yes |

Read live off each chain, not recorded by hand: `slot0()`, `virtualReserve()` and `ticks(band)`.

