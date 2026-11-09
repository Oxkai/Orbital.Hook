"use client";

import { useEstimateFeesPerGas } from "wagmi";

/// Multiple of the estimated `maxFeePerGas` actually offered.
///
/// Arbitrum Sepolia sits at a 0.02 gwei floor and ticks a fraction above it
/// between blocks (sampled: 20,000,000 -> 20,442,000 wei within seconds).
/// MetaMask pins its own estimate at the floor, so `eth_sendRawTransaction`
/// rejects with "max fee per gas less than block base fee" whenever the base
/// fee has moved since it cached that number. Headroom costs nothing at these
/// prices - 3x of 0.02 gwei is 0.06 gwei - and EIP-1559 refunds the difference,
/// so the trader still pays base + tip, never the cap.
const MAX_FEE_MULTIPLIER = 3n;
/// Floor for the tip, for chains whose estimate comes back at zero.
const MIN_PRIORITY_FEE = 1_000_000n; // 0.001 gwei

/// EIP-1559 fees to attach to a write, or `undefined` to let the wallet decide.
///
/// Passing these overrides the wallet's own estimate, which is the point: the
/// app can see the current base fee, and a stale wallet estimate is the single
/// most common reason a testnet send is rejected outright.
export function useTxFees(chainId: number | undefined) {
  const { data } = useEstimateFeesPerGas({ chainId, query: { refetchInterval: 12_000 } });

  if (!data?.maxFeePerGas) return undefined;
  const tip = data.maxPriorityFeePerGas && data.maxPriorityFeePerGas > 0n
    ? data.maxPriorityFeePerGas
    : MIN_PRIORITY_FEE;
  const cap = data.maxFeePerGas * MAX_FEE_MULTIPLIER;
  return {
    // The cap must never sit below the tip, or the node rejects the pair.
    maxFeePerGas: cap > tip ? cap : tip + MIN_PRIORITY_FEE,
    maxPriorityFeePerGas: tip,
  };
}
