# Orbital · Frontend

The web app for **Orbital**, an N-asset stableswap built as a **Uniswap v4 hook**. Swap, provide liquidity and inspect every live pool across **Unichain Sepolia**, **Arbitrum Sepolia** and **Circle's Arc testnet**, including the USD / EUR FX pool on Arc.

**Live → https://orbital-hook.vercel.app/**

Contracts live in [`../orbitalHook`](../orbitalHook). The pools the app talks to are registered in [`lib/crosschain.ts`](lib/crosschain.ts) (from `orbitalHook/deployments.json`) and [`lib/fx.ts`](lib/fx.ts) (the FX pool).

## What's in the app

| Page | What it does |
|---|---|
| **Swap** | Quotes every pool that holds both tokens and routes to the best one; a token on another chain turns the widget into an ERC-7683 cross-chain order (Unichain ↔ Arbitrum). |
| **Pools** | One row per pool: assets, network, address, 24h volume and TVL. |
| **Pool detail** | Reserves, liquidity depth by price, key metrics, transaction history, and live oracle rates for the FX pool. |
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
| Charts / 3D / math | Recharts 3 · three.js · KaTeX |

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
| `NEXT_PUBLIC_ARC_RPC_URL` | Dedicated Arc testnet RPC (Alchemy, QuickNode, dRPC). Used for every Arc call except `eth_getLogs`, which always goes to Arc's public endpoints: Alchemy's free tier caps log queries at 10 blocks. Restrict the key to your domains, since it ships to the browser. |
| `NEXT_PUBLIC_SUBGRAPH_UNICHAIN` · `_ARC` · `_ARBITRUM` | Override the Subgraph Studio endpoints in [`lib/subgraph.ts`](lib/subgraph.ts). |

## Where the data comes from

- **Pool state and quotes** are read on-chain through each chain's transport in [`lib/wagmi.ts`](lib/wagmi.ts).
- **Activity and 24h volume** come from the subgraph, one query per chain. A subgraph is used only while it matches the chain's live hook and has indexed to within five minutes of now; otherwise the app scans the hook's logs over RPC. The FX pool is not indexed and always uses RPC.
- **FX rates** are read from the same Chainlink `AggregatorV3` feed the FX hook prices against.

## Deploy on Vercel

1. Import the repo into Vercel and set **Root Directory** to `frontend`.
2. The Next.js preset is detected (and pinned in `vercel.json`).
3. Add the environment variables above, at least `NEXT_PUBLIC_ARC_RPC_URL`.
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
  fx.ts                     FX pool registry, feed ABI, revert explanations
  contracts.ts              hook ABIs and token metadata
  subgraph.ts               Studio endpoints, freshness guard, activity and volume
  wagmi.ts                  chains and transports
  hooks/                    usePool · usePositions · useDepositQuote · usePoolVolume24h ·
                            useTransactions · useFxRates · useTokenBalances · useCrossChainOrder
  orbital/                  client-side Orbital math helpers
constants/                  color themes and type scale
```

> Research deployment on testnets. Not audited, not production.
