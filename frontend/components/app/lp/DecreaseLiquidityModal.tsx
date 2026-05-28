"use client";

import { color } from "@/constants";
import { ModalShell, M } from "./_ModalShell";
import { fmtUSD } from "@/lib/mock/data";
import type { TokenAmount } from "./IncreaseLiquidityModal";

export function DecreaseLiquidityModal({ tokenId, hash, amounts, rWadRemoved, rWadRemaining, onClose }: {
  tokenId: bigint;
  hash: string;
  amounts: TokenAmount[];
  rWadRemoved: number;
  rWadRemaining: number;
  onClose: () => void;
}) {
  const accent = "#E89B3A";
  const total = amounts.reduce((s, t) => s + t.amount, 0);

  return (
    <ModalShell accentHex={accent} success hash={hash} label="Decrease liquidity" onClose={onClose}>
      {/* hero */}
      <div style={{ padding: "22px 20px 16px", borderBottom: `1px solid ${color.borderSubtle}` }}>
        <div style={{ ...M, fontSize: "9px", letterSpacing: "0.1em", textTransform: "uppercase" as const, color: color.textMuted, marginBottom: 6 }}>
          Withdrawn · Position #{tokenId.toString()}
        </div>
        <div style={{ fontFamily: "var(--font-sans)", fontSize: "32px", fontWeight: 500, letterSpacing: "-0.03em", color: accent, lineHeight: 1 }}>
          {fmtUSD(rWadRemoved)}
        </div>
        <div style={{ ...M, fontSize: "10px", color: color.textMuted, marginTop: 6 }}>
          Tokens returned to your wallet
        </div>
      </div>

      {/* per-token breakdown */}
      <div style={{ padding: "14px 20px 4px" }}>
        <div style={{ ...M, fontSize: "9px", letterSpacing: "0.08em", textTransform: "uppercase" as const, color: color.textMuted, marginBottom: 8 }}>
          Received tokens
        </div>
        {amounts.map(t => (
          <div key={t.symbol} style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "7px 0", borderBottom: `1px solid ${color.borderSubtle}` }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <span style={{ width: 8, height: 8, borderRadius: "50%", backgroundColor: t.color, flexShrink: 0, display: "inline-block" }} />
              <span style={{ ...M, fontSize: "11px", color: color.textSecondary }}>{t.symbol}</span>
            </div>
            <div style={{ textAlign: "right" as const }}>
              <span style={{ ...M, fontSize: "12px", color: color.textPrimary, fontWeight: 600 }}>{t.amount.toLocaleString("en-US", { maximumFractionDigits: 2 })}</span>
              <span style={{ ...M, fontSize: "10px", color: color.textMuted, marginLeft: 6 }}>{fmtUSD(t.amount)}</span>
            </div>
          </div>
        ))}

        {/* summary row */}
        <div style={{ display: "flex", gap: 0, marginTop: 12, marginBottom: 16 }}>
          {[
            { label: "Withdrawn", value: fmtUSD(total), accent: accent },
            { label: "Remaining",  value: fmtUSD(rWadRemaining), accent: color.textPrimary },
          ].map(s => (
            <div key={s.label} style={{ flex: 1, padding: "10px 12px", backgroundColor: color.surface2, border: `1px solid ${color.borderSubtle}`, marginRight: 4 }}>
              <div style={{ ...M, fontSize: "9px", letterSpacing: "0.07em", textTransform: "uppercase" as const, color: color.textMuted, marginBottom: 4 }}>{s.label}</div>
              <div style={{ ...M, fontSize: "13px", color: s.accent, fontWeight: 700 }}>{s.value}</div>
            </div>
          ))}
        </div>
      </div>
    </ModalShell>
  );
}
