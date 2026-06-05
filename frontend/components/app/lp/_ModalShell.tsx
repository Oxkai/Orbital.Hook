"use client";

import { color } from "@/constants";

export const M = { fontFamily: "var(--font-mono)" as const };
export const SEGMENTS = 24;

export function ModalShell({
  accentHex,
  success,
  label,
  hash,
  onClose,
  children,
}: {
  accentHex: string;
  success: boolean;
  label: string;
  hash?: string;
  onClose: () => void;
  children: React.ReactNode;
}) {
  const filled = success ? SEGMENTS : Math.floor(SEGMENTS * 0.35);

  return (
    <>
      {/* backdrop */}
      <div
        onClick={onClose}
        style={{
          position: "fixed", inset: 0, zIndex: 9998,
          backgroundColor: "rgba(0,0,0,0.82)",
          backgroundImage: `linear-gradient(${color.border}28 1px, transparent 1px), linear-gradient(90deg, ${color.border}28 1px, transparent 1px)`,
          backgroundSize: "80px 80px",
        }}
      />

      {/* panel */}
      <div style={{ position: "fixed", top: "50%", left: "50%", transform: "translate(-50%,-50%)", zIndex: 9999, width: "min(460px, calc(100vw - 24px))", backgroundColor: color.surface1, boxShadow: "0 24px 80px rgba(0,0,0,0.7)" }}>

        {/* corner brackets */}
        {([
          { top: -1,    left: -1,   borderTop:    `2px solid ${accentHex}`, borderLeft:  `2px solid ${accentHex}` },
          { top: -1,    right: -1,  borderTop:    `2px solid ${accentHex}`, borderRight: `2px solid ${accentHex}` },
          { bottom: -1, left: -1,   borderBottom: `2px solid ${accentHex}`, borderLeft:  `2px solid ${accentHex}` },
          { bottom: -1, right: -1,  borderBottom: `2px solid ${accentHex}`, borderRight: `2px solid ${accentHex}` },
        ] as React.CSSProperties[]).map((s, i) => (
          <div key={i} style={{ position: "absolute", width: 20, height: 20, ...s }} />
        ))}

        {/* header */}
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "11px 20px", borderBottom: `1px solid ${color.borderSubtle}` }}>
          <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <span style={{ ...M, fontSize: "10px", letterSpacing: "0.06em", color: color.textMuted }}>Positions</span>
            <span style={{ ...M, fontSize: "10px", color: color.borderSubtle }}>/</span>
            <span style={{ ...M, fontSize: "10px", letterSpacing: "0.04em", color: color.textSecondary }}>{label}</span>
            <span style={{ ...M, fontSize: "10px", color: color.borderSubtle }}>/</span>
            <span style={{ ...M, fontSize: "10px", letterSpacing: "0.04em", color: color.textSecondary }}>
              {success ? "Confirmed" : "Failed"}
            </span>
          </div>
          <span style={{ ...M, fontSize: "9px", letterSpacing: "0.08em", textTransform: "uppercase" as const, color: accentHex, backgroundColor: `${accentHex}18`, padding: "3px 9px" }}>
            {success ? "Success" : "Failed"}
          </span>
        </div>

        {/* slot for per-modal content */}
        {children}

        {/* progress bar */}
        <div style={{ display: "flex", gap: 2, padding: "0 20px 20px" }}>
          {Array.from({ length: SEGMENTS }).map((_, i) => (
            <div key={i} style={{ flex: 1, height: 3, backgroundColor: i < filled ? accentHex : color.surface3 }} />
          ))}
        </div>

        <div style={{ height: 1, backgroundColor: color.borderSubtle }} />

        {/* footer */}
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "12px 20px" }}>
          {hash ? (
            <a href={`https://sepolia.uniscan.xyz/tx/${hash}`} target="_blank" rel="noreferrer"
              style={{ ...M, fontSize: "10px", letterSpacing: "0.04em", color: color.textMuted, textDecoration: "none", display: "flex", alignItems: "center", gap: 5 }}>
              <span>TX</span>
              <span>{hash.slice(0, 12)}…{hash.slice(-6)}</span>
              <span style={{ color: accentHex }}>↗</span>
            </a>
          ) : <span />}
          <button onClick={onClose}
            style={{ ...M, fontSize: "9px", letterSpacing: "0.1em", textTransform: "uppercase" as const, color: color.textMuted, backgroundColor: "transparent", border: `1px solid ${color.border}`, padding: "5px 14px", cursor: "pointer" }}>
            Dismiss
          </button>
        </div>

        {/* auto-dismiss bar */}
        <div style={{ height: 2, backgroundColor: color.surface3 }}>
          <div style={{ height: "100%", backgroundColor: accentHex, animation: "shrink 6s linear forwards" }} />
        </div>
        <style>{`@keyframes shrink { from { width:100% } to { width:0% } }`}</style>
      </div>
    </>
  );
}

export function StatRow({ label, value, accent }: { label: string; value: string; accent?: string }) {
  return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "7px 0", borderBottom: `1px solid ${color.borderSubtle}` }}>
      <span style={{ ...M, fontSize: "10px", letterSpacing: "0.06em", color: color.textMuted }}>{label}</span>
      <span style={{ ...M, fontSize: "12px", color: accent ?? color.textPrimary, fontWeight: 600 }}>{value}</span>
    </div>
  );
}
