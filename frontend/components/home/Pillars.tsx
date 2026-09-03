import { color, colors, typography } from "@/constants";
import { SectionLabel } from "./SectionLabel";
import { Emphasized } from "./Emphasized";

type Pillar = {
  n: string;
  tag: string;
  title: string;
  lede: string;
  body: string;
  note: string;
  metric: { value: string; unit: string; caption: string };
  accent: string;
};

const PILLARS: Pillar[] = [
  {
    n: "01",
    tag: "EXECUTION",
    title: "Low slippage",
    lede: "While the coins hold their peg, trades barely move the price.",
    body: "Every LP packs their liquidity right around the peg, where stablecoins actually trade, so prices stay tight even on large orders, not just small ones.",
    note: "An ordinary AMM spreads its liquidity thinly across every price. Orbital piles it where stablecoins actually change hands.",
    metric: { value: "< 1", unit: "bps", caption: "price impact at peg, p=0.99" },
    accent: colors.green.hex,
  },
  {
    n: "02",
    tag: "DENSITY",
    title: "High capital efficiency",
    lede: "A dollar here does the work of about 154 in an ordinary pool.",
    body: "All the liquidity sits in one pool across every asset: none split between separate pairs, and none left idle outside its range.",
    note: "Compared with a plain pool holding the same reserves over the same peg range.",
    metric: { value: "154", unit: "×", caption: "vs flat sphere, N = 5" },
    accent: colors.purple.hex,
  },
  {
    n: "03",
    tag: "RESILIENCE",
    title: "Automatic depeg isolation",
    lede: "If one coin breaks its peg, the rest keep trading normally.",
    body: "The broken coin is walled off automatically. The pool doesn't drain into it, and the healthy coins stay liquid against each other.",
    note: "No vote, no pause button. The moment a coin's price leaves the tick it's walled off, so LPs stop absorbing it instead of taking the loss an ordinary pool would.",
    metric: { value: "N − 1", unit: "assets", caption: "stay live through a depeg" },
    accent: colors.yellow.hex,
  },
];

export function Pillars() {
  return (
    <section className="mx-6">
      <SectionLabel border chapter="IV" section="03" path="ORBITAL / PRINCIPLES" />

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
        <Emphasized
          size="clamp(22px, 2.4vw, 32px)"
          lineHeight="1.35"
          letterSpacing="-0.025em"
          fontFamily={typography.h2.family}
          maxWidth="58ch"
          segments={[
            { t: "Three things", v: "on" },
            { t: " make Orbital work", v: "off" },
            { t: ".", v: "green" },
            " ",
            { t: "Trades stay cheap", v: "on" },
            { t: " while the coins hold their peg", v: "off" },
            { t: ".", v: "green" },
            " ",
            { t: "Liquidity stays dense", v: "on" },
            { t: " across every asset", v: "off" },
            { t: ".", v: "green" },
            " ",
            { t: "And if one coin ", v: "off" },
            { t: "breaks", v: "on" },
            { t: ", it gets ", v: "off" },
            { t: "walled off", v: "on" },
            { t: " before it can drain the pool", v: "off" },
            { t: ".", v: "green" },
          ]}
        />
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
                <span className="col-span-12 md:col-span-2">{`// IV / 03 / ${letter}`}</span>
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
                    {p.note}
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
