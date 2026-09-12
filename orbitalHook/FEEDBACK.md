# Uniswap v4 Developer Feedback

Submitted for **ETHOnline 2026, Uniswap Foundation, Best Uniswap Stack Contribution**.

Project: **Orbital Hook**, a v4 hook that replaces constant-product with the Orbital sphere/torus curve so N stablecoins trade out of one shared reserve book instead of `N(N-1)/2` shallow pairs.

Repo: https://github.com/Oxkai/Orbital.Hook
Hook: [`orbitalHook/src/OrbitalHook.sol`](src/OrbitalHook.sol)

This is written from the perspective of a hook that fights the framework in an unusual way: it does not merely observe swaps, it *replaces the curve*. That path exercises corners of v4 that a fee-taking or logging hook never touches.

---

## What worked well

**`BeforeSwapDelta` is the right primitive for curve replacement.** Returning a delta from `_beforeSwap` and having `PoolManager` settle it means a hook can own the entire pricing decision without ever holding user funds. Custody stays in the `PoolManager` and the hook holds only matching ERC-6909 claims. That separation is the single feature that makes this project possible on v4 and impossible on v3. ([`OrbitalHook.sol:343-418`](src/OrbitalHook.sol#L343-L418))

**Flag-encoded hook addresses are a good design, and `HookMiner` makes them painless.** Permissions being verifiable from the address alone removes a whole class of trust question. Mining took seconds in practice.

**ERC-6909 on the `PoolManager` is underrated.** Settling into claim tokens rather than moving ERC-20s on every segment made the multi-tick solver loop dramatically cheaper. The docs undersell this.

**`BaseHook` from v4-periphery.** The `_before*` override pattern with the permission bitmap checked against the address is clean, and the compile-time error when the two disagree is genuinely helpful.

---

## Friction, in rough order of cost to us

### 1. Address constants do not cover new chains, and the failure is a bare revert

We deployed to **Circle's Arc** (chain `5042002`). `hookmate`'s `AddressConstants` covers 19 chains and has no Arc entry, so a chain-agnostic deploy script dies on `require(pm.code.length > 0, "no PoolManager on this chain")` with no indication of whether v4 is absent, the address is wrong, or the lookup simply lacks the chain.

Worse, the answer is genuinely ambiguous from the outside. Uniswap **has** announced v4 on Arc and the mainnet `PoolManager` is live at `0x8366a39cc670b4001a1121b8f6a443a643e40951`, but Arc testnet has nothing at any canonical address, and Arc appears nowhere in the official deployments page. We only established that by probing four known `PoolManager` addresses over RPC and getting `0 bytes` from each.

**Ask:** make the deployments page enumerate *testnets* as first-class rows including "not deployed", and have `AddressConstants` distinguish "unknown chain" from "known chain, no deployment". A `getPoolManagerAddressOrZero(chainId)` that returns zero rather than reverting would let scripts fall back cleanly.

### 2. Nothing tells you a self-deployed `PoolManager` is a supported path

Deploying v4 core ourselves on Arc turned out to be the correct move and works perfectly, but no documentation says so. It reads as an unsupported hack right up until it works. Given how many new L1s and L2s launch without v4, "here is how to stand up your own `PoolManager` for a testnet, and here is what you give up" would be a genuinely useful page. `hookmate`'s prebuilt artifacts made this a bytecode deploy rather than a compile fight, and deserve more prominence.

### 3. `PoolKey.lpFee` must be 0 when the hook runs its own fee, and the error does not say so

Orbital charges its own fee inside the engine. Setting a non-zero `lpFee` on the `PoolKey` while also returning a fee override from `_beforeSwap` fails in a way that took a while to attribute. The constraint is reasonable; the diagnostic is not. A named error along the lines of `LPFeeMustBeZeroWithDynamicFee` would have saved an hour.

### 4. One engine, many pools, is an awkward fit

Orbital is one N-asset book, but v4 models everything as pairs, so we register `N(N-1)/2` pools that all point at the same hook and share one state. This works, but every pool-level abstraction fights it:

- `_beforeInitialize` has to validate that each incoming `PoolKey` is a legal pair from the registered asset set. ([`OrbitalHook.sol:319`](src/OrbitalHook.sol#L319))
- Liquidity has to be blocked at the pool level entirely (`_beforeAddLiquidity` / `_beforeRemoveLiquidity` revert) because LPing happens against the *engine*, not any single pair. ([`OrbitalHook.sol:325-341`](src/OrbitalHook.sol#L325-L341))
- There is no way to express "these six pools are one book" to any downstream consumer. Routers, the API, and analytics all see six unrelated pairs, and TVL is either sextuple-counted or attributed arbitrarily.

**Ask:** this is the deepest structural gap for multi-asset hooks. Even a purely advisory interface (`IMultiPoolHook.relatedPools(PoolId)`) that routers and indexers could opt into would let a shared-book hook describe itself honestly.

### 5. No canonical `V4Quoter` on several chains

Base Sepolia, Arbitrum Sepolia and Arc have no canonical quoter, so we deploy our own per chain. Fine once known, but the deployments page implies a quoter exists wherever a `PoolManager` does. Please mark quoter availability per chain explicitly.

### 6. Testing custom-curve hooks

The v4-core test helpers assume a constant-product-ish pool. Anything asserting on `sqrtPriceX96` movement is meaningless for a hook that ignores `sqrtPrice` entirely and prices off its own reserve vector. We ended up writing our own harness. A documented "curve-replacement hook" test template would lower the barrier a lot; this is the category of hook the `BEFORE_SWAP_RETURNS_DELTA` flag exists to enable, and it is the least supported in tooling.

### 7. Docs gap: `BEFORE_SWAP_RETURNS_DELTA` sign conventions

Getting the sign of `toBeforeSwapDelta(specified, unspecified)` right for exact-input versus exact-output, in both directions, was mostly trial and error against the settlement accounting. A table mapping (exactIn/exactOut) × (zeroForOne/oneForZero) to the expected signs would be the single highest-value addition to the hooks docs.

---

## Smaller notes

- `HookMiner.find` needs the deployer to be the CREATE2 factory that will actually deploy. Obvious in hindsight, easy to get wrong, and the resulting mismatch surfaces late.
- Cross-chain: the same hook mines to a different address per chain, so asset indices differ per chain because the hook sorts by address. Events carry indices, so any multi-chain indexer must resolve them per chain. Worth a warning in the docs for anyone deploying the same hook to several chains.
- Transient storage makes v4 hard-require a Cancun-or-later EVM. Arc targets Osaka so it was fine, but a stated minimum EVM version on the deployments page would save people probing for it.

---

## Summary

v4 let us build something that is genuinely impossible on v3: a shared N-asset book with per-LP depeg boundaries, settled through the `PoolManager` with no custody in the hook. The primitives are right.

The gaps are almost entirely at the edges: multi-chain address resolution, chains without a canonical deployment, and the absence of any way for a hook that spans several pools to say so. The last one is the only structural one, and it is the one that would most help the class of hook we are in.
