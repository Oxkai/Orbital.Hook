import { color, typography } from "@/constants";

interface StatBoxProps {
  label: string;
  value: string;
  sub?: string;
  accent?: boolean;
}

export function StatBox({ label, value, sub, accent = false }: StatBoxProps) {
  return (
    <div
      className="flex flex-col gap-1 px-4 py-3"
      style={{
        backgroundColor: color.surface1,
      }}
    >
      <span
        style={{
          fontFamily: "var(--font-mono)",
          fontSize: "10px",
          letterSpacing: "0.07em",
          textTransform: "uppercase",
          color: color.textMuted,
        }}
      >
        {label}
      </span>
      <span
        style={{
          fontFamily: typography.h3.family,
          fontSize: typography.h3.size,
          lineHeight: typography.h3.lineHeight,
          letterSpacing: typography.h3.letterSpacing,
          fontWeight: 500,
          color: accent ? color.accent : color.textPrimary,
        }}
      >
        {value}
      </span>
      {sub && (
        <span
          style={{
            fontFamily: typography.caption.family,
            fontSize: typography.caption.size,
            color: color.textMuted,
          }}
        >
          {sub}
        </span>
      )}
    </div>
  );
}
