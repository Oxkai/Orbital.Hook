import { color } from "@/constants";

export function RecentSwaps() {
  return (
    <div style={{ backgroundColor: color.surface1 }}>
      <div className="px-4 py-3 shrink-0" style={{ borderBottom: `1px solid ${color.borderSubtle}` }}>
        <span style={{ fontFamily: "var(--font-mono)", fontSize: "11px", letterSpacing: "0.06em", textTransform: "uppercase" as const, color: color.textPrimary }}>
          Recent Swaps
        </span>
      </div>
      <div className="px-4 py-6" style={{ fontFamily: "var(--font-mono)", fontSize: "11px", color: color.textMuted }}>
        On-chain swap history coming soon.
      </div>
    </div>
  );
}
