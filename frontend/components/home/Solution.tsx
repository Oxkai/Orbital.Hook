import { color, colors, typography } from "@/constants";
import { SectionLabel } from "./SectionLabel";
import { Emphasized } from "./Emphasized";
import { Tex } from "@/components/Tex";

const MONO = "var(--font-mono)";

type Answer = {
  n: string;
  kind: string;
  title: string;
  tag: string;
  tex: string;
  answers: string;
  lede: string;
  body: string;
  points: string[];
  accent: string;
};

const ANSWERS: Answer[] = [
  {
    n: "01",
    kind: "GEOMETRY",
    title: "Spherical",
    tag: "N tokens · one reserve book",
    tex: "\\lVert \\vec{r} - \\vec{x} \\rVert^{2} = r^{2}",
    answers: "ANSWERS 01 + 02",
    lede: "Reserves ride a sphere, not a hyperbola.",
    body: "Uniswap prices two tokens on a curve; Orbital prices N tokens on an N-sphere. Every pair in the basket draws on the same reserves, so a USDC/FRAX trade has the same depth as USDC/USDT. One deep book replaces six thin ones, and adding a coin adds a dimension, not a market.",
    points: [
      "At the equal-price point every coin trades exactly 1:1",
      "The curve only bends as the basket drifts off peg",
      "Swaps stay O(1) however many coins are listed",
    ],
    accent: colors.purple.hex,
  },
  {
    n: "02",
    kind: "TICKS",
    title: "Bounded",
    tag: "per-LP depeg plane",
    tex: "\\textstyle\\sum_i x_i = k",
    answers: "ANSWERS 02 + 03",
    lede: "Each LP chooses the depeg they will hold.",
    body: "A plane cuts the sphere at a chosen bound: say, only while the coin holds above $0.95. Capital packs into that narrow band near peg where dollars actually trade, and a small real deposit behaves like a far larger reserve. Cross the bound and the tick exits to the boundary, so the pool stops absorbing the failure.",
    points: [
      "Virtual reserves, generalised from Uniswap v3 to the N-sphere",
      "Loss is capped at the bound the LP picked, by construction",
      "N−1 assets keep trading 1:1 straight through a depeg",
    ],
    accent: colors.green.hex,
  },
];

function AnswerCard({ a }: { a: Answer }) {
  return (
    <article className="flex flex-col" style={{ backgroundColor: color.surface1 }}>
      <div
        className="flex items-center justify-between gap-3 px-6 py-4 border-b border-dashed"
        style={{ borderColor: color.borderSubtle }}
      >
        <span
          style={{
            fontFamily: MONO,
            fontSize: "11px",
            letterSpacing: "0.1em",
            color: color.textMuted,
            textTransform: "uppercase",
          }}
        >
          {`// ${a.n} / ${a.kind}`}
        </span>
        <span
          className="text-right"
          style={{
            fontFamily: MONO,
            fontSize: "10px",
            letterSpacing: "0.08em",
            color: a.accent,
            textTransform: "uppercase",
          }}
        >
          {a.tag}
        </span>
      </div>

      <div className="flex flex-col gap-6 px-6 pt-8 pb-8 flex-1">
        <div className="flex flex-col gap-2">
          <span
            style={{
              fontFamily: MONO,
              fontSize: "10px",
              letterSpacing: "0.12em",
              color: color.textMuted,
              textTransform: "uppercase",
            }}
          >
            {a.answers}
          </span>
          <h3
            style={{
              fontFamily: typography.h1.family,
              fontSize: "clamp(34px, 4vw, 52px)",
              lineHeight: "0.98",
              letterSpacing: "-0.04em",
              color: color.textPrimary,
              fontWeight: 400,
            }}
          >
            {a.title}
          </h3>
        </div>

        <div
          className="px-4 border border-dashed flex items-center justify-center [&_.katex-display]:my-0"
          style={{ borderColor: color.borderSubtle, color: a.accent, fontSize: "19px", height: 60 }}
        >
          <Tex block>{a.tex}</Tex>
        </div>

        <p
          style={{
            fontFamily: typography.h2.family,
            fontSize: "clamp(20px, 2.1vw, 26px)",
            lineHeight: "1.3",
            letterSpacing: "-0.02em",
            color: color.textPrimary,
          }}
        >
          {a.lede}
        </p>

        <p
          className="flex-1"
          style={{
            fontFamily: typography.p2.family,
            fontSize: typography.p2.size,
            lineHeight: "22px",
            letterSpacing: typography.p2.letterSpacing,
            color: color.textMuted,
          }}
        >
          {a.body}
        </p>

        <ul className="flex flex-col mt-1">
          {a.points.map((pt, i) => (
            <li
              key={pt}
              className="grid grid-cols-[20px_1fr] items-baseline gap-3 py-3 border-t border-dashed"
              style={{ borderColor: color.borderSubtle }}
            >
              <span
                style={{
                  fontFamily: MONO,
                  fontSize: "11px",
                  letterSpacing: "0.04em",
                  color: a.accent,
                }}
              >
                {String.fromCharCode(65 + i)}
              </span>
              <span
                style={{
                  fontFamily: typography.p1.family,
                  fontSize: "16px",
                  lineHeight: "1.35",
                  letterSpacing: "-0.01em",
                  color: color.textSecondary,
                }}
              >
                {pt}
              </span>
            </li>
          ))}
        </ul>
      </div>
    </article>
  );
}

export function Solution() {
  return (
    <section className="mx-6 my-1">
      <SectionLabel border chapter="III" section="02" path="ORBITAL / SOLUTION" />

      <div className="pb-12 pt-20">
        <Emphasized
          size="clamp(40px, 5vw, 72px)"
          lineHeight="1.05"
          letterSpacing="-0.04em"
          fontFamily={typography.h1.family}
          segments={[
            { t: "Orbital does both at once", v: "on" },
            { t: ".", v: "green" },
            " ",
            { t: "It comes down to the ", v: "off" },
            { t: "shape of the curve", v: "on" },
            { t: ": price N coins on a ", v: "off" },
            { t: "sphere", v: "on" },
            { t: " and the whole basket shares one book", v: "off" },
            { t: ".", v: "green" },
            " ",
            { t: "Let each LP ", v: "off" },
            { t: "cut it with a plane", v: "on" },
            { t: " and depth lands at the peg, with a ", v: "off" },
            { t: "bound on what they can lose", v: "on" },
            { t: ".", v: "green" },
          ]}
        />
      </div>

      <div className="grid grid-cols-1 gap-1 md:grid-cols-2 mb-24 items-stretch">
        {ANSWERS.map((a) => (
          <AnswerCard key={a.n} a={a} />
        ))}
      </div>
    </section>
  );
}
