import { color, colors } from "@/constants";

export function SphereMark() {
  const size = 420;
  const cx = size / 2;
  const cy = size / 2;
  const r = 170;

  const longitudes = Array.from({ length: 14 }, (_, i) => (i * Math.PI) / 7);
  const latitudes = Array.from({ length: 8 }, (_, i) => -Math.PI / 2 + (i * Math.PI) / 7);

  const pathFromMeridian = (theta: number) => {
    const points: string[] = [];
    for (let t = -Math.PI / 2; t <= Math.PI / 2 + 0.01; t += Math.PI / 40) {
      const x3 = Math.cos(t) * Math.cos(theta);
      const z3 = Math.cos(t) * Math.sin(theta);
      const y3 = Math.sin(t);
      const px = cx + x3 * r;
      const py = cy - y3 * r;
      const alpha = (z3 + 1) / 2;
      points.push(`${points.length === 0 ? "M" : "L"}${px.toFixed(1)},${py.toFixed(1)}`);
      void alpha;
    }
    return points.join(" ");
  };

  const pathFromParallel = (phi: number) => {
    const points: string[] = [];
    const rr = Math.cos(phi) * r;
    const yy = cy - Math.sin(phi) * r;
    for (let t = 0; t <= Math.PI * 2 + 0.01; t += Math.PI / 60) {
      const px = cx + Math.cos(t) * rr;
      const py = yy + Math.sin(t) * rr * 0.35;
      points.push(`${points.length === 0 ? "M" : "L"}${px.toFixed(1)},${py.toFixed(1)}`);
    }
    return points.join(" ");
  };

  const reserveDot = { x: cx + 0.62 * r, y: cy - 0.18 * r };
  const tickPlanes = [0.35, 0.55, 0.72, 0.88];

  return (
    <div
      className="relative w-full border border-dashed"
      style={{
        borderColor: color.border,
        backgroundColor: color.surface1,
        aspectRatio: "1 / 1",
      }}
    >
      <div
        className="absolute top-3 left-3 right-3 flex items-center justify-between"
        style={{
          fontFamily: "var(--font-mono)",
          fontSize: "10px",
          letterSpacing: "0.08em",
          color: color.textMuted,
          textTransform: "uppercase",
        }}
      >
        <span>{"//"} LIVE / RESERVE VECTOR</span>
        <span>N = 4</span>
      </div>

      <svg
        viewBox={`0 0 ${size} ${size}`}
        width="100%"
        height="100%"
        style={{ display: "block" }}
      >
        <circle
          cx={cx}
          cy={cy}
          r={r}
          fill="none"
          stroke={color.border}
          strokeWidth={1}
          strokeDasharray="2 3"
        />

        {tickPlanes.map((k, i) => (
          <ellipse
            key={i}
            cx={cx}
            cy={cy - k * r * 0.4}
            rx={r * Math.sqrt(1 - k * k) * 0.95}
            ry={r * Math.sqrt(1 - k * k) * 0.32}
            fill="none"
            stroke={i === 2 ? colors.purple.hex : color.borderSubtle}
            strokeOpacity={i === 2 ? 0.8 : 0.5}
            strokeWidth={1}
            strokeDasharray={i === 2 ? "4 3" : "1 3"}
          />
        ))}

        {longitudes.map((theta, i) => (
          <path
            key={`lon-${i}`}
            d={pathFromMeridian(theta)}
            fill="none"
            stroke={color.borderSubtle}
            strokeWidth={0.5}
            opacity={0.7}
          />
        ))}
        {latitudes.map((phi, i) => (
          <path
            key={`lat-${i}`}
            d={pathFromParallel(phi)}
            fill="none"
            stroke={color.borderSubtle}
            strokeWidth={0.5}
            opacity={0.5}
          />
        ))}

        <circle
          cx={reserveDot.x}
          cy={reserveDot.y}
          r={14}
          fill={colors.purple.hex}
          opacity={0.12}
        />
        <circle
          cx={reserveDot.x}
          cy={reserveDot.y}
          r={5}
          fill={colors.purple.hex}
        />
        <line
          x1={cx}
          y1={cy}
          x2={reserveDot.x}
          y2={reserveDot.y}
          stroke={colors.purple.hex}
          strokeWidth={1}
          strokeDasharray="2 2"
          opacity={0.8}
        />

        {["USDC", "USDT", "DAI", "FRAX"].map((tk, i) => {
          const a = (i * Math.PI * 2) / 4 - Math.PI / 2;
          const x = cx + Math.cos(a) * (r + 24);
          const y = cy + Math.sin(a) * (r + 24);
          return (
            <text
              key={tk}
              x={x}
              y={y}
              textAnchor="middle"
              dominantBaseline="middle"
              fill={color.textMuted}
              style={{
                fontFamily: "var(--font-mono)",
                fontSize: "10px",
                letterSpacing: "0.08em",
              }}
            >
              {tk}
            </text>
          );
        })}
      </svg>

      <div
        className="absolute bottom-3 left-3 right-3 flex items-center justify-between"
        style={{
          fontFamily: "var(--font-mono)",
          fontSize: "10px",
          letterSpacing: "0.06em",
          color: color.textMuted,
        }}
      >
        <span>rInt = 1.99M</span>
        <span>TICKS 3/4 INTERIOR</span>
        <span style={{ color: colors.green.hex }}>● HEALTHY</span>
      </div>
    </div>
  );
}
