# Orbital Hook: the engine

A Uniswap v4 hook implementing the Orbital N-asset stableswap from [Paradigm (2025)](https://www.paradigm.xyz/2025/06/orbital).

The hook ([`src/OrbitalHook.sol`](src/OrbitalHook.sol)) holds the abstract Orbital state (the sphere reserve vector, the LP ticks, the fees) and replaces Uniswap's swap curve inside `beforeSwap`. Token custody stays in v4's `PoolManager`, the hook only holds matching ERC-6909 claim tokens. Each of the $\tfrac{N(N-1)}{2}$ pairs among the registered assets is a separate v4 pool, all pointing at this one hook and sharing one engine state.

[`src/fx/OrbitalFXHook.sol`](src/fx/OrbitalFXHook.sol) extends it into an FX pool: the same engine, with each non-dollar asset priced by a Chainlink `AggregatorV3` feed.

For the project overview and the frontend, see the [root README](../README.md).

---

## How the engine works

The hook keeps the pool as a point on an N-sphere and consolidates every LP tick into a single torus it can solve in O(1) per swap. A whole basket of stablecoins lives in one shared pool.

- **Sphere.** Reserves $\mathbf{x}$ satisfy $\|\mathbf{r} - \mathbf{x}\|^2 = r^2$, centred at $\mathbf{r} = (r, \dots, r)$. At the equal-price point $x_i = r\left(1 - \tfrac{1}{\sqrt{N}}\right)$ every coin trades 1:1; the curve only bends as the basket drifts off peg. ([`SphereMath.sol`](src/libraries/SphereMath.sol))
- **Ticks.** Each LP position is a plane $\sum_i x_i = k$ that cuts the sphere at a depeg bound, concentrated liquidity in the band near \$1. A tick stays *interior* while the pool holds above its bound and snaps to its *boundary* if price crosses it, so a depegging coin's tick exits without draining the rest. ([`TickLib.sol`](src/libraries/TickLib.sol))
- **Torus (`slot0`).** Instead of iterating ticks on every swap, the hook tracks five running sums, `sumX, sumXSq, rInt, kBound, sBound`, that fold all interior + boundary ticks into one torus. A swap reads and writes only these, so cost is independent of how many ticks or coins exist. ([`TorusMath.sol`](src/libraries/TorusMath.sol))
- **Segmenting solver.** `beforeSwap` walks the trade segment by segment: solve within the current tick configuration, cross the next tick that reaches its boundary (flip it interior↔boundary and update `slot0`), then continue until the input is consumed. The within-configuration solve is a safeguarded Newton method (`TorusMath.solveSwapBounded`): it keeps a sign bracket inside the domain, takes the analytic Newton step when that stays inside, bisects otherwise, and returns the pool-favourable end. The result is returned as a `BeforeSwapDelta`. ([`TorusMath.sol`](src/libraries/TorusMath.sol), [`QuadraticSolver.sol`](src/libraries/QuadraticSolver.sol), in [`OrbitalHook.sol`](src/OrbitalHook.sol))
- **The book never empties.** A trade is never allowed to cross the last interior tick; one that would reverts with `SwapExceedsLiquidity`, so the pool always keeps a live curve.

### Concentrated liquidity

A band's reserves below its floor $x_{min}$ can never be traded out, so they are **virtual**: the engine quotes on them, but the LP never deposits them.

- A mint deposits the tick's share of the reserves less its virtual part (`xMin` less a 1e-9 haircut). [`depositAmounts(k, r)`](src/OrbitalHook.sol) returns the exact amounts before any transaction.
- `reserves(i)` is the engine's full reserve; the tokens the pool actually holds are `reserves(i) − virtualReserve()`.
- A burn pays the burned share less its virtual part. A swap that would take an asset below the virtual floor reverts with `InsufficientRealReserves`.

The narrower the band, the larger its virtual part and the more depth each real dollar buys.

---

## Why it matters

- **No liquidity fragmentation.** A basket of stablecoins would normally need a separate pool per pair, each shallow. Here every pair is a view onto one shared reserve vector, so a USDC/FRAX trade taps the same depth as USDC/USDT.
- **Deep, shared liquidity.** All LP capital lands in one book instead of being split across pools, more depth behind every quote.
- **Capital efficiency via virtual reserves.** A tick removes the curve below its depeg bound, so a small amount of real capital behaves like a much larger reserve near peg (Uniswap v3's virtual-liquidity idea, generalized to the N-sphere).
- **Low slippage near peg.** Concentrating depth in the band where stablecoins actually trade keeps quotes close to 1:1 for ordinary size.
- **Depeg isolation.** When one coin breaks peg its tick snaps to the boundary and exits; the remaining coins keep trading 1:1 instead of the bad coin draining the pool.
- **O(1) regardless of scale.** The torus `slot0` means swap cost doesn't grow with the number of coins or ticks.

---

## Status

v1, working end-to-end (228 tests) and live on Unichain Sepolia, Arbitrum Sepolia and Arc testnet, including an FX pool on Arc. Testnet release, not yet audited.

**Engine**
- [x] Asset registry, N tokens per pool, sorted, unique, immutable
- [x] Decimal scaling for ≤18-decimal tokens (6dp USDC/USDT supported; >18 rejected), proven by a mixed-decimal solvency invariant rather than assumed
- [x] `beforeSwap` full segmenting solver (within-tick + tick crossings), safeguarded against overshoot
- [x] Concentrated liquidity: virtual reserves below each band's floor
- [x] Per-tick fee growth + per-position checkpoints (v3-style)
- [x] FX pool: Chainlink-priced assets, 50 bps oracle band, stale-feed protection

**Liquidity**
- [x] `addLiquidity`, `unlock` → settle N tokens → mint ERC-6909
- [x] `addLiquidityViaPermit2`, signature-based LP deposit
- [x] `removeLiquidity`, `unlock` → take N tokens → burn ERC-6909
- [x] `collect`, per-asset accrued fees
- [x] Soulbound LP shares (`transfer` / `transferFrom` revert)
- [x] Native v4 `modifyLiquidity` blocked by `beforeAddLiquidity` / `beforeRemoveLiquidity`

**Safety & ops**
- [x] Admin pause, Ownable2Step + Pausable
- [x] Deposit boundary enforced: a short transfer reverts with `TokenTransferShortfall`, so a fee-on-transfer or negatively-rebasing token fails closed instead of leaving claim tokens unbacked
- [x] Deploy + seed + simulation scripts; CREATE2-mined hook
- [x] Live and seeded on three chains, four pools

**Roadmap**
- [ ] Withdrawals while a tick sits at its boundary, via per-tick reserve attribution (today a position withdraws once its tick is interior again)
- [ ] TWAP oracle
- [ ] Native ETH support
- [ ] ERC-721 positions (transferable)
- [ ] Protocol fee
- [ ] External audit + hook-level fuzzing

---

## Build & test

```bash
forge build
forge test          # 228 tests across 18 suites
```

| Suite | What it proves |
|---|---|
| `Solvency.invariant.t.sol` | Stateful fuzz, **256 runs / 128k calls**, run twice: once all-18-decimal and once mixed 6/6/18. Custody always covers reserves plus accrued fees, and rounding only ever favours the pool. The all-18 profile leaves every raw↔WAD conversion a no-op, so it says nothing about the scaling layer; the mixed profile is the one that exercises it. |
| `MixedDecimalsLifecycle.t.sol` | Deterministic add → swap → collect → partial burn → full burn on a 6dp book, with every step asserted to *succeed*. Also asserts a fee-on-transfer token is refused at the deposit boundary with `TokenTransferShortfall`. |
| `OrbitalHook.t.sol` | 61 tests over the hook surface: constructor guards, permissions, LP entry, swaps, tick crossings, boundary behaviour, pause, ownership. |
| `VirtualLiquidity.t.sol` | Deposits equal share over capital efficiency, full range has no virtual part, the same capital concentrated is far deeper, burns return the deposit, partial burns keep the band. |
| `SolverRobustness.t.sol` | Large swaps up to the edge of the book: the solver converges, and a trade that would empty the book reverts cleanly. |
| `fx/` | `OrbitalFXHook.t.sol` (oracle band, staleness, pricing), `FXSolvency.invariant.t.sol`, a live-feed fork test, and `TestnetFxFeed.t.sol`. |
| `SphereMath` · `TorusMath` · `TickLib` · `QuadraticSolver` | Library units, including fuzzed solver residual and stability bounds. |
| `Benchmark.t.sol` | Slippage against depth, swap size and N. Not assertions, a console study. |

`via_ir = true` (solc 0.8.30) is required, the `TorusMath` library hits stack-too-deep without it. We implemented the complete Orbital math from the paper: the sphere invariant, tick planes, torus consolidation, and the segmenting solver.

---

## Project layout

```
src/
├── OrbitalHook.sol          one contract: storage + v4 hook + LP entry + engine
├── fx/
│   ├── OrbitalFXHook.sol    OrbitalHook + Chainlink-priced assets and swap guards
│   └── IAggregatorV3.sol    Chainlink's feed interface
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
├── fx/                            FX hook, FX solvency invariant, feed mirror
├── OrbitalIntentSettler.t.sol     ERC-7683 flow and proof authentication
├── CrosschainFork.t.sol           live Base + Arbitrum forks, forged-proof test
├── SphereMath.t.sol · TickLib.t.sol · TorusMath.t.sol
├── QuadraticSolver.t.sol          fuzzed solver residual / bounds / stability
└── Benchmark.t.sol                capital-efficiency / depth checks

script/
├── lib/TierLadder.sol       the liquidity ladder every deploy seeds
├── DeployTestnet.s.sol      tokens → CREATE2-mined hook → 6 pools → ladder seed → settler
├── DeployArc.s.sol          same on Arc, deploying the v4 core it lacks
├── DeployArcFX.s.sol        the FX pool: EUR tokens, feed or mirror, hook, seed
├── ReshapeLiquidity.s.sol   move a live pool onto the current ladder in place
├── fx/SyncFxFeed.s.sol      copy Chainlink EUR / USD onto the Arc testnet mirror
├── DeployCrosschain.s.sol   settler only, against an existing hook
├── DeployQuoter.s.sol       V4Quoter where no canonical one exists
├── SimulateMultiLPLive.s.sol  seeded LPs, mixed swap sizes and exits on a LIVE pool
├── SeedActivity.s.sol       swap waves + a mid-run re-seed
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
    IAllowanceTransfer permit2,  // canonical Permit2, for the signature LP path
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
addLiquidity(uint256 kWad, uint256 rWad, uint256[] maxAmounts)           // → tickIdx, mints ERC-6909
addLiquidityViaPermit2(uint256 kWad, uint256 rWad, uint256[] maxAmounts) // same, Permit2-funded
removeLiquidity(uint256 tickIdx, uint256 rWad, uint256[] minAmounts)     // burns ERC-6909
collect(uint256 tickIdx)                                                 // → per-asset fees
```

`tokenId = tickIdx`; the hook is the ERC-6909 issuer. Shares are soulbound in v1 (`transfer` / `transferFrom` revert). Per-position fee checkpoints live in engine storage keyed by `(owner, tickIdx)`.

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
export HYPERLANE_MAILBOX=0xDDcFEcF17586D08A5740B7D91735fcCE3dfe3eeD   # for the settler
export V4_ROUTER=0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540         # Unichain has no canonical one

forge script script/DeployTestnet.s.sol \
  --rpc-url unichain_sepolia --broadcast --slow \
  --private-key $PRIVATE_KEY
```

`DeployTestnet.s.sol` is chain-agnostic: it resolves the PoolManager and router by `chainId`, deploys four mock stables with a **realistic decimal mix** (USDC/USDT 6dp, DAI/FRAX 18dp), CREATE2-mines the hook address, initializes the 6 pair pools, seeds the liquidity ladder, and deploys the settler. `DeployArc.s.sol` does the same on Arc and `DeployArcFX.s.sol` deploys the FX pool.

### The liquidity ladder

Every deploy seeds [`TierLadder`](script/lib/TierLadder.sol): **$5M of real capital** (1.25M of each asset) over six concentrated bands plus a small full-range backstop. Each tier is given a share of the **depth**, tapering away from the peg, and the capital follows from it, so depth falls off gradually rather than piling into one band at $1.

| Profile | Band bounds | Depth weights |
|---|---|---|
| Stable | 0.999 · 0.997 · 0.995 · 0.99 · 0.98 · 0.95 · full range | 100 · 90 · 80 · 60 · 40 · 20 · 1 |
| FX | 0.995 · 0.99 · 0.98 · 0.97 · 0.95 · 0.90 · full range | 100 · 90 · 75 · 60 · 40 · 20 · 1 |

FX bands are wider because an FX pool's centre is fixed at deploy while the rate drifts. The full-range tier's boundary is reached only by draining an asset, so large trades still fill rather than revert. To move an existing pool onto the ladder without redeploying:

```bash
HOOK=<hook> PROFILE=STABLE forge script script/ReshapeLiquidity.s.sol \
  --rpc-url <rpc> --broadcast --slow --private-key $PRIVATE_KEY
```

### FX pool

`DeployArcFX.s.sol` deploys EURC and EURe (6dp), reuses the Arc stable pool's USDC and USDT, and wires each EUR asset to an EUR / USD `AggregatorV3` feed. Swap guards, all in [`OrbitalFXHook`](src/fx/OrbitalFXHook.sol):

| Guard | Behaviour |
|---|---|
| `FxPriceBeyondBand` | A trade may not move the marginal price more than `maxDeviationBps` (50) from the feed |
| `StalePrice` | Swaps pause when the feed is older than `maxPriceAge` (25h on a direct feed, 30h on the mirror) |
| `InvalidOraclePrice` | Swaps pause on a non-positive answer |

LP deposits and exits never read the oracle. On Arc testnet the pool reads Chainlink EUR / USD through a [`TestnetFxFeed`](script/mocks/TestnetFxFeed.sol) mirror of Chainlink EUR / USD on Ethereum mainnet; keep it fresh with:

```bash
forge script script/fx/SyncFxFeed.s.sol --rpc-url arc_testnet --broadcast --private-key $PRIVATE_KEY
```

---

## Design note: one tick per mint

A tick's band is encoded in `kNorm = k·WAD/r`, not in `k` alone: `_detectCrossing` tests `kNorm` against `alphaNorm`, and `kFromDepegPrice` returns a `k` proportional to `r`. Folding a new mint into an existing tick would add radius without the matching `k` and move the band away from the price the LP chose. So every mint gets its own tick ([`_findOrCreateTick`](src/OrbitalHook.sol)), with `k` and `r` from the same `kFromDepegPrice` call, and `kNorm` is exact by construction. Burned tick slots are recycled.

The [subgraph](../subgraph) and [`orbital-mcp`](../orbital-mcp) watch `kNorm` against `alphaNorm` for every tick, so any band that could never be reached is flagged on its first read.

**Trade-offs.** `MAX_TICKS` (128) bounds concurrent LP positions, and more than `MAX_CROSSINGS` (20) ticks sharing one `kNorm` cannot clear in a single swap: it reverts with `TooManyCrossings` and rolls back, and a router splits the trade. Both are pinned by tests:

| Test | What it pins |
|---|---|
| `test_sameDepeg_mints_preserve_kNorm` | mints at the same depeg keep their band |
| `test_duplicate_kNorm_ticks_all_cross` | 8 same-`kNorm` ticks all flip; the scan chains |
| `test_more_duplicates_than_MAX_CROSSINGS_reverts_cleanly` | reverts `TooManyCrossings`, state rolls back |
| `test_burned_tick_slot_is_reused_after_cap` | burns recycle slots via `_freeTickIndices` |

---

## Uniswap v4 integration points

Exact contracts and lines, for verification.

| What | Where |
|---|---|
| Hook contract (extends `BaseHook`) | [`src/OrbitalHook.sol:54`](src/OrbitalHook.sol#L54) |
| Permission bitmap (must match the mined address) | [`src/OrbitalHook.sol:323`](src/OrbitalHook.sol#L323) |
| `_beforeInitialize`: validates each `PoolKey` is a legal pair of registered assets | [`src/OrbitalHook.sol:346-350`](src/OrbitalHook.sol#L346-L350) |
| `_beforeAddLiquidity` / `_beforeRemoveLiquidity`: pool-level LP is blocked, liquidity goes to the engine | [`src/OrbitalHook.sol:352-368`](src/OrbitalHook.sol#L352-L368) |
| **`_beforeSwap`: the curve replacement.** Segment-walking solver, returns a `BeforeSwapDelta` | [`src/OrbitalHook.sol:370-452`](src/OrbitalHook.sol#L370-L452) |
| `toBeforeSwapDelta` return, where the engine's result becomes v4 accounting | [`src/OrbitalHook.sol:449`](src/OrbitalHook.sol#L449) |
| Segment walk across tick crossings | [`src/OrbitalHook.sol:516`](src/OrbitalHook.sol#L516) |
| Engine-level LP entry (ERC-6909 tick shares, not per-pool liquidity) | [`src/OrbitalHook.sol:786`](src/OrbitalHook.sol#L786) |
| Permit2 LP entry | [`src/OrbitalHook.sol:797`](src/OrbitalHook.sol#L797) |
| Safeguarded Newton solver within a tick configuration | [`src/libraries/TorusMath.sol:258`](src/libraries/TorusMath.sol#L258) |
| Crossing-point solver | [`src/libraries/QuadraticSolver.sol`](src/libraries/QuadraticSolver.sol) |
| FX swap guard (oracle band, staleness) | [`src/fx/OrbitalFXHook.sol:188`](src/fx/OrbitalFXHook.sol#L188) |
| Tick boundary maths (`kFromDepegPrice`, interior/boundary flips) | [`src/libraries/TickLib.sol`](src/libraries/TickLib.sol) |
| Hook address mining + pool registration | [`script/DeployTestnet.s.sol`](script/DeployTestnet.s.sol) |
| Arc deploy (v4 core deployed with the hook) | [`script/DeployArc.s.sol`](script/DeployArc.s.sol) |

Developer feedback on the Uniswap stack, as required by the track: [`FEEDBACK.md`](FEEDBACK.md).

---

## Deployed

Every address, per chain, is in [`deployments.json`](deployments.json). Owner of every hook: `0xb29e1ddDfc73E00dEE3EaA7EA102990ADca78b39`. Each hook's address is CREATE2-mined so its low bits encode its permission flags.

### Unichain Sepolia `1301`

Uniswap v4 is canonically deployed on Unichain, so the hook plugs into the official `PoolManager` and `V4Quoter`.

| Contract | Address |
|---|---|
| OrbitalHook | [`0xB9cD5ccF597e49F87C9c73eFABb5410195fE6A88`](https://sepolia.uniscan.xyz/address/0xB9cD5ccF597e49F87C9c73eFABb5410195fE6A88) |
| PoolManager (v4, canonical) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| V4Quoter (canonical) | `0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472` |
| V4Router | `0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540` |
| OrbitalIntentSettler | `0x905Ef8cb78aaDc33dC1de0f22471561f7d921E8A` |
| USDC (mock, 6dp) | `0xa2d96B6101231ea3DDBc056819834293e0c5849B` |
| USDT (mock, 6dp) | `0x5F134Ec4C77A71a6a7B008e951762bf26e763B6D` |
| DAI (mock, 18dp) | `0x8FE0995C389dF28f2aB910599Ff41E2F992d113f` |
| FRAX (mock, 18dp) | `0x530f64feE1F4DCBd2A7c725156f53DAa8f8191Db` |

### Arbitrum Sepolia `421614`

| Contract | Address |
|---|---|
| OrbitalHook | [`0x8e7BEf4320f73a39100C42325Fc426CBD1842a88`](https://sepolia.arbiscan.io/address/0x8e7BEf4320f73a39100C42325Fc426CBD1842a88) |
| PoolManager (v4, canonical) | `0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317` |
| V4Quoter | `0xF0DB224d356dFF5cFF51D3d7295391bB2c9265FE` |
| V4Router | `0xcD8D7e10A7aA794C389d56A07d85d63E28780220` |
| OrbitalIntentSettler | `0x050A876F5F4883ea17588077940c1E0dd4867D2B` |

### Arc Testnet `5042002`

The engine also runs on **[Circle's Arc](https://docs.arc.io) testnet**, where gas is paid in USDC. A stablecoin AMM on a stablecoin-native L1 is the same idea from both ends.

| Contract | Address |
|---|---|
| OrbitalHook (stable pool) | [`0x1D922FB97c92b00706A449ba78EEFc0D3E01aa88`](https://testnet.arcscan.app/address/0x1D922FB97c92b00706A449ba78EEFc0D3E01aa88) |
| **OrbitalFXHook** (USDC · USDT · EURC · EURe) | [`0xb7343fC8aA0Aaa583E3929B8De70D8e5751d2A88`](https://testnet.arcscan.app/address/0xb7343fC8aA0Aaa583E3929B8De70D8e5751d2A88) |
| EUR / USD feed (TestnetFxFeed mirror of Chainlink) | `0x8a4a34d41f3234215D20bb7472C9Cf2d71D3BD24` |
| EURC · EURe (mock, 6dp) | `0x2d59F25e42B396B25a9d4F474Ec1E230CEe02D82` · `0x09972c389552E02747336b87c557127fA0f6A385` |
| USDC · USDT (mock, 6dp, shared by both pools) | `0x18033E198A2b0af2AfA75aFcc520f42179955a68` · `0x7d1c2f283811A0aa7D538e3C859DA8BB45330e35` |
| PoolManager (v4, deployed with the hook) | `0x9BEACCac4e0358Cc276703dcE7341B9B9fEfd5f7` |
| V4Quoter (deployed with the hook) | `0x17684C1C522E7cCD9a38E1Ab5994BB294Bf1ef90` |
| V4Router (deployed with the hook) | `0xC30819b8ac12B5d12751b83cFfebD6F0bFa0b53E` |
| OrbitalIntentSettler | `0x71ac1F49f25a5f0Ad44e543fa4BB4e356d8252A0` |
| Mailbox (testnet; Hyperlane at mainnet) | `0x2896bc4b03610816eee4758c7a2e87a2724E2Dcb` |

**We brought Uniswap v4 to Arc testnet.** v4 is not deployed there yet, so `DeployArc` deploys the PoolManager, router and quoter alongside the hook. Arc **mainnet** (chain `5042`) has a canonical v4 at `0x8366a39cc670b4001a1121b8f6a443a643e40951`, and the same script plugs into it with no code change.

**Cross-chain on Arc arrives with mainnet.** Hyperlane runs on Arc mainnet, so on testnet the settler is deployed behind [`TestnetMailbox`](script/mocks/TestnetMailbox.sol), which emits dispatch events locally. The settler and its inbound authentication are the same contract as on the other chains; Arc trades same-chain on testnet while cross-chain orders run between Unichain and Arbitrum.

**Chainlink EUR / USD, relayed for testnet.** On testnet the FX pool reads Chainlink's rate relayed from Ethereum mainnet. Arc mainnet has Chainlink EUR / USD at `0xDd5B15443cd733D3966a50a3E48cB7DF9Fb5DE0D`, which `DeployArcFX` uses there by default. Re-running the Arc scripts on mainnet with `V4_POOL_MANAGER` and `HYPERLANE_MAILBOX` set gives a fully canonical deployment with no code changes.

### Live state

Each pool holds its $5M ladder plus independent LP positions, all ticks interior (`kBound = 0`):

| Pool | TVL | Ticks |
|---|---|---|
| Unichain | ~$5.70M | 13 |
| Arc stable | ~$5.25M | 13 |
| Arc FX | ~$5.79M | 14 |
| Arbitrum | ~$5.84M | 14 |
