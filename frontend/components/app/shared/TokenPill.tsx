import { color, typography } from "@/constants";
import type { Token } from "@/lib/mock/data";
import { TokenIcon } from "@/components/app/shared/TokenIcon";

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
