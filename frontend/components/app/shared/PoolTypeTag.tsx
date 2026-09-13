import { color, typography } from "@/constants";
import { POOL_TYPE_LABEL, type PoolType } from "@/lib/crosschain";

/** Small uppercase chip naming a pool's type ("Stable" or "FX").
 *
 *  The two types share one engine and are otherwise presented identically, so
 *  this chip is the single place the difference shows. FX is tinted with the
 *  accent so it reads at a glance in a mixed list; stable stays neutral. */
export function PoolTypeTag({ type }: { type: PoolType }) {
  const fx = type === "fx";
  return (
    <span
      className="inline-flex items-center px-1.5 shrink-0"
      style={{
        fontFamily: typography.caption.family,
        fontSize: 10,
        lineHeight: "16px",
        letterSpacing: "0.08em",
        textTransform: "uppercase",
        fontWeight: 500,
        color: fx ? color.accent : color.textMuted,
        border: `1px solid ${fx ? color.accent : color.borderSubtle}`,
      }}
    >
      {POOL_TYPE_LABEL[type]}
    </span>
  );
}
