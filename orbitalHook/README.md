# Orbital Hook

A Uniswap v4 hook implementing the **Orbital** N-asset stableswap from [Paradigm (2025)](https://www.paradigm.xyz/2025/06/orbital).

The hook holds the abstract Orbital state (sphere reserves, ticks, fees) and uses v4's `PoolManager` for token custody via ERC-6909 claim tokens. Each of the `N(N-1)/2` pairs among the registered assets is exposed as a separate v4 pool, all sharing one engine state.

## Status

**v1 — research artifact, not production.** Working end-to-end in tests; not safe to deploy with real money. See the deployment-readiness notes at the bottom of this file.

| Path | Implemented |
|---|---|
| Asset registry (N∈[2,5], sorted, immutable) | ✅ |
| `addLiquidity` via `unlock` → settle N tokens → mint ERC-6909 | ✅ |
| `removeLiquidity` via `unlock` → take N tokens → burn ERC-6909 | ✅ |
| `collect` (per-asset accrued fees) | ✅ |
| `beforeSwap` with full segmenting solver (within-tick + crossings) | ✅ |
| Native v4 `modifyLiquidity` reverted by `beforeAddLiquidity` | ✅ |
| Per-tick fee growth + per-position checkpoints (v3-style) | ✅ |
| Deployment scripts (CREATE2 hook-address mining, multi-pool init) | ❌ deferred |
| Decimal normalization (non-18-decimal tokens) | ❌ deferred |
| TWAP oracle, native ETH, ERC-721 positions, protocol fee | ❌ deferred (v2) |

## Build & test

```bash
forge build
forge test
```

82 tests across 5 suites. The math libraries are direct copies of the standalone Orbital AMM in [contracts/](../../contracts/) (same project root); the engine logic is a port of `OrbitalPool.sol` adapted to the v4 hook surface.

## Project layout

```
src/
├── OrbitalHook.sol          one contract: storage + v4 hook + LP entry + engine
└── libraries/               math (copied from ../../contracts/src/lib/)
    ├── FullMath.sol
    ├── SphereMath.sol
    ├── TorusMath.sol
    ├── TickLib.sol
    └── PositionLib.sol

test/
├── OrbitalHook.t.sol        constructor / hooks / LP / swap / crossing
├── SphereMath.t.sol         ported from ../../contracts/test/
├── TickLib.t.sol            ported from ../../contracts/test/
└── TorusMath.t.sol          ported from ../../contracts/test/
```

## Key design decisions

- **One contract, internal library code.** Engine logic is inlined as internal functions rather than a separate contract, avoiding cross-contract overhead while keeping the deployed contract under the 24KB limit (current size leaves comfortable headroom).
- **PoolManager holds tokens, hook holds claim tokens.** The hook tracks the abstract reserve vector `x⃗`; real ERC-20s sit in `PoolManager`, and the hook holds matching ERC-6909 claim tokens against them. Settlement uses the OZ `CurrencySettler` helper.
- **LP shares as ERC-6909.** `tokenId = tickIdx`, hook is the issuer. Per-position fee checkpoints stay in engine storage keyed by `(owner, tickIdx)`.
- **Pair-view model.** `N(N-1)/2` separate v4 PoolKeys all point at this hook; price coherence is guaranteed because every `beforeSwap` reads/writes the single shared engine state.
- **Native v4 liquidity disabled.** `beforeAddLiquidity` / `beforeRemoveLiquidity` revert; the hook's own `addLiquidity` is the only LP path.
- **`via_ir = true`** in `foundry.toml` — the standalone math library `TorusMath` hits stack-too-deep without it.

## Constructor

```solidity
constructor(
    IPoolManager poolManager,
    Currency[] memory assets,   // length 2..5, ascending by address, unique
    uint24 fee                  // hundredths of a bip (e.g. 100 = 1 bp)
)
```

After deployment, each pair `(assets[i], assets[j])` must be registered as a v4 pool via `PoolManager.initialize` with `PoolKey.hooks = address(orbitalHook)` and `PoolKey.lpFee = 0`. v1 assumes every registered asset is 18-decimal.

## Deployment readiness

**Not ready for any deployment yet.** To deploy to testnet:

1. Write a `script/00_DeployHook.s.sol` that CREATE2-mines a hook address with the right flag suffix (`BEFORE_INITIALIZE | BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY`). `HookMiner` from `lib/uniswap-hooks` handles this.
2. Write a pool-initialization script that calls `PoolManager.initialize` for every pair.

To deploy to mainnet, additionally: external audit, decimal-normalization layer, fuzz tests at the hook level, gas profiling, root-cause the open Newton-solver edge case in the 2-tick crossing scenario, an emergency-pause mechanism, and an oracle if downstream integrations need one.
