// Pure simulation math for a 3-token Orbital pool: a faithful float port of the
// on-chain geometry in orbitalHook/src/libraries (SphereMath + TickLib) and the
// OrbitalHook engine. Used to draw two correct cross-sections of the reserve
// sphere with real virtual reserves, real ticks and real capital efficiency.
//
// Sphere invariant (n assets):  Σ (r − xᵢ)² = r²   (centre (r,r,r))
//   • equal-price point:   xᵢ = r·(1 − 1/√n)          (SphereMath.equalPricePoint)
//   • spot price j in i:   (r − x_j)/(r − x_i)         (SphereMath.spotPrice)
//   • a tick is a plane k; it concentrates liquidity in a reserve band and has a
//     capital efficiency > 1×                          (TickLib §4.7–4.9)

export const TOKENS = ["USDC", "USDT", "DAI"] as const;
export type TokenSymbol = (typeof TOKENS)[number];

export const N = 3;
export const SQRT_N = Math.sqrt(N);

export type PoolState = {
  /** sphere radius */
  r: number;
  /** virtual reserve vector x⃗ (what OrbitalHook tracks as `reserves`) */
  x: [number, number, number];
};

/** Illustrative LP ticks, named by the depeg they tolerate (0.01 = 1%). */
export const TICK_DEPEGS = [0.001, 0.01, 0.05, 0.1] as const;

// ── core sphere geometry ──────────────────────────────────────

export function equalPricePoint(r: number): number {
  return r * (1 - 1 / SQRT_N);
}

/** Realistic pool: $10M virtual reserve per token ⇒ $30M TVL. */
export function initState(perToken = 10_000_000): PoolState {
  const r = perToken / (1 - 1 / SQRT_N);
  return { r, x: [perToken, perToken, perToken] };
}

export function spotPrice(s: PoolState, i: number, j: number): number {
  return (s.r - s.x[j]) / (s.r - s.x[i]);
}

/** Price of every token vs the balanced leg (r/√n); equal-price ⇒ all 1.0. */
export function prices(s: PoolState): [number, number, number] {
  const base = s.r / SQRT_N;
  return [(s.r - s.x[0]) / base, (s.r - s.x[1]) / base, (s.r - s.x[2]) / base];
}

export function maxDepeg(s: PoolState): number {
  return Math.max(...prices(s).map((p) => Math.abs(p - 1)));
}

export function tvl(s: PoolState): number {
  return s.x[0] + s.x[1] + s.x[2];
}

export function maxAmountIn(s: PoolState, i: number): number {
  return Math.max(0, (s.r - s.x[i]) * 0.85);
}

/** Closed-form output of swapping `amountIn` of token `i` for token `j`. */
export function quoteSwap(s: PoolState, i: number, j: number, amountIn: number): number {
  if (i === j || amountIn <= 0) return 0;
  const a = s.r - s.x[i];
  const b = s.r - s.x[j];
  const C = a * a + b * b;
  const aNew = a - amountIn;
  if (aNew <= 0) return s.x[j];
  const bNew2 = C - aNew * aNew;
  if (bNew2 <= 0) return 0;
  const xjNew = s.r - Math.sqrt(bNew2);
  return Math.max(0, Math.min(s.x[j], s.x[j] - xjNew));
}

export function applySwap(s: PoolState, i: number, j: number, amountIn: number): PoolState {
  const out = quoteSwap(s, i, j, amountIn);
  const x: [number, number, number] = [...s.x];
  x[i] += amountIn;
  x[j] -= out;
  return { r: s.r, x };
}

// ── tick geometry (float port of TickLib) ─────────────────────

export function kMin(r: number): number {
  return r * (SQRT_N - 1);
}
export function kMax(r: number): number {
  return (r * (N - 1)) / SQRT_N;
}

/** k from a depeg price p (e.g. 0.99) TickLib.kFromDepegPrice. */
export function kFromDepegPrice(r: number, p: number): number {
  const km = kMin(r);
  const kM = kMax(r);
  if (p >= 1) return km;
  if (p <= 0) return kM;
  const sqrtDenom = Math.sqrt(N * (p * p + (N - 1)));
  const numerator = p + (N - 1);
  const k = (r * (SQRT_N * sqrtDenom - numerator)) / sqrtDenom;
  return Math.min(kM, Math.max(km, k));
}

/** Per-asset reserve band [xMin, xMax] inside tick k: TickLib._reserveBounds. */
export function reserveBounds(r: number, k: number): { xMin: number; xMax: number } {
  const kSn = k * SQRT_N;
  const A = Math.max(0, (N - 1) * r - kSn);
  const disc = Math.max(0, N * k * k - N * A * A);
  const sd = Math.sqrt(disc);
  return {
    xMin: Math.max(0, (kSn - sd) / N),
    xMax: Math.min((kSn + sd) / N, r),
  };
}

/** Capital efficiency xBase/(xBase − xMin) TickLib.capitalEfficiency. */
export function capitalEfficiency(r: number, k: number): number {
  if (Math.abs(k - kMax(r)) < 1e-6) return 1;
  const xBase = equalPricePoint(r);
  const { xMin } = reserveBounds(r, k);
  if (xBase <= xMin) return 1;
  return xBase / (xBase - xMin);
}

export type TickInfo = {
  depeg: number; // tolerance, e.g. 0.01
  price: number; // p = 1 − depeg
  k: number;
  capEff: number;
  xMin: number;
  xMax: number;
  interior: boolean;
};

/** The pool's ticks with their real properties and interior/boundary status. */
export function ticks(s: PoolState): TickInfo[] {
  const d = maxDepeg(s);
  return TICK_DEPEGS.map((depeg) => {
    const price = 1 - depeg;
    const k = kFromDepegPrice(s.r, price);
    const { xMin, xMax } = reserveBounds(s.r, k);
    return {
      depeg,
      price,
      k,
      capEff: capitalEfficiency(s.r, k),
      xMin,
      xMax,
      interior: d < depeg, // price still inside this tick's tolerance
    };
  });
}

// ── section A: project along the equal-price (1,1,1) axis ─────

const INV_SQRT2 = 1 / Math.SQRT2;
const INV_SQRT6 = 1 / Math.sqrt(6);

export const AXIS_PROJ: { x: number; y: number }[] = [
  { x: INV_SQRT2, y: INV_SQRT6 }, // USDC
  { x: -INV_SQRT2, y: INV_SQRT6 }, // USDT
  { x: 0, y: -2 * INV_SQRT6 }, // DAI
];

/** Reserve vector in section A: angle = imbalance direction, depeg = radius. */
export function tickPlanePoint(s: PoolState): { angle: number; depeg: number } {
  const q = equalPricePoint(s.r);
  let px = 0;
  let py = 0;
  for (let i = 0; i < 3; i++) {
    const w = q - s.x[i]; // scarce (x<q) ⇒ w>0 ⇒ drift toward token i
    px += w * AXIS_PROJ[i].x;
    py += w * AXIS_PROJ[i].y;
  }
  return { angle: Math.atan2(py, px), depeg: maxDepeg(s) };
}

// ── section B: two-token plane (third token fixed) ───────────

export type PairArc = {
  i: number;
  j: number;
  third: number;
  r: number;
  rho: number;
  low: number;
  xi: number;
  xj: number;
};

export function pairArc(s: PoolState, i: number, j: number): PairArc {
  const third = 3 - i - j;
  const legK = s.r - s.x[third];
  const rho = Math.sqrt(Math.max(0, s.r * s.r - legK * legK));
  return { i, j, third, r: s.r, rho, low: s.r - rho, xi: s.x[i], xj: s.x[j] };
}

export function arcXj(arc: PairArc, xi: number): number {
  const dx = arc.r - xi;
  const v = arc.rho * arc.rho - dx * dx;
  if (v <= 0) return arc.r;
  return arc.r - Math.sqrt(v);
}
