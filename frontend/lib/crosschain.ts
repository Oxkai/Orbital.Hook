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
  /// Block the hook was deployed at. Event scanners start here, not genesis.
  deployBlock: bigint;
  assets: Record<string, CrossChainAsset>;
}

export const UNICHAIN_SEPOLIA_ID = 1301;
export const BASE_SEPOLIA_ID = 84532;
export const ARBITRUM_SEPOLIA_ID = 421614;

export const DEPLOYMENTS: Record<number, CrossChainDeployment> = {
  // Generated from orbitalHook/deployments.json - keep the two in step.
  [UNICHAIN_SEPOLIA_ID]: {
    chainId: UNICHAIN_SEPOLIA_ID,
    name: "Unichain Sepolia",
    short: "Unichain",
    explorer: "https://sepolia.uniscan.xyz",
    orbitalHook: "0xaf7450d89B674d11284Fa82693eF15612169aa88",
    poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
    swapRouter: "0xb974DE781ec4bCf09d91Db13A3aF74d14FfE7540",
    quoter: "0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472",
    intentSettler: "0x14a8d875F6d4468c83C1D3028e179DdA9B9364DC",
    hyperlaneMailbox: "0xDDcFEcF17586D08A5740B7D91735fcCE3dfe3eeD",
    hyperlaneDomain: 1301,
    deployBlock: 61607259n,
    assets: {
      USDC:  { symbol: "USDC", address: "0x4df69b21843F42a43a3CBe1C2712278404a0f394", decimals: 6 , index: 0 },
      USDT:  { symbol: "USDT", address: "0x9924e9D691642F6B8bAA0382aC9EFFDb43002B95", decimals: 6 , index: 2 },
      DAI:   { symbol: "DAI", address: "0xF2C5b0555F1ba2184Db8563188c00a1467251739", decimals: 18, index: 3 },
      FRAX:  { symbol: "FRAX", address: "0x5F1e60520d796bdAE086b8aA2D88fb039f76CaD7", decimals: 18, index: 1 },
    },
  },
  [BASE_SEPOLIA_ID]: {
    chainId: BASE_SEPOLIA_ID,
    name: "Base Sepolia",
    short: "Base",
    explorer: "https://sepolia.basescan.org",
    orbitalHook: "0xf3aE821a7e0b6effD96EaaeBC09C53905aF12a88",
    poolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    swapRouter: "0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9",
    quoter: "0x9eA8539097528BA1CdC4CcEfa99DBD0310D3Bde2",
    intentSettler: "0xF72F5537d6914e1D1379D68B62Eb6f8549792992",
    hyperlaneMailbox: "0x6966b0E55883d49BFB24539356a2f8A673E02039",
    hyperlaneDomain: 84532,
    deployBlock: 46345765n,
    assets: {
      USDC:  { symbol: "USDC", address: "0x8C3E9929b523D658A92cb61286ba00A1A15635F7", decimals: 6 , index: 3 },
      USDT:  { symbol: "USDT", address: "0x7EB345af1f38Ee7a2C7E5bE984596e33014bDc81", decimals: 6 , index: 2 },
      DAI:   { symbol: "DAI", address: "0x1A478E8Ad09D650f17df0288254bd24220Ff6b57", decimals: 18, index: 0 },
      FRAX:  { symbol: "FRAX", address: "0x5BD60b5a16be951f9185576da0DdC51993B28db8", decimals: 18, index: 1 },
    },
  },
  [ARBITRUM_SEPOLIA_ID]: {
    chainId: ARBITRUM_SEPOLIA_ID,
    name: "Arbitrum Sepolia",
    short: "Arbitrum",
    explorer: "https://sepolia.arbiscan.io",
    orbitalHook: "0xB5bcb2F158461E3d69bf38Be4af69954FB67aA88",
    poolManager: "0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317",
    swapRouter: "0xcD8D7e10A7aA794C389d56A07d85d63E28780220",
    quoter: "0xF0DB224d356dFF5cFF51D3d7295391bB2c9265FE",
    intentSettler: "0x46A0e3D32ebCeC9B65984469520F478C9e0C97D4",
    hyperlaneMailbox: "0x598facE78a4302f11E3de0bee1894Da0b2Cb71F8",
    hyperlaneDomain: 421614,
    deployBlock: 305071149n,
    assets: {
      USDC:  { symbol: "USDC", address: "0x7A3558170Ae4a15523D1E2848aA41Aed1C7fa292", decimals: 6 , index: 2 },
      USDT:  { symbol: "USDT", address: "0x9Aeb218E9f3E4f2366F4A09a9d33823A8856D192", decimals: 6 , index: 3 },
      DAI:   { symbol: "DAI", address: "0x31f54F08c8DF97d934b6804faB69c98C09898fB9", decimals: 18, index: 0 },
      FRAX:  { symbol: "FRAX", address: "0x4ac9f4b60baF290F3694C88c7e3EBc92e3dd923F", decimals: 18, index: 1 },
    },
  },
};

/// The chain the single-chain pages (pools, positions, transactions) default to,
/// and the swap widget's opening pair. Unichain Sepolia is the canonical home of
/// this hook; the other two carry the same deployment for cross-chain routes.
/// One constant to move if that changes.
export const PRIMARY_CHAIN_ID = UNICHAIN_SEPOLIA_ID;

/// Display order in the token dropdown, primary chain first.
export const CHAIN_IDS = [UNICHAIN_SEPOLIA_ID, BASE_SEPOLIA_ID, ARBITRUM_SEPOLIA_ID] as const;

/// Every chain carries the same four stables, so a same-chain route always exists.
export const ROUTABLE_SYMBOLS = ["USDC", "USDT", "DAI", "FRAX"] as const;

export function deploymentFor(chainId: number): CrossChainDeployment | undefined {
  return DEPLOYMENTS[chainId];
}

export function assetOn(chainId: number, symbol: string): CrossChainAsset | undefined {
  return DEPLOYMENTS[chainId]?.assets[symbol];
}

/// A chain can originate or receive a cross-chain order only if it has a settler.
export function supportsCrossChain(chainId: number): boolean {
  return !!DEPLOYMENTS[chainId]?.intentSettler;
}

/// Why a given (origin, destination) pair cannot be routed, or undefined if it can.
export function routeBlockedReason(originChainId: number, destChainId: number): string | undefined {
  if (originChainId === destChainId) return undefined;
  const a = DEPLOYMENTS[originChainId];
  const b = DEPLOYMENTS[destChainId];
  if (!a || !b) return "Unknown chain";
  if (!a.intentSettler) return `No settler on ${a.short}`;
  if (!b.intentSettler) return `No settler on ${b.short}`;
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
