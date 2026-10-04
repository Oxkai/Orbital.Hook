# Real-world run

Orbital on **live Arbitrum One contracts**, not mocks: Circle's USDC, Tether's USDT0, Paxos' USDG and DAI, the real Uniswap v4 PoolManager, and the live Uniswap v3 USDC/USDT0 pool as the benchmark. It runs on a fork of Arbitrum One, either a Tenderly Virtual TestNet (public explorer, shareable) or a local anvil.

What it does:

1. **Fund** fresh throwaway accounts with real tokens, minted through each issuer's own path: Circle's master minter, USDT0's LayerZero OFT, Paxos' SupplyControl, and the L2 DAI gateway. Nothing writes to storage, and no mock token is involved.
2. **Deploy** Orbital over the four live stablecoins ([`DeployReal.s.sol`](../DeployReal.s.sol)). By default it holds as much USDC and USDT0 as the live v3 pool does at that block.
3. **Replay real trades.** [`fetch-trades.sh`](fetch-trades.sh) pulls a week of real swaps from the v3 pool, each with its Arbiscan hash. [`sample-trades.py`](sample-trades.py) samples them across the size distribution, plus the largest. [`RealWorldReplay.s.sol`](../RealWorldReplay.s.sol) sends each one to **both** pools, in the real order, as real transactions.
4. **Report from receipts.** [`report.py`](report.py) reads every output from the Transfer in that swap's receipt and every gas figure from `gasUsed`, and writes `RESULTS.md`.

## On Tenderly

1. In the Tenderly dashboard, create a **Virtual TestNet**:
   - Parent network: **Arbitrum One**. Keep chain id **42161**; the scripts check it.
   - Turn on the **public explorer**, so anyone can open the transactions.
2. Copy its **RPC URL** and the explorer's transaction URL prefix.
3. Run:

   ```bash
   RPC=<virtual testnet rpc> EXPLORER_TX=<explorer tx url prefix> script/realworld/run.sh
   ```

Every transaction in `RESULTS.md` links to Tenderly's explorer (decoded trace, gas, state changes), and every sampled trade links to the original swap on Arbiscan.

## Locally

```bash
anvil --fork-url https://arb1.arbitrum.io/rpc --fork-block-number 509959150 --port 8546
RPC=http://127.0.0.1:8546 script/realworld/run.sh
```

## Keys

Each run signs with **fresh throwaway keys**, saved to `.keys` (git-ignored). The fork keeps Arbitrum One's chain id, so anything signed on it is also valid on the real chain. Never run this with a key that holds real funds.
