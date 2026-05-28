# Orbital

An **N-asset stableswap** ([Paradigm Orbital, 2025](https://www.paradigm.xyz/2025/06/orbital)) implemented as a **Uniswap v4 hook** and deployed on **X Layer Testnet**, with a full web app.

Four stablecoins (USDC / USDT / DAI / FRAX) form six v4 pools, all bound to one `OrbitalHook` that holds a single shared sphere of reserves. Swaps run through the hook's `beforeSwap`; LPs deposit directly into the hook and hold ERC-6909 shares.

```
UHI/
├── orbitalHook/   Solidity — the v4 hook, math libraries, deploy + simulation scripts, tests
└── frontend/      Next.js app — swap, pools, positions, wired to the live hook
```

## Deployed — X Layer Testnet (chainId 1952)

| Contract | Address |
|---|---|
| **OrbitalHook** | `0x4024911A26B5BF5160D156eccBAc148bd55c6a88` |
| PoolManager (v4) | `0x9BEACCac4e0358Cc276703dcE7341B9B9fEfd5f7` |
| SwapRouter (v4) | `0xC30819b8ac12B5d12751b83cFfebD6F0bFa0b53E` |
| Quoter (v4) | `0x77442de670D723Db1Ae17fa9cA887c9426eBb41f` |
| Permit2 (canonical) | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| USDC | `0xBe272Bcb1Fa1d99616F53Ce7d7703589C92bb33b` |
| USDT | `0x3a2bCfc287b8106774Ec85533d821D3604cB7DC5` |
| DAI | `0x78340e3C5169b6DF15F13a8d627Db2C0e23cf921` |
| FRAX | `0x17c868495deF240091E95410e2B2D5a6cEabf6f0` |
| Admin / owner | `0xb29e1ddDfc73E00dEE3EaA7EA102990ADca78b39` |

Hook explorer: <https://www.okx.com/web3/explorer/xlayer-test/address/0x4024911A26B5BF5160D156eccBAc148bd55c6a88>
Seeded with ~$20M TVL across 5 ticks, all interior.

## Architecture

```
  Trader                                 Liquidity Provider
  swapExactTokensForTokens               addLiquidity / removeLiquidity
        │                                        │
        ▼                                        │ (direct to hook)
  v4 PoolManager.swap(poolKey)                   │
        │                                        ▼
        ▼                                ┌──────────────────────┐
  6 v4 pools  ─────────────────────────▶│      OrbitalHook     │
  USDC/USDT, USDC/DAI, USDC/FRAX,        │  one shared sphere   │
  USDT/DAI, USDT/FRAX, DAI/FRAX          │  beforeSwap · 6909   │
        (every PoolKey.hooks = hook)     └──────────┬───────────┘
                                                    │ settles through
                                                    ▼
                                          v4 PoolManager (custody)
```

- **One hook, many pools.** Every pair is a separate v4 `PoolKey` whose `hooks` field points at the same `OrbitalHook`. They all read and write one reserve vector (`slot0`), so prices stay coherent across pairs.
- **Token custody is the PoolManager's.** The hook never holds ERC-20s — it tracks the abstract sphere and mints ERC-6909 claim tokens against the manager, settling via the `unlock` flow.
- **LP positions are ERC-6909 shares** (`tokenId = tickIdx`), soulbound in v1.
- **One swap, at runtime:** `PoolManager.swap → unlock → beforeSwap → solve(sphere · torus) → BeforeSwapDelta → settle`.

See [orbitalHook/README.md](orbitalHook/README.md) for the engine internals (sphere / tick / torus math, fees, admin/pause).

## Status

- **orbitalHook** — v1, **100 tests passing**; deployed + seeded on X Layer testnet. Engine: LP add/remove, fee collect, v4 swap interception with the full tick-crossing solver, admin pause (Ownable2Step + Pausable), Permit2 LP path. Research artifact — **not audited**.
- **frontend** — live app wired to the X Layer hook (swap via V4Quoter + router, pools, positions). Deployable on Vercel — see [frontend/README.md](frontend/README.md).

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

## Deploy scripts (`orbitalHook/script`)

| Script | Does |
|---|---|
| `Deploy.s.sol` | Mock tokens → CREATE2-mined hook → 6 pools → deep tiered seed |
| `DeployPeriphery.s.sol` | v4 SwapRouter + Quoter against an existing PoolManager |
| `SeedActivity.s.sol` | Gentle swaps + re-seed to exercise the live pool near peg |

```bash
forge script script/Deploy.s.sol --rpc-url https://testrpc.xlayer.tech --broadcast --slow --private-key $PRIVATE_KEY
```

## References

- Paradigm Orbital paper — <https://www.paradigm.xyz/2025/06/orbital>
- Uniswap v4 — <https://docs.uniswap.org/contracts/v4/overview>
- Standalone Orbital AMM the hook ports from: [`../contracts`](../contracts) (parent project)
