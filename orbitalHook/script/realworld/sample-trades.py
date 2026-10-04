#!/usr/bin/env python3
"""Pick the real trades the replay runs, from trades.json (fetch-trades.sh).

Replaying all of a week's swaps as transactions is slow, so this takes a sample
that keeps the shape of the flow: SAMPLE trades evenly spaced through the
size distribution (smallest to largest), plus the LARGEST biggest ones, where
pools differ most. The sample is then put back in the order the trades really
happened, so both pools see the flow in its real sequence.

    script/realworld/sample-trades.py [SAMPLE=50] [LARGEST=10]
"""
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
sample = int(sys.argv[1]) if len(sys.argv) > 1 else 50
largest = int(sys.argv[2]) if len(sys.argv) > 2 else 10

src = json.load(open(os.path.join(here, "trades.json")))
trades = [t for t in src["trades"] if t["amountIn"] > 0]
# Keep each trade's position in the real sequence.
for i, t in enumerate(trades):
    t["seq"] = i

by_size = sorted(trades, key=lambda t: t["amountIn"])
picked = {}
for k in range(sample):
    t = by_size[round(k * (len(by_size) - 1) / (sample - 1))]
    picked[t["seq"]] = t
for t in by_size[-largest:]:
    picked[t["seq"]] = t

replay = sorted(picked.values(), key=lambda t: t["seq"])
out = {
    "source": src["source"],
    "fromBlock": src["fromBlock"],
    "toBlock": src["toBlock"],
    "population": len(trades),
    # Parallel arrays: forge's JSON reader decodes these directly.
    "tx": [t["tx"] for t in replay],
    "usdcIn": [t["usdcIn"] for t in replay],
    "amountIn": [t["amountIn"] for t in replay],
    "v3Paid": [t["amountOut"] for t in replay],
}
json.dump(out, open(os.path.join(here, "replay.json"), "w"), indent=1)
print(f"{len(replay)} of {len(trades)} trades -> replay.json "
      f"(${min(out['amountIn'])/1e6:,.2f} to ${max(out['amountIn'])/1e6:,.2f})")
