"use client";

import { color } from "@/constants";
import { ModalShell, M } from "./_ModalShell";
import { fmtUSD } from "@/lib/mock/data";
import type { TokenAmount } from "./IncreaseLiquidityModal";

export function BurnPositionModal({ tokenId, hash, tokens, finalLiquidity, onClose }: {
  tokenId: bigint;
  hash: string;
  tokens: TokenAmount[];
  finalLiquidity: number;
  onClose: () => void;
}) {
  const accent = "#F56868";

  return (
    <ModalShell accentHex={accent} success hash={hash} label="Burn position" onClose={onClose}>
      {/* hero */}
      <div style={{ padding: "22px 20px 16px", borderBottom: `1px solid ${color.borderSubtle}` }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
          <div style={{ width: 44, height: 44, border: `1.5px solid ${accent}55`, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
            <span style={{ ...M, fontSize: "16px", color: accent, fontWeight: 700 }}>✕</span>
          </div>
          <div>
            <div style={{ ...M, fontSize: "9px", letterSpacing: "0.1em", textTransform: "uppercase" as const, color: color.textMuted, marginBottom: 4 }}>
              Position burned
            </div>
            <div style={{ fontFamily: "var(--font-sans)", fontSize: "24px", fontWeight: 500, letterSpacing: "-0.02em", color: accent, lineHeight: 1.1 }}>
              #{tokenId.toString()} destroyed
            </div>
          </div>
        </div>
      </div>

      {/* details */}
      <div style={{ padding: "14px 20px 4px" }}>
        <div style={{ ...M, fontSize: "9px", letterSpacing: "0.08em", textTransform: "uppercase" as const, color: color.textMuted, marginBottom: 8 }}>
          Position details at burn
        </div>

        {/* pool tokens */}
        <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "10px 12px", backgroundColor: color.surface2, border: `1px solid ${color.borderSubtle}`, marginBottom: 10 }}>
          <span style={{ ...M, fontSize: "9px", letterSpacing: "0.06em", color: color.textMuted, marginRight: 4 }}>POOL</span>
          {tokens.map(t => (
            <div key={t.symbol} style={{ display: "flex", alignItems: "center", gap: 4 }}>
              <span style={{ width: 7, height: 7, backgroundColor: t.color, display: "inline-block" }} />
              <span style={{ ...M, fontSize: "10px", color: color.textSecondary }}>{t.symbol}</span>
            </div>
          ))}
        </div>

        {/* stats */}
        <div style={{ display: "flex", gap: 4, marginBottom: 4 }}>
          {[
            { label: "Withdrawn",         value: fmtUSD(finalLiquidity), accent: color.textPrimary },
            { label: "LP shares",         value: "Burned",               accent: accent },
          ].map(s => (
            <div key={s.label} style={{ flex: 1, padding: "10px 12px", backgroundColor: color.surface2, border: `1px solid ${color.borderSubtle}` }}>
              <div style={{ ...M, fontSize: "9px", letterSpacing: "0.07em", textTransform: "uppercase" as const, color: color.textMuted, marginBottom: 4 }}>{s.label}</div>
              <div style={{ ...M, fontSize: "12px", color: s.accent, fontWeight: 700 }}>{s.value}</div>
            </div>
          ))}
        </div>

        <div style={{ padding: "10px 0 16px" }}>
          <span style={{ ...M, fontSize: "10px", color: color.textMuted }}>
            The whole position was withdrawn to your wallet and its LP shares burned. This is permanent.
          </span>
        </div>
      </div>
    </ModalShell>
  );
}
