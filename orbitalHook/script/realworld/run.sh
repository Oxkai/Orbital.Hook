#!/usr/bin/env bash
# The whole real-world run on a fork of Arbitrum One (Tenderly Virtual TestNet
# or anvil): fund, deploy Orbital over the live stablecoins, replay real trades
# through Orbital and the live Uniswap v3 pool, and build the report from the
# receipts.
#
#   RPC=<fork rpc> [EXPLORER_TX=<tx url prefix>] script/realworld/run.sh
#
# Keys: every run signs with FRESH throwaway keys (saved to .keys, git-ignored).
# The fork has Arbitrum One's chain id, so anything signed here is also valid on
# the real chain: never point this at a key that holds real funds.
set -euo pipefail
cd "$(dirname "$0")/../.."
source script/realworld/fork.sh

# Outputs of an earlier run must not survive a failed one looking current.
rm -f script/realworld/replay-plan.json script/realworld/results.json script/realworld/RESULTS.md

KEYS=script/realworld/.keys
cast wallet new --json | jq -r '.[0].private_key' > "$KEYS.deployer"
cast wallet new --json | jq -r '.[0].private_key' > "$KEYS.trader"
cat "$KEYS.deployer" "$KEYS.trader" > "$KEYS" && rm "$KEYS.deployer"
DEPLOYER_KEY=$(sed -n 1p "$KEYS"); TRADER_KEY=$(sed -n 2p "$KEYS"); rm -f "$KEYS.trader"
DEPLOYER=$(cast wallet address "$DEPLOYER_KEY"); TRADER=$(cast wallet address "$TRADER_KEY")
echo "fork: $FORK at block $(cast block-number --rpc-url "$RPC")"
echo "deployer $DEPLOYER · trader $TRADER"

echo "== funding (issuer mint paths) =="
script/realworld/fund.sh 1000000 "$DEPLOYER"
script/realworld/fund.sh 3000000 "$TRADER"

echo "== deploying Orbital over live USDC, USDT0, USDG, DAI =="
forge script script/DeployReal.s.sol --rpc-url "$RPC" --broadcast --slow --private-key "$DEPLOYER_KEY" \
  | grep -E "holds|capital|OrbitalHook:|TVL|ONCHAIN"
HOOK=$(jq -r '[.transactions[] | select(.contractName == "OrbitalHook")][0].contractAddress' \
  broadcast/DeployReal.s.sol/42161/run-latest.json)
HOOK=$(cast to-check-sum-address "$HOOK")
echo "hook: $HOOK"

echo "== replaying real trades =="
[[ -f script/realworld/replay.json ]] || { script/realworld/fetch-trades.sh; script/realworld/sample-trades.py; }
HOOK=$HOOK forge script script/RealWorldReplay.s.sol --rpc-url "$RPC" --broadcast --slow \
  --private-key "$TRADER_KEY" | grep -E "trades:|sent to|worst|market price|aligned|price after|ONCHAIN"

echo "== report (from receipts) =="
script/realworld/report.py
echo "wrote script/realworld/RESULTS.md"
