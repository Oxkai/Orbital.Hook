#!/usr/bin/env bash
# Shared helpers for driving a fork of Arbitrum One: a Tenderly Virtual TestNet
# or a local anvil. Sourced by the other real-world scripts.
#
#   RPC   the fork's RPC URL
#   FORK  "tenderly" or "anvil" (default: detected from the RPC)
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

: "${RPC:?set RPC to the RPC URL of the fork}"

if [[ -z "${FORK:-}" ]]; then
  if cast client --rpc-url "$RPC" 2>/dev/null | grep -qi anvil; then FORK=anvil; else FORK=tenderly; fi
fi

[[ "$(cast chain-id --rpc-url "$RPC")" == "42161" ]] || { echo "RPC is not Arbitrum One (or a fork of it)" >&2; exit 1; }

# Live contracts (see ArbitrumOne.sol).
USDC=0xaf88d065e77c8cC2239327C5EDb3A432268e5831
USDT0=0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9
USDG=0x004B506865409877C9fA29bfb1ebA929984B9bbC
DAI=0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1

# Issuer roles, read from the tokens themselves.
USDC_MASTER_MINTER=$(cast call $USDC 'masterMinter()(address)' --rpc-url "$RPC")
USDC_PAUSER=$(cast call $USDC 'pauser()(address)' --rpc-url "$RPC")
USDC_BLACKLISTER=$(cast call $USDC 'blacklister()(address)' --rpc-url "$RPC")
USDT0_MINTER=$(cast call $USDT0 'oftContract()(address)' --rpc-url "$RPC")
USDT0_OWNER=$(cast call $USDT0 'owner()(address)' --rpc-url "$RPC")
USDG_ADMIN=$(cast call $USDG 'owner()(address)' --rpc-url "$RPC")
USDG_SUPPLY=$(cast call $USDG 'supplyControl()(address)' --rpc-url "$RPC")
DAI_GATEWAY=0x467194771dAe2967Aef3ECbEDD3Bf9a310C76C65   # Arbitrum's L2 DAI gateway, a DAI ward

# Let `who` send transactions on the fork, with gas money.
impersonate() {
  local who=$1
  if [[ $FORK == anvil ]]; then
    cast rpc anvil_impersonateAccount "$who" --rpc-url "$RPC" >/dev/null
    cast rpc anvil_setBalance "$who" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  else
    # A Virtual TestNet accepts unsigned transactions from any address.
    cast rpc tenderly_setBalance "[\"$who\"]" 0x56BC75E2D63100000 --raw --rpc-url "$RPC" >/dev/null
  fi
}

# Send as `from` (impersonated). Prints the transaction hash; fails on revert.
send_as() {
  local from=$1; shift
  impersonate "$from"
  local out status
  out=$(cast send --from "$from" --unlocked --rpc-url "$RPC" --json "$@")
  status=$(printf '%s' "$out" | jq -r .status)
  if [[ $status != 0x1 ]]; then echo "reverted: $*" >&2; return 1; fi
  printf '%s' "$out" | jq -r .transactionHash
}
