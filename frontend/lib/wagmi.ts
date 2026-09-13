import { createConfig, http, fallback, type Config } from "wagmi";
import { defineChain, type Transport } from "viem";
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

// Circle's Arc testnet. Not in wagmi/chains, so defined here.
//
// Gas is USDC, not ETH. Native USDC is 18-decimal while the ERC-20 view of the
// same asset is 6-decimal; `nativeCurrency.decimals` is the NATIVE view, so 18
// is correct here and a balance shown to a user reads in whole USDC.
export const arcTestnet = defineChain({
  id: 5042002,
  name: "Arc Testnet",
  nativeCurrency: { name: "USD Coin", symbol: "USDC", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://rpc.testnet.arc.io"] },
  },
  blockExplorers: {
    default: {
      name: "Arcscan",
      url: "https://testnet.arcscan.app",
    },
  },
  testnet: true,
});

// Canonical block-explorer URL builders. Use these from components instead of
// hard-coding the explorer base.
export const EXPLORER_BASE = unichainSepolia.blockExplorers.default.url;
export const explorerAddressUrl = (address: string) => `${EXPLORER_BASE}/address/${address}`;
export const explorerTxUrl      = (hash: string)    => `${EXPLORER_BASE}/tx/${hash}`;

// Arbitrum Sepolia carries the cross-chain deployment alongside Unichain (an
// OrbitalHook plus an OrbitalIntentSettler on each, peered over Hyperlane).
// Unichain Sepolia stays the single-chain swap/LP deployment; the two are
// separate and are not routed between. Arc carries the same pool but is
// same-chain only, since Hyperlane has no Arc testnet deployment to peer with.
export { arbitrumSepolia };

/// Sends `eth_getLogs` through `logs` and every other method through `rest`.
///
/// A dedicated provider's free tier is fast and not rate-limited, but may cap
/// eth_getLogs far below what history scans need: Alchemy's free tier allows
/// a 10-block range, while the activity feed and 24h volume read 10,000
/// blocks at a time, which the public endpoints accept. So state reads and
/// quotes go to the dedicated provider, and log scans to the public endpoints.
function splitLogs(logs: Transport, rest: Transport): Transport {
  return (params) => {
    const logsT = logs(params);
    const restT = rest(params);
    return {
      ...restT,
      request: (args) => (args.method === "eth_getLogs" ? logsT.request(args) : restT.request(args)),
    };
  };
}

const ARC_PUBLIC = [http("https://rpc.testnet.arc.io"), http("https://rpc.testnet.arc.network")];

/// Arc testnet: the dedicated RPC (NEXT_PUBLIC_ARC_RPC_URL) when set, with the
/// public endpoints as fallback, and log scans always on the public endpoints.
function arcTransport(): Transport {
  const dedicated = process.env.NEXT_PUBLIC_ARC_RPC_URL;
  if (!dedicated) return fallback(ARC_PUBLIC);
  return splitLogs(fallback(ARC_PUBLIC), fallback([http(dedicated), ...ARC_PUBLIC]));
}

export function createWagmiConfig(): Config {
  const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL;
  return createConfig({
    chains: [unichainSepolia, arbitrumSepolia, arcTestnet],
    connectors: [injected(), coinbaseWallet({ appName: "Orbital" })],
    transports: {
      [unichainSepolia.id]: RPC_URL
        ? fallback([http(RPC_URL), http("https://sepolia.unichain.org")])
        : http("https://sepolia.unichain.org"),
      [arbitrumSepolia.id]: http("https://sepolia-rollup.arbitrum.io/rpc"),
      [arcTestnet.id]: arcTransport(),
    },
  });
}

export type WagmiConfig = ReturnType<typeof createWagmiConfig>;

declare module "wagmi" {
  interface Register {
    config: WagmiConfig;
  }
}
