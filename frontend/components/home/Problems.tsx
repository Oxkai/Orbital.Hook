import { color, colors, typography } from "@/constants";
import { SectionLabel } from "./SectionLabel";
import { Emphasized } from "./Emphasized";
import { Tex } from "@/components/Tex";
import { ProblemDiagram, type ProblemDiagramKind } from "./ProblemDiagram";

const MONO = "var(--font-mono)";

type Problem = {
  n: string;
  kind: string;
  title: string;
  tag: string;
  tex: string;
  diagram: ProblemDiagramKind;
  lede: string;
  points: string[];
  accent: string;
};

const PROBLEMS: Problem[] = [
  {
    n: "01",
    kind: "FRAGMENTATION",
    title: "Fragmented",
    tag: "4 coins → 6 pools",
    tex: "\\tfrac{N(N-1)}{2}\\ \\text{markets}",
    diagram: "fragmented",
    lede: "One basket, split across six order books.",
    points: [
      "A USDC/FRAX trade cannot touch USDC/USDT depth",
      "Per-pool depth falls as the basket grows",
      "Every new stablecoin needs its own set of markets",
    ],
    accent: colors.yellow.hex,
  },
  {
    n: "02",
    kind: "DENSITY",
    title: "Flat",
    tag: "~1–2× a flat curve",
    tex: "x \\cdot y = k",
    diagram: "flat",
    lede: "Depth spread across prices a dollar never reaches.",
    points: [
      "Curve: the whole basket, thin at the peg",
      "Uniswap v3: dense at the peg, one pair only",
      "Idle capital earns nothing and cushions nothing",
    ],
    accent: colors.yellow.hex,
  },
  {
    n: "03",
    kind: "TAIL RISK",
    title: "Fragile",
    tag: "USDC → $0.88 · Mar 2023",
    tex: "p_i \\to 0 \\;\\Rightarrow\\; \\vec{x} \\to x_i",
    diagram: "fragile",
    lede: "One broken coin becomes the entire pool.",
    points: [
      "The pool prices the depeg last, not first",
      "LPs absorb the fall with no bound of their own",
      "USDC after SVB: flat pools took the loss",
    ],
    accent: colors.red.hex,
  },
];

function ProblemCard({ p }: { p: Problem }) {
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
          {`// ${p.n} / ${p.kind}`}
        </span>
        <span
          className="text-right"
          style={{
            fontFamily: MONO,
            fontSize: "10px",
            letterSpacing: "0.08em",
            color: p.accent,
            textTransform: "uppercase",
          }}
        >
          {p.tag}
        </span>
      </div>

      <div className="flex flex-col gap-6 px-6 pt-8 pb-8 flex-1">
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
          {p.title}
        </h3>

        <div className="border border-dashed flex flex-col" style={{ borderColor: color.borderSubtle }}>
          <div className="px-5 py-6">
            <ProblemDiagram kind={p.diagram} />
          </div>
          <div
            className="px-4 py-3 border-t border-dashed flex items-center justify-center [&_.katex-display]:my-0"
            style={{ borderColor: color.borderSubtle, color: p.accent, fontSize: "17px" }}
          >
            <Tex block>{p.tex}</Tex>
          </div>
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
          {p.lede}
        </p>

        <ul className="flex flex-col mt-auto pt-2">
          {p.points.map((pt, i) => (
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
                  color: p.accent,
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

export function Problems() {
  return (
    <section className="mx-6 my-1">
      <SectionLabel border chapter="II" section="01" path="ORBITAL / PROBLEM" />

      <div className="pb-12 pt-20">
        <Emphasized
          size="clamp(40px, 5vw, 72px)"
          lineHeight="1.05"
          letterSpacing="-0.04em"
          fontFamily={typography.h1.family}
          segments={[
            { t: "Stablecoins all target the same dollar", v: "on" },
            { t: ", but ", v: "off" },
            { t: "AMMs make you choose", v: "on" },
            { t: ".", v: "green" },
            " ",
            { t: "Hold the ", v: "off" },
            { t: "whole basket", v: "on" },
            { t: " and depth goes thin. Get ", v: "off" },
            { t: "real depth", v: "on" },
            { t: " and you are back to two tokens", v: "off" },
            { t: ".", v: "green" },
            " ",
            { t: "Either way, ", v: "off" },
            { t: "one broken coin drains the rest", v: "on" },
            { t: ".", v: "green" },
          ]}
        />
      </div>

      <div className="grid grid-cols-1 gap-1 md:grid-cols-3 mb-24 items-stretch">
        {PROBLEMS.map((p) => (
          <ProblemCard key={p.n} p={p} />
        ))}
      </div>
    </section>
  );
}
