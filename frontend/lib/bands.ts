/** The hook's fixed menu of depeg bands (`BandLib` in the contracts).
 *
 *  A position is opened in a band, not at an arbitrary k: band `i` pins when an
 *  asset depegs to `BAND_BPS[i] / 10_000` of the peg, and every deposit into a
 *  band joins that band's one tick. The band index is also the position's
 *  ERC-6909 token id. Tightest first; the last band (0) is full range.
 *
 *  This mirrors the contract's menu so the UI can label bands without a read;
 *  the hook exposes the same values as `bandDepegPrice(i)`. */
export const BAND_BPS = [
  9999, 9998, 9995, 9990, 9985, 9980, 9975, 9970, 9960, 9950,
  9940, 9925, 9900, 9875, 9850, 9800, 9750, 9700, 9600, 9500,
  9400, 9200, 9000, 8800, 8500, 8000, 7500, 7000, 6000, 5000,
  0,
] as const;

export const NUM_BANDS = BAND_BPS.length;

/** Index of the full-range band. */
export const FULL_RANGE_BAND = NUM_BANDS - 1;

/** Band a new position defaults to ($0.95). */
export const DEFAULT_BAND = BAND_BPS.indexOf(9500);

/** The band's depeg threshold as a price (0 for full range). */
export function bandDepegPrice(band: number): number {
  return (BAND_BPS[band] ?? 0) / 10_000;
}

export function isFullRange(band: number): boolean {
  return band === FULL_RANGE_BAND;
}

/** "$0.9500", or "Full range". */
export function bandLabel(band: number): string {
  return isFullRange(band) ? "Full range" : `$${bandDepegPrice(band).toFixed(4)}`;
}
