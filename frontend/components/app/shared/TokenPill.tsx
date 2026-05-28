import { TokenDAI, TokenUSDT, TokenUSDC, TokenFRAX } from "@token-icons/react";
import { color, typography } from "@/constants";
import type { Token } from "@/lib/mock/data";

const TOKEN_ICON_MAP: Record<string, React.ElementType> = {
  DAI:  TokenDAI,
  USDT: TokenUSDT,
  USDC: TokenUSDC,
  FRAX: TokenFRAX,
};
const TOKEN_COLOR_MAP: Record<string, string> = {
  CRVUSD: "#FF6B35",
};

function TokenIcon({ symbol, color: tokenColor, size }: { symbol: string; color?: string; size: number }) {
  const Icon = TOKEN_ICON_MAP[symbol.toUpperCase()];
  if (Icon) return <Icon size={size} variant="branded" />;
  const bg = tokenColor ?? TOKEN_COLOR_MAP[symbol.toUpperCase()] ?? "#555";
  return (
    <span style={{ width: size, height: size, borderRadius: "50%", backgroundColor: bg, display: "inline-flex", alignItems: "center", justifyContent: "center", flexShrink: 0, fontSize: Math.max(5, size * 0.38), color: "#fff", fontFamily: "var(--font-mono)", fontWeight: 700 }}>
      {symbol.slice(0, 2).toUpperCase()}
    </span>
  );
}

interface TokenPillProps {
  token: Token;
  size?: "sm" | "md";
}

export function TokenPill({ token, size = "md" }: TokenPillProps) {
  const sm = size === "sm";
  const iconSize = sm ? 14 : 18;
  return (
    <span className="inline-flex items-center gap-1.5">
      <TokenIcon symbol={token.symbol} color={token.color} size={iconSize} />
      <span
        style={{
          fontFamily: typography.p3.family,
          fontSize: sm ? "11px" : typography.p3.size,
          letterSpacing: "0.02em",
          fontWeight: 500,
          color: color.textSecondary,
        }}
      >
        {token.symbol}
      </span>
    </span>
  );
}
