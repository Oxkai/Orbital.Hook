/** Real value of `shares` of a tick's liquidity, in the engine's WAD value
 *  units (USD): the shares' pro-rata part of the pool's virtual reserves, less
 *  their part of the tick's virtual reserve, summed over assets.
 *
 *  This is exactly what `removeLiquidity` pays while every tick is interior
 *  (the hook's burn formula); with a tick on its boundary burns are blocked
 *  and the figure is an estimate. */
export function positionValueWad(
  reservesVirtual: readonly bigint[],
  rIntWad: bigint,
  tickR: bigint,
  tickVirtual: bigint,
  shares: bigint,
): bigint {
  if (rIntWad === 0n || tickR === 0n || shares === 0n) return 0n;
  const virtualShare = (tickVirtual * shares) / tickR;
  return reservesVirtual.reduce((sum, x) => {
    const share = (x * shares) / rIntWad;
    return sum + (share > virtualShare ? share - virtualShare : 0n);
  }, 0n);
}
