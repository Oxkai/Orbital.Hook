# Orbital Hook — engine

A Uniswap v4 hook implementing the Orbital N-asset stableswap from [Paradigm (2025)](https://www.paradigm.xyz/2025/06/orbital).

The hook holds the abstract Orbital state (the sphere reserve vector, the LP ticks, the fees) and replaces Uniswap's swap curve inside `beforeSwap`. Token custody stays in v4's `PoolManager` — the hook only holds matching ERC-6909 claim tokens. Each of the $\tfrac{N(N-1)}{2}$ pairs among the registered assets is a separate v4 pool, all pointing at this one hook and sharing one engine state.

For the project overview and the frontend, see the [root README](../README.md).

---

## How the engine works

The hook keeps the pool as a point on an N-sphere and consolidates every LP tick into a single torus it can solve in O(1) per swap. It currently supports up to 5 tokens in one shared pool.

- **Sphere.** Reserves $\mathbf{x}$ satisfy $\|\mathbf{r} - \mathbf{x}\|^2 = r^2$, centred at $\mathbf{r} = (r, \dots, r)$. At the equal-price point $x_i = r\left(1 - \tfrac{1}{\sqrt{N}}\right)$ every coin trades 1:1; the curve only bends as the basket drifts off peg.
- **Ticks.** Each LP position is a plane $\sum_i x_i = k$ that cuts the sphere at a depeg bound — concentrated liquidity in the band near \$1. A tick stays *interior* while the pool holds above its bound and snaps to its *boundary* if price crosses it, so a depegging coin's tick exits without draining the rest.
- **Torus (`slot0`).** Instead of iterating ticks on every swap, the hook tracks five running sums — `sumX, sumXSq, rInt, kBound, sBound` — that fold all interior + boundary ticks into one torus. A swap reads and writes only these, so cost is independent of how many ticks or coins exist.
- **Segmenting solver.** `beforeSwap` walks the trade segment by segment: solve the within-tick quartic by Newton's method up to the next tick boundary, cross that tick (flip it interior↔boundary and update `slot0`), then continue until the input is consumed. The result is returned as a `BeforeSwapDelta`.

---

## Why it matters

- **No liquidity fragmentation.** Up to 5 stablecoins would normally need a separate pool per pair, each shallow. Here every pair is a view onto one shared reserve vector, so a USDC/FRAX trade taps the same depth as USDC/USDT.
- **Deep, shared liquidity.** All LP capital lands in one book instead of being split across pools — more depth behind every quote.
- **Capital efficiency via virtual reserves.** A tick removes the curve below its depeg bound, so a small amount of real capital behaves like a much larger reserve near peg (Uniswap v3's virtual-liquidity idea, generalized to the N-sphere).
- **Low slippage near peg.** Concentrating depth in the band where stablecoins actually trade keeps quotes close to 1:1 for ordinary size.
- **Depeg isolation.** When one coin breaks peg its tick snaps to the boundary and exits; the remaining coins keep trading 1:1 instead of the bad coin draining the pool.
- **O(1) regardless of scale.** The torus `slot0` means swap cost doesn't grow with the number of coins or ticks.

---

## Status

v1 — research artifact, not audited, not production. Working end-to-end (115 tests) and live on Unichain Sepolia.

**Engine**
- [x] Asset registry — up to 5 tokens per pool, sorted, unique, immutable
- [x] 18-decimal guard (`AssetNotEighteenDecimals` on registration)
- [x] `beforeSwap` full segmenting solver (within-tick + tick crossings)
- [x] Per-tick fee growth + per-position checkpoints (v3-style)

**Liquidity**
- [x] `addLiquidity` — `unlock` → settle N tokens → mint ERC-6909
- [x] `addLiquidityViaPermit2` — signature-based LP deposit
- [x] `removeLiquidity` — `unlock` → take N tokens → burn ERC-6909
- [x] `collect` — per-asset accrued fees
- [x] Soulbound LP shares (`transfer` / `transferFrom` revert)
- [x] Native v4 `modifyLiquidity` blocked by `beforeAddLiquidity` / `beforeRemoveLiquidity`

**Safety & ops**
- [x] Admin pause — Ownable2Step + Pausable
- [x] Deploy + seed + simulation scripts; CREATE2-mined hook
- [x] Live + seeded on Unichain Sepolia (115 tests passing)

**Deferred to v2**
- [ ] Decimal normalization for non-18-decimal tokens
- [ ] TWAP oracle
- [ ] Native ETH support
- [ ] ERC-721 positions (transferable)
- [ ] Protocol fee
- [ ] External audit + hook-level fuzzing

---

## Build & test

```bash
forge build
forge test          # 115 passing
```

`via_ir = true` (solc 0.8.30) is required — the `TorusMath` library hits stack-too-deep without it. We implemented the complete Orbital math from the paper — the sphere invariant, tick planes, torus consolidation, and the segmenting quartic solver. The same engine backs our standalone Orbital AMM in [`../../contracts/`](../../contracts/); this hook adapts it to the v4 surface.

---

## Project layout

```
src/
├── OrbitalHook.sol          one contract: storage + v4 hook + LP entry + engine
└── libraries/               math (shared with ../../contracts/src/lib/)
    ├── FullMath.sol         512-bit mulDiv — full-precision intermediate products
    ├── SphereMath.sol       sphere invariant, radius, equal-price point
    ├── TorusMath.sol        folds all ticks into the torus running sums
    ├── TickLib.sol          tick = depeg-bound plane; kFromDepegPrice, kMin/kMax
    └── PositionLib.sol      LP position struct + fee-checkpoint accounting

test/
├── OrbitalHook.t.sol        constructor / hooks / LP / swap / crossing / admin
├── SphereMath.t.sol
├── TickLib.t.sol
├── TorusMath.t.sol
└── Benchmark.t.sol          capital-efficiency / depth checks

script/
├── Deploy.s.sol             mock tokens → CREATE2-mined hook → 6 pools → tiered seed
├── DeployPeriphery.s.sol    v4 SwapRouter + Quoter against an existing PoolManager
└── SeedActivity.s.sol       exercises the live pool — swaps across pairs + adds a tick
```

---

## Hook permissions

The hook address is CREATE2-mined so its low bits encode these flags:

`beforeInitialize` · `beforeAddLiquidity` · `beforeRemoveLiquidity` · `beforeSwap` · `beforeSwapReturnDelta`

`beforeSwap` + `beforeSwapReturnDelta` is the pair that lets the hook return a `BeforeSwapDelta` that fully specifies the trade, so the PoolManager's default constant-product math is bypassed. The two `before*Liquidity` flags exist only to revert native v4 liquidity — the hook's own `addLiquidity` is the only LP path.

---

## Constructor

```solidity
constructor(
    IPoolManager poolManager,
    IAllowanceTransfer permit2,  // canonical Permit2, for the signature LP path
    Currency[] memory assets,    // up to 5 tokens, ascending by address, unique, all 18-decimal
    uint24 fee,                  // hundredths of a bip (e.g. 100 = 1 bp)
    address admin                // Ownable2Step owner; can pause/unpause
)
```

After deployment, each pair `(assets[i], assets[j])` is registered as a v4 pool via `PoolManager.initialize` with `PoolKey.hooks = address(orbitalHook)` and `PoolKey.lpFee = 0`. Non-18-decimal assets revert at construction.

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

- **One contract, internal library code.** Engine logic is inlined as internal functions rather than a separate contract — no cross-contract overhead, and the deployed bytecode stays under the 24KB limit.
- **PoolManager holds tokens, hook holds claim tokens.** The hook tracks the abstract reserve vector $\mathbf{x}$; real ERC-20s sit in `PoolManager`, and the hook holds matching ERC-6909 claim tokens. Settlement uses the OZ `CurrencySettler` helper inside `unlock`.
- **Pair-view model.** $\tfrac{N(N-1)}{2}$ separate v4 `PoolKey`s all point at this hook; price coherence is guaranteed because every `beforeSwap` reads and writes the single shared engine state.
- **Native v4 liquidity disabled.** `beforeAddLiquidity` / `beforeRemoveLiquidity` revert; the hook's own `addLiquidity` is the only entry.
- **`via_ir = true`** — `TorusMath` hits stack-too-deep without it.

---

## Deploy

```bash
forge script script/Deploy.s.sol \
  --rpc-url https://sepolia.unichain.org --broadcast --slow \
  --private-key $PRIVATE_KEY
```

`Deploy.s.sol` mines the hook address (`HookMiner` from `lib/uniswap-hooks`), deploys the four mock tokens, initializes the 6 pair pools, and seeds tiered liquidity across depeg bounds 0.95 / 0.90 / 0.85 / 0.80 (~$10M rInt). The deep, layered seed keeps quotes near 1:1 for ordinary flow, while the segmenting solver handles tick crossings when a swap is large enough to reach a boundary.

---

## Deployed — Unichain Sepolia (chainId 1301)

Uniswap v4 is canonically deployed on Unichain, so the hook plugs into the official `PoolManager`, `SwapRouter`, and `V4Quoter`.

| Contract | Address |
|---|---|
| OrbitalHook | [`0x405E3C4541077C501854082cf3256926BeF6AA88`](https://sepolia.uniscan.xyz/address/0x405E3C4541077C501854082cf3256926BeF6AA88) |
| PoolManager (v4, canonical) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| V4Quoter (canonical) | `0x56DcD40A3F2D466F48E7F48BdBe5cc9b92aE4472` |
| SwapRouter (v4) | `0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540` |
| Permit2 (canonical) | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| USDC (mock) | `0x3f53c9ae1ae5D34D8A89986ea456da8e69916725` |
| USDT (mock) | `0x17684C1C522E7cCD9a38E1Ab5994BB294Bf1ef90` |
| DAI (mock) | `0x345581C18e6b15D02b303A4E7Cc2F0671591acbE` |
| FRAX (mock) | `0x1D49545CccDA551d5f5b2Ec95Fc53C34432016cF` |
| Admin / owner | `0xb29e1ddDfc73E00dEE3EaA7EA102990ADca78b39` |

Four mock 18-decimal stablecoins → 6 pair pools registered against the hook → tiered seed across 4 tiers (depeg bounds 0.95 / 0.90 / 0.85 / 0.80, ~$10M rInt) → `SeedActivity` runs a swap wave and adds a 5th tick. Live state: **~$24M TVL across 5 ticks, all interior, kBound = 0**. The hook address suffix `...6AA88` encodes its permission flags (CREATE2-mined).
