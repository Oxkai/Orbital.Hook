import { type Hex, BaseError, ContractFunctionRevertedError, decodeErrorResult } from "viem";

// ─── Revert explanation ──────────────────────────────────────────────────────
// A swap or quote that the hook rejects reaches the client wrapped in up to two
// layers: the PoolManager wraps every hook revert as `WrappedError`, and the
// V4Quoter wraps anything that is not a quote as `UnexpectedRevertBytes`. The
// useful part is the innermost error, so unwrap until it is reached.

const POOL_ERRORS_ABI = [
  // Wrappers
  { type: "error", name: "UnexpectedRevertBytes", inputs: [{ name: "revertData", type: "bytes" }] },
  {
    type: "error",
    name: "WrappedError",
    inputs: [
      { name: "target", type: "address" },
      { name: "selector", type: "bytes4" },
      { name: "reason", type: "bytes" },
      { name: "details", type: "bytes" },
    ],
  },
  // OrbitalHook engine
  { type: "error", name: "NotEnoughLiquidity", inputs: [] },
  { type: "error", name: "SwapAmountTooSmall", inputs: [{ type: "uint256" }] },
  { type: "error", name: "SwapAmountTooLarge", inputs: [{ type: "uint256" }] },
  { type: "error", name: "TooManyCrossings", inputs: [] },
  { type: "error", name: "SwapExceedsLiquidity", inputs: [] },
  { type: "error", name: "SwapBeyondZeroPrice", inputs: [] },
  { type: "error", name: "InsufficientRealReserves", inputs: [{ type: "uint8" }] },
  { type: "error", name: "EnforcedPause", inputs: [] },
  // Liquidity
  { type: "error", name: "TickOutsideItsBand", inputs: [] },
  { type: "error", name: "MintBlockedByBoundaryTicks", inputs: [] },
  { type: "error", name: "InvalidBand", inputs: [{ type: "uint256" }] },
  { type: "error", name: "DeadlinePassed", inputs: [] },
  { type: "error", name: "RadiusCapExceeded", inputs: [] },
  { type: "error", name: "NothingOwed", inputs: [] },
  { type: "error", name: "SlippageExceeded", inputs: [{ type: "uint8" }, { type: "uint256" }, { type: "uint256" }] },
] as const;

const MESSAGES: Record<string, string> = {
  NotEnoughLiquidity: "The pool has no active liquidity.",
  SwapAmountTooSmall: "Amount too small to trade.",
  SwapAmountTooLarge: "Amount too large for a single trade.",
  TooManyCrossings: "This trade crosses too many liquidity bands at once. Split it into smaller trades.",
  SwapExceedsLiquidity: "This trade is larger than the pool can fill in this direction. Try a smaller amount.",
  SwapBeyondZeroPrice: "This trade sells more than the pool will take at any positive price. Try a smaller amount.",
  InsufficientRealReserves: "The pool doesn't hold enough of that token to fill this. Try a smaller amount.",
  TickOutsideItsBand: "The pool's price is outside this band, or the band is paused by a depeg. Choose a wider band.",
  MintBlockedByBoundaryTicks: "Every band in the pool is paused by a depeg. Deposits reopen once the price moves back.",
  InvalidBand: "That band doesn't exist on this pool.",
  DeadlinePassed: "The transaction waited too long to be included. Try again.",
  RadiusCapExceeded: "This deposit would take the pool past its size limit.",
  NothingOwed: "There is nothing to claim.",
  SlippageExceeded: "The pool moved since the quote. Try again.",
  EnforcedPause: "Swaps are paused by the pool admin.",
};

/// The innermost named error in `data`, following the known wrappers.
function innermostError(data: Hex): string | undefined {
  for (let depth = 0; depth < 4; depth++) {
    let decoded;
    try {
      decoded = decodeErrorResult({ abi: POOL_ERRORS_ABI, data });
    } catch {
      return undefined;
    }
    if (decoded.errorName === "UnexpectedRevertBytes") data = decoded.args[0] as Hex;
    else if (decoded.errorName === "WrappedError") data = decoded.args[2] as Hex;
    else return decoded.errorName;
  }
  return undefined;
}

/// Human explanation for a failed quote, swap or liquidity action on any
/// Orbital pool, or undefined if the error is not one we recognise (callers
/// fall back to the raw message).
export function explainPoolError(error: unknown): string | undefined {
  if (!(error instanceof BaseError)) return undefined;
  const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
  if (!(reverted instanceof ContractFunctionRevertedError) || !reverted.raw) return undefined;
  const name = innermostError(reverted.raw);
  return name ? MESSAGES[name] : undefined;
}
