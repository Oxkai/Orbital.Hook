"use client";

import { useState, useCallback, useEffect, useRef } from "react";
import { color, typography } from "@/constants";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { usePool } from "@/lib/hooks/usePool";
import { usePositions, useTickStatus, fmtWad } from "@/lib/hooks/usePositions";
import { useTokenBalances, useTokenAllowances } from "@/lib/hooks/useTokenBalances";
import { fmtUSD } from "@/lib/mock/data";
import { POOL_ADDRESSES, HOOK_ADDRESS, HOOK_LP_ABI, ERC20_ABI } from "@/lib/contracts";
import { type Address, type Hash, maxUint256 } from "viem";
import { TokenDAI, TokenUSDT, TokenUSDC, TokenFRAX } from "@token-icons/react";
import { X, Circle, CurrencyDollar, Pulse, TrendUp } from "@phosphor-icons/react";

const ZERO = "0x0000000000000000000000000000000000000000" as Address;
function useAllPools(addresses: readonly Address[]) {
  const a = usePool(addresses[0] ?? ZERO);
  const b = usePool(addresses[1] ?? ZERO);
  const c = usePool(addresses[2] ?? ZERO);
  const d = usePool(addresses[3] ?? ZERO);
  return [a, b, c, d].slice(0, addresses.length);
}
import { IncreaseLiquidityModal } from "@/components/app/lp/IncreaseLiquidityModal";
import { DecreaseLiquidityModal } from "@/components/app/lp/DecreaseLiquidityModal";
import { CollectFeesModal }       from "@/components/app/lp/CollectFeesModal";
import { BurnPositionModal }      from "@/components/app/lp/BurnPositionModal";
import type { TokenAmount }       from "@/components/app/lp/IncreaseLiquidityModal";

const WAD = 1e18;

const TOKEN_ICON_MAP: Record<string, React.ElementType> = {
  DAI: TokenDAI, USDT: TokenUSDT, USDC: TokenUSDC, FRAX: TokenFRAX,
};
const TOKEN_COLOR_MAP: Record<string, string> = { CRVUSD: "#FF6B35" };

function TokenIcon({ symbol, size = 22 }: { symbol: string; size?: number }) {
  const Icon = TOKEN_ICON_MAP[symbol.toUpperCase()];
  if (Icon) return <Icon size={size} variant="branded" />;
  const bg = TOKEN_COLOR_MAP[symbol.toUpperCase()] ?? "#555";
  return (
    <span style={{ width: size, height: size, borderRadius: "50%", backgroundColor: bg, display: "inline-flex", alignItems: "center", justifyContent: "center", flexShrink: 0, fontSize: Math.max(6, size * 0.38), color: "#fff", fontFamily: typography.caption.family, fontWeight: 700 }}>
      {symbol.slice(0, 2).toUpperCase()}
    </span>
  );
}

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

function mono(size = "12px", col: string = color.textSecondary) {
  return {
    fontFamily: "var(--font-mono)" as const,
    fontSize: size,
    color: col as never,
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

function StatItem({ icon, label, value, accent }: {
  icon: React.ReactNode;
  label: string;
  value: string;
  accent?: string;
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center gap-1.5">
        <span style={{ color: color.textMuted, lineHeight: 0 }}>{icon}</span>
        <span style={{ ...LBL, color: color.textMuted }}>{label}</span>
      </div>
      <span style={{ ...body("p1", accent ?? color.textPrimary), fontWeight: 500 }}>
        {value}
      </span>
    </div>
  );
}

// ─── Discriminated result union ───────────────────────────────────────────────

type TxResult =
  | { kind: "increase"; hash: string; tokenId: bigint; amounts: TokenAmount[]; rWadAdded: number }
  | { kind: "decrease"; hash: string; tokenId: bigint; amounts: TokenAmount[]; rWadRemoved: number; rWadRemaining: number }
  | { kind: "collect";  hash: string; tokenId: bigint; fees: TokenAmount[] }
  | { kind: "burn";     hash: string; tokenId: bigint; tokens: TokenAmount[]; finalLiquidity: number }
  | { kind: "error";    title: string; msg: string };

// ─── Amount modal (Increase / Decrease) ──────────────────────────────────────

function ModalFrame({ children, width = 400 }: { children: React.ReactNode; width?: number }) {
  return (
    <div
      style={{
        position: "fixed",
        top: "50%",
        left: "50%",
        transform: "translate(-50%,-50%)",
        zIndex: 9999,
        width: `min(${width}px, calc(100vw - 24px))`,
        backgroundColor: color.bg,
      }}
      className="flex flex-col gap-px"
    >
      {children}
    </div>
  );
}

function ModalBackdrop({ onClose }: { onClose: () => void }) {
  return (
    <div
      onClick={onClose}
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 9998,
        backgroundColor: "rgba(0,0,0,0.85)",
        backdropFilter: "blur(2px)",
      }}
    />
  );
}

function ModalHeader({ title, onClose }: { title: string; onClose: () => void }) {
  return (
    <div
      className="flex items-center justify-between px-5 py-3.5"
      style={{ backgroundColor: color.surface1 }}
    >
      <span style={{ ...LBL, color: color.textMuted }}>{title}</span>
      <button onClick={onClose} className="hover:opacity-100 opacity-70 transition-opacity">
        <X size={13} color={color.textMuted} weight="regular" />
      </button>
    </div>
  );
}

function AmountModal({ title, maxLabel, maxValue, onConfirm, onClose, isPending }: {
  title: string; maxLabel: string; maxValue: string;
  onConfirm: (amount: string) => void; onClose: () => void; isPending: boolean;
}) {
  const [val, setVal] = useState("");
  const num = parseFloat(val) || 0;
  const max = parseFloat(maxValue) || 0;
  const valid = num > 0 && num <= max + 0.001 && !isPending;

  return (
    <>
      <ModalBackdrop onClose={onClose} />
      <ModalFrame>
        <ModalHeader title={title} onClose={onClose} />

        {/* Input row */}
        <div className="px-5 py-5 flex flex-col gap-3" style={{ backgroundColor: color.surface1 }}>
          <div className="flex items-center justify-between">
            <span style={body("caption", color.textMuted)}>USD amount</span>
            <button
              onClick={() => setVal(maxValue)}
              className="hover:opacity-90 transition-opacity"
              style={{
                fontFamily: typography.caption.family,
                fontSize: "11px",
                fontWeight: 500,
                letterSpacing: "0.06em",
                textTransform: "uppercase",
                color: color.accent,
                backgroundColor: `${color.accent}1f`,
                padding: "3px 9px",
                borderRadius: 2,
                cursor: "pointer",
              }}
            >
              {maxLabel} {maxValue ? fmtUSD(parseFloat(maxValue)) : ""}
            </button>
          </div>
          <div className="flex items-baseline gap-2">
            <span
              style={{
                fontFamily: typography.h1.family,
                fontSize: "26px",
                fontWeight: 500,
                color: color.textMuted,
                letterSpacing: "-0.02em",
              }}
            >
              $
            </span>
            <input
              type="text" inputMode="decimal" placeholder="0" value={val} autoFocus
              onChange={e => { if (/^\d*(?:\.\d*)?$/.test(e.target.value)) setVal(e.target.value); }}
              className="flex-1 bg-transparent outline-none"
              style={{
                fontFamily: typography.h1.family,
                fontSize: "32px",
                letterSpacing: "-0.03em",
                color: val ? color.textPrimary : color.textMuted,
                lineHeight: 1,
                fontVariantNumeric: "tabular-nums",
                fontWeight: 500,
              }}
            />
          </div>
        </div>

        {/* Action row */}
        <div className="px-5 py-3" style={{ backgroundColor: color.surface1 }}>
          <button
            disabled={!valid}
            onClick={() => onConfirm(val)}
            className="w-full flex items-center justify-center h-11 hover:opacity-90 transition-opacity"
            style={{
              backgroundColor: valid ? color.textPrimary : color.surface2,
              color: valid ? color.bg : color.textMuted,
              fontFamily: typography.p2.family,
              fontSize: typography.p2.size,
              fontWeight: 500,
              letterSpacing: "-0.01em",
              cursor: !valid ? "not-allowed" : "pointer",
            }}
          >
            {isPending ? "Submitting…" : "Confirm"}
          </button>
        </div>
      </ModalFrame>
    </>
  );
}

function ConfirmModal({ title, body: bodyText, confirmLabel, onConfirm, onClose, isPending, danger }: {
  title: string; body: string; confirmLabel: string;
  onConfirm: () => void; onClose: () => void; isPending: boolean; danger?: boolean;
}) {
  return (
    <>
      <ModalBackdrop onClose={onClose} />
      <ModalFrame width={380}>
        <ModalHeader title={title} onClose={onClose} />

        {/* Body */}
        <div className="px-5 py-5" style={{ backgroundColor: color.surface1 }}>
          <p style={{ ...body("p3", color.textSecondary), lineHeight: 1.6 }}>{bodyText}</p>
        </div>

        {/* Actions */}
        <div className="flex gap-2 px-5 py-3" style={{ backgroundColor: color.surface1 }}>
          <button
            onClick={onClose}
            className="flex-1 flex items-center justify-center h-10 hover:opacity-90 transition-opacity"
            style={{
              backgroundColor: color.surface2,
              color: color.textSecondary,
              fontFamily: typography.p2.family,
              fontSize: typography.p2.size,
              cursor: "pointer",
            }}
          >
            Cancel
          </button>
          <button
            disabled={isPending}
            onClick={onConfirm}
            className="flex-1 flex items-center justify-center h-10 hover:opacity-90 transition-opacity"
            style={{
              backgroundColor: danger ? color.error : color.textPrimary,
              color: color.bg,
              fontFamily: typography.p2.family,
              fontSize: typography.p2.size,
              fontWeight: 500,
              cursor: isPending ? "not-allowed" : "pointer",
              opacity: isPending ? 0.6 : 1,
            }}
          >
            {isPending ? "Submitting…" : confirmLabel}
          </button>
        </div>
      </ModalFrame>
    </>
  );
}

// ─── Position row ─────────────────────────────────────────────────────────────

type ModalState = { type: "increase" } | { type: "decrease" } | { type: "collect" } | { type: "burn" } | null;

function PositionRow({
  tokenId, poolAddress, tickIndex, rWad, pool, onActionDone, onTxResult,
}: {
  tokenId: bigint; poolAddress: Address; tickIndex: number; rWad: bigint;
  pool: ReturnType<typeof usePool>["pool"];
  onActionDone: () => void;
  onTxResult: (r: TxResult) => void;
}) {
  const { address } = useAccount();
  const tick    = useTickStatus(poolAddress, tickIndex, !!pool);
  const rUSD    = fmtWad(rWad);
  const rNum    = Number(rWad) / WAD;

  const [modal,       setModal]       = useState<ModalState>(null);
  const [pendingHash, setPendingHash] = useState<Hash | undefined>();
  const [pendingKind, setPendingKind] = useState<"increase" | "decrease" | "collect" | "burn">("collect");
  // store the USD amounts typed by user to display in popup
  const [pendingUsd, setPendingUsd]   = useState(0);

  const { writeContract, isPending } = useWriteContract();

  const tokens     = pool?.tokens ?? [];
  const tokenAddrs = tokens.map(t => t.address as Address);
  const { allowances, refetch: refetchAllowances } = useTokenAllowances(tokenAddrs, address, HOOK_ADDRESS);
  const { balances } = useTokenBalances(tokenAddrs, address);
  // Maximum depositable USD = n * the smallest per-token balance (each token contributes equally)
  const n          = tokenAddrs.length || 1;
  const minBalance = balances.length > 0 ? Math.min(...balances) : 0;
  const walletUSD  = minBalance * n;

  const { isSuccess: txDone } = useWaitForTransactionReceipt({ hash: pendingHash, query: { enabled: !!pendingHash } });

  // Build equal-split token amounts array for display (real amounts from receipt decode not available client-side)
  function splitAmounts(totalUsd: number): TokenAmount[] {
    const perToken = totalUsd / n;
    return tokens.map(t => ({ symbol: t.symbol, color: t.color, amount: perToken }));
  }

  const handleTxDone = useCallback((hash: Hash) => {
    setPendingHash(undefined);
    setModal(null);
    onActionDone();

    if (pendingKind === "increase") {
      onTxResult({ kind: "increase", hash, tokenId, amounts: splitAmounts(pendingUsd), rWadAdded: pendingUsd });
    } else if (pendingKind === "decrease") {
      const remaining = Math.max(0, rNum - pendingUsd);
      onTxResult({ kind: "decrease", hash, tokenId, amounts: splitAmounts(pendingUsd), rWadRemoved: pendingUsd, rWadRemaining: remaining });
    } else if (pendingKind === "collect") {
      onTxResult({ kind: "collect", hash, tokenId, fees: splitAmounts(0) });
    } else if (pendingKind === "burn") {
      onTxResult({ kind: "burn", hash, tokenId, tokens: tokens.map(t => ({ symbol: t.symbol, color: t.color, amount: 0 })), finalLiquidity: rNum });
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [onActionDone, onTxResult, pendingKind, pendingUsd, rNum, tokenId, tokens]);

  useEffect(() => {
    if (txDone && pendingHash) handleTxDone(pendingHash);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [txDone, pendingHash]);

  const deadline = () => BigInt(Math.floor(Date.now() / 1000) + 600);

  // maxAmounts/minAmounts arrays sized to the asset count. Per-asset deposit is
  // always < rWad, so rWad is a safe spending ceiling; 0 is a safe withdraw floor.
  const maxAmounts = (rWad_: bigint) => Array(n).fill(rWad_);
  const zeroFloor = () => Array(n).fill(0n);

  function handleIncrease(amountStr: string) {
    if (!address) return;
    const usd    = parseFloat(amountStr);
    const rWadNew = BigInt(Math.round(usd * WAD));
    const needsApproval = tokenAddrs.findIndex((_, i) => (allowances[i] ?? 0n) < rWadNew);
    if (needsApproval >= 0) {
      writeContract(
        { address: tokenAddrs[needsApproval], abi: ERC20_ABI, functionName: "approve", args: [HOOK_ADDRESS, maxUint256] },
        { onSuccess: () => refetchAllowances() }
      );
      return;
    }
    setPendingKind("increase");
    setPendingUsd(usd);
    // Add to the existing tick by re-using its kWad (the hook merges by k).
    writeContract(
      { address: HOOK_ADDRESS, abi: HOOK_LP_ABI, functionName: "addLiquidity", args: [tick.kWad, rWadNew, maxAmounts(rWadNew)] },
      {
        onSuccess: (hash) => setPendingHash(hash),
        onError: (e) => { setModal(null); onTxResult({ kind: "error", title: "Increase liquidity", msg: e.message.split("\n")[0] }); },
      }
    );
  }

  function handleDecrease(amountStr: string) {
    if (!address) return;
    const usd    = parseFloat(amountStr);
    const rWadOut = BigInt(Math.round(usd * WAD));
    setPendingKind("decrease");
    setPendingUsd(usd);
    writeContract(
      { address: HOOK_ADDRESS, abi: HOOK_LP_ABI, functionName: "removeLiquidity", args: [tokenId, rWadOut, zeroFloor()] },
      {
        onSuccess: (hash) => setPendingHash(hash),
        onError: (e) => { setModal(null); onTxResult({ kind: "error", title: "Decrease liquidity", msg: e.message.split("\n")[0] }); },
      }
    );
  }

  function handleCollect() {
    if (!address) return;
    setPendingKind("collect");
    setPendingUsd(0);
    writeContract(
      { address: HOOK_ADDRESS, abi: HOOK_LP_ABI, functionName: "collect", args: [tokenId] },
      {
        onSuccess: (hash) => setPendingHash(hash),
        onError: (e) => { setModal(null); onTxResult({ kind: "error", title: "Collect fees", msg: e.message.split("\n")[0] }); },
      }
    );
  }

  function handleBurn() {
    if (!address) return;
    setPendingKind("burn");
    setPendingUsd(rNum);
    // "Burn" = remove the entire remaining position (the full share balance).
    writeContract(
      { address: HOOK_ADDRESS, abi: HOOK_LP_ABI, functionName: "removeLiquidity", args: [tokenId, rWad, zeroFloor()] },
      {
        onSuccess: (hash) => setPendingHash(hash),
        onError: (e) => { setModal(null); onTxResult({ kind: "error", title: "Burn position", msg: e.message.split("\n")[0] }); },
      }
    );
  }

  const pairLabel = pool?.tokens.map(t => t.symbol).join(" / ") ?? "Pool";

  return (
    <>
      <div className="flex flex-col gap-px">
        {/* ── Identity row ─────────────────────────────────────── */}
        <div
          className="flex items-center justify-between gap-3 px-5 py-4"
          style={{ backgroundColor: color.surface1 }}
        >
          <div className="flex items-center gap-3.5 min-w-0">
            <div className="flex shrink-0 items-center">
              {pool?.tokens.map((t, i) => (
                <span
                  key={t.address}
                  style={{
                    marginLeft: i === 0 ? 0 : -8,
                    outline: `2px solid ${color.surface1}`,
                    borderRadius: "50%",
                    lineHeight: 0,
                    position: "relative",
                    zIndex: (pool?.tokens.length ?? 0) - i,
                  }}
                >
                  <TokenIcon symbol={t.symbol} size={24} />
                </span>
              ))}
            </div>
            <div className="flex flex-col gap-0.5 min-w-0">
              <div className="flex items-center gap-2">
                <span
                  style={{
                    fontFamily: typography.h3.family,
                    fontSize: "17px",
                    fontWeight: 500,
                    letterSpacing: "-0.02em",
                    color: color.textPrimary,
                    whiteSpace: "nowrap",
                  }}
                >
                  {pairLabel}
                </span>
                <span
                  style={{
                    ...body("caption", color.textMuted),
                    backgroundColor: color.surface2,
                    padding: "2px 7px",
                    borderRadius: 2,
                  }}
                >
                  #{tokenId.toString()}
                </span>
              </div>
              <span style={body("caption", color.textMuted)}>
                Tick #{tickIndex} · {pool?.tokens.length ?? 0}-asset pool
              </span>
            </div>
          </div>
          <StatusPill healthy={tick.isInterior} label={tick.isInterior ? "Active" : "Paused"} />
        </div>

        {/* ── Stats row ────────────────────────────────────────── */}
        <div
          className="grid grid-cols-3 px-5 py-4 gap-x-6"
          style={{ backgroundColor: color.surface1 }}
        >
          <StatItem
            icon={<CurrencyDollar size={11} weight="regular" />}
            label="Liquidity"
            value={rUSD}
          />
          <StatItem
            icon={<Pulse size={11} weight="regular" />}
            label="Tick"
            value={`#${tickIndex}`}
          />
          <StatItem
            icon={<TrendUp size={11} weight="regular" />}
            label="Status"
            value={tick.isInterior ? "Earning fees" : "Paused"}
            accent={tick.isInterior ? color.success : color.warning}
          />
        </div>

        {/* ── Actions row ──────────────────────────────────────── */}
        <div
          className="flex flex-wrap gap-2 px-5 py-3"
          style={{ backgroundColor: color.surface1 }}
        >
          {([
            { label: "Increase", onClick: () => setModal({ type: "increase" }) },
            { label: "Decrease", onClick: () => setModal({ type: "decrease" }), disabled: rNum <= 0 },
            { label: "Collect",  onClick: () => setModal({ type: "collect" }) },
            { label: "Burn",     onClick: () => setModal({ type: "burn" }), danger: true },
          ] as { label: string; onClick: () => void; disabled?: boolean; danger?: boolean }[]).map(btn => (
            <button
              key={btn.label}
              disabled={!!btn.disabled}
              onClick={btn.onClick}
              className="flex items-center justify-center h-9 px-4 hover:opacity-90 transition-opacity"
              style={{
                backgroundColor: btn.danger ? "transparent" : color.surface2,
                color: btn.danger ? color.error : btn.disabled ? color.textMuted : color.textPrimary,
                border: btn.danger ? `1px solid ${color.error}55` : "none",
                fontFamily: typography.p2.family,
                fontSize: typography.p2.size,
                letterSpacing: "-0.01em",
                cursor: btn.disabled ? "not-allowed" : "pointer",
                opacity: btn.disabled ? 0.4 : 1,
              }}
            >
              {btn.label}
            </button>
          ))}
        </div>
      </div>

      {/* Input modals */}
      {modal?.type === "increase" && (
        <AmountModal title={`Increase Position #${tokenId}`} maxLabel="Wallet" maxValue={walletUSD.toFixed(2)}
          onConfirm={handleIncrease} onClose={() => setModal(null)} isPending={isPending} />
      )}
      {modal?.type === "decrease" && (
        <AmountModal title={`Decrease Position #${tokenId}`} maxLabel="Max" maxValue={rNum.toFixed(2)}
          onConfirm={handleDecrease} onClose={() => setModal(null)} isPending={isPending} />
      )}
      {modal?.type === "collect" && (
        <ConfirmModal title={`Collect fees — Position #${tokenId}`}
          body="Collected fees will be sent to your wallet. Your liquidity position remains unchanged."
          confirmLabel="Collect fees" onConfirm={handleCollect} onClose={() => setModal(null)} isPending={isPending} />
      )}
      {modal?.type === "burn" && (
        <ConfirmModal title={`Burn Position #${tokenId}`}
          body="This permanently removes the position NFT. Decrease liquidity to zero and collect fees first."
          confirmLabel="Burn position" onConfirm={handleBurn} onClose={() => setModal(null)} isPending={isPending} danger />
      )}
    </>
  );
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function PositionsPage() {
  const { address } = useAccount();

  // Load all known pools so each position row gets the right token metadata
  const poolHooks = useAllPools(POOL_ADDRESSES);
  const poolMap: Record<string, ReturnType<typeof usePool>["pool"]> = Object.fromEntries(
    POOL_ADDRESSES.map((addr, i) => [addr.toLowerCase(), poolHooks[i].pool])
  );
  // poolHooks is a new array each render; capture refetch fns in a ref so useCallback stays stable
  const poolRefetchsRef = useRef(poolHooks.map(h => h.refetch));
  poolRefetchsRef.current = poolHooks.map(h => h.refetch);
  const refetchPools = useCallback(() => { poolRefetchsRef.current.forEach(fn => fn()); }, []);

  const { positions, isLoading, refetch: refetchPositions } = usePositions(address);
  const [txResult, setTxResult] = useState<TxResult | null>(null);

  const totalR = positions.reduce((s, p) => s + Number(p.rWad), 0);

  const handleActionDone = useCallback(() => {
    refetchPools();
    refetchPositions();
  }, [refetchPools, refetchPositions]);

  return (
    <section className="flex-1 flex flex-col py-8 sm:py-10">
      {/* ── Hero ─────────────────────────────────────────────────── */}
      <header className="flex flex-col gap-1.5 mb-7">
        <h1
          style={{
            fontFamily: typography.h2.family,
            fontSize: typography.h2.size,
            lineHeight: typography.h2.lineHeight,
            letterSpacing: typography.h2.letterSpacing,
            fontWeight: 500,
            color: color.textPrimary,
          }}
        >
          Positions
        </h1>
        <p
          style={{
            fontFamily: typography.p2.family,
            fontSize: typography.p2.size,
            color: color.textMuted,
            lineHeight: typography.p2.lineHeight,
          }}
        >
          Manage your liquidity positions, collect fees, and adjust ranges.
        </p>
      </header>

      {/* ── Body ─────────────────────────────────────────────────── */}
      {!address ? (
        <div
          className="flex items-center justify-center py-20"
          style={{ backgroundColor: color.surface1 }}
        >
          <span style={body("p3", color.textMuted)}>
            Connect your wallet to see your positions.
          </span>
        </div>
      ) : isLoading ? (
        <div
          className="flex items-center justify-center py-20"
          style={{ backgroundColor: color.surface1 }}
        >
          <span style={body("p3", color.textMuted)}>Fetching positions…</span>
        </div>
      ) : positions.length === 0 ? (
        <div
          className="flex items-center justify-center py-20"
          style={{ backgroundColor: color.surface1 }}
        >
          <span style={body("p3", color.textMuted)}>
            No positions found. Add liquidity to get started.
          </span>
        </div>
      ) : (
        <div className="flex flex-col gap-3">
          {positions.map(pos => (
            <PositionRow
              key={pos.tokenId.toString()}
              tokenId={pos.tokenId}
              poolAddress={pos.poolAddress}
              tickIndex={pos.tickIndex}
              rWad={pos.rWad}
              pool={poolMap[pos.poolAddress.toLowerCase()] ?? null}
              onActionDone={handleActionDone}
              onTxResult={setTxResult}
            />
          ))}
        </div>
      )}

      {/* Per-action result modals */}
      {txResult?.kind === "increase" && (
        <IncreaseLiquidityModal
          tokenId={txResult.tokenId} hash={txResult.hash}
          amounts={txResult.amounts} rWadAdded={txResult.rWadAdded}
          onClose={() => setTxResult(null)}
        />
      )}
      {txResult?.kind === "decrease" && (
        <DecreaseLiquidityModal
          tokenId={txResult.tokenId} hash={txResult.hash}
          amounts={txResult.amounts} rWadRemoved={txResult.rWadRemoved} rWadRemaining={txResult.rWadRemaining}
          onClose={() => setTxResult(null)}
        />
      )}
      {txResult?.kind === "collect" && (
        <CollectFeesModal
          tokenId={txResult.tokenId} hash={txResult.hash}
          fees={txResult.fees}
          onClose={() => setTxResult(null)}
        />
      )}
      {txResult?.kind === "burn" && (
        <BurnPositionModal
          tokenId={txResult.tokenId} hash={txResult.hash}
          tokens={txResult.tokens} finalLiquidity={txResult.finalLiquidity}
          onClose={() => setTxResult(null)}
        />
      )}

      {/* Error modal */}
      {txResult?.kind === "error" && (
        <>
          <ModalBackdrop onClose={() => setTxResult(null)} />
          <ModalFrame width={400}>
            <div
              className="flex items-center justify-between px-5 py-3.5"
              style={{ backgroundColor: color.surface1 }}
            >
              <span
                className="inline-flex items-center gap-1.5"
                style={{
                  backgroundColor: `${color.error}1f`,
                  color: color.error,
                  fontFamily: typography.caption.family,
                  fontSize: "11px",
                  fontWeight: 500,
                  letterSpacing: "0.04em",
                  padding: "3px 9px",
                  borderRadius: 999,
                  whiteSpace: "nowrap",
                }}
              >
                <Circle size={6} color={color.error} weight="fill" />
                {txResult.title} failed
              </span>
              <button
                onClick={() => setTxResult(null)}
                className="hover:opacity-100 opacity-70 transition-opacity"
              >
                <X size={13} color={color.textMuted} weight="regular" />
              </button>
            </div>
            <div className="px-5 py-5" style={{ backgroundColor: color.surface1 }}>
              <p style={{ ...body("p3", color.textSecondary), lineHeight: 1.6, wordBreak: "break-word" as const }}>
                {txResult.msg}
              </p>
            </div>
          </ModalFrame>
        </>
      )}
    </section>
  );
}
