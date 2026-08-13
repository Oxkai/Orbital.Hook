import { TokenUSDC, TokenUSDT, TokenDAI, TokenFRAX } from "@token-icons/react";
import { typography } from "@/constants";

/** Branded icons from @token-icons/react. Anything without one (crvUSD, USDS,
 *  a fresh mock) falls back to a colored initials badge. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const ICONS: Record<string, React.ComponentType<any>> = {
  USDC: TokenUSDC,
  USDT: TokenUSDT,
  DAI: TokenDAI,
  FRAX: TokenFRAX,
};

/** Brand colors for the fallback badge. */
export const TOKEN_COLORS: Record<string, string> = {
  USDC: "#2775CA",
  USDT: "#26A17B",
  DAI: "#F5AC37",
  FRAX: "#BFBFBF",
  CRVUSD: "#FF6B35",
  USDS: "#7C5CFC",
};

export function tokenColor(symbol: string, fallback = "#555"): string {
  return TOKEN_COLORS[symbol.toUpperCase()] ?? fallback;
}

/** A token's branded icon, or a colored initials badge if we don't have one. */
export function TokenIcon({
  symbol,
  size = 22,
  color: override,
}: {
  symbol: string;
  size?: number;
  /** Overrides the fallback badge color (ignored when a branded icon exists). */
  color?: string;
}) {
  const Icon = ICONS[symbol.toUpperCase()];
  if (Icon) return <Icon size={size} variant="branded" />;
  return (
    <span
      style={{
        width: size,
        height: size,
        borderRadius: "50%",
        backgroundColor: override ?? tokenColor(symbol),
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        flexShrink: 0,
        fontSize: Math.max(6, size * 0.38),
        color: "#fff",
        fontFamily: typography.caption.family,
        fontWeight: 700,
      }}
    >
      {symbol.slice(0, 2).toUpperCase()}
    </span>
  );
}
