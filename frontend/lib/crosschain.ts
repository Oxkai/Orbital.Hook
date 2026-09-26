import { type Address, type Hex, encodeAbiParameters, parseAbiParameters } from "viem";

// ─── Cross-chain deployments ─────────────────────────────────────────────────
// One OrbitalHook per chain, plus an OrbitalIntentSettler wherever Hyperlane
// runs. The settlers are registered as Hyperlane peers of each other, which is
// what lets the origin chain verify that a fill really happened on the
// destination. Robinhood Chain testnet has no Hyperlane, so no settler.
//
// NOTE ON ASSET ORDER: the hook sorts its assets ascending by address, and
// addresses are unrelated across chains. USDC is index 3 on Arbitrum Sepolia,
// 0 on Unichain Sepolia and 3 on Robinhood testnet. Always resolve by symbol,
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
export const UNICHAIN_SEPOLIA_ID = 1301;
export const ROBINHOOD_TESTNET_ID = 46630;

export const DEPLOYMENTS: Record<number, CrossChainDeployment> = {
  // Generated from orbitalHook/deployments.json - keep the two in step.
  [ARBITRUM_SEPOLIA_ID]: {
    chainId: ARBITRUM_SEPOLIA_ID,
    name: "Arbitrum Sepolia",
    short: "Arbitrum",
    explorer: "https://sepolia.arbiscan.io",
    orbitalHook: "0xdEE6773E69611CfA1395Dc47cDd4Cca6E36CaA88",
    poolManager: "0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317",
    swapRouter: "0xcD8D7e10A7aA794C389d56A07d85d63E28780220",
    quoter: "0xF0DB224d356dFF5cFF51D3d7295391bB2c9265FE",
    intentSettler: "0x3104462820D7D721cc7139400016B27cb137D74b",
    hyperlaneMailbox: "0x598facE78a4302f11E3de0bee1894Da0b2Cb71F8",
    hyperlaneDomain: 421614,
    deployBlock: 312599603n,
    assets: {
      FRAX:  { symbol: "FRAX", address: "0x0B44Ab88312EEAa545D9e27EE5Ea8DaD90a6bF9E", decimals: 18, index: 0 },
      DAI:   { symbol: "DAI", address: "0xB563e0914e80c7D8d726F3fAb12ac2dD8e315cF2", decimals: 18, index: 1 },
      USDT:  { symbol: "USDT", address: "0xC6c82FD06055346886F50A5a3B028dE9e8ad1e87", decimals: 6 , index: 2 },
      USDC:  { symbol: "USDC", address: "0xe22D8b0FfC1b3e94ecD8bb92724f8cC4eeba8f17", decimals: 6 , index: 3 },
    },
  },
  [UNICHAIN_SEPOLIA_ID]: {
    chainId: UNICHAIN_SEPOLIA_ID,
    name: "Unichain Sepolia",
    short: "Unichain",
    explorer: "https://sepolia.uniscan.xyz",
    orbitalHook: "0x2ad0767A51fD05c2d150f0f60eE436a52bF76a88",
    poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
    swapRouter: "0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540",
    quoter: "0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472",
    intentSettler: "0x0d20A58a3Ac0D017DFB093dBF3Bd3D843E285784",
    hyperlaneMailbox: "0xDDcFEcF17586D08A5740B7D91735fcCE3dfe3eeD",
    hyperlaneDomain: 1301,
    deployBlock: 63492025n,
    assets: {
      USDC:  { symbol: "USDC", address: "0x08662d330e03D0C624D4b00F7594fc297005957B", decimals: 6 , index: 0 },
      FRAX:  { symbol: "FRAX", address: "0x1A478E8Ad09D650f17df0288254bd24220Ff6b57", decimals: 18, index: 1 },
      DAI:   { symbol: "DAI", address: "0x7EB345af1f38Ee7a2C7E5bE984596e33014bDc81", decimals: 18, index: 2 },
      USDT:  { symbol: "USDT", address: "0x8C3E9929b523D658A92cb61286ba00A1A15635F7", decimals: 6 , index: 3 },
    },
  },
  [ROBINHOOD_TESTNET_ID]: {
    chainId: ROBINHOOD_TESTNET_ID,
    name: "Robinhood Chain Testnet",
    short: "Robinhood",
    explorer: "https://explorer.testnet.chain.robinhood.com",
    orbitalHook: "0x7F063D4852F0BE1Fb39490AcDc3A75ffC398EA88",
    poolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
    swapRouter: "0x5911Ef6ABd9Cb84BFc78d78383d964c1e7ef12f2",
    quoter: "0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94",
    // No Hyperlane on Robinhood testnet, so no settler: same-chain only.
    crossChainNote: "Robinhood Chain testnet has no Hyperlane route, so it is same-chain only",
    deployBlock: 124525672n,
    assets: {
      USDT:  { symbol: "USDT", address: "0x2896bc4b03610816eee4758c7a2e87a2724E2Dcb", decimals: 6 , index: 0 },
      DAI:   { symbol: "DAI", address: "0x602E7B42515d3E93A04e176C09a24eaF9F617c88", decimals: 18, index: 1 },
      FRAX:  { symbol: "FRAX", address: "0xe574C92e61579B3B77F5491a0C02C57157C915C1", decimals: 18, index: 2 },
      USDC:  { symbol: "USDC", address: "0xf17496625e0d602FF36e133C3B4CD1f5c0D3678a", decimals: 6 , index: 3 },
    },
  },
};

/// The chain the single-chain pages (pools, positions, transactions) default to,
/// and the swap widget's opening pair. Arbitrum Sepolia is the home of this
/// hook; the other two carry the same deployment for cross-chain routes.
/// One constant to move if that changes.
export const PRIMARY_CHAIN_ID = ARBITRUM_SEPOLIA_ID;

/// Chain the swap widget opens on.
///
/// Deliberately separate from `PRIMARY_CHAIN_ID`. The widget used to key its
/// opening pair off `CHAIN_IDS[0]`, which silently coupled the default swap to
/// the dropdown's display order: reordering that array to move a chain up the
/// list would have changed which pool the app opens on. These are different
/// decisions, so they get different constants.
///
/// The opening pair is same-chain, so the widget never opens on a route that
/// depends on a cross-chain settlement.
export const DEFAULT_SWAP_CHAIN_ID = ARBITRUM_SEPOLIA_ID;

/// Display order in the token dropdown, primary chain first.
export const CHAIN_IDS = [ARBITRUM_SEPOLIA_ID, UNICHAIN_SEPOLIA_ID, ROBINHOOD_TESTNET_ID] as const;

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
