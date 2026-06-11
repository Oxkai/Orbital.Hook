# Orbital × Reactive Network — Depeg Circuit-Breaker

A keeper-free safety layer for the Orbital pool. When an external price oracle
reports that one of the pool's stablecoins has broken its peg, the pool is
**paused automatically** — faster than any human or bot — before arbitrageurs
can drain LPs at a stale on-pool price.

## Why this matters

Orbital already isolates a depegged coin *geometrically*: its ticks flip to
their boundary and the bad coin is fenced off. But the pool only "learns" of a
depeg once trades have already pushed its internal price there — which is
exactly the window in which LPs bleed value. This circuit-breaker reacts to an
**off-pool oracle signal**, so it can pause the pool *before* the internal state
catches up. It is an additive safety net, not a replacement for the geometry.

## Flow

```
  Origin chain (testnet)          Reactive Lasna (5318007)        Unichain Sepolia (1301)
  ┌────────────────────┐          ┌─────────────────────┐         ┌──────────────────────┐
  │ Chainlink feed      │  log →   │ OrbitalDepegReactive │ callback│ OrbitalDepegCallback  │
  │ AnswerUpdated(price)│ ───────→ │  react(): price out  │ ───────→│  pauseOnDepeg(...)    │
  └────────────────────┘  subscribe│  of peg band?        │         │   → hook.guardianPause│
                                   └─────────────────────┘         └──────────┬───────────┘
                                                                              │ guardian
                                                                   ┌──────────▼───────────┐
                                                                   │ OrbitalHook (paused)  │
                                                                   └──────────────────────┘
```

1. **OrbitalDepegReactive** (Reactive Lasna) subscribes to a Chainlink feed's
   `AnswerUpdated(int256,uint256,uint256)` event on the origin chain. On each
   update it reads the new price from `topic_1`; if it leaves the configured
   peg band it emits a cross-chain `Callback`.
2. The Reactive **callback proxy** on Unichain Sepolia
   (`0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`) invokes
   **OrbitalDepegCallback.pauseOnDepeg(...)**.
3. That contract is the hook's **guardian**, so it calls
   `OrbitalHook.guardianPause()` and the pool pauses.

## Hook surface

The core hook stays clean — reactive-lib is *not* a dependency of `OrbitalHook`.
The only additions are a `guardian` role and a fail-safe pause:

- `setGuardian(address)` — owner-only.
- `guardianPause()` — callable by the guardian (or owner); can **only pause**.
- `unpause()` — stays **owner-only**, so a human reviews before liquidity
  resumes.

## Deploy

See the step-by-step header in [`script/DeployReactive.s.sol`](../../script/DeployReactive.s.sol).
Deploy both steps from the **same account** — the callback's `rvm_id` is bound
to its deployer. Testnet origins pair only with Reactive Lasna.
