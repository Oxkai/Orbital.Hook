import { createConfig, http, fallback, type Config } from "wagmi";
import { defineChain } from "viem";
import { arbitrumSepolia } from "wagmi/chains";
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

// Robinhood Chain testnet (an Arbitrum Orbit L2). Not in viem's chain list, so
// defined here like Unichain Sepolia.
export const robinhoodTestnet = defineChain({
  id: 46630,
  name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://rpc.testnet.chain.robinhood.com"] },
  },
  blockExplorers: {
    default: {
      name: "Blockscout",
      url: "https://explorer.testnet.chain.robinhood.com",
    },
  },
  testnet: true,
});

// Explorer links are per chain: use `explorerTx` / `explorerAddress` from
// `lib/crosschain`, which read each deployment's own explorer.

// Robinhood Chain testnet is the primary deployment; Arbitrum Sepolia and
// Unichain Sepolia carry the same hook. Those two each also have an
// OrbitalIntentSettler, peered over Hyperlane; Robinhood has no Hyperlane, so
// it is same-chain only.
export { arbitrumSepolia };

export function createWagmiConfig(): Config {
  const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL;
  return createConfig({
    chains: [robinhoodTestnet, arbitrumSepolia, unichainSepolia],
    connectors: [injected(), coinbaseWallet({ appName: "Orbital" })],
    transports: {
      [unichainSepolia.id]: RPC_URL
        ? fallback([http(RPC_URL), http("https://sepolia.unichain.org")])
        : http("https://sepolia.unichain.org"),
      [arbitrumSepolia.id]: http("https://sepolia-rollup.arbitrum.io/rpc"),
      [robinhoodTestnet.id]: http("https://rpc.testnet.chain.robinhood.com"),
    },
  });
}

export type WagmiConfig = ReturnType<typeof createWagmiConfig>;

declare module "wagmi" {
  interface Register {
    config: WagmiConfig;
  }
}
