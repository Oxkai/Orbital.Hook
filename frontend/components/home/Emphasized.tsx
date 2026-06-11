import { color, colors } from "@/constants";

export type Seg =
  | string
  | { t: string; v?: "on" | "off" | "accent" | "green" | "u" };

export function Emphasized({
  segments,
  size = "52px",
  lineHeight = "1.1",
  letterSpacing = "-0.03em",
  fontFamily,
  maxWidth,
}: {
  segments: Seg[];
  size?: string;
  lineHeight?: string;
  letterSpacing?: string;
  fontFamily?: string;
  maxWidth?: string;
}) {
  return (
    <p
      style={{
        fontSize: size,
        lineHeight,
        letterSpacing,
        fontWeight: 400,
        color: color.textPrimary,
        fontFamily,
        maxWidth,
        width: "100%",
      }}
    >
      {segments.map((seg, i) => {
        if (typeof seg === "string") {
          return <span key={i}>{seg}</span>;
        }
        const { t, v = "on" } = seg;
        if (v === "off") {
          return (
            <span key={i} style={{ color: color.textMuted }}>
              {t}
            </span>
          );
        }
        if (v === "accent") {
          return (
            <span key={i} style={{ color: colors.purple.hex }}>
              {t}
            </span>
          );
        }
        if (v === "green") {
          return (
            <span key={i} style={{ color: colors.green.hex }}>
              {t}
            </span>
          );
        }
        if (v === "u") {
          return (
            <span
              key={i}
              style={{
                textDecoration: "underline",
                textDecorationColor: color.textMuted,
                textUnderlineOffset: "4px",
              }}
            >
              {t}
            </span>
          );
        }
        return <span key={i}>{t}</span>;
      })}
    </p>
  );
}
