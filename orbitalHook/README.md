# Orbital Hook: the engine

A Uniswap v4 hook implementing the Orbital N-asset stableswap from [Paradigm (2025)](https://www.paradigm.xyz/2025/06/orbital).

The hook ([`src/OrbitalHook.sol`](src/OrbitalHook.sol)) holds the abstract Orbital state (the sphere reserve vector, the LP ticks, the fees) and replaces Uniswap's swap curve inside `beforeSwap`. Token custody stays in v4's `PoolManager`, the hook only holds matching ERC-6909 claim tokens. Each of the $\tfrac{N(N-1)}{2}$ pairs among the registered assets is a separate v4 pool, all pointing at this one hook and sharing one engine state.

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

v1, working end-to-end (179 tests) and live on Arbitrum Sepolia, Unichain Sepolia and Base Sepolia. Testnet release, not yet audited.

**Engine**
- [x] Asset registry, N tokens per pool, sorted, unique, immutable
- [x] Decimal scaling for ≤18-decimal tokens (6dp USDC/USDT supported; >18 rejected), proven by a mixed-decimal solvency invariant rather than assumed
- [x] `beforeSwap` full segmenting solver (within-tick + tick crossings), safeguarded against overshoot
- [x] Concentrated liquidity: virtual reserves below each band's floor
- [x] Per-tick fee growth + per-position checkpoints (v3-style)

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
forge test          # 179 tests across 14 suites
```

| Suite | What it proves |
|---|---|
| `Solvency.invariant.t.sol` | Stateful fuzz, **256 runs / 128k calls**, run twice: once all-18-decimal and once mixed 6/6/18. Custody always covers reserves plus accrued fees, and rounding only ever favours the pool. The all-18 profile leaves every raw↔WAD conversion a no-op, so it says nothing about the scaling layer; the mixed profile is the one that exercises it. |
| `MixedDecimalsLifecycle.t.sol` | Deterministic add → swap → collect → partial burn → full burn on a 6dp book, with every step asserted to *succeed*. Also asserts a fee-on-transfer token is refused at the deposit boundary with `TokenTransferShortfall`. |
| `OrbitalHook.t.sol` | 61 tests over the hook surface: constructor guards, permissions, LP entry, swaps, tick crossings, boundary behaviour, pause, ownership. |
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
export HYPERLANE_MAILBOX=0x598facE78a4302f11E3de0bee1894Da0b2Cb71F8   # this chain's Mailbox, for the settler
export V4_ROUTER=0xcD8D7e10A7aA794C389d56A07d85d63E28780220         # optional; required on Unichain

forge script script/DeployTestnet.s.sol \
  --rpc-url arbitrum_sepolia --broadcast --slow \
  --private-key $PRIVATE_KEY
```

`DeployTestnet.s.sol` is chain-agnostic: it resolves the PoolManager and router by `chainId`, deploys four mock stables with a **realistic decimal mix** (USDC/USDT 6dp, DAI/FRAX 18dp), CREATE2-mines the hook address, initializes the 6 pair pools, seeds the liquidity ladder, and deploys the settler.

Once every chain is deployed, register each settler with the others (the owner calls `setPeer(chainId, hyperlaneDomain, bytes32(settler))` once per remote chain):

```bash
cast send <settler> "setPeer(uint256,uint32,bytes32)" <remoteChainId> <remoteDomain> <remoteSettlerAsBytes32> \
  --rpc-url <rpc> --private-key $PRIVATE_KEY
```

### The liquidity ladder

Every deploy seeds [`TierLadder`](script/lib/TierLadder.sol): **$5M of real capital** (1.25M of each asset) over six concentrated bands plus a small full-range backstop. Each tier is given a share of the **depth**, tapering away from the peg, and the capital follows from it, so depth falls off gradually rather than piling into one band at $1.

| Band bounds | Depth weights |
|---|---|
| 0.999 · 0.997 · 0.995 · 0.99 · 0.98 · 0.95 · full range | 100 · 90 · 80 · 60 · 40 · 20 · 1 |

The full-range tier's boundary is reached only by draining an asset, so large trades still fill rather than revert. To move an existing pool onto the ladder without redeploying:

```bash
HOOK=<hook> forge script script/ReshapeLiquidity.s.sol \
  --rpc-url <rpc> --broadcast --slow --private-key $PRIVATE_KEY
```

---

## Design note: one tick per mint

A tick's band is encoded in `kNorm = k·WAD/r`, not in `k` alone: `_detectCrossing` tests `kNorm` against `alphaNorm`, and `kFromDepegPrice` returns a `k` proportional to `r`. Folding a new mint into an existing tick would add radius without the matching `k` and move the band away from the price the LP chose. So every mint gets its own tick ([`_findOrCreateTick`](src/OrbitalHook.sol)), with `k` and `r` from the same `kFromDepegPrice` call, and `kNorm` is exact by construction. Burned tick slots are recycled.

The [subgraph](../subgraph) watches `kNorm` against `alphaNorm` for every tick, so any band that could never be reached is flagged on its first read.

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
| Tick boundary maths (`kFromDepegPrice`, interior/boundary flips) | [`src/libraries/TickLib.sol`](src/libraries/TickLib.sol) |
| Hook address mining + pool registration | [`script/DeployTestnet.s.sol`](script/DeployTestnet.s.sol) |

Developer feedback on the Uniswap stack, as required by the track: [`FEEDBACK.md`](FEEDBACK.md).

---

## Deployed

Every address, per chain, is in [`deployments.json`](deployments.json). Owner of every hook: `0xb29e1ddDfc73E00dEE3EaA7EA102990ADca78b39`. Each hook's address is CREATE2-mined so its low bits encode its permission flags.

### Arbitrum Sepolia `421614` (primary)

| Contract | Address |
|---|---|
| OrbitalHook | [`0xdEE6773E69611CfA1395Dc47cDd4Cca6E36CaA88`](https://sepolia.arbiscan.io/address/0xdEE6773E69611CfA1395Dc47cDd4Cca6E36CaA88) |
| PoolManager (v4, canonical) | `0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317` |
| V4Quoter | `0xF0DB224d356dFF5cFF51D3d7295391bB2c9265FE` |
| V4Router | `0xcD8D7e10A7aA794C389d56A07d85d63E28780220` |
| OrbitalIntentSettler | `0x3104462820D7D721cc7139400016B27cb137D74b` |
| USDC (mock, 6dp) | `0xe22D8b0FfC1b3e94ecD8bb92724f8cC4eeba8f17` |
| USDT (mock, 6dp) | `0xC6c82FD06055346886F50A5a3B028dE9e8ad1e87` |
| DAI (mock, 18dp) | `0xB563e0914e80c7D8d726F3fAb12ac2dD8e315cF2` |
| FRAX (mock, 18dp) | `0x0B44Ab88312EEAa545D9e27EE5Ea8DaD90a6bF9E` |

### Unichain Sepolia `1301`

Uniswap v4 is canonically deployed on Unichain, so the hook plugs into the official `PoolManager` and `V4Quoter`.

| Contract | Address |
|---|---|
| OrbitalHook | [`0x2ad0767A51fD05c2d150f0f60eE436a52bF76a88`](https://sepolia.uniscan.xyz/address/0x2ad0767A51fD05c2d150f0f60eE436a52bF76a88) |
| PoolManager (v4, canonical) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| V4Quoter (canonical) | `0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472` |
| V4Router | `0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540` |
| OrbitalIntentSettler | `0x0d20A58a3Ac0D017DFB093dBF3Bd3D843E285784` |

### Base Sepolia `84532`

| Contract | Address |
|---|---|
| OrbitalHook | [`0xe63d5c2F15284BD6DDcFa0BD31C16c1B8F986a88`](https://sepolia.basescan.org/address/0xe63d5c2F15284BD6DDcFa0BD31C16c1B8F986a88) |
| PoolManager (v4, canonical) | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| V4Quoter | `0xDeCedb2746DE9c0793BcEBa7E2eDA044d9Cd4891` |
| V4Router | `0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9` |
| OrbitalIntentSettler | `0x30BA254a542879d8d89ae1BB7e36cfb59D342cb5` |

Token addresses for Unichain and Base are in [`deployments.json`](deployments.json).

### Live state

Each pool holds its $5M ladder, all ticks interior (`kBound = 0`), with random retail swaps from five independent traders run on top by [`SimulateSwaps.s.sol`](script/SimulateSwaps.s.sol), each trade capped at $5,000:

| Pool | TVL | Ticks | Swaps | Volume | Largest swap |
|---|---|---|---|---|---|
| Arbitrum | ~$5.00M | 7 | 46 | ~$30.5k | $3,791.62 |
| Unichain | ~$5.00M | 7 | 25 | ~$14.8k | $1,591.96 |
| Base | ~$5.00M | 7 | 25 | ~$28.3k | $4,269.29 |
