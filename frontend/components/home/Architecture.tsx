import { color, typography } from "@/constants";
import { SectionLabel } from "./SectionLabel";

const MONO = "var(--font-mono)";

// 4 tokens → C(4,2) = 6 v4 pools, every one bound to the same hook.
const TOKENS = ["USDC", "USDT", "DAI", "FRAX"] as const;

function pairs(toks: readonly string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < toks.length; i++) {
    for (let j = i + 1; j < toks.length; j++) out.push(`${toks[i]} / ${toks[j]}`);
  }
  return out;
}

const PAIRS = pairs(TOKENS);

function cap(_label?: string) {
  return {
    fontFamily: MONO,
    fontSize: "10px",
    letterSpacing: "0.1em",
    textTransform: "uppercase" as const,
    color: color.textMuted,
  };
}

function Box({
  children,
  accent = false,
  className = "",
}: {
  children: React.ReactNode;
  accent?: boolean;
  className?: string;
}) {
  return (
    <div
      className={className}
      style={{
        border: `1px ${accent ? "solid" : "dashed"} ${accent ? color.accent : color.border}`,
        backgroundColor: color.surface1,
      }}
    >
      {children}
    </div>
  );
}

export function Architecture() {
  return (
    <section className="mx-6 my-1">
      <SectionLabel border chapter="IV" section="03" path="ORBITAL / ARCHITECTURE" />

      <div className="pb-12 pt-20">
        <p
          style={{
            fontFamily: typography.h1.family,
            fontSize: "clamp(40px, 5vw, 72px)",
            lineHeight: "1.05",
            letterSpacing: "-0.04em",
            color: color.textPrimary,
            fontWeight: 400,
          }}
        >
          Six pools, one hook.{" "}
          <span style={{ color: color.textMuted }}>
            Four stablecoins make six v4 pools — every one bound to a single OrbitalHook that holds one shared
            sphere. They quote off the same reserves and settle through the v4 PoolManager.
          </span>
        </p>
      </div>

      {/* Diagram */}
      <div
        className="border border-dashed mb-24"
        style={{ borderColor: color.border, backgroundColor: color.bg }}
      >
        {/* Layer 0 — the two actors and how each enters */}
        <div className="px-5 pt-6 pb-7">
          <span style={cap()}>{`// WHO INTERACTS`}</span>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-1 mt-4">
            {[
              {
                name: "Trader",
                via: "swapExactTokensForTokens",
                path: "→ v4 PoolManager.swap(poolKey) → beforeSwap returns the orbital delta",
              },
              {
                name: "Liquidity Provider",
                via: "addLiquidity / removeLiquidity",
                path: "→ calls the hook directly; settles N tokens, mints ERC-6909 shares",
              },
            ].map((actor) => (
              <Box key={actor.name} className="px-5 py-5">
                <div className="flex flex-wrap items-baseline justify-between gap-3">
                  <span
                    style={{
                      fontFamily: typography.h1.family,
                      fontSize: "clamp(18px, 2.4vw, 26px)",
                      letterSpacing: "-0.03em",
                      color: color.textPrimary,
                      fontWeight: 400,
                    }}
                  >
                    {actor.name}
                  </span>
                  <span style={{ fontFamily: MONO, fontSize: "11px", letterSpacing: "0.02em", color: color.accent }}>
                    {actor.via}
                  </span>
                </div>
                <p
                  style={{
                    fontFamily: typography.p2.family,
                    fontSize: typography.p2.size,
                    lineHeight: "18px",
                    color: color.textMuted,
                    marginTop: 8,
                  }}
                >
                  {actor.path}
                </p>
              </Box>
            ))}
          </div>
        </div>

        {/* Connector */}
        <div
          className="flex items-center justify-center py-2 border-t border-b border-dashed"
          style={{ borderColor: color.borderSubtle }}
        >
          <span style={cap()}>{`trader swaps a pair · LP funds the hook  ↓`}</span>
        </div>

        {/* Layer 1 — the 6 pair-pools */}
        <div className="px-5 pt-6 pb-7">
          <span style={cap("pools")}>{`// ${PAIRS.length} v4 POOLS · PoolKey(currency0, currency1, hooks)`}</span>
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-1 mt-4">
            {PAIRS.map((p) => (
              <Box key={p} className="px-3 py-3 text-center">
                <span
                  style={{
                    fontFamily: typography.p2.family,
                    fontSize: "13px",
                    letterSpacing: "-0.01em",
                    color: color.textPrimary,
                    fontVariantNumeric: "tabular-nums",
                  }}
                >
                  {p}
                </span>
              </Box>
            ))}
          </div>
        </div>

        {/* Connector */}
        <div
          className="flex items-center justify-center py-2 border-t border-b border-dashed"
          style={{ borderColor: color.borderSubtle }}
        >
          <span style={cap("connector")}>{`all bind to one hook  ↓`}</span>
        </div>

        {/* Layer 2 — the hook (shared engine) */}
        <div className="px-5 py-7">
          <Box accent className="px-5 py-5">
            <div className="flex flex-wrap items-baseline justify-between gap-3">
              <span
                style={{
                  fontFamily: typography.h1.family,
                  fontSize: "clamp(22px, 3vw, 34px)",
                  letterSpacing: "-0.03em",
                  color: color.textPrimary,
                  fontWeight: 400,
                }}
              >
                OrbitalHook
              </span>
              <span style={{ ...cap("hook"), color: color.accent }}>{`// SHARED SPHERE STATE`}</span>
            </div>
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-1 mt-4">
              {[
                ["beforeSwap", "intercepts every pair's swap, runs the orbital math"],
                ["one reserve vector", "all pools read & write the same slot0"],
                ["ERC-6909 shares", "soulbound LP positions, one id per tick"],
              ].map(([t, d]) => (
                <div key={t} className="border-t border-dashed pt-3" style={{ borderColor: color.borderSubtle }}>
                  <div
                    style={{
                      fontFamily: MONO,
                      fontSize: "12px",
                      letterSpacing: "0.02em",
                      color: color.textPrimary,
                    }}
                  >
                    {t}
                  </div>
                  <div
                    style={{
                      fontFamily: typography.p2.family,
                      fontSize: typography.p2.size,
                      lineHeight: "18px",
                      color: color.textMuted,
                      marginTop: 4,
                    }}
                  >
                    {d}
                  </div>
                </div>
              ))}
            </div>
          </Box>
        </div>

        {/* Connector */}
        <div
          className="flex items-center justify-center py-2 border-t border-b border-dashed"
          style={{ borderColor: color.borderSubtle }}
        >
          <span style={cap("connector")}>{`settles through  ↓`}</span>
        </div>

        {/* Layer 3 — the PoolManager (custody) */}
        <div className="px-5 py-7">
          <Box className="px-5 py-5">
            <div className="flex flex-wrap items-baseline justify-between gap-3">
              <span
                style={{
                  fontFamily: typography.h1.family,
                  fontSize: "clamp(20px, 2.6vw, 28px)",
                  letterSpacing: "-0.03em",
                  color: color.textPrimary,
                  fontWeight: 400,
                }}
              >
                Uniswap v4 PoolManager
              </span>
              <span style={cap("custody")}>{`// SINGLETON · TOKEN CUSTODY`}</span>
            </div>
            <p
              style={{
                fontFamily: typography.p2.family,
                fontSize: typography.p2.size,
                lineHeight: "20px",
                color: color.textMuted,
                marginTop: 12,
                maxWidth: 640,
              }}
            >
              Holds the real ERC-20 reserves and routes the unlock/settle flow. The hook never custodies tokens —
              it tracks the abstract sphere and mints claim tokens against the manager.
            </p>
          </Box>
        </div>

        {/* Runtime — the per-swap call path */}
        <div
          className="px-5 py-5 border-t border-dashed"
          style={{ borderColor: color.border, backgroundColor: color.surface1 }}
        >
          <span style={cap()}>{`// ONE SWAP, AT RUNTIME`}</span>
          <div className="flex flex-wrap items-center gap-x-2 gap-y-2 mt-4">
            {[
              "PoolManager.swap",
              "unlock",
              "beforeSwap",
              "solve sphere · torus",
              "BeforeSwapDelta",
              "settle",
            ].map((step, i, arr) => (
              <span key={step} className="inline-flex items-center gap-2">
                <span
                  className="px-2.5 py-1.5 border border-dashed"
                  style={{
                    borderColor: color.borderSubtle,
                    fontFamily: MONO,
                    fontSize: "11px",
                    letterSpacing: "0.02em",
                    color: i === 2 || i === 3 ? color.accent : color.textSecondary,
                    whiteSpace: "nowrap",
                  }}
                >
                  {step}
                </span>
                {i < arr.length - 1 && (
                  <span style={{ fontFamily: MONO, fontSize: "11px", color: color.textMuted }}>→</span>
                )}
              </span>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
