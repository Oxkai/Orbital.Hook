import { typography, color } from "@/constants";
import { ChainBadge, chainPlateColor } from "@/components/app/shared/ChainBadge";

/** Symbols with a hand-supplied SVG in `public/icons/`. These are full-bleed
 *  32x32 discs with the glyph already on top, so they need no backing shape 
 *  unlike the @token-icons variants, which are either outline art or a knockout
 *  that has to be composited over a disc. */
const CUSTOM_ICONS = new Set(["USDC", "USDT", "DAI", "FRAX"]);

/** Brand colors, used only by the fallback badge for symbols with no SVG. */
export const TOKEN_COLORS: Record<string, string> = {
  USDC: "#2775CA",
  USDT: "#26A17B",
  DAI: "#F4B731",
  FRAX: "#BFBFBF",
  CRVUSD: "#FF6B35",
  USDS: "#7C5CFC",
};

export function tokenColor(symbol: string, fallback = "#555"): string {
  return TOKEN_COLORS[symbol.toUpperCase()] ?? fallback;
}

export function chainBrandColor(chainId: number): string {
  return chainPlateColor(chainId);
}

/** A token's icon, or a colored initials badge if we have no SVG for it.
 *
 *  Pass `chainId` to badge it with the network mark, bottom-right. The badge is
 *  separated from the token disc by a ring in `ringColor`, which must match the
 *  surface the icon sits on or the two shapes visually merge. */
export function TokenIcon({
  symbol,
  size = 22,
  color: override,
  chainId,
  ringColor = color.surface1,
}: {
  symbol: string;
  size?: number;
  /** Overrides the fallback badge color (ignored when an SVG exists). */
  color?: string;
  /** When set, overlays that chain's network mark as a corner badge. */
  chainId?: number;
  /** Background behind the icon, used for the badge's separating ring. */
  ringColor?: string;
}) {
  const upper = symbol.toUpperCase();

  const base = CUSTOM_ICONS.has(upper) ? (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={`/icons/${upper}.svg`}
      alt={upper}
      width={size}
      height={size}
      style={{ display: "block", width: size, height: size, flexShrink: 0 }}
    />
  ) : (
    <span
      style={{
        width: size,
        height: size,
        borderRadius: "50%",
        backgroundColor: override ?? tokenColor(symbol),
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        flexShrink: 0,
        lineHeight: 1,
        fontSize: Math.max(6, size * 0.38),
        color: "#fff",
        fontFamily: typography.caption.family,
        fontWeight: 700,
      }}
    >
      {symbol.slice(0, 2).toUpperCase()}
    </span>
  );

  if (chainId === undefined) return base;

  // Badge scales with the token so it stays legible at 22px and not oversized
  // at 36px; the floor keeps it from vanishing on the smallest instances.
  const badge = Math.max(11, Math.round(size * 0.46));
  const ring = Math.max(2, Math.round(size * 0.085));

  return (
    <span
      style={{
        position: "relative",
        display: "block",
        width: size,
        height: size,
        flexShrink: 0,
        lineHeight: 0,
        fontSize: 0,
        // The badge overhangs the disc; reserve the overhang so it never
        // collides with whatever sits to the right of the icon.
        marginRight: Math.round(badge * 0.28),
      }}
    >
      {base}
      <span
        style={{
          position: "absolute",
          right: -Math.round(badge * 0.28),
          bottom: -Math.round(badge * 0.16),
          display: "block",
          lineHeight: 0,
          fontSize: 0,
        }}
      >
        <ChainBadge
          chainId={chainId}
          size={badge}
          style={{ boxShadow: `0 0 0 ${ring}px ${ringColor}`, borderRadius: Math.max(2, Math.round(badge * 0.3)) }}
        />
      </span>
    </span>
  );
}
