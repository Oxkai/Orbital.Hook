import { color, colors, typography } from "@/constants";
import { SectionLabel } from "./SectionLabel";

type Pillar = {
  n: string;
  tag: string;
  title: string;
  lede: string;
  body: string;
  metric: { value: string; unit: string; caption: string };
  accent: string;
};

const PILLARS: Pillar[] = [
  {
    n: "01",
    tag: "EXECUTION",
    title: "Low slippage",
    lede: "At peg, trades move along the sphere's flat equator.",
    body: "Every LP's tick concentrates liquidity where stables actually trade. Routes stay tight through the full depth of the book — not just the first few basis points.",
    metric: { value: "< 1", unit: "bps", caption: "price impact at peg, p=0.99" },
    accent: colors.green.hex,
  },
  {
    n: "02",
    tag: "DENSITY",
    title: "High capital efficiency",
    lede: "One dollar here behaves like ~154 in a flat sphere pool.",
    body: "Concentrated ticks compound across N assets in a single pool. No fragmentation across pairs, no idle reserves sitting outside the active range.",
    metric: { value: "154", unit: "×", caption: "vs flat sphere, N = 5" },
    accent: colors.purple.hex,
  },
  {
    n: "03",
    tag: "RESILIENCE",
    title: "Automatic depeg isolation",
    lede: "When one asset breaks peg, the other N−1 keep trading.",
    body: "Ticks flip to their boundary and the broken asset is fenced off. The pool doesn't drain into the bad leg — healthy stables stay liquid against each other.",
    metric: { value: "N − 1", unit: "assets", caption: "stay live through a depeg" },
    accent: colors.yellow.hex,
  },
];

export function Pillars() {
  return (
    <section className="mx-6">
      <SectionLabel border chapter="II" section="01" path="ORBITAL / PRINCIPLES" />

      <div className="grid grid-cols-12 gap-5 pt-20 pb-12">
        <h2
          className="col-span-12 text-left"
          style={{
            fontFamily: typography.h1.family,
            fontSize: "clamp(44px, 7vw, 76px)",
            lineHeight: "0.9",
            letterSpacing: "-0.05em",
            fontWeight: 400,
            color: color.textPrimary,
          }}
        >
          Principles
        </h2>
      </div>

      <div className="pb-20" style={{ borderColor: color.borderSubtle }}>
        <p
          className="col-span-12"
          style={{
            fontFamily: typography.h2.family,
            fontSize: "clamp(22px, 2.4vw, 32px)",
            lineHeight: "1.35",
            letterSpacing: "-0.025em",
            color: color.textPrimary,
            maxWidth: "58ch",
          }}
        >
          Three properties do the work.{" "}
          <span style={{ color: color.textMuted }}>
            Tight execution at peg. Dense capital across N assets. And a clean
            fence when one of them breaks.
          </span>
        </p>
      </div>

      <div className="grid grid-cols-12 gap-5">
        {PILLARS.map((p, i) => {
          const letter = String.fromCharCode(65 + i);
          return (
            <article
              key={p.n}
              className="col-span-12 border-t border-dashed"
              style={{ borderColor: color.borderSubtle }}
            >
              <div
                className="grid grid-cols-12 items-center gap-5 py-3"
                style={{
                  fontFamily: "var(--font-mono)",
                  fontSize: typography.caption.size,
                  letterSpacing: typography.caption.letterSpacing,
                  color: color.textMuted,
                  textTransform: "uppercase",
                }}
              >
                <span className="col-span-12 md:col-span-2">{`// II / 01 / ${letter}`}</span>
                <span className="col-span-12 md:col-span-10">{`// PRINCIPLES / ${p.tag}`}</span>

              </div>

              <div className="grid grid-cols-1 md:grid-cols-12 gap-y-10 md:gap-x-10 py-20 md:py-12">
                <div className="md:col-span-2">
                  <span
                    style={{
                       fontFamily: typography.h1.family,
                      fontSize: "clamp(36px, 3.6vw, 40px)",
                      lineHeight: "1.05",
                      letterSpacing: "-0.03em",
                      color: color.textMuted,
                      fontWeight: 400,
                    }}
                  >
                    {letter}
                  </span>
                </div>

                <div className="md:col-span-4">
                  <h3
                    style={{
                      fontFamily: typography.h1.family,
                      fontSize: "clamp(36px, 3.6vw, 40px)",
                      lineHeight: "1.05",
                      letterSpacing: "-0.03em",
                      color: color.textPrimary,
                      fontWeight: 400,
                    }}
                  >
                    {p.title}
                  </h3>
                </div>

                <div className="md:col-span-6 md:col-start-7  grid gap-10">
                  <p
                    style={{
                       fontFamily: typography.h2.family,
                        fontSize: "clamp(22px, 2.4vw, 32px)",
                        lineHeight: "1.35",

                     color: color.textPrimary,

                    }}
                  >
                    {p.lede} {p.body}
                  </p>

                  <p
                    style={{
                      fontFamily: typography.p1.family,
                      fontSize: "clamp(20px, 1.6vw, 26px)",
                      lineHeight: "1.45",
                      color: color.textMuted,
                      maxWidth: "42ch",
                    }}
                  >
                    {p.metric.caption} — measured against an equivalent flat-sphere pool.
                  </p>

                  <div
                    className="grid grid-cols-12 items-baseline gap-5 pt-6 border-t border-dashed max-w-md"
                    style={{ borderColor: color.borderSubtle }}
                  >
                    <p
                      className="col-span-7"
                      style={{
                        fontFamily: "var(--font-mono)",
                        fontSize: typography.caption.size,
                        lineHeight: typography.caption.lineHeight,
                        letterSpacing: typography.caption.letterSpacing,
                        color: color.textMuted,
                        textTransform: "uppercase",
                      }}
                    >
                      {p.metric.caption}
                    </p>
                    <div className="col-span-5 inline-grid grid-flow-col auto-cols-max items-baseline gap-1.5 whitespace-nowrap justify-self-end">
                      <span
                        style={{
                          fontFamily: typography.h2.family,
                          fontSize: typography.h2.size,
                          lineHeight: "1",
                          letterSpacing: typography.h2.letterSpacing,
                          color: p.accent,
                          fontWeight: 500,
                        }}
                      >
                        {p.metric.value}
                      </span>
                      <span
                        style={{
                          fontFamily: typography.p2.family,
                          fontSize: typography.p2.size,
                          lineHeight: typography.p2.lineHeight,
                          letterSpacing: typography.p2.letterSpacing,
                          color: color.textSecondary,
                        }}
                      >
                        {p.metric.unit}
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            </article>
          );
        })}
        <div
          className=""
          style={{ borderColor: color.borderSubtle }}
        />
      </div>
    </section>
  );
}
