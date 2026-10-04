#!/usr/bin/env bash
# Pull real swaps from the live Uniswap v3 USDC/USDT0 0.01% pool on Arbitrum One
# into trades.json: the trade sizes the real-world run replays through Orbital.
#
# Every entry keeps its transaction hash, so any size in the results can be
# checked on Arbiscan.
#
#   ARB_RPC=<arbitrum one rpc> DAYS=7 script/realworld/fetch-trades.sh
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

RPC="${ARB_RPC:-https://arb1.arbitrum.io/rpc}"
DAYS="${DAYS:-7}"
POOL=0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6   # Uniswap v3 USDC/USDT0, fee 100
CHUNK=500000                                      # blocks per getLogs call
OUT="$(dirname "$0")/trades.json"

head=$(cast block-number --rpc-url "$RPC")
# Arbitrum One produces a block every ~0.25s.
from=$(( head - DAYS * 24 * 3600 * 4 ))

tmp=$(mktemp)
echo "[]" > "$tmp"
for (( lo = from; lo <= head; lo += CHUNK )); do
  hi=$(( lo + CHUNK - 1 )); (( hi > head )) && hi=$head
  cast logs --from-block "$lo" --to-block "$hi" --address "$POOL" \
    'Swap(address indexed,address indexed,int256,int256,uint160,uint128,int24)' \
    --rpc-url "$RPC" --json > "$tmp.chunk"
  jq -s '.[0] + .[1]' "$tmp" "$tmp.chunk" > "$tmp.next" && mv "$tmp.next" "$tmp"
  echo "blocks $lo-$hi: $(jq length "$tmp.chunk") swaps" >&2
done

# Keep each log's hash, block and raw amounts; decoded below.
jq --argjson from "$from" --argjson to "$head" '
  {
    source: "Uniswap v3 USDC/USDT0 0.01% (0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6), Arbitrum One",
    fromBlock: $from, toBlock: $to,
    trades: [ .[] | {
      tx: .transactionHash,
      block: .blockNumber,
      a0: ("0x" + .data[2:66]),
      a1: ("0x" + .data[66:130])
    } ]
  }' "$tmp" > "$tmp.shaped"

# Decode the signed amounts (jq has no 256-bit integers). amount0 (USDC) and
# amount1 (USDT0) are from the pool's side: the positive one is what the trader
# paid in. Both tokens have 6 decimals.
count=$(jq '.trades | length' "$tmp.shaped")
echo "decoding $count swaps" >&2
python3 - "$tmp.shaped" "$OUT" <<'PY'
import json, sys
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))
def signed(h):
    v = int(h, 16)
    return v - (1 << 256) if v >= 1 << 255 else v
trades = []
for t in d["trades"]:
    a0, a1 = signed(t["a0"]), signed(t["a1"])
    usdc_in = a0 > 0
    trades.append({
        "tx": t["tx"],
        "block": int(t["block"], 16) if t["block"].startswith("0x") else int(t["block"]),
        "usdcIn": usdc_in,
        "amountIn": a0 if usdc_in else a1,      # 6 decimals
        "amountOut": -a1 if usdc_in else -a0,   # what v3 actually paid
    })
d["trades"] = trades
json.dump(d, open(out, "w"), indent=1)
PY
rm -f "$tmp" "$tmp.chunk" "$tmp.shaped"
echo "wrote $OUT" >&2
