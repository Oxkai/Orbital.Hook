import { createConfig, http, type Config } from "wagmi";
import { defineChain } from "viem";
import { arbitrumSepolia, sepolia, baseSepolia } from "wagmi/chains";
import { injected, coinbaseWallet } from "wagmi/connectors";

// Robinhood Chain testnet (an Arbitrum Orbit L2). Not in viem's chain list, so
// defined here by hand.
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

// Arbitrum Sepolia is the primary deployment (see `PRIMARY_CHAIN_ID`); Ethereum
// Sepolia, Base Sepolia and Robinhood Chain testnet carry the same hook.
// Arbitrum, Ethereum and Base are peered for cross-chain intents; Robinhood has
// no Hyperlane mailbox, so it is same-chain only.
export { arbitrumSepolia, sepolia, baseSepolia };

export function createWagmiConfig(): Config {
  return createConfig({
    chains: [arbitrumSepolia, sepolia, baseSepolia, robinhoodTestnet],
    connectors: [injected(), coinbaseWallet({ appName: "Orbital" })],
    transports: {
      [arbitrumSepolia.id]: http("https://sepolia-rollup.arbitrum.io/rpc"),
      [robinhoodTestnet.id]: http("https://rpc.testnet.chain.robinhood.com"),
      [baseSepolia.id]: http("https://base-sepolia-rpc.publicnode.com"),
      [sepolia.id]: http("https://ethereum-sepolia-rpc.publicnode.com"),
    },
  });
}

export type WagmiConfig = ReturnType<typeof createWagmiConfig>;

declare module "wagmi" {
  interface Register {
    config: WagmiConfig;
  }
}
