"use client";

import { useState, useRef, useEffect, useCallback, useMemo } from "react";
import {
  GearSix,
  ArrowDown,
  ArrowsDownUp,
  CaretDown,
  CaretUp,
  X,
  Check,
  Circle,
  ArrowSquareOut,
} from "@phosphor-icons/react";
import {
  useAccount,
  useConnect,
  useConnectors,
  useSwitchChain,
  useWriteContract,
  useReadContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { type Address, type Hash, type Hex, formatUnits, parseUnits, maxUint256 } from "viem";
import { color, typography } from "@/constants";
import { ERC20_ABI, MOCK_ERC20_ABI, ROUTER_ABI, QUOTER_ABI } from "@/lib/contracts";
import {
  DEPLOYMENTS,
  CHAIN_IDS,
  ALL_TOKENS,
  tokenByKey,
  routeBlockedReason,
  assetOn,
  SETTLER_ABI,
  OrderStatus,
  ORDER_STATUS_LABEL,
  explorerTx,
  type TokenRow,
} from "@/lib/crosschain";
import {
  useBuildOrder,
  useResolvedOrderId,
  useOrderStatus,
  useAllTokenBalances,
  useAllowance,
} from "@/lib/hooks/useCrossChainOrder";
import { TokenIcon } from "@/components/app/shared/TokenIcon";

const LBL = {
  fontFamily: typography.caption.family,
  fontSize: typography.caption.size,
  letterSpacing: "0.12em",
  textTransform: "uppercase" as const,
  fontWeight: 500,
};

function body(size: "p1" | "p2" | "p3" | "caption" = "p2", c: string = color.textPrimary) {
  const t = typography[size];
  return {
    fontFamily: t.family,
    fontSize: t.size,
    lineHeight: t.lineHeight,
    letterSpacing: t.letterSpacing,
    color: c,
    fontVariantNumeric: "tabular-nums" as const,
  };
}

function StatusPill({ healthy, label }: { healthy: boolean; label: string }) {
  const c = healthy ? color.success : color.warning;
  return (
    <span
      className="inline-flex items-center gap-1.5"
      style={{
        backgroundColor: `${c}1f`,
        color: c,
        fontFamily: typography.caption.family,
        fontSize: "11px",
        fontWeight: 500,
        letterSpacing: "0.04em",
        padding: "3px 9px",
        borderRadius: 999,
        whiteSpace: "nowrap",
      }}
    >
      <Circle size={6} color={c} weight="fill" />
      {label}
    </span>
  );
}

function fmtAmount(raw: bigint, decimals: number): string {
  const n = parseFloat(formatUnits(raw, decimals));
  if (n === 0) return "0.0000";
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(2) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(2) + "K";
  return n.toFixed(4);
}

// ─── Token dropdown, grouped by chain ────────────────────────────────────────

interface DropdownProps {
  balances: Record<string, bigint>;
  selectedKey: string;
  excludedKey: string;
  onSelect: (key: string) => void;
  onClose: () => void;
}

function TokenDropdown({ balances, selectedKey, excludedKey, onSelect, onClose }: DropdownProps) {
  const ref = useRef<HTMLDivElement>(null);
  const [filter, setFilter] = useState("");

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose();
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [onClose]);

  const q = filter.trim().toLowerCase();
  const groups = CHAIN_IDS.map((chainId) => ({
    chainId,
    dep: DEPLOYMENTS[chainId],
    rows: ALL_TOKENS.filter(
      (t) =>
        t.chainId === chainId &&
        (q === "" ||
          t.symbol.toLowerCase().includes(q) ||
          DEPLOYMENTS[chainId].short.toLowerCase().includes(q))
    ),
  })).filter((g) => g.rows.length > 0);

  return (
    <div
      ref={ref}
      className="absolute right-0 top-full mt-2 z-50 w-72 flex flex-col gap-px max-h-96 overflow-y-auto"
      style={{ boxShadow: "0 12px 32px rgba(0,0,0,0.4)", backgroundColor: color.borderSubtle }}
    >
      <div className="px-4 py-3" style={{ backgroundColor: color.surface1 }}>
        <input
          autoFocus
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          placeholder="Search token or chain"
          className="w-full bg-transparent outline-none"
          style={body("p3", color.textPrimary)}
        />
      </div>

      {groups.map((g) => (
        <div key={g.chainId} className="flex flex-col gap-px">
          <div
            className="flex items-center justify-between px-4 py-2"
            style={{ backgroundColor: color.surface2 }}
          >
            <span style={{ ...LBL, color: color.textMuted }}>{g.dep.short}</span>
            {!g.dep.intentSettler && (
              <span style={{ ...body("caption", color.textMuted), textTransform: "none" }}>
                same-chain only
              </span>
            )}
          </div>

          {g.rows.map((t) => {
            const isSelected = t.key === selectedKey;
            const isExcluded = t.key === excludedKey;
            const bal = balances[t.key] ?? 0n;
            return (
              <button
                key={t.key}
                disabled={isExcluded}
                onClick={() => {
                  onSelect(t.key);
                  onClose();
                }}
                className="w-full flex items-center gap-3 px-4 py-3 hover:bg-(--color-surface-2) transition-colors disabled:opacity-35"
                style={{
                  backgroundColor: isSelected ? color.surface2 : color.surface1,
                  cursor: isExcluded ? "not-allowed" : "pointer",
                }}
              >
                <TokenIcon
                  symbol={t.symbol}
                  size={26}
                  chainId={t.chainId}
                  ringColor={isSelected ? color.surface2 : color.surface1}
                />
                <span
                  className="flex-1 text-left"
                  style={{ ...body("p2", color.textPrimary), fontWeight: 500 }}
                >
                  {t.symbol}
                </span>
                <span style={body("caption", color.textMuted)}>{fmtAmount(bal, t.decimals)}</span>
                {isSelected && <Check size={11} color={color.success} weight="bold" />}
              </button>
            );
          })}
        </div>
      ))}

      {groups.length === 0 && (
        <div className="px-4 py-6 text-center" style={{ backgroundColor: color.surface1 }}>
          <span style={body("p3", color.textMuted)}>No match</span>
        </div>
      )}
    </div>
  );
}

// ─── Token box ───────────────────────────────────────────────────────────────

function TokenBox({
  mode, token, balances, selectedKey, excludedKey, value, onChange, onTokenSelect,
  isConnected, balanceReady = true, onFaucet,
}: {
  mode: "in" | "out";
  token: TokenRow;
  balances: Record<string, bigint>;
  selectedKey: string;
  excludedKey: string;
  value: string;
  onChange?: (v: string) => void;
  onTokenSelect: (key: string) => void;
  isConnected: boolean;
  balanceReady?: boolean;
  onFaucet?: () => void;
}) {
  const [open, setOpen] = useState(false);
  const numVal = parseFloat(value) || 0;
  const bal = balances[token.key] ?? 0n;
  const balanceStr = !isConnected ? "—" : !balanceReady ? "…" : fmtAmount(bal, token.decimals);

  return (
    <div className="relative px-5 py-5" style={{ backgroundColor: color.surface1 }}>
      <div className="flex items-center justify-between mb-3">
        <span style={{ ...LBL, color: color.textMuted }}>
          {mode === "in" ? "You pay" : "You receive"}
        </span>
        <span className="flex items-center gap-2.5">
          {mode === "in" && isConnected && balanceReady && bal === 0n && onFaucet && (
            <button
              onClick={onFaucet}
              className="hover:opacity-100 opacity-70 transition-opacity"
              style={{ ...body("caption", color.accent), cursor: "pointer" }}
            >
              Get test tokens
            </button>
          )}
          <span style={body("caption", color.textMuted)}>
            {mode === "in" ? `Balance ${balanceStr}` : DEPLOYMENTS[token.chainId]?.short}
          </span>
        </span>
      </div>

      <div className="flex items-center gap-3">
        <div className="flex-1 min-w-0">
          {mode === "in" ? (
            <input
              type="text"
              inputMode="decimal"
              placeholder="0"
              value={value}
              onChange={(e) => {
                if (/^\d*(?:\.\d*)?$/.test(e.target.value)) onChange?.(e.target.value);
              }}
              className="w-full bg-transparent outline-none"
              style={{
                fontFamily: typography.h1.family,
                fontSize: "36px",
                letterSpacing: "-0.03em",
                fontWeight: 500,
                color: value ? color.textPrimary : color.textMuted,
                lineHeight: 1,
                fontVariantNumeric: "tabular-nums",
              }}
            />
          ) : (
            <div
              style={{
                fontFamily: typography.h1.family,
                fontSize: "36px",
                letterSpacing: "-0.03em",
                fontWeight: 500,
                color: value ? color.textPrimary : color.textMuted,
                lineHeight: 1,
                fontVariantNumeric: "tabular-nums",
              }}
            >
              {value || "0"}
            </div>
          )}
        </div>

        <div className="relative shrink-0">
          <button
            onClick={() => setOpen((v) => !v)}
            className="flex items-center gap-2 pl-2 pr-3 h-10 hover:bg-(--color-surface-3) transition-colors"
            style={{ backgroundColor: color.surface2, cursor: "pointer" }}
          >
            <TokenIcon
              symbol={token.symbol}
              size={28}
              chainId={token.chainId}
              ringColor={color.surface2}
            />
            <span style={{ ...body("p2", color.textPrimary), fontWeight: 500 }}>{token.symbol}</span>
            <CaretDown
              size={11}
              color={color.textMuted}
              weight="regular"
              style={{ transform: open ? "rotate(180deg)" : "rotate(0deg)", transition: "transform 0.15s" }}
            />
          </button>
          {open && (
            <TokenDropdown
              balances={balances}
              selectedKey={selectedKey}
              excludedKey={excludedKey}
              onSelect={onTokenSelect}
              onClose={() => setOpen(false)}
            />
          )}
        </div>
      </div>

      <div className="flex items-center justify-between mt-3">
        <span style={body("caption", color.textMuted)}>
          ≈ ${numVal > 0 ? numVal.toFixed(2) : "0.00"}
        </span>
        {mode === "in" && isConnected && bal > 0n && (
          <button
            onClick={() => onChange?.(formatUnits(bal, token.decimals))}
            className="hover:opacity-90 transition-opacity"
            style={{
              fontFamily: typography.caption.family,
              fontSize: "11px",
              fontWeight: 500,
              letterSpacing: "0.06em",
              textTransform: "uppercase",
              color: color.accent,
              cursor: "pointer",
            }}
          >
            Max
          </button>
        )}
      </div>
    </div>
  );
}

// ─── Settings ────────────────────────────────────────────────────────────────

function SettingsPanel({ slippage, setSlippage, deadline, setDeadline, onClose }: {
  slippage: number; setSlippage: (v: number) => void;
  deadline: number; setDeadline: (v: number) => void;
  onClose: () => void;
}) {
  return (
    <div className="px-5 py-5 flex flex-col gap-4" style={{ backgroundColor: color.surface1 }}>
      <div className="flex items-center justify-between">
        <span style={{ ...LBL, color: color.textMuted }}>Settings</span>
        <button onClick={onClose} className="hover:opacity-100 opacity-70 transition-opacity">
          <X size={13} color={color.textMuted} weight="regular" />
        </button>
      </div>

      <div className="flex flex-col gap-2">
        <span style={body("caption", color.textMuted)}>
          Slippage tolerance
          <span style={{ marginLeft: 6 }}>· cross-chain: max filler spread</span>
        </span>
        <div className="flex gap-2">
          {[0.1, 0.5, 1].map((v) => {
            const active = slippage === v;
            return (
              <button
                key={v}
                onClick={() => setSlippage(v)}
                className="flex-1 flex items-center justify-center h-9 hover:opacity-90 transition-opacity"
                style={{
                  backgroundColor: active ? `${color.accent}1f` : color.surface2,
                  color: active ? color.accent : color.textSecondary,
                  fontFamily: typography.p3.family,
                  fontSize: typography.p3.size,
                  fontWeight: active ? 500 : 400,
                  cursor: "pointer",
                  fontVariantNumeric: "tabular-nums",
                }}
              >
                {v}%
              </button>
            );
          })}
        </div>
      </div>

      <div className="flex flex-col gap-2">
        <span style={body("caption", color.textMuted)}>Transaction deadline</span>
        <div className="flex gap-2">
          {[5, 10, 30].map((v) => {
            const active = deadline === v;
            return (
              <button
                key={v}
                onClick={() => setDeadline(v)}
                className="flex-1 flex items-center justify-center h-9 hover:opacity-90 transition-opacity"
                style={{
                  backgroundColor: active ? `${color.accent}1f` : color.surface2,
                  color: active ? color.accent : color.textSecondary,
                  fontFamily: typography.p3.family,
                  fontSize: typography.p3.size,
                  fontWeight: active ? 500 : 400,
                  cursor: "pointer",
                  fontVariantNumeric: "tabular-nums",
                }}
              >
                {v}m
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}

// ─── Info panel ──────────────────────────────────────────────────────────────

function SwapInfoPanel({ tokenIn, tokenOut, numIn, amountOut, slippage, fee, isCrossChain }: {
  tokenIn: TokenRow; tokenOut: TokenRow;
  numIn: number; amountOut: number; slippage: number; fee: number; isCrossChain: boolean;
}) {
  const [expanded, setExpanded] = useState(false);
  const [rateFlipped, setRateFlipped] = useState(false);
  const hasValues = numIn > 0 && amountOut > 0;
  const rate = hasValues ? amountOut / numIn : 0;
  const rateStr = hasValues
    ? rateFlipped
      ? `1 ${tokenOut.symbol} = ${(1 / rate).toFixed(5)} ${tokenIn.symbol}`
      : `1 ${tokenIn.symbol} = ${rate.toFixed(5)} ${tokenOut.symbol}`
    : `1 ${tokenIn.symbol} = — ${tokenOut.symbol}`;

  const rows = isCrossChain
    ? [
        { label: "Route", value: `${DEPLOYMENTS[tokenIn.chainId]?.short} → ${DEPLOYMENTS[tokenOut.chainId]?.short}` },
        { label: "Max filler spread", value: `${slippage}%` },
        { label: "Guaranteed out", value: hasValues ? `${amountOut.toFixed(4)} ${tokenOut.symbol}` : "—" },
        { label: "Settlement", value: "Hyperlane proof" },
        { label: "Fill window", value: "6h" },
      ]
    : [
        {
          label: "Fee",
          value: hasValues ? `${((numIn * fee) / 1_000_000).toFixed(4)} ${tokenIn.symbol}` : "—",
          note: hasValues ? `${(fee / 10000).toFixed(2)}%` : undefined,
        },
        { label: "Slippage", value: `${slippage}%` },
        {
          label: "Min received",
          value: hasValues ? `${(amountOut * (1 - slippage / 100)).toFixed(4)} ${tokenOut.symbol}` : "—",
        },
        { label: "Route", value: `Direct · ${DEPLOYMENTS[tokenIn.chainId]?.short}` },
      ];

  return (
    <div style={{ backgroundColor: color.surface1 }}>
      <button
        onClick={() => setExpanded((v) => !v)}
        className="w-full flex items-center justify-between px-5 py-4 hover:bg-(--color-surface-2) transition-colors"
      >
        <span style={body("p3", color.textSecondary)}>{rateStr}</span>
        <div className="flex items-center gap-2">
          {hasValues && (
            <span
              onClick={(e) => { e.stopPropagation(); setRateFlipped((v) => !v); }}
              style={{ lineHeight: 0, cursor: "pointer" }}
            >
              <ArrowsDownUp size={12} color={color.textMuted} weight="regular" />
            </span>
          )}
          {expanded
            ? <CaretUp size={12} color={color.textMuted} weight="regular" />
            : <CaretDown size={12} color={color.textMuted} weight="regular" />}
        </div>
      </button>
      {expanded && (
        <div className="px-5 py-4 flex flex-col gap-2.5" style={{ borderTop: `1px dashed ${color.borderSubtle}` }}>
          {rows.map((r) => (
            <div key={r.label} className="flex items-center justify-between">
              <span style={body("p3", color.textMuted)}>{r.label}</span>
              <span style={body("p3", color.textSecondary)}>
                {r.value}
                {"note" in r && r.note && <span style={{ color: color.textMuted, marginLeft: 4 }}>({r.note})</span>}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ─── Cross-chain order tracker ───────────────────────────────────────────────

function OrderTracker({ originChainId, destChainId, orderId, onDismiss }: {
  originChainId: number; destChainId: number; orderId: Hex; onDismiss: () => void;
}) {
  const { status } = useOrderStatus(originChainId, orderId);
  const { data: filler } = useReadContract({
    chainId: destChainId,
    address: DEPLOYMENTS[destChainId]?.intentSettler,
    abi: SETTLER_ABI,
    functionName: "filledBy",
    args: [orderId],
    query: { enabled: !!orderId, refetchInterval: 8_000 },
  });

  const isFilled = !!filler && filler !== "0x0000000000000000000000000000000000000000";
  const settled = status === OrderStatus.SETTLED;
  const refunded = status === OrderStatus.REFUNDED;

  const steps = [
    { label: `Escrowed on ${DEPLOYMENTS[originChainId]?.short}`, done: true },
    { label: `Filled on ${DEPLOYMENTS[destChainId]?.short}`, done: isFilled },
    { label: "Proof verified, escrow released", done: settled },
  ];

  return (
    <div className="mt-px flex flex-col gap-px">
      <div className="flex items-center justify-between px-5 py-4" style={{ backgroundColor: color.surface1 }}>
        <span style={{ ...LBL, color: color.textMuted }}>Cross-chain order</span>
        <StatusPill
          healthy={settled}
          label={status !== undefined ? ORDER_STATUS_LABEL[status] : "…"}
        />
      </div>
      <div className="px-5 py-4 flex flex-col gap-3" style={{ backgroundColor: color.surface1 }}>
        {steps.map((s) => (
          <div key={s.label} className="flex items-center gap-3">
            {s.done
              ? <Check size={12} color={color.success} weight="bold" />
              : <Circle size={10} color={color.textMuted} weight="regular" />}
            <span style={body("p3", s.done ? color.textSecondary : color.textMuted)}>{s.label}</span>
          </div>
        ))}
        {!isFilled && !refunded && (
          <p style={{ ...body("caption", color.textMuted), marginTop: 2, lineHeight: 1.6 }}>
            A filler takes the order when your limit covers their cost. Settlement
            after that is automatic.
          </p>
        )}
      </div>
      <div className="flex items-center justify-between px-5 py-3" style={{ backgroundColor: color.surface1 }}>
        <a
          href={`${DEPLOYMENTS[originChainId]?.explorer}/address/${DEPLOYMENTS[originChainId]?.intentSettler}`}
          target="_blank"
          rel="noreferrer"
          className="inline-flex items-center gap-1.5 hover:opacity-100 opacity-70 transition-opacity"
          style={body("caption", color.textMuted)}
        >
          Settler <ArrowSquareOut size={11} weight="regular" />
        </a>
        <button onClick={onDismiss} style={{ ...LBL, color: color.textPrimary, cursor: "pointer" }}>
          Dismiss
        </button>
      </div>
    </div>
  );
}

// ─── Main widget ─────────────────────────────────────────────────────────────

// Opens as an ordinary same-chain swap. Cross-chain is reached by picking a
// token under a different chain heading in the dropdown, not by default.
const DEFAULT_IN = `${CHAIN_IDS[0]}:USDC`;
const DEFAULT_OUT = `${CHAIN_IDS[0]}:USDT`;

export function SwapWidget() {
  const [inKey, setInKey] = useState(DEFAULT_IN);
  const [outKey, setOutKey] = useState(DEFAULT_OUT);
  const [amountIn, setAmountIn] = useState("");
  const [showSettings, setShowSettings] = useState(false);
  const [deadline, setDeadline] = useState(10);
  const [slippage, setSlippage] = useState(0.5);
  const [swapResult, setSwapResult] = useState<{ status: "pending" | "success" | "error"; hash?: string; msg: string } | null>(null);
  const [pendingHash, setPendingHash] = useState<Hash | undefined>(undefined);
  const [trackedOrder, setTrackedOrder] = useState<Hex | undefined>(undefined);
  const resultTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const { address, isConnected, chainId: walletChainId } = useAccount();
  const { connect } = useConnect();
  const connectors = useConnectors();
  const { switchChain } = useSwitchChain();
  const { writeContract, isPending } = useWriteContract();

  const tokenIn = tokenByKey(inKey) ?? ALL_TOKENS[0];
  const tokenOut = tokenByKey(outKey) ?? ALL_TOKENS[1];
  const isCrossChain = tokenIn.chainId !== tokenOut.chainId;
  const originChainId = tokenIn.chainId;
  const originDep = DEPLOYMENTS[originChainId];
  const blockedReason = routeBlockedReason(tokenIn.chainId, tokenOut.chainId);

  const { balances, refetch: refetchBalances, isLoading: balancesLoading } = useAllTokenBalances(address);
  const balanceReady = !!address && !balancesLoading;

  // Approval target depends on the route: the v4 router for a same-chain swap,
  // the intent settler for a cross-chain order.
  const spender = isCrossChain ? originDep?.intentSettler : originDep?.swapRouter;
  const { allowance, refetch: refetchAllowance } = useAllowance(
    originChainId, tokenIn.address, address, spender
  );

  const amtInRaw = useMemo(() => {
    try {
      const n = parseFloat(amountIn);
      if (!Number.isFinite(n) || n <= 0) return 0n;
      return parseUnits(amountIn, tokenIn.decimals);
    } catch {
      return 0n;
    }
  }, [amountIn, tokenIn.decimals]);
  const numIn = parseFloat(amountIn) || 0;

  // ── Quote ──
  // Same-chain: quote the origin pool directly.
  // Cross-chain: the swap that actually happens is on the DESTINATION chain,
  // between that chain's own addresses for the two symbols: a filler holding
  // the input stable there converts it and pays out. Quoting the origin pool
  // would price a trade nobody makes. A same-symbol route (USDC -> USDC) is a
  // pure bridge with no swap at all, so it needs no quote.
  const quoteChainId = isCrossChain ? tokenOut.chainId : originChainId;
  const quoteDep = DEPLOYMENTS[quoteChainId];
  const quoteInAddr = isCrossChain
    ? assetOn(tokenOut.chainId, tokenIn.symbol)?.address
    : tokenIn.address;
  const isPureBridge = isCrossChain && tokenIn.symbol === tokenOut.symbol;

  const quotePoolKey = useMemo(() => {
    if (!quoteDep || !quoteInAddr || isPureBridge) return undefined;
    if (quoteInAddr.toLowerCase() === tokenOut.address.toLowerCase()) return undefined;
    const zeroForOne = quoteInAddr.toLowerCase() < tokenOut.address.toLowerCase();
    const [currency0, currency1] = zeroForOne
      ? [quoteInAddr, tokenOut.address]
      : [tokenOut.address, quoteInAddr];
    return {
      key: { currency0, currency1, fee: 0, tickSpacing: 1, hooks: quoteDep.orbitalHook },
      zeroForOne,
    };
  }, [quoteDep, quoteInAddr, tokenOut.address, isPureBridge]);

  // The cross-chain leg is denominated in the DESTINATION chain's copy of the
  // input token, whose decimals can differ from the origin's (Unichain is all
  // 18-decimal, Base/Arbitrum are mixed), so the amount is re-scaled.
  const quoteAmtInRaw = useMemo(() => {
    if (!isCrossChain) return amtInRaw;
    const destIn = assetOn(tokenOut.chainId, tokenIn.symbol);
    if (!destIn) return 0n;
    try {
      const n = parseFloat(amountIn);
      if (!Number.isFinite(n) || n <= 0) return 0n;
      return parseUnits(amountIn, destIn.decimals);
    } catch {
      return 0n;
    }
  }, [isCrossChain, amtInRaw, amountIn, tokenOut.chainId, tokenIn.symbol]);

  const { data: quoteData } = useReadContract({
    chainId: quoteChainId,
    address: quoteDep?.quoter,
    abi: QUOTER_ABI,
    functionName: "quoteExactInputSingle",
    args: quotePoolKey
      ? [{ poolKey: quotePoolKey.key, zeroForOne: quotePoolKey.zeroForOne, exactAmount: quoteAmtInRaw, hookData: "0x" as const }]
      : undefined,
    query: { enabled: quoteAmtInRaw > 0n && !!quotePoolKey },
  });

  const quotedOutRaw = quoteData ? (quoteData as readonly [bigint, bigint])[0] : undefined;

  // ── Cross-chain order ──
  const order = useBuildOrder({
    originChainId: tokenIn.chainId,
    destChainId: tokenOut.chainId,
    symbolIn: tokenIn.symbol,
    symbolOut: tokenOut.symbol,
    amountIn,
    maxSpreadPct: slippage,
    recipient: address,
    expectedOutRaw: isPureBridge ? undefined : quotedOutRaw,
  });
  const { orderId } = useResolvedOrderId(tokenIn.chainId, isCrossChain ? order : undefined, address);

  // The guaranteed cross-chain floor, derived straight from the quote rather
  // than from `order`. `order` needs a recipient and so is undefined until a
  // wallet connects: deriving the display from it meant cross-chain showed a
  // flat 0 pre-connect while same-chain quoted fine, which reads as broken.
  const crossChainMinRaw = useMemo(() => {
    if (!isCrossChain) return undefined;
    let baseline: bigint | undefined;
    if (isPureBridge) {
      try {
        const n = parseFloat(amountIn);
        baseline = Number.isFinite(n) && n > 0 ? parseUnits(amountIn, tokenOut.decimals) : undefined;
      } catch {
        baseline = undefined;
      }
    } else {
      baseline = quotedOutRaw;
    }
    if (baseline === undefined || baseline === 0n) return undefined;
    const keptBps = BigInt(Math.round((100 - slippage) * 100));
    return (baseline * keptBps) / 10_000n;
  }, [isCrossChain, isPureBridge, amountIn, tokenOut.decimals, quotedOutRaw, slippage]);

  // Output shown to the user: a real quote same-chain, the guaranteed floor
  // cross-chain. They are different promises and the info panel labels them so.
  const amountOut = isCrossChain
    ? crossChainMinRaw !== undefined ? parseFloat(formatUnits(crossChainMinRaw, tokenOut.decimals)) : 0
    : quotedOutRaw !== undefined ? parseFloat(formatUnits(quotedOutRaw, tokenOut.decimals)) : 0;
  const amountOutStr = amountOut > 0 ? amountOut.toFixed(5) : "";

  const { isSuccess: txConfirmed } = useWaitForTransactionReceipt({
    hash: pendingHash,
    query: { enabled: !!pendingHash },
  });

  useEffect(() => {
    if (!txConfirmed) return;
    setPendingHash(undefined);
    setSwapResult((prev) => (prev && prev.status === "pending" ? { ...prev, status: "success" } : prev));
    if (resultTimer.current) clearTimeout(resultTimer.current);
    resultTimer.current = setTimeout(() => setSwapResult(null), 6000);
    refetchBalances();
    refetchAllowance();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [txConfirmed]);

  useEffect(() => () => { if (resultTimer.current) clearTimeout(resultTimer.current); }, []);

  function showResult(result: { status: "pending" | "success" | "error"; hash?: string; msg: string }) {
    if (resultTimer.current) clearTimeout(resultTimer.current);
    setSwapResult(result);
    if (result.status !== "pending") {
      resultTimer.current = setTimeout(() => setSwapResult(null), 6000);
    }
  }

  const inBalance = balances[tokenIn.key] ?? 0n;
  const isInsufficient = balanceReady && amtInRaw > 0n && amtInRaw > inBalance;
  const needsApproval = isConnected && amtInRaw > 0n && allowance < amtInRaw;
  const onWrongChain = isConnected && walletChainId !== originChainId;

  const flip = useCallback(() => {
    const prev = amountOut;
    setInKey(outKey);
    setOutKey(inKey);
    setAmountIn(prev > 0 ? prev.toFixed(5) : "");
  }, [inKey, outKey, amountOut]);

  const handleInSelect = useCallback((k: string) => { if (k === outKey) flip(); else setInKey(k); }, [outKey, flip]);
  const handleOutSelect = useCallback((k: string) => { if (k === inKey) flip(); else setOutKey(k); }, [inKey, flip]);

  function handleFaucet() {
    if (!address) return;
    writeContract(
      {
        chainId: originChainId,
        address: tokenIn.address,
        abi: MOCK_ERC20_ABI,
        functionName: "mint",
        args: [address, 100_000n * 10n ** BigInt(tokenIn.decimals)],
      },
      {
        onSuccess: (hash) => {
          setPendingHash(hash);
          showResult({ status: "pending", hash, msg: `100,000 ${tokenIn.symbol} minted` });
        },
        onError: (e) => showResult({ status: "error", msg: e.message.split("\n")[0] }),
      }
    );
  }

  function handleApprove() {
    if (!address || !spender) return;
    writeContract(
      {
        chainId: originChainId,
        address: tokenIn.address,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [spender, maxUint256],
      },
      {
        onSuccess: (hash) => {
          setPendingHash(hash);
          showResult({ status: "pending", hash, msg: `${tokenIn.symbol} approved` });
        },
        onError: (e) => showResult({ status: "error", msg: e.message.split("\n")[0] }),
      }
    );
  }

  function handleSameChainSwap() {
    const sameChainPoolKey = quotePoolKey;
    if (!address || !sameChainPoolKey || !originDep || isCrossChain) return;
    const amtMin = amountOut > 0
      ? parseUnits((amountOut * (1 - slippage / 100)).toFixed(tokenOut.decimals), tokenOut.decimals)
      : 0n;
    writeContract(
      {
        chainId: originChainId,
        address: originDep.swapRouter,
        abi: ROUTER_ABI,
        functionName: "swapExactTokensForTokens",
        args: [
          amtInRaw,
          amtMin,
          sameChainPoolKey.zeroForOne,
          sameChainPoolKey.key,
          "0x",
          address,
          BigInt(Math.floor(Date.now() / 1000) + deadline * 60),
        ],
      },
      {
        onSuccess: (hash) => {
          setAmountIn("");
          setPendingHash(hash);
          showResult({
            status: "pending",
            hash,
            msg: `Swapped ${numIn.toFixed(4)} ${tokenIn.symbol} → ${amountOut.toFixed(4)} ${tokenOut.symbol}`,
          });
        },
        onError: (e) => showResult({ status: "error", msg: e.message.split("\n")[0] }),
      }
    );
  }

  function handleCrossChainOpen() {
    if (!order || !orderId || !originDep?.intentSettler) return;
    writeContract(
      {
        chainId: originChainId,
        address: originDep.intentSettler,
        abi: SETTLER_ABI,
        functionName: "open",
        args: [{ fillDeadline: order.fillDeadline, orderDataType: order.orderDataType, orderData: order.orderData }],
      },
      {
        onSuccess: (hash) => {
          setAmountIn("");
          setPendingHash(hash);
          setTrackedOrder(orderId);
          showResult({
            status: "pending",
            hash,
            msg: `Order opened · ${numIn.toFixed(4)} ${tokenIn.symbol} → ${amountOut.toFixed(4)} ${tokenOut.symbol}`,
          });
        },
        onError: (e) => showResult({ status: "error", msg: e.message.split("\n")[0] }),
      }
    );
  }

  const btnLabel = !isConnected
    ? "Connect Wallet"
    : blockedReason
    ? blockedReason
    : onWrongChain
    ? `Switch to ${originDep?.short}`
    : numIn <= 0
    ? "Enter an amount"
    : isInsufficient
    ? `Insufficient ${tokenIn.symbol}`
    : needsApproval
    ? `Approve ${tokenIn.symbol}`
    : isPending
    ? "Submitting…"
    : isCrossChain
    ? "Open cross-chain order"
    : "Swap";

  const btnDisabled =
    isConnected && (!!blockedReason || (!onWrongChain && (numIn <= 0 || isInsufficient || isPending)));

  function handleBtn() {
    if (!isConnected) {
      const connector = connectors.find((c) => c.type === "injected") ?? connectors[0];
      if (connector) connect({ connector });
      return;
    }
    if (blockedReason) return;
    if (onWrongChain) { switchChain({ chainId: originChainId }); return; }
    if (needsApproval) { handleApprove(); return; }
    if (isCrossChain) handleCrossChainOpen();
    else handleSameChainSwap();
  }

  return (
    <div className="flex flex-col w-full">
      {/* Header */}
      <div className="flex items-center justify-between px-5 py-3.5" style={{ backgroundColor: color.surface1 }}>
        <span
          style={{
            fontFamily: typography.p2.family,
            fontSize: typography.p2.size,
            fontWeight: 500,
            letterSpacing: "-0.01em",
            color: color.textPrimary,
          }}
        >
          Swap
        </span>
        <div className="flex items-center gap-2.5">
          <div className="flex items-center gap-1.5 px-2.5 h-7" style={{ backgroundColor: color.surface2 }}>
            <span
              style={{
                fontFamily: typography.caption.family,
                fontSize: "11px",
                letterSpacing: "0.02em",
                color: color.textSecondary,
                whiteSpace: "nowrap",
              }}
            >
              {isCrossChain
                ? `${DEPLOYMENTS[tokenIn.chainId]?.short} → ${DEPLOYMENTS[tokenOut.chainId]?.short}`
                : originDep?.name}
            </span>
          </div>
          <button
            onClick={() => setShowSettings((v) => !v)}
            className="flex items-center justify-center w-7 h-7 hover:opacity-100 opacity-70 transition-opacity"
            style={{ cursor: "pointer" }}
          >
            <GearSix size={14} color={showSettings ? color.textPrimary : color.textMuted} weight="regular" />
          </button>
        </div>
      </div>

      {showSettings && (
        <div className="mt-px">
          <SettingsPanel
            slippage={slippage} setSlippage={setSlippage}
            deadline={deadline} setDeadline={setDeadline}
            onClose={() => setShowSettings(false)}
          />
        </div>
      )}

      {/* You pay */}
      <div className="mt-px relative">
        <TokenBox
          mode="in"
          token={tokenIn}
          balances={balances}
          selectedKey={inKey}
          excludedKey={outKey}
          value={amountIn}
          onChange={setAmountIn}
          onTokenSelect={handleInSelect}
          isConnected={isConnected}
          balanceReady={balanceReady}
          onFaucet={handleFaucet}
        />
      </div>

      {/* Flip */}
      <div className="relative" style={{ height: 0 }}>
        <div className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 z-10">
          <button
            onClick={flip}
            className="flex items-center justify-center w-9 h-9 hover:bg-(--color-surface-3) transition-colors"
            style={{
              backgroundColor: color.surface2,
              outline: `2px solid ${color.bg}`,
              cursor: "pointer",
              borderRadius: 2,
            }}
          >
            <ArrowDown size={14} color={color.textPrimary} weight="regular" />
          </button>
        </div>
      </div>

      {/* You receive */}
      <div className="mt-px">
        <TokenBox
          mode="out"
          token={tokenOut}
          balances={balances}
          selectedKey={outKey}
          excludedKey={inKey}
          value={amountOutStr}
          onTokenSelect={handleOutSelect}
          isConnected={isConnected}
        />
      </div>

      {blockedReason && (
        <div className="mt-px px-5 py-4" style={{ backgroundColor: color.surface1 }}>
          <span style={body("p3", color.warning)}>
            {blockedReason}. Cross-chain routes exist only between chains that have an
            intent settler deployed.
          </span>
        </div>
      )}

      {!blockedReason && numIn > 0 && amountOut > 0 && (
        <div className="mt-px">
          <SwapInfoPanel
            tokenIn={tokenIn} tokenOut={tokenOut}
            numIn={numIn} amountOut={amountOut}
            slippage={slippage} fee={100} isCrossChain={isCrossChain}
          />
        </div>
      )}

      {/* Action */}
      <button
        disabled={btnDisabled}
        onClick={handleBtn}
        className="w-full flex items-center justify-center h-12 mt-3 hover:opacity-90 transition-opacity"
        style={{
          backgroundColor: isInsufficient || blockedReason
            ? color.surface1
            : numIn <= 0 && isConnected && !onWrongChain
            ? color.surface1
            : color.textPrimary,
          color: isInsufficient
            ? color.error
            : blockedReason
            ? color.textMuted
            : numIn <= 0 && isConnected && !onWrongChain
            ? color.textMuted
            : color.bg,
          fontFamily: typography.p1.family,
          fontSize: typography.p1.size,
          fontWeight: 500,
          letterSpacing: "-0.01em",
          cursor: btnDisabled ? "not-allowed" : "pointer",
        }}
      >
        {btnLabel}
      </button>

      {trackedOrder && isCrossChain && (
        <OrderTracker
          originChainId={tokenIn.chainId}
          destChainId={tokenOut.chainId}
          orderId={trackedOrder}
          onDismiss={() => setTrackedOrder(undefined)}
        />
      )}

      {/* Result modal */}
      {swapResult && (() => {
        const pending = swapResult.status === "pending";
        const success = swapResult.status === "success";
        const successColor = success ? color.success : pending ? color.warning : color.error;
        const halves = swapResult.msg.replace(/^Swapped |^Order opened · /, "").split(" → ");
        const [inAmt = "", inSym = ""] = (halves[0] ?? "").split(" ");
        const [outAmt = "", outSym = ""] = (halves[1] ?? "").split(" ");

        return (
          <>
            <div
              onClick={() => setSwapResult(null)}
              style={{
                position: "fixed", inset: 0, zIndex: 9998,
                backgroundColor: "rgba(0,0,0,0.85)",
                backdropFilter: "blur(2px)",
              }}
            />
            <div
              style={{
                position: "fixed",
                top: "50%", left: "50%",
                transform: "translate(-50%, -50%)",
                zIndex: 9999,
                width: "min(440px, calc(100vw - 24px))",
                backgroundColor: color.bg,
              }}
              className="flex flex-col gap-px"
            >
              <div className="flex items-center justify-between px-5 py-4" style={{ backgroundColor: color.surface1 }}>
                <StatusPill healthy={success} label={pending ? "Confirming…" : success ? "Confirmed" : "Failed"} />
                <button onClick={() => setSwapResult(null)} className="hover:opacity-100 opacity-70 transition-opacity">
                  <X size={14} color={color.textMuted} weight="regular" />
                </button>
              </div>

              {halves.length === 2 ? (
                <div className="px-6 py-7 flex items-center gap-4" style={{ backgroundColor: color.surface1 }}>
                  <div className="flex-1">
                    <div style={{ ...LBL, color: color.textMuted, marginBottom: 10 }}>
                      From · {DEPLOYMENTS[tokenIn.chainId]?.short}
                    </div>
                    <div className="flex items-center gap-3">
                      <TokenIcon symbol={inSym} size={36} chainId={tokenIn.chainId} ringColor={color.surface1} />
                      <div>
                        <div
                          style={{
                            fontFamily: typography.h2.family,
                            fontSize: "26px",
                            fontWeight: 500,
                            letterSpacing: "-0.03em",
                            color: color.textPrimary,
                            lineHeight: 1,
                            fontVariantNumeric: "tabular-nums",
                          }}
                        >
                          {inAmt}
                        </div>
                        <div style={{ ...body("caption", color.textMuted), marginTop: 4 }}>{inSym}</div>
                      </div>
                    </div>
                  </div>
                  <ArrowDown size={18} color={color.textMuted} weight="regular" style={{ transform: "rotate(-90deg)" }} />
                  <div className="flex-1 text-right">
                    <div style={{ ...LBL, color: color.textMuted, marginBottom: 10 }}>
                      To · {DEPLOYMENTS[tokenOut.chainId]?.short}
                    </div>
                    <div className="flex items-center gap-3 justify-end">
                      <div>
                        <div
                          style={{
                            fontFamily: typography.h2.family,
                            fontSize: "26px",
                            fontWeight: 500,
                            letterSpacing: "-0.03em",
                            color: successColor,
                            lineHeight: 1,
                            fontVariantNumeric: "tabular-nums",
                          }}
                        >
                          {outAmt}
                        </div>
                        <div style={{ ...body("caption", color.textMuted), marginTop: 4 }}>{outSym}</div>
                      </div>
                      <TokenIcon symbol={outSym} size={36} chainId={tokenOut.chainId} ringColor={color.surface1} />
                    </div>
                  </div>
                </div>
              ) : (
                <div className="px-5 py-5" style={{ backgroundColor: color.surface1 }}>
                  <p style={{ ...body("p3", color.textSecondary), lineHeight: 1.6 }}>{swapResult.msg}</p>
                </div>
              )}

              <div className="flex items-center justify-between gap-3 px-5 py-3" style={{ backgroundColor: color.surface1 }}>
                {swapResult.hash ? (
                  <a
                    href={explorerTx(originChainId, swapResult.hash)}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex items-center gap-1.5 hover:opacity-100 opacity-70 transition-opacity"
                    style={body("caption", color.textMuted)}
                  >
                    {swapResult.hash.slice(0, 12)}…{swapResult.hash.slice(-6)}
                    <ArrowSquareOut size={11} weight="regular" />
                  </a>
                ) : <span />}
                <button
                  onClick={() => setSwapResult(null)}
                  className="hover:opacity-100 opacity-70 transition-opacity"
                  style={{ ...LBL, color: color.textPrimary, cursor: "pointer" }}
                >
                  Dismiss
                </button>
              </div>
            </div>
          </>
        );
      })()}
    </div>
  );
}
