"use client";

import { useState, useCallback, useEffect } from "react";
import { color, typography } from "@/constants";
import { useAccount, useConfig, useSwitchChain, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { usePool } from "@/lib/hooks/usePool";
import { usePositions, useTickStatus } from "@/lib/hooks/usePositions";
import { fetchDepositQuote } from "@/lib/hooks/useDepositQuote";
import { positionValueWad } from "@/lib/orbital/liquidity";
import { useTokenBalances, useTokenAllowances } from "@/lib/hooks/useTokenBalances";
import { fmtUSD } from "@/lib/mock/data";
import { HOOK_LP_ABI, ERC20_ABI } from "@/lib/contracts";
import { DEPLOYMENTS, type PoolType } from "@/lib/crosschain";
import { type Address, type Hash, type TransactionReceipt, maxUint256, parseAbi, parseEventLogs } from "viem";
import { X, Circle, CurrencyDollar, Pulse, TrendUp } from "@phosphor-icons/react";

import { IncreaseLiquidityModal } from "@/components/app/lp/IncreaseLiquidityModal";
import { DecreaseLiquidityModal } from "@/components/app/lp/DecreaseLiquidityModal";
import { CollectFeesModal }       from "@/components/app/lp/CollectFeesModal";
import { BurnPositionModal }      from "@/components/app/lp/BurnPositionModal";
import type { TokenAmount }       from "@/components/app/lp/IncreaseLiquidityModal";
import { TokenIcon } from "@/components/app/shared/TokenIcon";
import { ChainBadge } from "@/components/app/shared/ChainBadge";
import { PoolTypeTag } from "@/components/app/shared/PoolTypeTag";

/// Mint event, to learn the tick (position id) a new deposit landed on.
const MINT_EVENT = parseAbi([
  "event Mint(address indexed recipient, uint256 indexed tickIdx, uint256 kWad, uint256 rWad, uint256[] amounts)",
]);

const WAD = 1e18;

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
  tokenId, poolAddress, chainId, poolType, tickIndex, rWad, onActionDone, onTxResult,
}: {
  tokenId: bigint; poolAddress: Address; chainId: number; poolType: PoolType; tickIndex: number; rWad: bigint;
  onActionDone: () => void;
  onTxResult: (r: TxResult) => void;
}) {
  const { address, chainId: walletChainId } = useAccount();
  const { switchChain } = useSwitchChain();
  // Each row reads its OWN pool on its own chain. Rows of the same pool share
  // the query, so this costs nothing over a page-level lookup.
  const { pool, refetch: refetchPool } = usePool(poolAddress, { chainId });
  const tick    = useTickStatus(poolAddress, tickIndex, chainId, !!pool);
  const onChain = walletChainId === chainId;
  const chainName = DEPLOYMENTS[chainId]?.name ?? `chain ${chainId}`;
  const config  = useConfig();
  // What the position is actually worth: its share of the pool's reserves less
  // its share of the tick's virtual reserve (a concentrated band's radius is far
  // larger than the capital behind it, so the radius is not a value).
  const valueWad = pool
    ? positionValueWad(pool.reservesVirtual, pool.rIntWad, tick.rWad, tick.virtualWad, rWad)
    : 0n;
  const valueUsd = Number(valueWad) / WAD;

  const [modal,       setModal]       = useState<ModalState>(null);
  const [pendingHash, setPendingHash] = useState<Hash | undefined>();
  const [pendingKind, setPendingKind] = useState<"increase" | "decrease" | "collect" | "burn">("collect");
  // store the USD amounts typed by user to display in popup
  const [pendingUsd, setPendingUsd]   = useState(0);

  const { writeContract, isPending } = useWriteContract();

  const tokens     = pool?.tokens ?? [];
  const tokenAddrs = tokens.map(t => t.address as Address);
  const { allowances, refetch: refetchAllowances } = useTokenAllowances(tokenAddrs, address, poolAddress, chainId);
  const { balances } = useTokenBalances(tokenAddrs, address, chainId);
  // Maximum depositable USD = n * the smallest per-token balance (each token contributes equally)
  const n          = tokenAddrs.length || 1;
  const minBalance = balances.length > 0 ? Math.min(...balances) : 0;
  const walletUSD  = minBalance * n;

  const { isSuccess: txDone, data: receipt } = useWaitForTransactionReceipt({ chainId, hash: pendingHash, query: { enabled: !!pendingHash } });

  // Build equal-split token amounts array for display (real amounts from receipt decode not available client-side)
  function splitAmounts(totalUsd: number): TokenAmount[] {
    const perToken = totalUsd / n;
    return tokens.map(t => ({ symbol: t.symbol, color: t.color, amount: perToken }));
  }

  const handleTxDone = useCallback((hash: Hash, txReceipt: TransactionReceipt | undefined) => {
    setPendingHash(undefined);
    setModal(null);
    refetchPool();
    onActionDone();

    if (pendingKind === "increase") {
      // Every mint opens its own tick, so the deposit is a NEW position. Report
      // the id it actually landed on, read from the receipt's Mint event.
      const minted = txReceipt
        ? parseEventLogs({ abi: MINT_EVENT, logs: txReceipt.logs, eventName: "Mint" })
            .find((l) => l.address.toLowerCase() === poolAddress.toLowerCase())?.args.tickIdx
        : undefined;
      onTxResult({ kind: "increase", hash, tokenId: minted ?? tokenId, amounts: splitAmounts(pendingUsd), rWadAdded: pendingUsd });
    } else if (pendingKind === "decrease") {
      const remaining = Math.max(0, valueUsd - pendingUsd);
      onTxResult({ kind: "decrease", hash, tokenId, amounts: splitAmounts(pendingUsd), rWadRemoved: pendingUsd, rWadRemaining: remaining });
    } else if (pendingKind === "collect") {
      onTxResult({ kind: "collect", hash, tokenId, fees: splitAmounts(0) });
    } else if (pendingKind === "burn") {
      onTxResult({ kind: "burn", hash, tokenId, tokens: splitAmounts(pendingUsd), finalLiquidity: pendingUsd });
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [onActionDone, onTxResult, pendingKind, pendingUsd, valueUsd, tokenId, tokens, refetchPool, poolAddress]);

  useEffect(() => {
    if (txDone && pendingHash) handleTxDone(pendingHash, receipt);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [txDone, pendingHash]);

  const deadline = () => BigInt(Math.floor(Date.now() / 1000) + 600);

  const zeroFloor = () => Array(n).fill(0n);

  async function handleIncrease(amountStr: string) {
    if (!address || tick.rWad === 0n) return;
    const usd = parseFloat(amountStr);
    if (!(usd > 0)) return;
    // Quote a new position at THIS position's band (its kNorm), worth `usd`.
    const quote = await fetchDepositQuote(config, {
      pool: poolAddress,
      chainId,
      n,
      kNormWad: (tick.kWad * BigInt(WAD)) / tick.rWad,
      valueWad: BigInt(Math.round(usd * 1e6)) * 10n ** 12n,
    });
    if (quote.error || quote.rWad === 0n) {
      setModal(null);
      onTxResult({ kind: "error", title: "Add at this band", msg: quote.error ?? "Could not price this deposit." });
      return;
    }
    // Allowances are raw token units: compare with the raw deposit.
    const needsApproval = tokenAddrs.findIndex((_, i) => (allowances[i] ?? 0n) < (quote.amountsRaw[i] ?? 0n));
    if (needsApproval >= 0) {
      writeContract(
        { chainId, address: tokenAddrs[needsApproval], abi: ERC20_ABI, functionName: "approve", args: [poolAddress, maxUint256] },
        { onSuccess: () => refetchAllowances() }
      );
      return;
    }
    setPendingKind("increase");
    setPendingUsd(usd);
    // Deposit at this position's band (its k). Every mint gets its own tick,
    // so this opens a NEW position at the same band rather than growing this one.
    // Each asset may cost at most its quote plus 0.5%, should the pool move.
    const maxAmounts = quote.amountsWad.map((a) => a + a / 200n + 1n);
    writeContract(
      { chainId, address: poolAddress, abi: HOOK_LP_ABI, functionName: "addLiquidity", args: [quote.kWad, quote.rWad, maxAmounts] },
      {
        onSuccess: (hash) => setPendingHash(hash),
        onError: (e) => { setModal(null); onTxResult({ kind: "error", title: "Increase liquidity", msg: e.message.split("\n")[0] }); },
      }
    );
  }

  function handleDecrease(amountStr: string) {
    if (!address || valueWad === 0n) return;
    const usd    = parseFloat(amountStr);
    if (!(usd > 0)) return;
    // Withdrawals are pro-rata in shares, so remove the matching fraction.
    const usdWad = BigInt(Math.round(usd * 1e6)) * 10n ** 12n;
    const rWadOut = usdWad >= valueWad ? rWad : (rWad * usdWad) / valueWad;
    setPendingKind("decrease");
    setPendingUsd(usd);
    writeContract(
      { chainId, address: poolAddress, abi: HOOK_LP_ABI, functionName: "removeLiquidity", args: [tokenId, rWadOut, zeroFloor()] },
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
      { chainId, address: poolAddress, abi: HOOK_LP_ABI, functionName: "collect", args: [tokenId] },
      {
        onSuccess: (hash) => setPendingHash(hash),
        onError: (e) => { setModal(null); onTxResult({ kind: "error", title: "Collect fees", msg: e.message.split("\n")[0] }); },
      }
    );
  }

  function handleBurn() {
    if (!address) return;
    setPendingKind("burn");
    setPendingUsd(valueUsd);
    // "Burn" = remove the entire remaining position (the full share balance).
    writeContract(
      { chainId, address: poolAddress, abi: HOOK_LP_ABI, functionName: "removeLiquidity", args: [tokenId, rWad, zeroFloor()] },
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
                  key={`${t.address}-${i}`}
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
              <span className="flex items-center gap-1.5" style={body("caption", color.textMuted)}>
                <ChainBadge chainId={chainId} size={11} />
                {DEPLOYMENTS[chainId]?.short ?? chainId}
                <PoolTypeTag type={poolType} />
                <span>· Tick #{tickIndex} · {pool?.tokens.length ?? 0}-asset pool</span>
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
            label="Value"
            value={fmtUSD(valueUsd)}
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
          {!onChain && address ? (
            <button
              onClick={() => switchChain({ chainId })}
              className="flex items-center justify-center h-9 px-4 hover:opacity-90 transition-opacity"
              style={{ backgroundColor: color.surface2, color: color.textPrimary, fontFamily: typography.p2.family, fontSize: typography.p2.size }}
            >
              Switch to {chainName} to manage
            </button>
          ) : ([
            { label: "Add at this band", onClick: () => setModal({ type: "increase" }) },
            { label: "Decrease", onClick: () => setModal({ type: "decrease" }), disabled: valueWad === 0n },
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
        <AmountModal title={`Add at the band of position #${tokenId}`} maxLabel="Wallet" maxValue={walletUSD.toFixed(2)}
          onConfirm={handleIncrease} onClose={() => setModal(null)} isPending={isPending} />
      )}
      {modal?.type === "decrease" && (
        <AmountModal title={`Decrease Position #${tokenId}`} maxLabel="Max" maxValue={valueUsd.toFixed(2)}
          onConfirm={handleDecrease} onClose={() => setModal(null)} isPending={isPending} />
      )}
      {modal?.type === "collect" && (
        <ConfirmModal title={`Collect fees, Position #${tokenId}`}
          body="Collected fees will be sent to your wallet. Your liquidity position remains unchanged."
          confirmLabel="Collect fees" onConfirm={handleCollect} onClose={() => setModal(null)} isPending={isPending} />
      )}
      {modal?.type === "burn" && (
        <ConfirmModal title={`Burn Position #${tokenId}`}
          body="This withdraws the entire position and burns its LP shares. Collect any owed fees first; they aren't claimed automatically."
          confirmLabel="Burn position" onConfirm={handleBurn} onClose={() => setModal(null)} isPending={isPending} danger />
      )}
    </>
  );
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function PositionsPage() {
  const { address } = useAccount();

  const { positions, isLoading, refetch: refetchPositions } = usePositions(address);
  const [txResult, setTxResult] = useState<TxResult | null>(null);

  // Rows refresh their own pool; the page only re-reads which positions exist.
  const handleActionDone = useCallback(() => {
    refetchPositions();
  }, [refetchPositions]);

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
              // tokenId is the tick index, unique only within a pool.
              key={`${pos.poolAddress}-${pos.tokenId}`}
              tokenId={pos.tokenId}
              poolAddress={pos.poolAddress}
              chainId={pos.chainId}
              poolType={pos.poolType}
              tickIndex={pos.tickIndex}
              rWad={pos.rWad}
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
