"use client";

import { color } from "@/constants";
import { ModalShell, StatRow, M } from "./_ModalShell";
import { fmtUSD } from "@/lib/mock/data";

export type TokenAmount = { symbol: string; color: string; amount: number };

export function IncreaseLiquidityModal({ tokenId, hash, amounts, rWadAdded, onClose }: {
  tokenId: bigint;
  hash: string;
  amounts: TokenAmount[];
  rWadAdded: number;
  onClose: () => void;
}) {
  const accent = color.accent;
  const total = amounts.reduce((s, t) => s + t.amount, 0);

  return (
    <ModalShell accentHex={accent} success hash={hash} label="Increase liquidity" onClose={onClose}>
      {/* hero */}
      <div style={{ padding: "22px 20px 16px", borderBottom: `1px solid ${color.borderSubtle}` }}>
        <div style={{ ...M, fontSize: "9px", letterSpacing: "0.1em", textTransform: "uppercase" as const, color: color.textMuted, marginBottom: 6 }}>
          Liquidity added · Position #{tokenId.toString()}
        </div>
        <div style={{ fontFamily: "var(--font-sans)", fontSize: "32px", fontWeight: 500, letterSpacing: "-0.03em", color: color.textPrimary, lineHeight: 1 }}>
          {fmtUSD(rWadAdded)}
        </div>
        <div style={{ ...M, fontSize: "10px", color: color.textMuted, marginTop: 6 }}>
          Position is earning fees
        </div>
      </div>

      {/* per-token breakdown */}
      <div style={{ padding: "14px 20px 4px" }}>
        <div style={{ ...M, fontSize: "9px", letterSpacing: "0.08em", textTransform: "uppercase" as const, color: color.textMuted, marginBottom: 8 }}>
          Deposited tokens
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
        <div style={{ padding: "10px 0 16px", display: "flex", justifyContent: "space-between" }}>
          <span style={{ ...M, fontSize: "10px", letterSpacing: "0.06em", color: color.textMuted }}>TOTAL DEPOSITED</span>
          <span style={{ ...M, fontSize: "13px", color: accent, fontWeight: 700 }}>{fmtUSD(total)}</span>
        </div>
      </div>
    </ModalShell>
  );
}
