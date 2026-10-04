import { color, colors } from "@/constants";

/**
 * The three problem diagrams, drawn to the same geometry as the pitch deck so
 * the site and the deck read as one piece of work.
 *
 * Colours come from the theme variables rather than the deck's literals, so the
 * strokes and fills follow light and purple themes instead of staying dark-grey
 * on a cream background. The coin colours are brand constants and do not move.
 */

const COIN = [
  colors.purple.hex,
  colors.green.hex,
  colors.yellow.hex,
  colors.red.hex,
];
const LINE = color.surface4;
const MUTED = color.textMuted;

const W = 486;
const H = 176;

export type ProblemDiagramKind = "fragmented" | "flat" | "fragile";

function Frame({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <svg
      role="img"
      aria-label={label}
      viewBox={`0 0 ${W} ${H}`}
      width="100%"
      style={{ display: "block", height: "auto" }}
    >
      {children}
    </svg>
  );
}

/** 01 — four coins split into the six pair pools they need, each one shallow. */
function Fragmented() {
  const pairs: [number, number][] = [
    [0, 1],
    [0, 2],
    [0, 3],
    [1, 2],
    [1, 3],
    [2, 3],
  ];
  const gap = 13;
  const bw = (W - gap * 5) / 6;

  return (
    <Frame label="Four stablecoins split into six pair pools, each holding a sliver of the capital">
      {pairs.map(([a, b], i) => {
        const x = i * (bw + gap);
        return (
          <g key={`${a}${b}`}>
            <circle
              cx={x + bw / 2 - 13}
              cy={18}
              r={9}
              style={{ fill: COIN[a] }}
            />
            <circle
              cx={x + bw / 2 + 13}
              cy={18}
              r={9}
              style={{ fill: COIN[b] }}
            />
            <rect
              x={x}
              y={46}
              width={bw}
              height={112}
              fill="none"
              strokeWidth={1.5}
              style={{ stroke: LINE }}
            />
            <rect
              x={x + 1.5}
              y={138}
              width={bw - 3}
              height={18.5}
              style={{ fill: LINE }}
            />
          </g>
        );
      })}
    </Frame>
  );
}

/** 02 — depth laid flat across prices, with only the band at the peg trading. */
function Flat() {
  const n = 17;
  const gap = 6;
  const bw = (W - gap * (n - 1)) / n;

  return (
    <Frame label="Depth laid flat across every price, with only the band at the peg ever trading">
      {Array.from({ length: n }, (_, i) => (
        <rect
          key={i}
          x={i * (bw + gap)}
          y={84}
          width={bw}
          height={58}
          style={{
            fill: Math.abs(i - (n - 1) / 2) <= 1 ? colors.green.hex : LINE,
          }}
        />
      ))}
      <line
        x1={W / 2}
        y1={18}
        x2={W / 2}
        y2={160}
        strokeWidth={1.5}
        strokeDasharray="5 5"
        style={{ stroke: MUTED }}
      />
    </Frame>
  );
}

/** 03 — pool composition before and after a depeg: the broken coin takes over. */
function Fragile() {
  const gap = 3;
  const seg = (W - gap * 3) / 4;

  return (
    <Frame label="Pool composition before and after a depeg: the broken coin takes over the pool">
      {COIN.map((c, i) => (
        <rect
          key={c}
          x={i * (seg + gap)}
          y={14}
          width={seg}
          height={44}
          style={{ fill: c }}
        />
      ))}
      <path
        d={`M${W / 2} 72 L${W / 2} 100 M${W / 2 - 11} 89 L${W / 2} 102 L${W / 2 + 11} 89`}
        fill="none"
        strokeWidth={2.5}
        style={{ stroke: MUTED }}
      />
      {COIN.slice(0, 3).map((c, i) => (
        <rect
          key={c}
          x={i * 22}
          y={116}
          width={19}
          height={44}
          style={{ fill: c }}
        />
      ))}
      <rect
        x={66}
        y={116}
        width={W - 66}
        height={44}
        style={{ fill: colors.red.hex }}
      />
    </Frame>
  );
}

const DIAGRAMS: Record<ProblemDiagramKind, () => React.ReactElement> = {
  fragmented: Fragmented,
  flat: Flat,
  fragile: Fragile,
};

export function ProblemDiagram({ kind }: { kind: ProblemDiagramKind }) {
  const D = DIAGRAMS[kind];
  return <D />;
}
