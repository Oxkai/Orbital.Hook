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

| | USDT→DAI | USDT→USDC | USDT→FRAX | DAI→USDC | DAI→FRAX | USDC→FRAX |
|---|---:|---:|---:|---:|---:|---:|
| price impact | 1.22 bps | 1.21 bps | 1.22 bps | 1.21 bps | 1.21 bps | 1.22 bps |

One basis point of that is the pool's own fee, so the curve costs about 0.2 bps on a
$100k trade — and it is the same on all six pairs, because they are one book.

Against the live Uniswap v3 USDC/USDT0 0.01% pool on Arbitrum, read tick by tick and
scaled to the same $5M, the curves are level: 0.00 bps at $10k and 0.05 bps at $100k
for v3, 0.02 and 0.22 for Orbital. The difference is coverage — matching six pairs at
this depth takes six v3 pools, so roughly six times the capital, and pairs like
DAI/FRAX have almost no v3 market at all.

---

## Status

v1, working end-to-end (205 tests) and live on Arbitrum Sepolia, Unichain Sepolia and Robinhood Chain testnet. Testnet release, not yet audited.

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

**Roadmap**
- [ ] TWAP oracle
- [ ] Native ETH support
- [ ] ERC-721 positions (transferable)
- [ ] Protocol fee
- [ ] External audit + hook-level fuzzing

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
├── DeployTestnet.s.sol      tokens → CREATE2-mined hook → 6 pools → ladder seed → settler
├── ReshapeLiquidity.s.sol   move a live pool onto the current ladder in place
├── DeployCrosschain.s.sol   settler only, against an existing hook
├── DeployQuoter.s.sol       V4Quoter where no canonical one exists
├── SimulateMultiLPLive.s.sol  seeded LPs, mixed swap sizes and exits on a LIVE pool
├── SimulateSwaps.s.sol      seeded retail swap flow on a LIVE pool, dollar-capped per trade
├── Lifecycle.s.sol          full LP lifecycle, asserts tick-slot recycling
├── CrosschainDemo.s.sol     open → fill → Hyperlane proof → settle
└── Simulate.s.sol · SimulateMultiLP.s.sol   local anvil equivalents
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

- **One contract, internal library code.** Engine logic is inlined as internal functions rather than a separate contract, no cross-contract overhead, and the deployed bytecode stays under the 24KB limit.
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
export V4_ROUTER=0xcD8D7e10A7aA794C389d56A07d85d63E28780220         # optional; required on Unichain

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

### Arbitrum Sepolia `421614`

| Contract | Address |
|---|---|
| OrbitalHook | [`0x6B92D109D09F5A78A9Af582136B5553409cc6a88`](https://sepolia.arbiscan.io/address/0x6B92D109D09F5A78A9Af582136B5553409cc6a88) |
| PoolManager (v4, canonical) | `0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317` |
| V4Quoter | `0xF0DB224d356dFF5cFF51D3d7295391bB2c9265FE` |
| V4Router | `0xcD8D7e10A7aA794C389d56A07d85d63E28780220` |
| OrbitalIntentSettler | `0xC82eAe0EF133b3488b5c9Cb416b6e1bCD3d9b30D` |
| USDC (mock, 6dp) | `0xD79658962eF717207C748d09e6c1c87D07857dE6` |
| USDT (mock, 6dp) | `0x11C10E5D13EAb8666cf1e24a341cAA6FfE89DdB8` |
| DAI (mock, 18dp) | `0xA7f648296EAb6290445D830FB16708766DBbEd8A` |
| FRAX (mock, 18dp) | `0x3de8bABB9DEf68999A57E4C641B580b1C2F88785` |

### Unichain Sepolia `1301`

Uniswap v4 is canonically deployed on Unichain, so the hook plugs into the official `PoolManager` and `V4Quoter`.

| Contract | Address |
|---|---|
| OrbitalHook | [`0x86D785bbABED2f192afAc0fF3979eC125b6c6a88`](https://sepolia.uniscan.xyz/address/0x86D785bbABED2f192afAc0fF3979eC125b6c6a88) |
| PoolManager (v4, canonical) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| V4Quoter (canonical) | `0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472` |
| V4Router | `0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540` |
| OrbitalIntentSettler | `0x11C10E5D13EAb8666cf1e24a341cAA6FfE89DdB8` |

### Robinhood Chain testnet `46630` (primary)

Uniswap v4 and the V4Router are already deployed here, so the hook plugs into them. There is no Hyperlane on this testnet, so no settler: the pool is same-chain only.

| Contract | Address |
|---|---|
| OrbitalHook | [`0x525184D68F7bCddE055b1DB5aC7279CFC72d2a88`](https://explorer.testnet.chain.robinhood.com/address/0x525184D68F7bCddE055b1DB5aC7279CFC72d2a88) |
| PoolManager (v4, canonical) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| V4Quoter (canonical) | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` |
| V4Router | `0x5911Ef6ABd9Cb84BFc78d78383d964c1e7ef12f2` |

Token addresses for Unichain and Robinhood are in [`deployments.json`](deployments.json). An earlier Base Sepolia deployment is retired; its settler is paused.

### Live state

Each pool holds its $5M ladder, all ticks interior (`kBound = 0`), with random retail swaps from five independent traders run on top by [`SimulateSwaps.s.sol`](script/SimulateSwaps.s.sol), each trade capped at $5,000:

| Pool | TVL | Ticks | Swaps | Volume | Largest swap |
|---|---|---|---|---|---|
| Arbitrum | ~$5.00M | 7 | 46 | ~$30.5k | $3,791.62 |
| Unichain | ~$5.00M | 7 | 25 | ~$14.8k | $1,591.96 |
| Robinhood | ~$5.00M | 7 | 25 | ~$28.1k | $4,923.45 |
