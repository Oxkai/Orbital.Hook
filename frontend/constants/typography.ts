export const fontFamily = {
  sans: "Roboto, system-ui, -apple-system, sans-serif",
} as const;

export const letterSpacing = {
  tight: "-0.03em",
} as const;

export const typography = {
  h1: {
    family: fontFamily.sans,
    size: "40px",
    lineHeight: "44px",
    letterSpacing: letterSpacing.tight,
    weight: 500,
  },
  h2: {
    family: fontFamily.sans,
    size: "24px",
    lineHeight: "32px",
    letterSpacing: letterSpacing.tight,
    weight: 500,
  },
  h3: {
    family: fontFamily.sans,
    size: "20px",
    lineHeight: "28px",
    letterSpacing: letterSpacing.tight,
    weight: 500,
  },
  p1: {
    family: fontFamily.sans,
    size: "16px",
    lineHeight: "24px",
    letterSpacing: letterSpacing.tight,
    weight: 400,
  },
  p2: {
    family: fontFamily.sans,
    size: "14px",
    lineHeight: "20px",
    letterSpacing: letterSpacing.tight,
    weight: 400,
  },
  p2Underline: {
    family: fontFamily.sans,
    size: "14px",
    lineHeight: "20px",
    letterSpacing: letterSpacing.tight,
    weight: 400,
    textDecoration: "underline",
  },
  p3: {
    family: fontFamily.sans,
    size: "12px",
    lineHeight: "16px",
    letterSpacing: letterSpacing.tight,
    weight: 400,
  },
  caption: {
    family: fontFamily.sans,
    size: "10px",
    lineHeight: "14px",
    letterSpacing: letterSpacing.tight,
    weight: 400,
  },
} as const;

export type TypographyKey = keyof typeof typography;

export function typeStyle(key: TypographyKey): React.CSSProperties {
  const t = typography[key];
  const s: React.CSSProperties = {
    fontFamily: t.family,
    fontSize: t.size,
    lineHeight: t.lineHeight,
    letterSpacing: t.letterSpacing,
    fontWeight: t.weight as React.CSSProperties["fontWeight"],
  };
  if ("textDecoration" in t) s.textDecoration = t.textDecoration;
  return s;
}
