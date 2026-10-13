import { type Address, type Hex, encodeAbiParameters, parseAbiParameters } from "viem";

// ─── Cross-chain deployments ─────────────────────────────────────────────────
// One OrbitalHook per chain, plus an OrbitalIntentSettler wherever Hyperlane
// runs. The settlers are registered as Hyperlane peers of each other, which is
// what lets the origin chain verify that a fill really happened on the
// destination. Robinhood Chain testnet has no Hyperlane, so no settler.
//
// NOTE ON ASSET ORDER: the hook sorts its assets ascending by address, and
// addresses are unrelated across chains. USDC is index 3 on Arbitrum Sepolia,
// 1 on Ethereum Sepolia and 0 on Robinhood testnet. Always resolve by symbol,
// never by index.

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
  /// mailbox behind it also has to actually relay. Defaults to true; set false
  /// where the mailbox is stubbed, and `supportsCrossChain` will then exclude
  /// the chain.
  mailboxRelays?: boolean;
  /// Shown in the UI wherever a chain is excluded from cross-chain routing.
  crossChainNote?: string;
  /// Block the hook was deployed at. Event scanners start here, not genesis.
  deployBlock: bigint;
  assets: Record<string, CrossChainAsset>;
}

export const ARBITRUM_SEPOLIA_ID = 421614;
export const ROBINHOOD_TESTNET_ID = 46630;
export const ETHEREUM_SEPOLIA_ID = 11155111;
export const BASE_SEPOLIA_ID = 84532;

export const DEPLOYMENTS: Record<number, CrossChainDeployment> = {
  // Generated from orbitalHook/deployments.json - keep the two in step.
  [ARBITRUM_SEPOLIA_ID]: {
    chainId: ARBITRUM_SEPOLIA_ID,
    name: "Arbitrum Sepolia",
    short: "Arbitrum",
    explorer: "https://sepolia.arbiscan.io",
    orbitalHook: "0x3F09f9eCf71Cf78f346Eb2683D4a295D00e82A88",
    poolManager: "0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317",
    swapRouter: "0xcD8D7e10A7aA794C389d56A07d85d63E28780220",
    quoter: "0xF0DB224d356dFF5cFF51D3d7295391bB2c9265FE",
    // Redeployed 12 Oct 2026; no settler on the new hook, so same-chain only.
    crossChainNote: "This deployment is same-chain only",
    deployBlock: 318516459n,
    assets: {
      FRAX:  { symbol: "FRAX", address: "0x15aabbc1c571147f05b5f9d37690ca6843dee044", decimals: 18, index: 0 },
      USDC:  { symbol: "USDC", address: "0x36b5bc5998f1aae8754697e60314b8c5b6d435ff", decimals: 6 , index: 1 },
      USDT:  { symbol: "USDT", address: "0x47936d9fa0bf4eee6f44ff6308cfe59a3f80913d", decimals: 6 , index: 2 },
      DAI:   { symbol: "DAI", address: "0xc4fdb067adff5bc0d10886598ddc00fb432f9794", decimals: 18, index: 3 },
    },
  },
  [ROBINHOOD_TESTNET_ID]: {
    chainId: ROBINHOOD_TESTNET_ID,
    name: "Robinhood Chain Testnet",
    short: "Robinhood",
    explorer: "https://explorer.testnet.chain.robinhood.com",
    orbitalHook: "0xe2cE434ABB1F2a939fA017f69CD5f7c19c36Aa88",
    poolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
    swapRouter: "0x5911Ef6ABd9Cb84BFc78d78383d964c1e7ef12f2",
    quoter: "0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94",
    // No Hyperlane on Robinhood testnet, so no settler: same-chain only.
    crossChainNote: "Robinhood Chain testnet has no Hyperlane route, so it is same-chain only",
    deployBlock: 133795692n,
    assets: {
      USDT:  { symbol: "USDT", address: "0x0a29619e8580d90b14200a734faad4677e9d1645", decimals: 6 , index: 0 },
      USDC:  { symbol: "USDC", address: "0x2f7a2dc7d74645a31cabb5466219ccab70913377", decimals: 6 , index: 1 },
      DAI:   { symbol: "DAI", address: "0x45dc287a307eccf7426cb2377ee2865457592fae", decimals: 18, index: 2 },
      FRAX:  { symbol: "FRAX", address: "0xc79a946a0a8661cde0cc02a34d387c5b4ccab0e4", decimals: 18, index: 3 },
    },
  },
  [ETHEREUM_SEPOLIA_ID]: {
    chainId: ETHEREUM_SEPOLIA_ID,
    name: "Ethereum Sepolia",
    short: "Ethereum",
    explorer: "https://sepolia.etherscan.io",
    orbitalHook: "0xd92022CB51f49D61261321836A7a7b2e1A332a88",
    poolManager: "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543",
    swapRouter: "0xf13D190e9117920c703d79B5F33732e10049b115",
    quoter: "0x58D48990408b4ba45dE08679de3921EbD6fA71b7",
    crossChainNote: "This deployment is same-chain only",
    deployBlock: 11901133n,
    assets: {
      FRAX:  { symbol: "FRAX", address: "0x51fb24e0e855e8709a017f3acc69ec6aa42cf8d6", decimals: 18, index: 0 },
      USDT:  { symbol: "USDT", address: "0x7cd4e073fd118f2f1197c1c1aa450dd410ebdeef", decimals: 6 , index: 1 },
      USDC:  { symbol: "USDC", address: "0xd289f244ac5fb4e372bea5f92f07fa6960ca4307", decimals: 6 , index: 2 },
      DAI:   { symbol: "DAI", address: "0xf2dc831ee8e1400ce58f8c27427025cb91ec64cd", decimals: 18, index: 3 },
    },
  },
  [BASE_SEPOLIA_ID]: {
    chainId: BASE_SEPOLIA_ID,
    name: "Base Sepolia",
    short: "Base",
    explorer: "https://sepolia.basescan.org",
    orbitalHook: "0xa1685261278e44C12921a0f213daDfBF9Beb6A88",
    poolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    swapRouter: "0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9",
    quoter: "0xE584726a93f37177219F72b4BA76DE7fFA851664",
    crossChainNote: "This deployment is same-chain only",
    deployBlock: 48033167n,
    assets: {
      USDC:  { symbol: "USDC", address: "0x2822852629b4ed8420da072cb40318cf1318537f", decimals: 6 , index: 0 },
      USDT:  { symbol: "USDT", address: "0x8119fc1a13e2a69735de1c9a38d6ffa0c94e986d", decimals: 6 , index: 1 },
      DAI:   { symbol: "DAI", address: "0x92d06018f07cea34f09a2aa2c8bcc47a6ade59b4", decimals: 18, index: 2 },
      FRAX:  { symbol: "FRAX", address: "0xe6de3e3be032e391786754c824c5800ca010c54f", decimals: 18, index: 3 },
    },
  },
};

/// The chain the single-chain pages (pools, positions, transactions) default to,
/// and the swap widget's opening pair. Robinhood Chain is the home of this
/// hook; the other two carry the same deployment, and between them the
/// cross-chain routes. One constant to move if that changes.
export const PRIMARY_CHAIN_ID = ROBINHOOD_TESTNET_ID;

/// Chain the swap widget opens on.
///
/// Deliberately separate from `PRIMARY_CHAIN_ID`. The widget used to key its
/// opening pair off `CHAIN_IDS[0]`, which silently coupled the default swap to
/// the dropdown's display order: reordering that array to move a chain up the
/// list would have changed which pool the app opens on. These are different
/// decisions, so they get different constants.
///
/// The opening pair is same-chain, so the widget never opens on a route that
/// depends on a cross-chain settlement — which matters more here, since
/// Robinhood has no Hyperlane mailbox and so no cross-chain settler at all.
export const DEFAULT_SWAP_CHAIN_ID = ROBINHOOD_TESTNET_ID;

/// Display order in the token dropdown, primary chain first.
export const CHAIN_IDS = [
  ROBINHOOD_TESTNET_ID,
  ARBITRUM_SEPOLIA_ID,
  BASE_SEPOLIA_ID,
  ETHEREUM_SEPOLIA_ID,
] as const;

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
/// Both halves matter: an order opened behind a mailbox that does not relay
/// could never be proven and would wait out the refund window.
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
  if (!a.intentSettler) return a.crossChainNote ?? `No settler on ${a.short}`;
  if (!b.intentSettler) return b.crossChainNote ?? `No settler on ${b.short}`;
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
  return out;
})();

// ─── Pools ───────────────────────────────────────────────────────────────────
// Every page that lists, reads or scans pools goes through `ALL_POOLS`, so a
// new pool only has to be registered once.

export interface PoolEntry {
  chainId: number;
  address: Address;
  /// Chain display names.
  name: string;
  short: string;
  /// Block the hook was deployed at: event scanners start here.
  deployBlock: bigint;
  /// Assets in the hook's OWN index order, the order its events use. Carried
  /// per POOL, not per chain: two pools on one chain have unrelated orders.
  assets: CrossChainAsset[];
}

/// Every deployed Orbital pool, one per chain.
export const ALL_POOLS: PoolEntry[] = CHAIN_IDS.map((chainId) => ({
  chainId,
  address: DEPLOYMENTS[chainId].orbitalHook,
  name: DEPLOYMENTS[chainId].name,
  short: DEPLOYMENTS[chainId].short,
  deployBlock: DEPLOYMENTS[chainId].deployBlock,
  assets: assetsByIndex(chainId),
}));

/// The pool behind an address.
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
/// which means querying one chain's RPC for another chain's address and
/// rendering an empty pool. Unknown addresses fall back to the primary chain.
export function chainIdForPool(address: string): number {
  return poolByAddress(address)?.chainId ?? PRIMARY_CHAIN_ID;
}

// ─── Tokens and routes ───────────────────────────────────────────────────────

/// A pool a token trades in, and the token's index in THAT pool's asset order.
/// Indices are per pool: a token held by two pools generally sits at a
/// different index in each.
export interface PoolSlot {
  pool: Address;
  index: number;
}

/// One row per token CONTRACT on a chain. A token can sit in several pools on
/// its chain; the pair being swapped decides which pool trades it.
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
      row.pools.push({ pool: p.address, index: a.index });
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

/// A same-chain swap venue: one pool holding both tokens, with each token's
/// index in that pool.
export interface Venue {
  pool: Address;
  indexIn: number;
  indexOut: number;
}

/// Every pool on the tokens' chain that holds both, in `ALL_POOLS` order.
/// More than one means a choice: the swap quotes each and takes the best.
export function venuesFor(a: TokenRow, b: TokenRow): Venue[] {
  if (a.chainId !== b.chainId) return [];
  return a.pools.flatMap((sa) => {
    const sb = b.pools.find((s) => s.pool.toLowerCase() === sa.pool.toLowerCase());
    return sb ? [{ pool: sa.pool, indexIn: sa.index, indexOut: sb.index }] : [];
  });
}

/// Why `a -> b` cannot be routed, with a one-line explanation, or undefined if
/// it can. Same-chain, some pool must hold both tokens; cross-chain, both
/// chains need a settler.
export function tokenRouteBlocked(a: TokenRow, b: TokenRow): { reason: string; detail: string } | undefined {
  if (a.chainId === b.chainId) {
    if (venuesFor(a, b).length > 0) return undefined;
    return {
      reason: `No pool holds ${a.symbol} and ${b.symbol}`,
      detail: `${a.symbol} and ${b.symbol} trade in different pools on ${a.chainShort}. Swap through a token both pools hold, such as USDC.`,
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
