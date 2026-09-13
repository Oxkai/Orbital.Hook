import { Address, BigInt, Bytes, dataSource, ethereum, log } from "@graphprotocol/graph-ts";
import {
  OrbitalHook,
  Swap as SwapEvent,
  Mint as MintEvent,
  Burn as BurnEvent,
  Collect as CollectEvent,
  TickCrossed as TickCrossedEvent,
} from "../generated/OrbitalHook/OrbitalHook";
import { ERC20 } from "../generated/OrbitalHook/ERC20";
import { Pool, Asset, Tick, Swap, LiquidityEvent, TickCross, PoolSnapshot } from "../generated/schema";

const ZERO = BigInt.fromI32(0);
const ONE = BigInt.fromI32(1);
const TWO = BigInt.fromI32(2);
const WAD = BigInt.fromString("1000000000000000000");
const BPS = BigInt.fromI32(10000);

/// Integer square root, Newton's method. Mirrors SphereMath.sqrt in the hook.
///
/// Needed because `sqrtN` is `internal immutable` in OrbitalHook and therefore
/// not callable, yet every boundary comparison the engine makes is normalised
/// by it. Recomputing it here is the only way to reproduce the engine's own
/// crossing condition rather than approximate it.
function bigSqrt(n: BigInt): BigInt {
  if (n.le(ZERO)) return ZERO;
  let x = n;
  let y = x.plus(ONE).div(TWO);
  while (y.lt(x)) {
    x = y;
    y = x.plus(n.div(x)).div(TWO);
  }
  return x;
}

// Chain ids keyed by the graph-cli network name, so a Pool row can say which
// deployment it came from without the manifest carrying an extra parameter.
function chainIdForNetwork(net: string): i32 {
  if (net == "unichain-testnet") return 1301;
  if (net == "base-sepolia") return 84532;
  if (net == "arbitrum-sepolia") return 421614;
  if (net == "arc-testnet") return 5042002;
  return 0;
}

function tickId(pool: Pool, idx: BigInt): string {
  return pool.id.toHexString() + "-" + idx.toString();
}

function eventId(event: ethereum.Event): string {
  return event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
}

// ─────────────────────────── pool bootstrap ───────────────────────────

/// Load the pool, creating it on first sight.
///
/// The basket is read once, at creation. `N`, the asset addresses and their
/// decimals are immutable in the hook, so re-reading them on every event would
/// be four wasted eth_calls per log for values that cannot change.
function loadPool(addr: Address, event: ethereum.Event): Pool {
  let id = addr as Bytes;
  let pool = Pool.load(id);
  if (pool != null) return pool as Pool;

  pool = new Pool(id);
  let net = dataSource.network();
  pool.network = net;
  pool.chainId = chainIdForNetwork(net);

  let hook = OrbitalHook.bind(addr);

  let n = hook.try_N();
  pool.assetCount = n.reverted ? 0 : n.value;

  let fee = hook.try_fee();
  pool.feeBps = fee.reverted ? ZERO : BigInt.fromI32(fee.value);

  pool.sumX = ZERO;
  pool.alphaNorm = ZERO;
  pool.alphaParity = ZERO;
  pool.sumXSq = ZERO;
  pool.rInt = ZERO;
  pool.kBound = ZERO;
  pool.sBound = ZERO;
  pool.virtualReserveWad = ZERO;
  pool.tickCount = 0;
  pool.interiorTickCount = 0;
  pool.frozen = false;
  pool.swapCount = ZERO;
  pool.crossCount = ZERO;
  pool.volumeWad = ZERO;
  pool.feesWad = ZERO;
  pool.lastUpdatedBlock = event.block.number;
  pool.lastUpdatedAt = event.block.timestamp;
  pool.save();

  for (let i = 0; i < pool.assetCount; i++) {
    let a = hook.try_assetAt(i);
    if (a.reverted) continue;

    let asset = new Asset(pool.id.toHexString() + "-" + i.toString());
    asset.pool = pool.id;
    asset.index = i;
    asset.token = a.value as Bytes;

    let erc = ERC20.bind(a.value);
    let sym = erc.try_symbol();
    asset.symbol = sym.reverted ? "?" : sym.value;
    let dec = erc.try_decimals();
    asset.decimals = dec.reverted ? 18 : dec.value;

    let sc = hook.try_scaleOf(i);
    asset.scale = sc.reverted ? ONE : sc.value;

    asset.reserveWad = ZERO;
    asset.realReserveWad = ZERO;
    asset.feesAccruedWad = ZERO;
    asset.save();
  }

  return pool as Pool;
}

// ─────────────────────────── state refresh ───────────────────────────

/// Pull live engine state and recompute every tick's distance to its boundary.
///
/// This is the reason the subgraph is worth more than a log scan. `TickCrossed`
/// only fires once a boundary has ALREADY been hit, which is useless as an
/// early warning. Reading `slot0` and `ticks` at each event turns the feed into
/// a leading indicator: how much slack is left, and in which tick.
///
/// Returns the minimum distance across interior ticks, or null if none.
function refreshState(pool: Pool, event: ethereum.Event): BigInt | null {
  let hook = OrbitalHook.bind(Address.fromBytes(pool.id));

  let s = hook.try_slot0();
  if (!s.reverted) {
    pool.sumX = s.value.value0;
    pool.sumXSq = s.value.value1;
    pool.rInt = s.value.value2;
    pool.kBound = s.value.value3;
    pool.sBound = s.value.value4;
    // A non-zero kBound means some tick sits on its boundary. While that holds
    // the engine refuses mint and burn for the WHOLE book, not just that tick.
    pool.frozen = s.value.value3.notEqual(ZERO);
  }

  let v = hook.try_virtualReserve();
  if (!v.reverted) pool.virtualReserveWad = v.value;

  for (let i = 0; i < pool.assetCount; i++) {
    let asset = Asset.load(pool.id.toHexString() + "-" + i.toString());
    if (asset == null) continue;
    let r = hook.try_reserves(i);
    if (!r.reverted) asset.reserveWad = r.value;
    // The hook guarantees reserves never fall below the virtual floor; the
    // guard only keeps a failed read from underflowing.
    asset.realReserveWad = asset.reserveWad.gt(pool.virtualReserveWad)
      ? asset.reserveWad.minus(pool.virtualReserveWad)
      : ZERO;
    let f = hook.try_feesAccrued(i);
    if (!f.reverted) asset.feesAccruedWad = f.value;
    asset.save();
  }

  let nt = hook.try_numTicks();
  let count = nt.reverted ? 0 : nt.value.toI32();
  pool.tickCount = count;

  // Reproduce the engine's own normalised projection.
  //
  //   sqrtN     = sqrt(N * WAD^2)
  //   alphaTot  = sumX * WAD / sqrtN
  //   alphaInt  = max(alphaTot - kBound, 0)
  //   alphaNorm = alphaInt * WAD / rInt
  //
  // This is what `_detectCrossing` compares against each tick's kNorm. An
  // earlier version of this mapping used `sumX - k`, which is neither the right
  // quantity nor the right units: `sumX` is an absolute reserve sum while `k`
  // is a per-tick plane constant, so the two are not comparable at all.
  let sqrtN = bigSqrt(BigInt.fromI32(pool.assetCount).times(WAD).times(WAD));
  let alphaParity = sqrtN.gt(WAD) ? sqrtN.minus(WAD) : ZERO;
  pool.alphaParity = alphaParity;

  let alphaNorm = ZERO;
  if (sqrtN.gt(ZERO) && pool.rInt.gt(ZERO)) {
    let alphaTot = pool.sumX.times(WAD).div(sqrtN);
    let alphaInt = alphaTot.gt(pool.kBound) ? alphaTot.minus(pool.kBound) : ZERO;
    alphaNorm = alphaInt.times(WAD).div(pool.rInt);
  }
  pool.alphaNorm = alphaNorm;

  let interior = 0;
  let minDist: BigInt | null = null;
  let nearest: string | null = null;
  let maxProgress = 0;

  for (let i = 0; i < count; i++) {
    let idx = BigInt.fromI32(i);
    let t = hook.try_ticks(idx);
    if (t.reverted) continue;

    let id = tickId(pool, idx);
    let tick = Tick.load(id);
    if (tick == null) {
      // A tick seen by state refresh before its own Mint log was handled.
      tick = new Tick(id);
      tick.pool = pool.id;
      tick.tickIdx = idx;
      tick.crossCount = ZERO;
      tick.createdAt = event.block.timestamp;
      tick.createdBlock = event.block.number;
      tick.creator = Address.zero() as Bytes;
      tick.shareOfRIntBps = 0;
      tick.boundaryProgressBps = 0;
    }

    tick.k = t.value.value0;
    tick.r = t.value.value1;
    tick.isInterior = t.value.value2;
    tick.feeGrowthInside = t.value.value3;
    tick.liquidityGross = t.value.value4;

    // kNorm = k*WAD/r is the value the engine tests alphaNorm against.
    let kNorm = tick.r.gt(ZERO) ? tick.k.times(WAD).div(tick.r) : null;
    tick.kNorm = kNorm;

    if (tick.isInterior) {
      interior += 1;

      // Slack in normalised units. A tick crosses when alphaNorm RISES to meet
      // kNorm, so positive means interior with room left. The sign is kept: a
      // negative value means the tick sits past its own plane, which is an
      // anomaly worth surfacing rather than clamping away.
      let dist: BigInt | null = null;
      if (kNorm !== null) {
        dist = (kNorm as BigInt).minus(alphaNorm);
        if (minDist === null || (dist as BigInt).lt(minDist as BigInt)) {
          minDist = dist;
          nearest = id;
        }
      }
      tick.distanceToBoundaryWad = dist;

      // Progress from parity to THIS tick's bound, in bps.
      //
      // Normalising by each tick's own span is what makes a 0.97 tick and a
      // 0.80 tick comparable: they sit at different distances by construction,
      // so a raw gap says nothing about which is nearer to giving way.
      let progress = 0;
      if (kNorm !== null) {
        let span = (kNorm as BigInt).minus(alphaParity);
        let travelled = alphaNorm.minus(alphaParity);
        if (span.gt(ZERO)) {
          let raw = travelled.times(BPS).div(span).toI32();
          progress = raw < 0 ? 0 : (raw > 10000 ? 10000 : raw);
        } else {
          // span <= 0: the tick's bound is at or behind parity, so it has no
          // forward journey left. Treat as fully progressed.
          progress = 10000;
        }
      }
      tick.boundaryProgressBps = progress;
      if (progress > maxProgress) maxProgress = progress;

      tick.shareOfRIntBps = pool.rInt.equals(ZERO)
        ? 0
        : tick.r.times(BPS).div(pool.rInt).toI32();
    } else {
      // A boundary tick contributes nothing and has no meaningful slack.
      tick.distanceToBoundaryWad = null;
      tick.boundaryProgressBps = 10000;
      tick.shareOfRIntBps = 0;
    }
    tick.save();
  }

  pool.interiorTickCount = interior;
  pool.lastUpdatedBlock = event.block.number;
  pool.lastUpdatedAt = event.block.timestamp;
  pool.save();

  let snap = new PoolSnapshot(
    pool.id.toHexString() + "-" + event.block.number.toString() + "-" + event.logIndex.toString()
  );
  snap.pool = pool.id;
  snap.sumX = pool.sumX;
  snap.rInt = pool.rInt;
  snap.kBound = pool.kBound;
  snap.frozen = pool.frozen;
  snap.interiorTickCount = interior;
  snap.alphaNorm = alphaNorm;
  snap.minDistanceToBoundaryWad = minDist;
  snap.maxBoundaryProgressBps = maxProgress;
  snap.nearestTick = nearest;
  snap.blockNumber = event.block.number;
  snap.timestamp = event.block.timestamp;
  snap.save();

  return minDist;
}

// ─────────────────────────── handlers ───────────────────────────

export function handleSwap(event: SwapEvent): void {
  let pool = loadPool(event.address, event);

  let inIdx = event.params.assetIn;
  let outIdx = event.params.assetOut;
  let inId = pool.id.toHexString() + "-" + inIdx.toString();
  let outId = pool.id.toHexString() + "-" + outIdx.toString();

  let aIn = Asset.load(inId);
  let aOut = Asset.load(outId);

  // Mixed decimals are the norm here (USDC/USDT 6dp, DAI/FRAX 18dp), so the two
  // legs are not comparable in raw units. Scale both to WAD before doing any
  // arithmetic across them; comparing raw amounts is how a 6dp asset ends up
  // looking like a 1e12 slippage event.
  let inScale = aIn == null ? ONE : aIn.scale;
  let outScale = aOut == null ? ONE : aOut.scale;
  let amountInWad = event.params.amountIn.times(inScale);
  let amountOutWad = event.params.amountOut.times(outScale);

  let swap = new Swap(eventId(event));
  swap.pool = pool.id;
  swap.sender = event.params.sender;
  swap.assetInIndex = inIdx;
  swap.assetOutIndex = outIdx;
  swap.assetIn = inId;
  swap.assetOut = outId;
  swap.amountIn = event.params.amountIn;
  swap.amountOut = event.params.amountOut;
  swap.amountInWad = amountInWad;
  swap.amountOutWad = amountOutWad;

  // These are same-peg assets, so 1:1 IS the fair price and everything missing
  // from the output is fee plus curve slippage.
  swap.slippageBps = amountInWad.equals(ZERO)
    ? 0
    : amountInWad.minus(amountOutWad).times(BPS).div(amountInWad).toI32();

  refreshState(pool, event);

  swap.rIntAfter = pool.rInt;
  swap.frozenAfter = pool.frozen;
  swap.blockNumber = event.block.number;
  swap.timestamp = event.block.timestamp;
  swap.txHash = event.transaction.hash;
  swap.save();

  pool.swapCount = pool.swapCount.plus(ONE);
  pool.volumeWad = pool.volumeWad.plus(amountInWad);
  // Fee is charged on input, in hundredths of a bip.
  pool.feesWad = pool.feesWad.plus(
    amountInWad.times(pool.feeBps).div(BigInt.fromI32(1000000))
  );
  pool.save();
}

export function handleMint(event: MintEvent): void {
  let pool = loadPool(event.address, event);
  let id = tickId(pool, event.params.tickIdx);

  let tick = Tick.load(id);
  if (tick == null) {
    tick = new Tick(id);
    tick.pool = pool.id;
    tick.tickIdx = event.params.tickIdx;
    tick.crossCount = ZERO;
    tick.createdAt = event.block.timestamp;
    tick.createdBlock = event.block.number;
    tick.shareOfRIntBps = 0;
    tick.boundaryProgressBps = 0;
    tick.k = event.params.kWad;
    tick.r = event.params.rWad;
    tick.isInterior = true;
    tick.feeGrowthInside = ZERO;
    tick.liquidityGross = ZERO;
  }
  // `creator` is set on every Mint so a tick discovered by refreshState before
  // its log arrives does not keep the zero address.
  tick.creator = event.params.recipient;
  tick.save();

  let ev = new LiquidityEvent(eventId(event));
  ev.pool = pool.id;
  ev.tick = id;
  ev.action = "MINT";
  ev.account = event.params.recipient;
  ev.rWad = event.params.rWad;
  ev.kWad = event.params.kWad;
  ev.amounts = event.params.amounts;
  ev.blockNumber = event.block.number;
  ev.timestamp = event.block.timestamp;
  ev.txHash = event.transaction.hash;
  ev.save();

  refreshState(pool, event);
}

export function handleBurn(event: BurnEvent): void {
  let pool = loadPool(event.address, event);
  let id = tickId(pool, event.params.tickIdx);
  refreshState(pool, event);

  if (Tick.load(id) == null) {
    log.warning("Burn for unknown tick {}", [id]);
    return;
  }

  let ev = new LiquidityEvent(eventId(event));
  ev.pool = pool.id;
  ev.tick = id;
  ev.action = "BURN";
  ev.account = event.params.owner;
  ev.rWad = event.params.rWad;
  ev.kWad = null;
  ev.amounts = event.params.amounts;
  ev.blockNumber = event.block.number;
  ev.timestamp = event.block.timestamp;
  ev.txHash = event.transaction.hash;
  ev.save();
}

export function handleCollect(event: CollectEvent): void {
  let pool = loadPool(event.address, event);
  let id = tickId(pool, event.params.tickIdx);
  refreshState(pool, event);

  if (Tick.load(id) == null) {
    log.warning("Collect for unknown tick {}", [id]);
    return;
  }

  let ev = new LiquidityEvent(eventId(event));
  ev.pool = pool.id;
  ev.tick = id;
  ev.action = "COLLECT";
  ev.account = event.params.owner;
  ev.rWad = ZERO;
  ev.kWad = null;
  ev.amounts = event.params.fees;
  ev.blockNumber = event.block.number;
  ev.timestamp = event.block.timestamp;
  ev.txHash = event.transaction.hash;
  ev.save();
}

export function handleTickCrossed(event: TickCrossedEvent): void {
  let pool = loadPool(event.address, event);
  let id = tickId(pool, event.params.tickIdx);

  refreshState(pool, event);

  let tick = Tick.load(id);
  if (tick == null) {
    log.warning("TickCrossed for unknown tick {}", [id]);
    return;
  }
  tick.crossCount = tick.crossCount.plus(ONE);
  tick.lastCrossedAt = event.block.timestamp;
  tick.save();

  let x = new TickCross(eventId(event));
  x.pool = pool.id;
  x.tick = id;
  x.nowInterior = event.params.nowInterior;
  x.rIntAfter = pool.rInt;
  // Recorded from state read AFTER the crossing, so this is the real answer to
  // "did this crossing freeze mint and burn for everyone", not a guess.
  x.causedFreeze = pool.frozen;
  x.blockNumber = event.block.number;
  x.timestamp = event.block.timestamp;
  x.txHash = event.transaction.hash;
  x.save();

  pool.crossCount = pool.crossCount.plus(ONE);
  pool.save();
}
