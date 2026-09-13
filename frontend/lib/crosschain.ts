import { type Address, type Hex, encodeAbiParameters, parseAbiParameters } from "viem";
import { FX_POOL, fxAssetsByIndex } from "@/lib/fx";

// ─── Cross-chain deployments ─────────────────────────────────────────────────
// One OrbitalHook + one OrbitalIntentSettler per chain. The two settlers are
// registered as Hyperlane peers of each other, which is what lets the origin
// chain verify that a fill really happened on the destination.
//
// NOTE ON ASSET ORDER: the hook sorts its assets ascending by address, and
// addresses are unrelated across chains. USDC is index 3 on Base Sepolia and
// index 1 on Arbitrum Sepolia. Always resolve by symbol, never by index.

export interface CrossChainAsset {
  symbol: string;
  address: Address;
  decimals: number;
  index: number;
}

export interface CrossChainDeployment {
  chainId: number;
  name: string;
  short: string;
  explorer: string;
  orbitalHook: Address;
  poolManager: Address;
  /// Router + quoter for SAME-chain swaps against this chain's Orbital pool.
  swapRouter: Address;
  quoter: Address;
  /// Absent on chains with no ERC-7683 settler; those can only do same-chain swaps.
  intentSettler?: Address;
  hyperlaneMailbox?: Address;
  hyperlaneDomain?: number;
  /// Whether `hyperlaneMailbox` is REAL Hyperlane transport.
  ///
  /// A deployed settler is not sufficient for a routable cross-chain order: the
  /// mailbox behind it also has to actually relay. Arc testnet has no Hyperlane
  /// deployment at all, so its settler sits behind a local shim that emits
  /// events and delivers nothing. Defaults to true; only set false where the
  /// mailbox is stubbed, and `supportsCrossChain` will then exclude the chain.
  mailboxRelays?: boolean;
  /// Shown in the UI wherever a chain is excluded from cross-chain routing.
  crossChainNote?: string;
  /// Block the hook was deployed at. Event scanners start here, not genesis.
  deployBlock: bigint;
  assets: Record<string, CrossChainAsset>;
}

export const UNICHAIN_SEPOLIA_ID = 1301;
export const ARBITRUM_SEPOLIA_ID = 421614;
export const ARC_TESTNET_ID = 5042002;

export const DEPLOYMENTS: Record<number, CrossChainDeployment> = {
  // Generated from orbitalHook/deployments.json - keep the two in step.
  [UNICHAIN_SEPOLIA_ID]: {
    chainId: UNICHAIN_SEPOLIA_ID,
    name: "Unichain Sepolia",
    short: "Unichain",
    explorer: "https://sepolia.uniscan.xyz",
    orbitalHook: "0xB9cD5ccF597e49F87C9c73eFABb5410195fE6A88",
    poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
    swapRouter: "0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540",
    quoter: "0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472",
    intentSettler: "0x905Ef8cb78aaDc33dC1de0f22471561f7d921E8A",
    hyperlaneMailbox: "0xDDcFEcF17586D08A5740B7D91735fcCE3dfe3eeD",
    hyperlaneDomain: 1301,
    deployBlock: 62428261n,
    assets: {
      FRAX:  { symbol: "FRAX", address: "0x530f64feE1F4DCBd2A7c725156f53DAa8f8191Db", decimals: 18, index: 0 },
      USDT:  { symbol: "USDT", address: "0x5F134Ec4C77A71a6a7B008e951762bf26e763B6D", decimals: 6 , index: 1 },
      DAI:   { symbol: "DAI", address: "0x8FE0995C389dF28f2aB910599Ff41E2F992d113f", decimals: 18, index: 2 },
      USDC:  { symbol: "USDC", address: "0xa2d96B6101231ea3DDBc056819834293e0c5849B", decimals: 6 , index: 3 },
    },
  },
  [ARBITRUM_SEPOLIA_ID]: {
    chainId: ARBITRUM_SEPOLIA_ID,
    name: "Arbitrum Sepolia",
    short: "Arbitrum",
    explorer: "https://sepolia.arbiscan.io",
    orbitalHook: "0x8e7BEf4320f73a39100C42325Fc426CBD1842a88",
    poolManager: "0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317",
    swapRouter: "0xcD8D7e10A7aA794C389d56A07d85d63E28780220",
    quoter: "0xF0DB224d356dFF5cFF51D3d7295391bB2c9265FE",
    intentSettler: "0x050A876F5F4883ea17588077940c1E0dd4867D2B",
    hyperlaneMailbox: "0x598facE78a4302f11E3de0bee1894Da0b2Cb71F8",
    hyperlaneDomain: 421614,
    deployBlock: 308368410n,
    assets: {
      FRAX:  { symbol: "FRAX", address: "0x20b4287b2214bC45be698a8112D8041564E560Fc", decimals: 18, index: 0 },
      DAI:   { symbol: "DAI", address: "0x7f9510069Bc2c9b0Caa2b67dA83993c023f37403", decimals: 18, index: 1 },
      USDC:  { symbol: "USDC", address: "0x9F1D4cA186fa3fb9ED4BBA5b1E199808d73Fe14f", decimals: 6 , index: 2 },
      USDT:  { symbol: "USDT", address: "0xF5D81CbFb68DAF9AbBc8A4056E04CC09B88E9002", decimals: 6 , index: 3 },
    },
  },
  // Circle's Arc. Same hook, same four stables, same $24M seed as the others,
  // but SAME-CHAIN ONLY: see `mailboxRelays`. Arc testnet has neither a
  // canonical Uniswap v4 nor a Hyperlane deployment, so the PoolManager, router
  // and quoter here were deployed by `script/DeployArc.s.sol` and the settler
  // sits behind a local shim. Arc MAINNET has both canonically and is the path
  // to real cross-chain; see `_arc` in orbitalHook/deployments.json.
  [ARC_TESTNET_ID]: {
    chainId: ARC_TESTNET_ID,
    name: "Arc Testnet",
    short: "Arc",
    explorer: "https://testnet.arcscan.app",
    orbitalHook: "0x1D922FB97c92b00706A449ba78EEFc0D3E01aa88",
    poolManager: "0x9BEACCac4e0358Cc276703dcE7341B9B9fEfd5f7",
    swapRouter: "0xC30819b8ac12B5d12751b83cFfebD6F0bFa0b53E",
    quoter: "0x17684C1C522E7cCD9a38E1Ab5994BB294Bf1ef90",
    intentSettler: "0x71ac1F49f25a5f0Ad44e543fa4BB4e356d8252A0",
    hyperlaneMailbox: "0x2896bc4b03610816eee4758c7a2e87a2724E2Dcb",
    hyperlaneDomain: ARC_TESTNET_ID,
    mailboxRelays: false,
    crossChainNote: "Arc testnet has no Hyperlane deployment; same-chain swaps only",
    deployBlock: 61854987n,
    assets: {
      USDC:  { symbol: "USDC", address: "0x18033E198A2b0af2AfA75aFcc520f42179955a68", decimals: 6 , index: 0 },
      FRAX:  { symbol: "FRAX", address: "0x5A2EB33e6Ec0c8bbE9c18ED09428e4E7B5A86265", decimals: 18, index: 1 },
      USDT:  { symbol: "USDT", address: "0x7d1c2f283811A0aa7D538e3C859DA8BB45330e35", decimals: 6 , index: 2 },
      DAI:   { symbol: "DAI", address: "0xdA585869c1b63F20Cb54226cd99B006d90BAD784", decimals: 18, index: 3 },
    },
  },
};

/// The chain the single-chain pages (pools, positions, transactions) default to,
/// and the swap widget's opening pair. Unichain Sepolia is the canonical home of
/// this hook; the other two carry the same deployment for cross-chain routes.
/// One constant to move if that changes.
export const PRIMARY_CHAIN_ID = UNICHAIN_SEPOLIA_ID;

/// Chain the swap widget opens on.
///
/// Deliberately separate from `PRIMARY_CHAIN_ID`. The widget used to key its
/// opening pair off `CHAIN_IDS[0]`, which silently coupled the default swap to
/// the dropdown's display order: reordering that array to move a chain up the
/// list would have changed which pool the app opens on. These are different
/// decisions, so they get different constants.
///
/// Arc is a valid default precisely because it is same-chain only: both sides
/// of the opening pair live on it, so the widget never opens on a route that
/// cannot settle.
export const DEFAULT_SWAP_CHAIN_ID = ARC_TESTNET_ID;

/// Display order in the token dropdown, primary chain first.
// Base Sepolia was retired on 2026-09-07 with the tick-merge fix: its
// deployment still runs the old contract, so leaving it listed would have shown
// stale, defective ticks alongside three corrected ones.
export const CHAIN_IDS = [UNICHAIN_SEPOLIA_ID, ARBITRUM_SEPOLIA_ID, ARC_TESTNET_ID] as const;

/// Every chain carries the same four stables, so a same-chain route always exists.
export const ROUTABLE_SYMBOLS = ["USDC", "USDT", "DAI", "FRAX"] as const;

export function deploymentFor(chainId: number): CrossChainDeployment | undefined {
  return DEPLOYMENTS[chainId];
}

export function assetOn(chainId: number, symbol: string): CrossChainAsset | undefined {
  return DEPLOYMENTS[chainId]?.assets[symbol];
}

/// A chain can originate or receive a cross-chain order only if it has a settler
/// AND that settler's mailbox actually relays.
///
/// Both halves matter. Arc has a deployed, fully functional settler, but behind
/// a shim mailbox that delivers nothing, so an order opened there could never be
/// proven and would sit until it hit the refund window. Gating on the settler
/// alone would surface Arc routes in the UI that are guaranteed to strand funds.
export function supportsCrossChain(chainId: number): boolean {
  const d = DEPLOYMENTS[chainId];
  return !!d?.intentSettler && d.mailboxRelays !== false;
}

/// Why a given (origin, destination) pair cannot be routed, or undefined if it can.
export function routeBlockedReason(originChainId: number, destChainId: number): string | undefined {
  if (originChainId === destChainId) return undefined;
  const a = DEPLOYMENTS[originChainId];
  const b = DEPLOYMENTS[destChainId];
  if (!a || !b) return "Unknown chain";
  if (!a.intentSettler) return `No settler on ${a.short}`;
  if (!b.intentSettler) return `No settler on ${b.short}`;
  if (a.mailboxRelays === false) return a.crossChainNote ?? `No message relay on ${a.short}`;
  if (b.mailboxRelays === false) return b.crossChainNote ?? `No message relay on ${b.short}`;
  return undefined;
}

// ─── Order encoding ──────────────────────────────────────────────────────────

/// keccak256 of the OrbitalOrderData struct signature. Read from the deployed
/// settler rather than recomputed here, so a struct change surfaces as a
/// rejected order instead of a silent mismatch.
export const ORBITAL_ORDER_DATA_TYPE =
  "0x3b84c8cf9f64e5325c17c9d45975710aea13c76922950c9f4a5caaa7667602b2" as Hex;

/// Seconds the order stays fillable. The settler adds its own `refundBuffer`
/// (12h) on top before the user may reclaim, so a slow proof cannot strand a
/// filler who already paid out.
export const DEFAULT_FILL_WINDOW_SECONDS = 6 * 60 * 60;

export interface OrbitalOrderData {
  inputToken: Address;
  inputAmount: bigint;
  outputToken: Address;
  outputAmount: bigint;
  destinationChainId: bigint;
  destinationSettler: Address;
  recipient: Address;
}

const ORDER_DATA_PARAMS = parseAbiParameters(
  "(address inputToken, uint256 inputAmount, address outputToken, uint256 outputAmount, uint64 destinationChainId, address destinationSettler, address recipient)"
);

export function encodeOrderData(d: OrbitalOrderData): Hex {
  return encodeAbiParameters(ORDER_DATA_PARAMS, [
    {
      inputToken: d.inputToken,
      inputAmount: d.inputAmount,
      outputToken: d.outputToken,
      outputAmount: d.outputAmount,
      destinationChainId: d.destinationChainId,
      destinationSettler: d.destinationSettler,
      recipient: d.recipient,
    },
  ]);
}

/// Order lifecycle on the ORIGIN chain, mirroring the settler's enum.
export enum OrderStatus {
  NONE = 0,
  OPENED = 1,
  SETTLED = 2,
  REFUNDED = 3,
}

export const ORDER_STATUS_LABEL: Record<OrderStatus, string> = {
  [OrderStatus.NONE]: "Not found",
  [OrderStatus.OPENED]: "Awaiting filler",
  [OrderStatus.SETTLED]: "Settled",
  [OrderStatus.REFUNDED]: "Refunded",
};

// ─── ABIs ────────────────────────────────────────────────────────────────────

export const SETTLER_ABI = [
  {
    type: "function",
    name: "open",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "order",
        type: "tuple",
        components: [
          { name: "fillDeadline", type: "uint32" },
          { name: "orderDataType", type: "bytes32" },
          { name: "orderData", type: "bytes" },
        ],
      },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "resolve",
    stateMutability: "view",
    inputs: [
      {
        name: "order",
        type: "tuple",
        components: [
          { name: "fillDeadline", type: "uint32" },
          { name: "orderDataType", type: "bytes32" },
          { name: "orderData", type: "bytes" },
        ],
      },
    ],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "user", type: "address" },
          { name: "originChainId", type: "uint256" },
          { name: "openDeadline", type: "uint32" },
          { name: "fillDeadline", type: "uint32" },
          { name: "orderId", type: "bytes32" },
          {
            name: "maxSpent",
            type: "tuple[]",
            components: [
              { name: "token", type: "bytes32" },
              { name: "amount", type: "uint256" },
              { name: "recipient", type: "bytes32" },
              { name: "chainId", type: "uint256" },
            ],
          },
          {
            name: "minReceived",
            type: "tuple[]",
            components: [
              { name: "token", type: "bytes32" },
              { name: "amount", type: "uint256" },
              { name: "recipient", type: "bytes32" },
              { name: "chainId", type: "uint256" },
            ],
          },
          {
            name: "fillInstructions",
            type: "tuple[]",
            components: [
              { name: "destinationChainId", type: "uint64" },
              { name: "destinationSettler", type: "bytes32" },
              { name: "originData", type: "bytes" },
            ],
          },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "orders",
    stateMutability: "view",
    inputs: [{ name: "", type: "bytes32" }],
    outputs: [
      { name: "user", type: "address" },
      { name: "inputToken", type: "address" },
      { name: "inputAmount", type: "uint256" },
      { name: "fillDeadline", type: "uint32" },
      { name: "refundAfter", type: "uint32" },
      { name: "status", type: "uint8" },
    ],
  },
  {
    type: "function",
    name: "refund",
    stateMutability: "nonpayable",
    inputs: [{ name: "orderId", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "filledBy",
    stateMutability: "view",
    inputs: [{ name: "", type: "bytes32" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "refundBuffer",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint32" }],
  },
] as const;

/// Minimal quoter surface on the OrbitalHook, for the destination-side estimate.
export const HOOK_RESERVES_ABI = [
  { type: "function", name: "reserves", inputs: [{ type: "uint8" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "N", inputs: [], outputs: [{ type: "uint8" }], stateMutability: "view" },
  { type: "function", name: "fee", inputs: [], outputs: [{ type: "uint24" }], stateMutability: "view" },
] as const;

export const CC_ERC20_ABI = [
  { type: "function", name: "balanceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "allowance", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "approve", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }], stateMutability: "nonpayable" },
  { type: "function", name: "mint", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "decimals", inputs: [], outputs: [{ type: "uint8" }], stateMutability: "view" },
] as const;

export const explorerTx = (chainId: number, hash: string) =>
  `${DEPLOYMENTS[chainId]?.explorer ?? ""}/tx/${hash}`;
export const explorerAddress = (chainId: number, addr: string) =>
  `${DEPLOYMENTS[chainId]?.explorer ?? ""}/address/${addr}`;

/// Display metadata keyed by LOWERCASED token address, across every chain.
/// Built from the registry so a redeploy cannot leave stale symbols or the
/// wrong decimals behind.
export const TOKEN_DISPLAY: Record<string, { symbol: string; name: string; color: string; decimals: number; chainId: number }> = (() => {
  const NAMES: Record<string, string> = {
    USDC: "USD Coin",
    USDT: "Tether USD",
    DAI: "Dai Stablecoin",
    FRAX: "Frax",
  };
  const COLORS: Record<string, string> = {
    USDC: "#2775CA",
    USDT: "#26A17B",
    DAI: "#F4B731",
    FRAX: "#BFBFBF",
    EURC: "#6E56CF",
    EURe: "#EA6A1F",
  };
  const out: Record<string, { symbol: string; name: string; color: string; decimals: number; chainId: number }> = {};
  for (const chainId of CHAIN_IDS) {
    const dep = DEPLOYMENTS[chainId];
    for (const sym of ROUTABLE_SYMBOLS) {
      const a = dep.assets[sym];
      out[a.address.toLowerCase()] = {
        symbol: sym,
        name: NAMES[sym] ?? sym,
        color: COLORS[sym] ?? "#888",
        decimals: a.decimals,
        chainId,
      };
    }
  }
  // FX pool tokens are distinct contracts from the stable pools' (its USDC is
  // not the stable pool's USDC), so they get their own address-keyed entries.
  if (FX_POOL) {
    for (const a of FX_POOL.assets) {
      out[a.address.toLowerCase()] = {
        symbol: a.symbol,
        name: a.name,
        color: COLORS[a.symbol] ?? "#888",
        decimals: a.decimals,
        chainId: FX_POOL.chainId,
      };
    }
  }
  return out;
})();

// ─── Pools ───────────────────────────────────────────────────────────────────
// Orbital has two pool TYPES on one engine: `stable` (OrbitalHook, pegged
// assets at parity) and `fx` (OrbitalFXHook, different currencies priced by
// AggregatorV3 feeds). Every page that lists, reads or scans pools goes
// through `ALL_POOLS`, so a pool of either type behaves the same everywhere.

export type PoolType = "stable" | "fx";

export interface PoolEntry {
  chainId: number;
  address: Address;
  /// Chain display names.
  name: string;
  short: string;
  type: PoolType;
  /// Block the hook was deployed at: event scanners start here.
  deployBlock: bigint;
  /// Assets in the hook's OWN index order, the order its events use. Carried
  /// per POOL, not per chain: one chain can host a stable and an FX pool, and
  /// their index orders are unrelated.
  assets: CrossChainAsset[];
}

export const POOL_TYPE_LABEL: Record<PoolType, string> = { stable: "Stable", fx: "FX" };

/// Every deployed Orbital pool: the stable pool on each chain, then FX pools.
export const ALL_POOLS: PoolEntry[] = [
  ...CHAIN_IDS.map((chainId) => ({
    chainId,
    address: DEPLOYMENTS[chainId].orbitalHook,
    name: DEPLOYMENTS[chainId].name,
    short: DEPLOYMENTS[chainId].short,
    type: "stable" as const,
    deployBlock: DEPLOYMENTS[chainId].deployBlock,
    assets: assetsByIndex(chainId),
  })),
  ...(FX_POOL
    ? [
        {
          chainId: FX_POOL.chainId,
          address: FX_POOL.hook,
          name: DEPLOYMENTS[FX_POOL.chainId]?.name ?? String(FX_POOL.chainId),
          short: DEPLOYMENTS[FX_POOL.chainId]?.short ?? String(FX_POOL.chainId),
          type: "fx" as const,
          deployBlock: FX_POOL.deployBlock,
          assets: fxAssetsByIndex(FX_POOL).map(({ symbol, address, decimals, index }) => ({ symbol, address, decimals, index })),
        },
      ]
    : []),
];

/// The pool behind an address, of either type.
///
/// Pool routes are keyed by address alone (`/app/pool/[address]`), so anything
/// resolving one back to its deployment has to go through here. Hook addresses
/// are CREATE2-mined and unique across pools and chains, so the lookup is
/// unambiguous.
export function poolByAddress(address: string): PoolEntry | undefined {
  const want = address.toLowerCase();
  return ALL_POOLS.find((p) => p.address.toLowerCase() === want);
}

/// Which chain a given Orbital pool address lives on.
///
/// Reading a pool without its chain silently falls back to the primary chain,
/// which means querying a Unichain RPC for an Arc address and rendering an
/// empty pool. Unknown addresses fall back to the primary chain.
export function chainIdForPool(address: string): number {
  return poolByAddress(address)?.chainId ?? PRIMARY_CHAIN_ID;
}

// ─── Tokens and routes ───────────────────────────────────────────────────────

/// A pool a token trades in, and the token's index in THAT pool's asset order.
/// Indices are per pool: a token held by two pools generally sits at a
/// different index in each.
export interface PoolSlot {
  pool: Address;
  type: PoolType;
  index: number;
}

/// One row per token CONTRACT on a chain. A token can sit in several pools on
/// its chain (Arc's USDC and USDT are in both the stable and the FX pool); the
/// pair being swapped decides which pool trades it.
export interface TokenRow {
  symbol: string;
  address: Address;
  decimals: number;
  chainId: number;
  chainShort: string;
  /// `chainId:SYMBOL`; symbols are unique per chain across all its pools.
  key: string;
  pools: PoolSlot[];
}

/// Every token on every chain, grouped by chain in `CHAIN_IDS` order, the
/// cross-chain stables first in `ROUTABLE_SYMBOLS` order.
export const ALL_TOKENS: TokenRow[] = (() => {
  const byContract = new Map<string, TokenRow>();
  for (const p of ALL_POOLS) {
    for (const a of p.assets) {
      const id = `${p.chainId}:${a.address.toLowerCase()}`;
      let row = byContract.get(id);
      if (!row) {
        row = {
          symbol: a.symbol,
          address: a.address,
          decimals: a.decimals,
          chainId: p.chainId,
          chainShort: p.short,
          key: `${p.chainId}:${a.symbol}`,
          pools: [],
        };
        byContract.set(id, row);
      }
      row.pools.push({ pool: p.address, type: p.type, index: a.index });
    }
  }
  const rows = [...byContract.values()];

  // Two contracts under one key would make `tokenByKey` ambiguous; a registry
  // that produces that is wrong, so fail loudly at load rather than misroute.
  const seen = new Set<string>();
  for (const r of rows) {
    if (seen.has(r.key)) throw new Error(`Token registry: two contracts share the key ${r.key}`);
    seen.add(r.key);
  }

  const chainOrder = (id: number) => (CHAIN_IDS as readonly number[]).indexOf(id);
  const rank = (r: TokenRow) => {
    const i = (ROUTABLE_SYMBOLS as readonly string[]).indexOf(r.symbol);
    return i >= 0 ? i : ROUTABLE_SYMBOLS.length;
  };
  return rows
    .map((r, order) => ({ r, order }))
    .sort(
      (x, y) =>
        chainOrder(x.r.chainId) - chainOrder(y.r.chainId) || rank(x.r) - rank(y.r) || x.order - y.order,
    )
    .map(({ r }) => r);
})();

export function tokenByKey(key: string): TokenRow | undefined {
  return ALL_TOKENS.find((t) => t.key === key);
}

/// Whether the token trades in a stable pool, the only pools cross-chain
/// orders settle through.
export function inStablePool(t: TokenRow): boolean {
  return t.pools.some((s) => s.type === "stable");
}

/// A same-chain swap venue: one pool holding both tokens, with each token's
/// index in that pool.
export interface Venue {
  pool: Address;
  type: PoolType;
  indexIn: number;
  indexOut: number;
}

/// Every pool on the tokens' chain that holds both, in `ALL_POOLS` order.
/// More than one means a choice: the swap quotes each and takes the best.
export function venuesFor(a: TokenRow, b: TokenRow): Venue[] {
  if (a.chainId !== b.chainId) return [];
  return a.pools.flatMap((sa) => {
    const sb = b.pools.find((s) => s.pool.toLowerCase() === sa.pool.toLowerCase());
    return sb ? [{ pool: sa.pool, type: sa.type, indexIn: sa.index, indexOut: sb.index }] : [];
  });
}

/// Why `a -> b` cannot be routed, with a one-line explanation, or undefined if
/// it can. Same-chain, some pool must hold both tokens; cross-chain orders
/// settle through the stable pools, so both tokens must trade in one.
export function tokenRouteBlocked(a: TokenRow, b: TokenRow): { reason: string; detail: string } | undefined {
  if (a.chainId === b.chainId) {
    if (venuesFor(a, b).length > 0) return undefined;
    return {
      reason: `No pool holds ${a.symbol} and ${b.symbol}`,
      detail: `${a.symbol} and ${b.symbol} trade in different pools on ${a.chainShort}. Swap through a token both pools hold, such as USDC.`,
    };
  }
  if (!inStablePool(a) || !inStablePool(b)) {
    return {
      reason: "FX tokens trade on their own chain",
      detail: "Cross-chain orders settle through stable pools. FX currencies trade within their chain's FX pool.",
    };
  }
  const reason = routeBlockedReason(a.chainId, b.chainId);
  return reason
    ? { reason, detail: "Cross-chain routes exist only between chains that have an intent settler deployed." }
    : undefined;
}

/// A chain's assets in the hook's OWN index order (`assetAt(0..N-1)`).
///
/// Events emit `assetIn`/`assetOut` as INDICES into that array, so anything
/// decoding them must map through this, not through a symbol list or a
/// cross-chain table. Indexing a multi-chain map by a per-chain index silently
/// resolves to the wrong token.
export function assetsByIndex(chainId: number): CrossChainAsset[] {
  const dep = DEPLOYMENTS[chainId];
  if (!dep) return [];
  return Object.values(dep.assets).sort((a, b) => a.index - b.index);
}
