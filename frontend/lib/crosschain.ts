import { type Address, type Hex, encodeAbiParameters, parseAbiParameters } from "viem";

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
    orbitalHook: "0xA4E98Ae00FdC5F62C53496a3B207632F4727aa88",
    poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
    swapRouter: "0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540",
    quoter: "0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472",
    intentSettler: "0xF430302b0F8f70806feE5117f45DB019ddaA3a99",
    hyperlaneMailbox: "0xDDcFEcF17586D08A5740B7D91735fcCE3dfe3eeD",
    hyperlaneDomain: 1301,
    deployBlock: 61913398n,
    assets: {
      USDT:  { symbol: "USDT", address: "0x287ca3Cc67FDE6c45717dD420146C937a93Ed237", decimals: 6 , index: 0 },
      DAI:   { symbol: "DAI", address: "0x7467369a0267505603c2D0dbfC369502508Cce75", decimals: 18, index: 1 },
      FRAX:  { symbol: "FRAX", address: "0x90aA5b5Db105DC190dD29e01b40e75549C39C3dF", decimals: 18, index: 2 },
      USDC:  { symbol: "USDC", address: "0xC09DefF23c7Ac44C1B4bfB11EF3AC7b0ec46328f", decimals: 6 , index: 3 },
    },
  },
  [ARBITRUM_SEPOLIA_ID]: {
    chainId: ARBITRUM_SEPOLIA_ID,
    name: "Arbitrum Sepolia",
    short: "Arbitrum",
    explorer: "https://sepolia.arbiscan.io",
    orbitalHook: "0x35C9D292768779E040e296AC20cf10b9D7A22a88",
    poolManager: "0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317",
    swapRouter: "0xcD8D7e10A7aA794C389d56A07d85d63E28780220",
    quoter: "0xF0DB224d356dFF5cFF51D3d7295391bB2c9265FE",
    intentSettler: "0xD8447BeAcf4a2768C4DCDb195b8D7122809a64e6",
    hyperlaneMailbox: "0x598facE78a4302f11E3de0bee1894Da0b2Cb71F8",
    hyperlaneDomain: 421614,
    deployBlock: 306305946n,
    assets: {
      USDT:  { symbol: "USDT", address: "0x11d99F5D06ec687704A563a425064f74F9929C97", decimals: 6 , index: 0 },
      USDC:  { symbol: "USDC", address: "0x2E02885397e0c9E77c432C252Decc60d1af2494C", decimals: 6 , index: 1 },
      FRAX:  { symbol: "FRAX", address: "0x32825BCb9E24E7CFC87c7f8956Ab833D4480A389", decimals: 18, index: 2 },
      DAI:   { symbol: "DAI", address: "0x3b6C33Be36B633Fe04f2A987f5BD627D55CA2734", decimals: 18, index: 3 },
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
    orbitalHook: "0x9474a0Eff4d0501c472b29987925E03F69bd6a88",
    poolManager: "0x9BEACCac4e0358Cc276703dcE7341B9B9fEfd5f7",
    swapRouter: "0xC30819b8ac12B5d12751b83cFfebD6F0bFa0b53E",
    quoter: "0x17684C1C522E7cCD9a38E1Ab5994BB294Bf1ef90",
    intentSettler: "0xE82C3dFe38bb607E5c409C2b9b361a05855d8715",
    hyperlaneMailbox: "0x2896bc4b03610816eee4758c7a2e87a2724E2Dcb",
    hyperlaneDomain: ARC_TESTNET_ID,
    mailboxRelays: false,
    crossChainNote: "Arc testnet has no Hyperlane deployment; same-chain swaps only",
    deployBlock: 60874911n,
    assets: {
      USDC:  { symbol: "USDC", address: "0xADdb0fcA532961745baed77B5346Aa32E4E10239", decimals: 6 , index: 2 },
      USDT:  { symbol: "USDT", address: "0xc4EeEDB4C5e194ec422AF850B9ff60F164c8aa72", decimals: 6 , index: 3 },
      DAI:   { symbol: "DAI", address: "0x44406ad771b05827F5fd95b002189e51EEbEDC91", decimals: 18, index: 0 },
      FRAX:  { symbol: "FRAX", address: "0x60Cb112631Ce92f9fe164878d690FAc1FD1C295d", decimals: 18, index: 1 },
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

/// One flat row per (chain, asset), for the chain-grouped token dropdown.
export interface TokenRow extends CrossChainAsset {
  chainId: number;
  chainShort: string;
  key: string;
}

export const ALL_TOKENS: TokenRow[] = CHAIN_IDS.flatMap((chainId) => {
  const dep = DEPLOYMENTS[chainId];
  return ROUTABLE_SYMBOLS.map((symbol) => {
    const a = dep.assets[symbol];
    return { ...a, chainId, chainShort: dep.short, key: `${chainId}:${symbol}` };
  });
});

export function tokenByKey(key: string): TokenRow | undefined {
  return ALL_TOKENS.find((t) => t.key === key);
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

/// Every deployed Orbital pool, one per chain.
export const ALL_POOLS = CHAIN_IDS.map((chainId) => ({
  chainId,
  address: DEPLOYMENTS[chainId].orbitalHook,
  name: DEPLOYMENTS[chainId].name,
  short: DEPLOYMENTS[chainId].short,
}));

/// Which chain a given Orbital pool address lives on.
///
/// Pool routes are keyed by address alone (`/app/pool/[address]`), so anything
/// resolving one back to a deployment has to go through here. Reading a pool
/// without its chain silently falls back to the primary chain, which means
/// querying a Unichain RPC for an Arc address and rendering an empty pool.
///
/// Hook addresses are CREATE2-mined per chain and do not collide, so the lookup
/// is unambiguous. Unknown addresses fall back to the primary chain.
export function chainIdForPool(address: string): number {
  const want = address.toLowerCase();
  return ALL_POOLS.find((p) => p.address.toLowerCase() === want)?.chainId ?? PRIMARY_CHAIN_ID;
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
