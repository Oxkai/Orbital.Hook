#!/usr/bin/env bash
# Give accounts real USDC, USDT0, USDG and DAI on a fork of Arbitrum One, minted
# through each issuer's own mint path (no storage writes, no mock tokens):
#
#   USDC   Circle's master minter configures a minter, which mints
#   USDT0  its LayerZero OFT contract mints
#   USDG   Paxos' SupplyControl whitelists the account for a supply
#          controller, which mints
#   DAI    Arbitrum's L2 DAI gateway (a DAI ward) mints
#
#   RPC=<fork rpc> script/realworld/fund.sh <dollars> <address>...
set -euo pipefail
source "$(dirname "$0")/fork.sh"

DOLLARS=${1:?usage: fund.sh <dollars> <address>...}; shift
(( $# > 0 )) || { echo "usage: fund.sh <dollars> <address>..." >&2; exit 1; }

SIX=$(( DOLLARS * 1000000 ))
EIGHTEEN="${DOLLARS}000000000000000000"

# USDC: the master minter makes itself a minter with enough allowance.
send_as "$USDC_MASTER_MINTER" $USDC 'configureMinter(address,uint256)' "$USDC_MASTER_MINTER" \
  "$(( SIX * $# ))" >/dev/null

# USDG: the largest-capacity supply controller mints; its manager role is held
# by SupplyControl's admin, who grants it to itself on the fork.
USDG_CONTROLLER=0x2fb074FA59c9294c71246825C1c9A0c7782d41a4
MANAGER_ROLE=$(cast call "$USDG_SUPPLY" 'SUPPLY_CONTROLLER_MANAGER_ROLE()(bytes32)' --rpc-url "$RPC")
SUPPLY_ADMIN=$(cast call "$USDG_SUPPLY" 'owner()(address)' --rpc-url "$RPC")
if [[ $(cast call "$USDG_SUPPLY" 'hasRole(bytes32,address)(bool)' "$MANAGER_ROLE" "$SUPPLY_ADMIN" --rpc-url "$RPC") != true ]]; then
  send_as "$SUPPLY_ADMIN" "$USDG_SUPPLY" 'grantRole(bytes32,address)' "$MANAGER_ROLE" "$SUPPLY_ADMIN" >/dev/null
fi

for who in "$@"; do
  send_as "$USDC_MASTER_MINTER" $USDC 'mint(address,uint256)' "$who" "$SIX" >/dev/null
  send_as "$USDT0_MINTER" $USDT0 'mint(address,uint256)' "$who" "$SIX" >/dev/null
  send_as "$DAI_GATEWAY" $DAI 'mint(address,uint256)' "$who" "$EIGHTEEN" >/dev/null
  send_as "$SUPPLY_ADMIN" "$USDG_SUPPLY" 'addMintAddressToWhitelist(address,address)' "$USDG_CONTROLLER" "$who" \
    >/dev/null 2>&1 || true   # already whitelisted
  send_as "$USDG_CONTROLLER" $USDG 'increaseSupplyToAddress(uint256,address)' "$SIX" "$who" >/dev/null

  # Gas money for the account itself.
  if [[ $FORK == anvil ]]; then
    cast rpc anvil_setBalance "$who" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  else
    cast rpc tenderly_setBalance "[\"$who\"]" 0x56BC75E2D63100000 --raw --rpc-url "$RPC" >/dev/null
  fi

  printf '%s  USDC %s  USDT0 %s  USDG %s  DAI %s\n' "$who" \
    "$(cast call $USDC 'balanceOf(address)(uint256)' "$who" --rpc-url "$RPC" | cut -d' ' -f1)" \
    "$(cast call $USDT0 'balanceOf(address)(uint256)' "$who" --rpc-url "$RPC" | cut -d' ' -f1)" \
    "$(cast call $USDG 'balanceOf(address)(uint256)' "$who" --rpc-url "$RPC" | cut -d' ' -f1)" \
    "$(cast call $DAI 'balanceOf(address)(uint256)' "$who" --rpc-url "$RPC" | cut -d' ' -f1)"
done
