"use client";

import { useQuery } from "@tanstack/react-query";
import { useConfig } from "wagmi";
import { getPublicClient } from "wagmi/actions";
import { parseAbiItem, type Address, type PublicClient } from "viem";

import { poolByAddress, type PoolEntry } from "@/lib/crosschain";
import { fetchSwapVolumeWadSince, subgraphIndexes } from "@/lib/subgraph";

const DAY = 86_400;

const SWAP_EVENT = parseAbiItem(
  "event Swap(address indexed sender, uint8 assetIn, uint8 assetOut, uint256 amountIn, uint256 amountOut)",
);
const SCALE_OF_ABI = [
  { type: "function", name: "scaleOf", stateMutability: "view", inputs: [{ type: "uint8" }], outputs: [{ type: "uint256" }] },
] as const;

/** Largest `eth_getLogs` block range each chain's public RPC accepts (measured:
 *  Arc rejects 50k with "requested range too large", Arbitrum takes 100k). */
const LOG_RANGE: Record<number, bigint> = {
  421614: 100_000n,
};
const DEFAULT_LOG_RANGE = 10_000n;

/** Swap volume of one pool over the last 24 hours, in USD, and the fees it
 *  earned. `undefined` while loading or if every source failed.
 *
 *  Source per pool: the chain's subgraph when it indexes the pool (one query,
 *  exact timestamps), otherwise a scan of the hook's Swap logs over the blocks
 *  of the last day. The Swap event carries RAW token amounts, so each is
 *  valued through the hook's own `scaleOf` (raw -> WAD, where WAD is USD for a
 *  stable pool and USD at the pool's centre rate for an FX pool). */
export function usePoolVolume24h(poolAddress: Address, fee: number, enabled: boolean) {
  const config = useConfig();
  const pool = poolByAddress(poolAddress);

  const query = useQuery({
    queryKey: ["poolVolume24h", pool?.chainId, poolAddress.toLowerCase()],
    enabled: enabled && pool !== undefined,
    staleTime: 60_000,
    refetchInterval: 5 * 60_000,
    queryFn: async () => {
      const entry = pool!;
      const since = Math.floor(Date.now() / 1000) - DAY;
      if (subgraphIndexes(entry.chainId, entry.address)) {
        try {
          return wadToNumber(await fetchSwapVolumeWadSince(entry.chainId, entry.address, since));
        } catch (e) {
          console.warn("[usePoolVolume24h] subgraph failed, scanning logs", e);
        }
      }
      const client = getPublicClient(config, { chainId: entry.chainId });
      if (!client) throw new Error(`No client for chain ${entry.chainId}`);
      return wadToNumber(await scanVolumeWad(client as PublicClient, entry));
    },
  });

  const volume24h = query.data;
  return { volume24h, fees24h: volume24h === undefined ? undefined : (volume24h * fee) / 1_000_000 };
}

/** WAD to a plain number, keeping 6 decimals of precision. */
function wadToNumber(wad: bigint): number {
  return Number(wad / 10n ** 12n) / 1e6;
}

/** Swap volume in WAD over roughly the last day of blocks, from the logs.
 *  The window is sized from the chain's measured block time. */
async function scanVolumeWad(client: PublicClient, pool: PoolEntry): Promise<bigint> {
  const latest = await client.getBlock();
  const probeNumber = latest.number > 10_000n ? latest.number - 10_000n : 0n;
  const probe = await client.getBlock({ blockNumber: probeNumber });
  const blocks = latest.number - probeNumber;
  const secondsPerBlock = blocks > 0n ? Number(latest.timestamp - probe.timestamp) / Number(blocks) : 1;
  const span = BigInt(Math.ceil(DAY / Math.max(secondsPerBlock, 0.01)));

  let from = latest.number > span ? latest.number - span : 0n;
  if (from < pool.deployBlock) from = pool.deployBlock;

  const scales = await Promise.all(
    pool.assets.map((_, i) =>
      client.readContract({ address: pool.address, abi: SCALE_OF_ABI, functionName: "scaleOf", args: [i] }),
    ),
  );

  const range = LOG_RANGE[pool.chainId] ?? DEFAULT_LOG_RANGE;
  let total = 0n;
  for (let start = from; start <= latest.number; start += range) {
    const end = start + range - 1n < latest.number ? start + range - 1n : latest.number;
    const logs = await client.getLogs({ address: pool.address, event: SWAP_EVENT, fromBlock: start, toBlock: end });
    for (const log of logs) {
      const { assetIn, amountIn } = log.args;
      if (assetIn === undefined || amountIn === undefined) continue;
      total += amountIn * scales[assetIn];
    }
  }
  return total;
}
