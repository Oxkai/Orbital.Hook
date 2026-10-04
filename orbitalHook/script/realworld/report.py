#!/usr/bin/env python3
"""Build the real-world results from transaction receipts.

Nothing here is computed from the replay script's own view: each output is the
token Transfer to the trader recorded in that swap's receipt, and each gas
figure is the receipt's gasUsed. The receipts come from forge's broadcast log
of the replay (the transactions as the chain executed them).

    EXPLORER_TX=<tx url prefix, e.g. a Tenderly public explorer> \
        script/realworld/report.py

Writes script/realworld/results.json and script/realworld/RESULTS.md.
"""
import json
import os
import statistics

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(os.path.dirname(here))

TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
USDC = "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
USDT0 = "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9"
ARBISCAN = "https://arbiscan.io/tx/"
explorer = os.environ.get("EXPLORER_TX", "")

replay = json.load(open(os.path.join(here, "replay.json")))
plan = json.load(open(os.path.join(here, "replay-plan.json")))
run = json.load(open(os.path.join(root, "broadcast", "RealWorldReplay.s.sol", "42161", "run-latest.json")))

trader = plan["trader"].lower()
receipts = {r["transactionHash"]: r for r in run["receipts"]}


def swaps(fn):
    """The replay's swap transactions of one kind, in the order sent."""
    return [t["hash"] for t in run["transactions"] if (t.get("function") or "").startswith(fn)]


v3_txs = iter(swaps("exactInputSingle"))
orbital_txs = iter(swaps("swapExactTokensForTokens"))
# The trade that first moved Orbital to v3's market price is not a replayed one.
align_tx = next(orbital_txs) if plan.get("orbitalAligned") else None

# Below $1 a trade's output is a handful of raw units, where one unit of
# rounding is tens of basis points: listed, but kept out of the statistics.
DUST = 1_000_000


def paid_out(tx_hash, token):
    """What the trader received of `token` in this transaction, from its logs."""
    r = receipts[tx_hash]
    assert int(r["status"], 16) == 1, f"{tx_hash} reverted"
    total = 0
    for log in r["logs"]:
        t = log["topics"]
        if log["address"].lower() == token and t[0] == TRANSFER and ("0x" + t[2][-40:]).lower() == trader:
            total += int(log["data"], 16)
    return total, int(r["gasUsed"], 16)


rows = []
for i, src_tx in enumerate(replay["tx"]):
    usdc_in = replay["usdcIn"][i]
    amount = replay["amountIn"][i]
    out_token = USDT0 if usdc_in else USDC
    row = {
        "realTx": src_tx,
        "direction": "USDC→USDT0" if usdc_in else "USDT0→USDC",
        "amountIn": amount,
    }
    for pool, sent, rebalanced, refusal, txs in (
        ("v3", plan["v3Sent"][i], plan["v3Rebalanced"][i], plan["v3Refusal"][i], v3_txs),
        ("orbital", plan["orbitalSent"][i], plan["orbitalRebalanced"][i], plan["orbitalRefusal"][i], orbital_txs),
    ):
        if sent:
            h = next(txs)
            out, gas = paid_out(h, out_token)
            row[pool] = {"tx": h, "out": out, "gas": gas}
            # The arbitrage leg that returned the pool to its pre-trade state:
            # a transaction of the same kind, not a trade to compare.
            if rebalanced:
                row[pool]["rebalanceTx"] = next(txs)
        else:
            row[pool] = {"refused": refusal}
    rows.append(row)

filled = [r for r in rows if "out" in r["v3"] and "out" in r["orbital"]]
both = [r for r in filled if r["amountIn"] >= DUST]


def bps(r):
    """Orbital's output relative to v3's, in basis points (+ = Orbital paid more)."""
    return (r["orbital"]["out"] - r["v3"]["out"]) * 10_000 / r["v3"]["out"]


def usd(raw):
    return raw / 1e6


summary = {
    "source": replay["source"],
    "sampledFrom": replay["population"],
    "blocks": [replay["fromBlock"], replay["toBlock"]],
    "trades": len(rows),
    "filledByBoth": len(filled),
    "dust": len(filled) - len(both),
    "orbitalAlignTx": align_tx,
    "orbitalPaidMore": sum(1 for r in both if r["orbital"]["out"] > r["v3"]["out"]),
    "v3PaidMore": sum(1 for r in both if r["orbital"]["out"] < r["v3"]["out"]),
    "medianDiffBps": statistics.median(bps(r) for r in both) if both else None,
    "totalOutV3": sum(r["v3"]["out"] for r in both),
    "totalOutOrbital": sum(r["orbital"]["out"] for r in both),
    "medianGasV3": statistics.median(r["v3"]["gas"] for r in both) if both else None,
    "medianGasOrbital": statistics.median(r["orbital"]["gas"] for r in both) if both else None,
    "refusedByV3": sum(1 for r in rows if "refused" in r["v3"]),
    "refusedByOrbital": sum(1 for r in rows if "refused" in r["orbital"]),
}
json.dump({"summary": summary, "trades": rows}, open(os.path.join(here, "results.json"), "w"), indent=1)


def link(h, label=None):
    label = label or (h[:10] + "…")
    return f"[{label}]({explorer}{h})" if explorer else f"`{h[:10]}…`"


lines = [
    "# Real-world replay: Orbital vs Uniswap v3 on Arbitrum One",
    "",
    f"Trades: {summary['trades']} real USDC/USDT0 swaps sampled from {summary['sampledFrom']} "
    f"in {replay['source']}, blocks {summary['blocks'][0]}–{summary['blocks'][1]}, replayed in their real order "
    f"on a fork of Arbitrum One at block {plan.get('forkBlock', '?')}.",
    "",
    "Between trades, a rebalancing transaction returns each pool to its pre-trade state, standing in for the "
    "arbitrage that keeps mainnet pools at the market price, so every trade meets a pool at the market price. "
    "Outputs are the Transfer to the trader in each trade's receipt; gas is the receipt's gasUsed.",
    "",
    "Orbital is freshly seeded at exactly 1:1, so before the replay one arbitrage trade moves it to v3's "
    "market price (as the first arbitrageur would on mainnet)"
    + (f": {link(align_tx, 'tx')}." if align_tx else "."),
    "",
    f"- Filled by both: **{summary['filledByBoth']}** ({summary['dust']} under $1 are listed but left out of the "
    "statistics: at that size one raw unit of rounding is tens of bps)",
    f"- Orbital paid more: **{summary['orbitalPaidMore']}** · v3 paid more: **{summary['v3PaidMore']}**",
    f"- Median difference: **{summary['medianDiffBps']:+.2f} bps** (+ = Orbital paid more)" if both else "",
    f"- Total paid out on those trades: Orbital **${usd(summary['totalOutOrbital']):,.2f}** "
    f"vs v3 **${usd(summary['totalOutV3']):,.2f}**",
    f"- Median gas: Orbital **{summary['medianGasOrbital']:,.0f}** vs v3 **{summary['medianGasV3']:,.0f}**" if both else "",
    f"- Refused: Orbital {summary['refusedByOrbital']} · v3 {summary['refusedByV3']}",
    "",
    "## By trade size",
    "",
    "Median difference in what the trader received, Orbital vs v3 (+ = Orbital paid more).",
    "",
    "| Size | Trades | Median Δ bps | Range |",
    "|---|---:|---:|---|",
    *[
        f"| {label} | {len(x)} | {statistics.median(x):+.2f} | {min(x):+.2f} to {max(x):+.2f} |"
        for label, lo, hi in (
            ("$1 – $100", 1, 100),
            ("$100 – $1k", 100, 1_000),
            ("$1k – $10k", 1_000, 10_000),
            ("$10k – $100k", 10_000, 100_000),
            ("$100k +", 100_000, float("inf")),
        )
        for x in [[bps(r) for r in both if lo <= usd(r["amountIn"]) < hi]]
        if x
    ],
    "",
    "## Every trade",
    "",
    "| # | Real trade | Size | Direction | v3 paid | Orbital paid | Δ bps | Gas v3 / Orbital |",
    "|---|---|---:|---|---:|---:|---:|---|",
]
for i, r in enumerate(rows, 1):
    v3, orb = r["v3"], r["orbital"]
    v3_cell = f"{usd(v3['out']):,.6f} {link(v3['tx'], 'tx')}" if "out" in v3 else "refused"
    orb_cell = f"{usd(orb['out']):,.6f} {link(orb['tx'], 'tx')}" if "out" in orb else "refused"
    d = f"{bps(r):+.2f}" if r in both else ("dust" if r in filled else "—")
    gas = f"{v3['gas']:,} / {orb['gas']:,}" if r in filled else "—"
    lines.append(
        f"| {i} | [{r['realTx'][:10]}…]({ARBISCAN}{r['realTx']}) | ${usd(r['amountIn']):,.2f} | {r['direction']} "
        f"| {v3_cell} | {orb_cell} | {d} | {gas} |"
    )
refusals = [(i, r) for i, r in enumerate(rows, 1) if "refused" in r["orbital"] or "refused" in r["v3"]]
if refusals:
    lines += ["", "## Refusals", ""]
    for i, r in refusals:
        for pool in ("v3", "orbital"):
            if "refused" in r[pool]:
                lines.append(f"- #{i} {pool}: `{r[pool]['refused'][:200]}`")
open(os.path.join(here, "RESULTS.md"), "w").write("\n".join(l for l in lines if l is not None) + "\n")
print(json.dumps(summary, indent=1))
