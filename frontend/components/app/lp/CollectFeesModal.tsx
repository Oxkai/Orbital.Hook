"use client";

import { color } from "@/constants";
import { ModalShell, M } from "./_ModalShell";
import { fmtUSD } from "@/lib/mock/data";
import type { TokenAmount } from "./IncreaseLiquidityModal";

export function CollectFeesModal({ tokenId, hash, fees, onClose }: {
  tokenId: bigint;
  hash: string;
  fees: TokenAmount[];
  onClose: () => void;
}) {
  const accent = "#4FC97E";
  const total = fees.reduce((s, t) => s + t.amount, 0);
  const hasAnyFees = fees.some(t => t.amount > 0);

  return (
    <ModalShell accentHex={accent} success hash={hash} label="Collect fees" onClose={onClose}>
      {/* hero */}
      <div style={{ padding: "22px 20px 16px", borderBottom: `1px solid ${color.borderSubtle}` }}>
        <div style={{ ...M, fontSize: "9px", letterSpacing: "0.1em", textTransform: "uppercase" as const, color: color.textMuted, marginBottom: 6 }}>
          Fees collected · Position #{tokenId.toString()}
        </div>
        <div style={{ fontFamily: "var(--font-sans)", fontSize: "32px", fontWeight: 500, letterSpacing: "-0.03em", color: accent, lineHeight: 1 }}>
          {fmtUSD(total)}
        </div>
        <div style={{ ...M, fontSize: "10px", color: color.textMuted, marginTop: 6 }}>
          {hasAnyFees ? "Sent to your wallet" : "No fees accrued yet"}
        </div>
      </div>

      {/* per-token fee breakdown */}
      <div style={{ padding: "14px 20px 4px" }}>
        <div style={{ ...M, fontSize: "9px", letterSpacing: "0.08em", textTransform: "uppercase" as const, color: color.textMuted, marginBottom: 8 }}>
          Fee breakdown by token
        </div>
        {fees.map(t => {
          const pct = total > 0 ? (t.amount / total) * 100 : 0;
          return (
            <div key={t.symbol}>
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "8px 0 4px" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <span style={{ width: 8, height: 8, borderRadius: "50%", backgroundColor: t.color, flexShrink: 0, display: "inline-block" }} />
                  <span style={{ ...M, fontSize: "11px", color: color.textSecondary }}>{t.symbol}</span>
                </div>
                <div>
                  <span style={{ ...M, fontSize: "12px", color: t.amount > 0 ? color.textPrimary : color.textMuted, fontWeight: 600 }}>
                    {t.amount.toLocaleString("en-US", { maximumFractionDigits: 4 })}
                  </span>
                  <span style={{ ...M, fontSize: "10px", color: color.textMuted, marginLeft: 8 }}>
                    {pct.toFixed(1)}%
                  </span>
                </div>
              </div>
              {/* mini bar */}
              <div style={{ height: 2, backgroundColor: color.surface3, marginBottom: 6 }}>
                <div style={{ height: "100%", width: `${pct}%`, backgroundColor: t.color, opacity: 0.7 }} />
              </div>
            </div>
          );
        })}
        <div style={{ padding: "10px 0 16px", display: "flex", justifyContent: "space-between" }}>
          <span style={{ ...M, fontSize: "10px", letterSpacing: "0.06em", color: color.textMuted }}>TOTAL FEES COLLECTED</span>
          <span style={{ ...M, fontSize: "13px", color: accent, fontWeight: 700 }}>{fmtUSD(total)}</span>
        </div>
      </div>
    </ModalShell>
  );
}
