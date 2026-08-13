"use client";

import { useEffect, useState } from "react";
import { usePublicClient } from "wagmi";
import { parseAbiItem, type AbiEvent } from "viem";
import { POOL_ADDRESS, DEPLOY_BLOCK } from "@/lib/contracts";

const WAD = 1e18;
const SECONDS_PER_DAY = 86_400;

const SWAP_EVENT = parseAbiItem(
  "event Swap(address indexed sender, uint8 assetIn, uint8 assetOut, uint256 amountIn, uint256 amountOut)"
) as AbiEvent;

export function useVolume24h(fee: number, enabled: boolean = true) {
  const client = usePublicClient();
  const [volume24h, setVolume24h] = useState(0);
  const [fees24h,   setFees24h]   = useState(0);

  useEffect(() => {
    if (!client || !enabled) return;
    let cancelled = false;

    async function load() {
      try {
        const latest = await client!.getBlockNumber();

        // the public RPC caps getLogs at 100 blocks, so we can't scan a
        // full 24h window cheaply. Instead scan a bounded recent window
        // (RECENT_BLOCKS) in 100-block chunks and report it as recent volume.
        const RECENT_BLOCKS = 1_500n;
        const CHUNK = 100n;
        const start = latest - RECENT_BLOCKS > DEPLOY_BLOCK ? latest - RECENT_BLOCKS : DEPLOY_BLOCK;

        let vol = 0;
        for (let from = start; from <= latest; from += CHUNK) {
          if (cancelled) return;
          const to = from + CHUNK - 1n < latest ? from + CHUNK - 1n : latest;
          const logs = await client!.getLogs({ address: POOL_ADDRESS, event: SWAP_EVENT, fromBlock: from, toBlock: to });
          for (const log of logs) {
            const { amountIn } = log.args as { amountIn: bigint };
            vol += Number(amountIn) / WAD;
          }
        }

        if (cancelled) return;
        setVolume24h(vol);
        setFees24h(vol * fee / 1_000_000);
      } catch (e) {
        console.warn("[useVolume24h]", e);
      }
    }

    load();
    const interval = setInterval(load, 60_000);
    return () => { cancelled = true; clearInterval(interval); };
  }, [client, fee, enabled]);

  return { volume24h, fees24h };
}
