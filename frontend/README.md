# Orbital · UHI Frontend

The web app for **Orbital**, an N-asset stableswap built as a **Uniswap v4 hook**, deployed on **Unichain Sepolia (chainId 1301)**. Swap, provide liquidity, and inspect the live pool, wired directly to the on-chain hook.

**Live → https://orbital-hook.vercel.app/**

Contracts live in [`../orbitalHook`](../orbitalHook). The deployed addresses the app talks to are in [`lib/contracts.ts`](lib/contracts.ts).

## Stack

| Layer | Choice |
|---|---|
| Framework | Next.js 16 (App Router) |
| UI | React 19 |
| Chain | wagmi 3 + viem 2 (Unichain Sepolia) |
| Styling | Tailwind CSS 4 + inline design tokens |
| Math | KaTeX |
| Charts / 3D | Recharts · three.js |
| Fonts | Roboto · Geist Mono |

## Run locally

```bash
npm install
npm run dev      # http://localhost:3000
npm run build
npm run lint
```

Connect a wallet on **Unichain Sepolia (1301)**. The Nav prompts a network switch if you're on the wrong chain.

## Environment

| Var | Required | Purpose |
|---|---|---|
| `NEXT_PUBLIC_RPC_URL` | optional | Private Unichain RPC. Falls back to the public `https://sepolia.unichain.org` (rate-limited; caps `getLogs` at 100 blocks). |

Copy `.env.example` → `.env.local` and fill in if you have one.

## Deploy on Vercel

Deploy this folder as its own Vercel project:

1. **Import** the `Oxkai/Orbital.Hook` repo into Vercel.
2. Set **Root Directory** to `frontend`.
3. Framework preset auto-detects **Next.js** (also pinned in `vercel.json`).
4. (Optional) add `NEXT_PUBLIC_RPC_URL` as an env var.
5. Deploy.

`vercel.json` pins `framework: nextjs`, `buildCommand: next build`, `installCommand: npm install`.

## Structure

```
app/
  layout.tsx              root layout: fonts, theme vars, KaTeX css
  page.tsx                home page: assembles all sections
  app/                    the dApp
    swap/                 swap widget (V4Quoter + v4 router)
    pools/  pool/[address]  pool list + detail + add-liquidity
    positions/            LP positions (ERC-6909 shares)
    transactions/         on-chain activity
components/
  home/                   Masthead · Pillars · Mechanics · Architecture · PoolSim (3-token sphere simulation) · VsTable · Deployed · References
  app/                    swap widget, pool/position cards, LP modals
  layout/                 Nav (dark/light) · Footer
  Tex.tsx                 KaTeX formula renderer
lib/
  contracts.ts            deployed addresses + ABIs + PoolKey helper
  wagmi.ts                Unichain Sepolia chain config
  hooks/                  usePool · usePositions · useTokenBalances · useTransactions · useVolume24h
constants/                color themes (dark/light) + type scale
```

> Research deployment on Unichain Sepolia. Not audited, not production.
