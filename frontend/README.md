# Orbital · Frontend

The web app for **Orbital**, an N-asset stableswap built as a **Uniswap v4 hook**. Swap, provide liquidity and inspect the live pools on **Arbitrum Sepolia** (primary), **Unichain Sepolia** and **Base Sepolia**.

**Live → https://orbital-hook.vercel.app/**

Contracts live in [`../orbitalHook`](../orbitalHook). The pools the app talks to are registered in [`lib/crosschain.ts`](lib/crosschain.ts), generated from `orbitalHook/deployments.json`.

## What's in the app

| Page | What it does |
|---|---|
| **Swap** | Quotes every pool that holds both tokens and routes to the best one; a token on another chain turns the widget into an ERC-7683 cross-chain order between any two of Arbitrum, Unichain and Base. |
| **Pools** | One row per pool: assets, network, address, 24h volume and TVL. |
| **Pool detail** | Reserves, liquidity depth by price, key metrics and transaction history. |
| **Add liquidity** | Pick a depeg band and an amount; the hook's own `depositAmounts` quote sizes the position exactly. |
| **Positions** | Every ERC-6909 position across all pools at its real value: increase, decrease, collect fees, withdraw. |
| **Transactions** | Swaps, deposits, withdrawals and fee claims across all pools, with type filters. |

TVL and position values are the tokens a pool actually holds, excluding the virtual floor concentrated bands quote on.

## Stack

| Layer | Choice |
|---|---|
| Framework | Next.js 16 (App Router) |
| UI | React 19 |
| Chain | wagmi 3 + viem 2, TanStack Query 5 |
| Styling | Tailwind CSS 4 + design tokens in `constants/` |
| Charts / math | Recharts 3 · KaTeX |

## Run locally

```bash
cp .env.example .env.local   # optional, see below
npm install
npm run dev      # http://localhost:3000
npm run build
npm run lint
```

Connect a wallet on any of the three chains; the app prompts a network switch when an action needs a different one.

## Environment

All optional. Without them the app uses public endpoints.

| Var | Purpose |
|---|---|
| `NEXT_PUBLIC_RPC_URL` | Unichain Sepolia RPC. Defaults to `https://sepolia.unichain.org`. |
| `NEXT_PUBLIC_SUBGRAPH_ARBITRUM` · `_UNICHAIN` · `_BASE` | Override the Subgraph Studio endpoints in [`lib/subgraph.ts`](lib/subgraph.ts). |

## Where the data comes from

- **Pool state and quotes** are read on-chain through each chain's transport in [`lib/wagmi.ts`](lib/wagmi.ts).
- **Activity and 24h volume** come from the subgraph, one query per chain. The app checks that each subgraph matches the chain's live hook and is current, and otherwise reads the hook's logs directly from the chain, so what it shows is always up to date.

## Deploy on Vercel

1. Import the repo into Vercel and set **Root Directory** to `frontend`.
2. The Next.js preset is detected (and pinned in `vercel.json`).
3. Add any of the environment variables above.
4. Deploy.

## Structure

```
app/
  page.tsx                  landing page
  app/                      the dApp
    swap/                   swap widget and venue routing
    pools/  pool/[address]/ pool list, pool detail, add liquidity
    positions/              LP positions
    transactions/           activity across every pool
components/
  home/                     landing sections
  app/                      swap, pools, pool, lp, positions, transactions, shared
lib/
  crosschain.ts             pool and token registry, per chain and per pool
  poolErrors.ts             human explanations for a pool's revert reasons
  contracts.ts              hook ABIs and token metadata
  subgraph.ts               Studio endpoints, freshness guard, activity and volume
  wagmi.ts                  chains and transports
  hooks/                    usePool · usePositions · useDepositQuote · usePoolVolume24h ·
                            useTransactions · useTokenBalances · useCrossChainOrder
  orbital/                  client-side Orbital math helpers
constants/                  color themes and type scale
```

> Testnet deployment, not yet audited.
