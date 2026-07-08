# Reactive depeg circuit-breaker — deployment runbook

Two active chains: **Unichain Sepolia** (the pool, the callback, and — in this demo — the
price feed) and **Reactive Lasna** (the watcher). Ethereum/Base Sepolia is used only to
fund the Lasna faucet.

```
 Unichain Sepolia (origin + destination)          Reactive Lasna
 MockChainlinkFeed ── AnswerUpdated ─────────────▶ OrbitalDepegReactive
 (updateAnswer)                                    (react: price out of band?)
        ▲                                                   │
        │                                          emits Callback
 OrbitalHook.guardianPause() ◀── OrbitalDepegCallback ◀─────┘  (via callback proxy)
```

Use the **same deployer account on every chain** — the callback's `rvm_id` and the RSC's
callbacks are bound to one address.

## What you must provide

- A deployer **private key** (one key, all chains) set in `orbitalHook/.env` as `PRIVATE_KEY`.
- **Unichain Sepolia ETH** — hook + pools + callback (the callback constructor sends 0.05 ETH).
- **lREACT on Reactive Lasna** — get it by sending a little Ethereum Sepolia ETH to the faucet
  `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` (1 ETH → 100 lREACT; the lREACT lands on Lasna a
  few seconds later). The RSC needs ~0.1 value + Lasna gas, so ~0.25 lREACT per deploy is comfortable.

## Fixed addresses / params

| | |
|---|---|
| Origin + destination chain | Unichain Sepolia, chainId `1301`, RPC `https://sepolia.unichain.org` |
| Reactive chain | Reactive Lasna, chainId `5318007`, RPC `https://lasna-rpc.rnk.dev/` |
| Unichain callback proxy (CALLBACK_SENDER) | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` |
| Lasna faucet (on Ethereum Sepolia) | `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` |
| Reactive system contract (Lasna) | `0x0000000000000000000000000000000000fffFfF` |

Ethereum Sepolia (`11155111`) is also a valid Reactive origin, but its ~13-minute finality
makes the breaker react slowly. Unichain Sepolia finalizes in seconds, so we use it as the
origin for a snappy demo. To use a real feed in production, point `PRICE_FEED` at a live
Chainlink aggregator and keep the same `[LOWER_BOUND, UPPER_BOUND]` band.

## Steps

```bash
cd orbitalHook
set -a; . ./.env; set +a                        # loads PRIVATE_KEY
export UNICHAIN_RPC=https://sepolia.unichain.org
export LASNA_RPC=https://lasna-rpc.rnk.dev/

# 1) Deploy a guardian-enabled OrbitalHook + pools + seed on Unichain Sepolia.
forge script script/Deploy.s.sol:DeployScript --rpc-url $UNICHAIN_RPC --broadcast --slow \
  --private-key $PRIVATE_KEY
export HOOK=0x...                               # OrbitalHook printed above

# 2) Deploy the triggerable mock feed on Unichain Sepolia. Starts at $1.00 (8 decimals).
forge script script/DeployReactive.s.sol:DeployReactiveScript --sig "deployMockFeed()" \
  --rpc-url $UNICHAIN_RPC --broadcast --private-key $PRIVATE_KEY
export PRICE_FEED=0x...                          # MockChainlinkFeed printed above

# 3) Deploy the callback on Unichain Sepolia and wire it as the hook's guardian.
export CALLBACK_SENDER=0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4
forge script script/DeployReactive.s.sol:DeployReactiveScript --sig "deployCallback()" \
  --rpc-url $UNICHAIN_RPC --broadcast --slow --private-key $PRIVATE_KEY
export CALLBACK_CONTRACT=0x...                   # OrbitalDepegCallback printed above

# 4) Deploy the Reactive watcher on Lasna. Peg band in 8-decimal feed units: $0.98 .. $1.02.
#    Use `forge create` (NOT forge script): the RSC constructor calls the Lasna system-contract
#    precompile, which forge's local simulation can't execute.
#    constructor args: originChainId, feed, asset, destChainId, callback, lowerBound, upperBound
forge create src/reactive/OrbitalDepegReactive.sol:OrbitalDepegReactive \
  --rpc-url $LASNA_RPC --private-key $PRIVATE_KEY --broadcast --value 0.1ether \
  --constructor-args 1301 $PRICE_FEED <ASSET> 1301 $CALLBACK_CONTRACT 98000000 102000000
# <ASSET> = any of the pool's mock stablecoins (pass-through, for the event trail only)

# 5) DEMO — fire a depeg ($0.90, below the band) on the Unichain feed:
export DEPEG_PRICE=90000000
forge script script/DeployReactive.s.sol:DeployReactiveScript --sig "triggerDepeg()" \
  --rpc-url $UNICHAIN_RPC --broadcast --private-key $PRIVATE_KEY

# 6) Verify the pool paused (give the Reactive callback a short time to relay):
cast call $HOOK "paused()(bool)" --rpc-url $UNICHAIN_RPC       # expect: true
```

## Live testnet deployment

| Contract | Chain | Address |
|---|---|---|
| OrbitalHook (guardian-enabled) | Unichain Sepolia | `0x7FA9c378ee27156E3De1F7d9006e99e3734f2a88` |
| OrbitalDepegCallback (hook guardian) | Unichain Sepolia | `0x7f5A05f555ee3F270d63ACa998CDBa421E458A73` |
| MockChainlinkFeed | Unichain Sepolia | `0x959dfEAb43690fB0037B9a8E5746Df942A1C3A81` |
| OrbitalDepegReactive (RSC) | Reactive Lasna | `0xa854E3ee9eFa1936034dE51CCD6e6fB66F4309cF` |

## Notes

- A real Chainlink stablecoin feed never depegs in a test window, so the mock feed lets you
  trigger the breaker on demand. In production, swap in a real aggregator.
- `guardianPause()` is one-way (fail-safe). To reset for another demo run, the hook owner calls
  `unpause()`: `cast send $HOOK "unpause()" --rpc-url $UNICHAIN_RPC --private-key $PRIVATE_KEY`.
- Capture the tx hashes from steps 5–6 — the `updateAnswer` tx, the Lasna react, and the pause —
  they are the proof trail for the grant application.
