import { createConfig, http, fallback, type Config } from "wagmi";
import { defineChain } from "viem";
import { baseSepolia, arbitrumSepolia } from "wagmi/chains";
import { injected, coinbaseWallet } from "wagmi/connectors";

// Unichain Sepolia: Uniswap v4 is canonically deployed here.
export const unichainSepolia = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Sepolia Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://sepolia.unichain.org"] },
  },
  blockExplorers: {
    default: {
      name: "Uniscan",
      url: "https://sepolia.uniscan.xyz",
    },
  },
  testnet: true,
});

// Canonical block-explorer URL builders. Use these from components instead of
// hard-coding the explorer base.
export const EXPLORER_BASE = unichainSepolia.blockExplorers.default.url;
export const explorerAddressUrl = (address: string) => `${EXPLORER_BASE}/address/${address}`;
export const explorerTxUrl      = (hash: string)    => `${EXPLORER_BASE}/tx/${hash}`;

// Base Sepolia and Arbitrum Sepolia carry the cross-chain deployment (an
// OrbitalHook plus an OrbitalIntentSettler on each, peered over Hyperlane).
// Unichain Sepolia stays the single-chain swap/LP deployment; the two are
// separate and are not routed between.
export { baseSepolia, arbitrumSepolia };

export function createWagmiConfig(): Config {
  const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL;
  return createConfig({
    chains: [unichainSepolia, baseSepolia, arbitrumSepolia],
    connectors: [injected(), coinbaseWallet({ appName: "Orbital" })],
    transports: {
      [unichainSepolia.id]: RPC_URL
        ? fallback([http(RPC_URL), http("https://sepolia.unichain.org")])
        : http("https://sepolia.unichain.org"),
      [baseSepolia.id]: http("https://sepolia.base.org"),
      [arbitrumSepolia.id]: http("https://sepolia-rollup.arbitrum.io/rpc"),
    },
  });
}

export type WagmiConfig = ReturnType<typeof createWagmiConfig>;

declare module "wagmi" {
  interface Register {
    config: WagmiConfig;
  }
}
