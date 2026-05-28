import { color, typography, typeStyle } from "@/constants";
import { TokenPill } from "@/components/app/shared/TokenPill";
import { Badge }     from "@/components/app/shared/Badge";
import { fmtUSD, type Position } from "@/lib/mock/data";

interface PositionCardProps {
  position: Position;
}

export function PositionCard({ position }: PositionCardProps) {
  const { pool, tokenId, tickDepegPrice, capitalEfficiency, r, isInterior, feesOwed } = position;
  const totalFees = feesOwed.reduce((a, b) => a + b, 0);
  const hasFees = totalFees > 0;

  return (
    <div
      style={{
        border: `1px solid ${isInterior ? color.border : color.warning + "44"}`,
        backgroundColor: color.surface1,
      }}
    >
      {/* Header */}
      <div
        className="flex items-center justify-between px-4 py-3"
        style={{ borderBottom: `1px solid ${color.borderSubtle}` }}
      >
        <div className="flex items-center gap-3">
          <span
            style={{
              fontFamily: "var(--font-mono)",
              fontSize: "10px",
              letterSpacing: "0.06em",
              color: color.textMuted,
              border: `1px solid ${color.borderSubtle}`,
              padding: "1px 6px",
            }}
          >
            #{tokenId}
          </span>
          <div className="flex items-center gap-1.5 flex-wrap">
            {pool.tokens.map(t => (
              <TokenPill key={t.address} token={t} size="sm" />
            ))}
          </div>
        </div>
        <Badge variant={isInterior ? "success" : "warning"} dot>
          {isInterior ? "Active" : "Paused"}
        </Badge>
      </div>

      {/* Paused explanation */}
      {!isInterior && (() => {
        const depeggedNames = pool.depeggedTokenIndices.map(i => pool.tokens[i].symbol);
        const names = depeggedNames.length > 0 ? depeggedNames.join(", ") : "An asset";
        const verb = depeggedNames.length === 1 ? "has" : "have";
        return (
          <div
            className="px-4 py-2.5 flex items-start gap-2"
            style={{
              backgroundColor: `${color.warning}0d`,
              borderBottom: `1px solid ${color.warning}2a`,
            }}
          >
            <span style={{ ...typeStyle("caption"), color: color.warning, lineHeight: "1.5" }}>
              {names} {verb} fallen below your ${tickDepegPrice} threshold. This position earns no fees while depegged and resumes automatically when {depeggedNames.length === 1 ? `${names} recovers` : "prices recover"}.
            </span>
          </div>
        );
      })()}

      {/* Stats */}
      <div
        className="grid grid-cols-2 md:grid-cols-4 gap-px"
        style={{ backgroundColor: color.borderSubtle, borderBottom: `1px solid ${color.borderSubtle}` }}
      >
        {[
          { label: "Liquidity",         value: fmtUSD(r) },
          { label: "Depeg tolerance",   value: `$${tickDepegPrice}` },
          { label: "Cap. efficiency",   value: `${capitalEfficiency}×`, accent: true },
          { label: "Unclaimed fees",    value: hasFees ? fmtUSD(totalFees) : "—", accent: hasFees },
        ].map(s => (
          <div key={s.label} className="px-4 py-3" style={{ backgroundColor: color.surface1 }}>
            <div style={{ fontFamily: "var(--font-mono)", fontSize: "10px", letterSpacing: "0.07em", textTransform: "uppercase", color: color.textMuted, marginBottom: 4 }}>
              {s.label}
            </div>
            <div
              style={{
                fontFamily: typography.h3.family,
                fontSize: "16px",
                fontWeight: 500,
                letterSpacing: "-0.02em",
                color: s.accent ? color.accent : color.textPrimary,
              }}
            >
              {s.value}
            </div>
          </div>
        ))}
      </div>

      {/* Fee breakdown */}
      {hasFees && (
        <div className="px-4 py-3" style={{ borderBottom: `1px solid ${color.borderSubtle}` }}>
          <div style={{ fontFamily: "var(--font-mono)", fontSize: "10px", letterSpacing: "0.06em", textTransform: "uppercase", color: color.textMuted, marginBottom: 8 }}>
            Claimable fees
          </div>
          <div className="flex flex-wrap gap-4">
            {pool.tokens.map((t, i) => (
              feesOwed[i] > 0 && (
                <div key={t.address} className="flex items-center gap-1.5">
                  <span style={{ width: 6, height: 6, borderRadius: "50%", backgroundColor: t.color, display: "inline-block" }} />
                  <span style={{ fontFamily: "var(--font-mono)", fontSize: "12px", color: color.success }}>
                    {feesOwed[i].toFixed(4)} {t.symbol}
                  </span>
                </div>
              )
            ))}
          </div>
        </div>
      )}

      {/* Actions */}
      <div className="flex gap-2 px-4 pt-3 pb-2">
        {[
          { label: "Increase",  disabled: !isInterior, title: !isInterior ? "Cannot increase while paused" : undefined },
          { label: "Decrease",  disabled: false },
          { label: "Collect",   disabled: !hasFees, title: !hasFees ? "No fees to collect" : undefined },
          { label: "Burn",      disabled: r > 0,    title: r > 0 ? "Decrease liquidity to zero first" : undefined },
        ].map(({ label, disabled, title }) => (
          <button
            key={label}
            disabled={disabled}
            title={title}
            style={{
              border: `1px solid ${disabled ? color.borderSubtle : color.border}`,
              backgroundColor: "transparent",
              color: disabled ? color.textMuted : color.textSecondary,
              fontFamily: typography.p3.family,
              fontSize: typography.p3.size,
              letterSpacing: "-0.01em",
              padding: "6px 12px",
              cursor: disabled ? "not-allowed" : "pointer",
              opacity: disabled ? 0.5 : 1,
            }}
          >
            {label}
          </button>
        ))}
      </div>

      {/* Exit flow hint */}
      <div className="px-4 pb-3 flex items-center gap-1.5">
        {["Decrease", "→", "Collect", "→", "Burn"].map((step, i) => (
          <span
            key={i}
            style={{
              fontFamily: "var(--font-mono)",
              fontSize: "10px",
              color: step === "→" ? color.borderSubtle : color.textMuted,
              letterSpacing: step === "→" ? 0 : "0.04em",
            }}
          >
            {step}
          </span>
        ))}
        <span style={{ fontFamily: "var(--font-mono)", fontSize: "10px", color: color.textMuted, marginLeft: 4 }}>
          to close position
        </span>
      </div>
    </div>
  );
}
