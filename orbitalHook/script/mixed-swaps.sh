#!/usr/bin/env bash
# Random retail swap flow across EVERY deployed chain, interleaved.
#
# `SimulateSwaps.s.sol` runs one chain at a time, so running it per chain leaves
# each chain's history in one contiguous block — not what live traffic looks
# like. This shuffles the chains and sends a small batch at a time, so the three
# activity feeds fill in together.
#
# Chains, hooks, routers and quoters all come from deployments.json, so it
# follows a redeploy without edits.
#
#   ROUNDS=18 PER_ROUND=2 script/mixed-swaps.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
set -a; . ./.env; set +a
: "${PRIVATE_KEY:?PRIVATE_KEY must be set in .env}"

ROUNDS=${ROUNDS:-18}
PER_ROUND=${PER_ROUND:-2}
MAX_SWAP_USD=${MAX_SWAP_USD:-5000}

CHAINS=($(jq -r 'to_entries[] | select(.key != "_comment") | .key' deployments.json))

# One slot per round, chains repeated evenly, then shuffled: every chain gets a
# fair share of the rounds but the order is mixed.
schedule=()
for ((r = 0; r < ROUNDS; r++)); do schedule+=("${CHAINS[$((r % ${#CHAINS[@]}))]}"); done
schedule=($(printf '%s\n' "${schedule[@]}" | sort -R))

echo "== ${#schedule[@]} rounds x $PER_ROUND swaps, mixed over: ${CHAINS[*]}"
for ((r = 0; r < ${#schedule[@]}; r++)); do
  cid=${schedule[$r]}
  cfg=$(jq -r --arg c "$cid" '.[$c] | "\(.short)\t\(.rpc)\t\(.orbitalHook)\t\(.v4Router)\t\(.quoter)"' deployments.json)
  IFS=$'\t' read -r name rpc hook router quoter <<<"$cfg"

  # Robinhood is an Orbit chain: its L1 data fee is not in the gas estimate.
  extra=()
  [[ $cid == 46630 ]] && extra=(--gas-estimate-multiplier 150)

  echo "-- round $((r + 1))/${#schedule[@]}: $name"
  # Testnet RPCs drop a request now and then (Robinhood lags its own head), so
  # a round gets a second try before it is reported as failed.
  for attempt in 1 2; do
    out=$(ORBITAL_HOOK=$hook V4_ROUTER=$router V4_QUOTER=$quoter \
      ACTIVITY_SEED=$((1000 + r)) SWAP_COUNT=$PER_ROUND MAX_SWAP_USD=$MAX_SWAP_USD \
      forge script script/SimulateSwaps.s.sol --rpc-url "$rpc" --broadcast --slow \
        --private-key "$PRIVATE_KEY" ${extra[@]+"${extra[@]}"} 2>&1) || true
    printf '%s\n' "$out" | grep -E "swaps executed:|volume \(\$\):|skipped:" && break
    if [[ $attempt == 2 ]]; then
      echo "   FAILED: $(printf '%s\n' "$out" | grep -E "Error|revert" | head -2)"
    else
      sleep 5
    fi
  done
done
echo "== done"
