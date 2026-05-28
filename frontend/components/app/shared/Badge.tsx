import { color } from "@/constants";

type Variant = "default" | "success" | "warning" | "error" | "muted" | "accent";

const TEXT_COLOR: Record<Variant, string> = {
  default: color.textMuted,
  success: color.textMuted,
  warning: color.warning,
  error:   color.error,
  muted:   color.textMuted,
  accent:  color.accent,
};

const DOT_COLOR: Record<Variant, string> = {
  default: color.textMuted,
  success: color.success,
  warning: color.warning,
  error:   color.error,
  muted:   color.textMuted,
  accent:  color.accent,
};

interface BadgeProps {
  children: React.ReactNode;
  variant?: Variant;
  dot?: boolean;
}

export function Badge({ children, variant = "default", dot }: BadgeProps) {
  return (
    <span
      className="inline-flex items-center gap-1.5"
      style={{
        color: TEXT_COLOR[variant],
        fontFamily: "var(--font-mono)",
        fontSize: "9px",
        letterSpacing: "0.08em",
        textTransform: "uppercase",
        lineHeight: "16px",
      }}
    >
      {dot && (
        <span
          style={{
            width: 4,
            height: 4,
            borderRadius: "50%",
            backgroundColor: DOT_COLOR[variant],
            display: "inline-block",
            flexShrink: 0,
          }}
        />
      )}
      {children}
    </span>
  );
}
