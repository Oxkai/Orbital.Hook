"use client";

import { useMemo } from "react";
import { useReadContract, useReadContracts } from "wagmi";
import { type Address, type Hex, parseUnits } from "viem";
import {
  DEPLOYMENTS,
  SETTLER_ABI,
  CC_ERC20_ABI,
  ORBITAL_ORDER_DATA_TYPE,
  DEFAULT_FILL_WINDOW_SECONDS,
  encodeOrderData,
  assetOn,
  ALL_TOKENS,
  type OrderStatus,
} from "@/lib/crosschain";

/// One ERC-7683 OnchainCrossChainOrder, ready to hand to `resolve` or `open`.
export interface BuiltOrder {
  fillDeadline: number;
  orderDataType: Hex;
  orderData: Hex;
  inputRaw: bigint;
  outputRaw: bigint;
}

/// Build the order struct for a route. Returns undefined when the route or the
/// amount is not yet valid, so callers can gate on a single truthy check.
///
/// The user is setting a LIMIT, not receiving a quote: they offer `amountIn` and
/// demand at least `outputRaw`. The gap is the filler's margin, and a filler
/// takes the order only if that margin covers their cost. There is deliberately
/// no on-chain quote here, because the price is whatever a filler will accept.
export function useBuildOrder(params: {
  originChainId: number;
  destChainId: number;
  symbolIn: string;
  symbolOut: string;
  amountIn: string;
  maxSpreadPct: number;
  recipient?: Address;
  fillWindowSeconds?: number;
  /** What the destination pool actually quotes for this pair, in the OUTPUT
   *  token's raw units. The guaranteed minimum is this less the spread. When
   *  omitted the pair is treated as 1:1 (same symbol on both chains, i.e. a
   *  pure bridge, where no swap happens on the destination). */
  expectedOutRaw?: bigint;
}): BuiltOrder | undefined {
  const {
    originChainId,
    destChainId,
    symbolIn,
    symbolOut,
    amountIn,
    maxSpreadPct,
    recipient,
    fillWindowSeconds = DEFAULT_FILL_WINDOW_SECONDS,
    expectedOutRaw,
  } = params;

  return useMemo(() => {
    const assetIn = assetOn(originChainId, symbolIn);
    const assetOut = assetOn(destChainId, symbolOut);
    const dest = DEPLOYMENTS[destChainId];
    // No settler on the destination means no cross-chain route at all.
    if (!assetIn || !assetOut || !dest?.intentSettler || !recipient) return undefined;

    const n = parseFloat(amountIn);
    if (!Number.isFinite(n) || n <= 0) return undefined;

    let inputRaw: bigint;
    try {
      inputRaw = parseUnits(amountIn, assetIn.decimals);
    } catch {
      return undefined;
    }
    if (inputRaw === 0n) return undefined;

    // The guaranteed minimum is the destination pool's actual quote less the
    // filler's spread. Deriving it from the input amount instead made every
    // route quote an identical `amountIn * (1 - spread)`, ignoring pool depth
    // and the price between the two stables entirely.
    //
    // Falling back to the nominal amount is only correct for a same-symbol
    // bridge, where the destination performs no swap. Note this cannot be a
    // straight copy of the raw input: decimals differ across these assets
    // (USDC/USDT are 6, DAI/FRAX are 18), so it is re-scaled.
    const baseline = expectedOutRaw ?? parseUnits(amountIn, assetOut.decimals);
    const keptBps = BigInt(Math.round((100 - maxSpreadPct) * 100));
    const outputRaw = (baseline * keptBps) / 10_000n;
    if (outputRaw === 0n) return undefined;

    const orderData = encodeOrderData({
      inputToken: assetIn.address,
      inputAmount: inputRaw,
      outputToken: assetOut.address,
      outputAmount: outputRaw,
      destinationChainId: BigInt(destChainId),
      destinationSettler: dest.intentSettler!,
      recipient,
    });

    return {
      fillDeadline: Math.floor(Date.now() / 1000) + fillWindowSeconds,
      orderDataType: ORBITAL_ORDER_DATA_TYPE,
      orderData,
      inputRaw,
      outputRaw,
    };
  }, [originChainId, destChainId, symbolIn, symbolOut, amountIn, maxSpreadPct, recipient, fillWindowSeconds, expectedOutRaw]);
}

/// Ask the origin settler for the orderId it WOULD assign. Read-only, so it is
/// safe to call before the user commits. The id depends on the caller's current
/// nonce, so it must be read as the user's own address.
export function useResolvedOrderId(originChainId: number, order: BuiltOrder | undefined, account?: Address) {
  const settler = DEPLOYMENTS[originChainId]?.intentSettler;
  const { data, isLoading } = useReadContract({
    chainId: originChainId,
    address: settler,
    abi: SETTLER_ABI,
    functionName: "resolve",
    args: order
      ? [{ fillDeadline: order.fillDeadline, orderDataType: order.orderDataType, orderData: order.orderData }]
      : undefined,
    account,
    query: { enabled: !!order && !!settler && !!account },
  });
  return { orderId: data?.orderId as Hex | undefined, isLoading };
}

/// Poll an opened order's lifecycle on the ORIGIN chain. Settlement is driven by
/// a Hyperlane message from the destination, so nothing local signals progress;
/// polling is the only way the UI learns the escrow was released.
export function useOrderStatus(originChainId: number, orderId?: Hex, enabled = true) {
  const settler = DEPLOYMENTS[originChainId]?.intentSettler;
  const { data, refetch } = useReadContract({
    chainId: originChainId,
    address: settler,
    abi: SETTLER_ABI,
    functionName: "orders",
    args: orderId ? [orderId] : undefined,
    query: {
      enabled: !!orderId && !!settler && enabled,
      refetchInterval: 8_000,
    },
  });

  if (!data) return { status: undefined, inputAmount: undefined, refundAfter: undefined, refetch };
  const [, , inputAmount, , refundAfter, status] = data as readonly [
    Address, Address, bigint, number, number, number
  ];
  return {
    status: status as OrderStatus,
    inputAmount,
    refundAfter,
    refetch,
  };
}

/// Balances + settler allowance for every routable asset on one chain.
export function useChainAssets(chainId: number, symbols: readonly string[], account?: Address) {
  const dep = DEPLOYMENTS[chainId];
  const assets = useMemo(
    () => symbols.map((s) => dep?.assets[s]).filter((a): a is NonNullable<typeof a> => !!a),
    [dep, symbols]
  );

  const { data, refetch } = useReadContracts({
    contracts: account
      ? assets.flatMap((a) => [
          {
            chainId,
            address: a.address,
            abi: CC_ERC20_ABI,
            functionName: "balanceOf" as const,
            args: [account] as const,
          },
          {
            chainId,
            address: a.address,
            abi: CC_ERC20_ABI,
            functionName: "allowance" as const,
            args: [account, dep!.intentSettler] as const,
          },
        ])
      : [],
    query: { enabled: !!account && !!dep && assets.length > 0, refetchInterval: 15_000 },
  });

  const rows = assets.map((a, i) => {
    const bal = data?.[i * 2]?.result as bigint | undefined;
    const allow = data?.[i * 2 + 1]?.result as bigint | undefined;
    return { ...a, balance: bal ?? 0n, allowance: allow ?? 0n };
  });

  return { assets: rows, refetch };
}

/// Balances for EVERY (chain, asset) pair, keyed `chainId:SYMBOL`. Powers the
/// chain-grouped token dropdown, which shows what the user holds on each chain
/// without making them switch networks to find out.
export function useAllTokenBalances(account?: Address) {
  const { data, refetch, isLoading } = useReadContracts({
    contracts: account
      ? ALL_TOKENS.map((t) => ({
          chainId: t.chainId,
          address: t.address,
          abi: CC_ERC20_ABI,
          functionName: "balanceOf" as const,
          args: [account] as const,
        }))
      : [],
    query: { enabled: !!account, refetchInterval: 20_000 },
  });

  const balances = useMemo(() => {
    const m: Record<string, bigint> = {};
    ALL_TOKENS.forEach((t, i) => {
      m[t.key] = (data?.[i]?.result as bigint | undefined) ?? 0n;
    });
    return m;
  }, [data]);

  return { balances, refetch, isLoading: !!account && isLoading };
}

/// Allowance of one token for one spender on one chain. The spender differs by
/// route: the v4 router for a same-chain swap, the intent settler for a
/// cross-chain order.
export function useAllowance(
  chainId: number,
  token?: Address,
  owner?: Address,
  spender?: Address
) {
  const { data, refetch } = useReadContract({
    chainId,
    address: token,
    abi: CC_ERC20_ABI,
    functionName: "allowance",
    args: owner && spender ? [owner, spender] : undefined,
    query: { enabled: !!token && !!owner && !!spender, refetchInterval: 15_000 },
  });
  return { allowance: (data as bigint | undefined) ?? 0n, refetch };
}
