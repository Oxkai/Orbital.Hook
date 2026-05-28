import { color, typography } from "@/constants";
import { SectionLabel } from "./SectionLabel";
import { Tex } from "@/components/Tex";

const MONO = "var(--font-mono)";

const CARDS = [
  {
    n: "01",
    title: "Sphere",
    lede: "Reserves live on an N-dimensional sphere.",
    tex: "\\lVert \\vec{r} - \\vec{x} \\rVert^{2} = r^{2}",
    body: "All N coins share one surface. At the centre every pair trades 1:1 — the curve only bends as the basket drifts off peg.",
  },
  {
    n: "02",
    title: "Ticks",
    lede: "Each LP picks a plane — its depeg tolerance.",
    tex: "k_{\\min} \\le \\vec{1}\\cdot\\vec{x} \\le k_{\\max}",
    body: "A plane cuts the sphere at a chosen depeg bound. Liquidity concentrates between that bound and the peg, so capital never sits idle outside its range.",
  },
  {
    n: "03",
    title: "Torus",
    lede: "Stacked ticks consolidate into one torus.",
    tex: "(\\alpha - r\\sqrt{n})^{2} + (w - s)^{2} = r_{\\text{int}}^{2}",
    body: "Interior ticks fold into one torus. The pool tracks only Σx and Σx² in slot0, so a swap stays O(1) regardless of ticks or coins.",
  },
] as const;

function MechanicsCard({ card }: { card: typeof CARDS[number] }) {
  return (
    <article
      className="flex flex-col"
      style={{ backgroundColor: color.surface1, minHeight: 320 }}
    >
      <div
        className="px-6 py-4 border-b border-dashed"
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
          {`// ${card.n} / ${card.title.toUpperCase()}`}
        </span>
      </div>

      <div className="flex flex-col gap-5 px-6 pt-8 pb-7">
        <p
          style={{
            fontFamily: typography.h1.family,
            fontSize: "clamp(24px, 2.6vw, 34px)",
            lineHeight: "1.12",
            letterSpacing: "-0.03em",
            color: color.textPrimary,
            fontWeight: 400,
            minHeight: "2.24em",
          }}
        >
          {card.lede}
        </p>

        {/* Formula */}
        <div
          className="px-4 border border-dashed flex items-center justify-center [&_.katex-display]:my-0"
          style={{ borderColor: color.borderSubtle, color: color.accent, fontSize: "18px", height: 56 }}
        >
          <Tex block>{card.tex}</Tex>
        </div>

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
          {card.body}
        </p>
      </div>
    </article>
  );
}

export function Mechanics() {
  return (
    <section className="mx-6 my-1">
      <SectionLabel border chapter="III" section="02" path="ORBITAL / MECHANICS" />

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
          The whole curve, in three shapes.{" "}
          <span style={{ color: color.textMuted }}>
            A sphere for the reserves, a plane for every LP position, and a torus that folds them into one O(1) swap.
          </span>
        </p>
      </div>

      <div className="grid grid-cols-1 gap-1 md:grid-cols-3 mb-24">
        {CARDS.map((card) => (
          <MechanicsCard key={card.n} card={card} />
        ))}
      </div>
    </section>
  );
}
