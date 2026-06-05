import { color, colors, typography } from "@/constants";
import { SectionLabel } from "./SectionLabel";
import {
  HOOK_ADDRESS, POOL_MANAGER, SWAP_ROUTER, QUOTER_ADDRESS,
  TOKEN_ADDRESSES,
} from "@/lib/contracts";

type Contract = { name: string; address: string };

const GROUPS: { kind: string; label: string; items: Contract[] }[] = [
  {
    kind: "CORE",
    label: "Core protocol",
    items: [
      { name: "OrbitalHook (v4)",      address: HOOK_ADDRESS },
      { name: "PoolManager (v4)",      address: POOL_MANAGER },
    ],
  },
  {
    kind: "PERIPHERY",
    label: "Periphery",
    items: [
      { name: "SwapRouter", address: SWAP_ROUTER    },
      { name: "Quoter",     address: QUOTER_ADDRESS },
    ],
  },
  {
    kind: "TEST TOKENS",
    label: "Test tokens (18-dec)",
    items: [
      { name: "USDC", address: TOKEN_ADDRESSES.USDC },
      { name: "USDT", address: TOKEN_ADDRESSES.USDT },
      { name: "DAI",  address: TOKEN_ADDRESSES.DAI },
      { name: "FRAX", address: TOKEN_ADDRESSES.FRAX },
    ],
  },
];

const MONO = "var(--font-mono)";

function GroupHeader({ code, label, count }: { code: string; label: string; count: number }) {
  return (
    <div
      className="border-b border-dashed"
      style={{ borderColor: color.borderSubtle, backgroundColor: color.bg }}
    >
      {/* mobile */}
      <div className="md:hidden flex items-center justify-between px-4 py-2.5">
        <div className="flex items-center gap-2">
          <span style={{ fontFamily: MONO, fontSize: "9px", letterSpacing: "0.1em", color: color.textMuted }}>{code}</span>
          <span style={{ fontFamily: typography.h3.family, fontSize: "13px", letterSpacing: "-0.01em", color: color.textPrimary, fontWeight: 500 }}>{label}</span>
        </div>
        <span style={{ fontFamily: MONO, fontSize: "9px", letterSpacing: "0.08em", color: color.textMuted }}>{String(count).padStart(2, "0")} CTR</span>
      </div>
      {/* desktop */}
      <div className="hidden md:grid grid-cols-12 items-center gap-5 px-5 py-3">
        <span className="col-start-1 col-span-2" style={{ fontFamily: MONO, fontSize: "10px", letterSpacing: "0.08em", color: color.textMuted }}>{code}</span>
        <span className="col-start-3 col-span-3" style={{ fontFamily: typography.h3.family, fontSize: "14px", letterSpacing: "-0.01em", color: color.textPrimary, fontWeight: 500 }}>{label}</span>
        <span className="col-start-12 col-span-1 justify-self-end" style={{ fontFamily: MONO, fontSize: "10px", letterSpacing: "0.08em", color: color.textMuted }}>{String(count).padStart(2, "0")} CONTRACTS</span>
      </div>
    </div>
  );
}

function Row({ c, index }: { c: Contract; index: string }) {
  return (
    <a
      href={`https://sepolia.uniscan.xyz/address/${c.address}`}
      target="_blank"
      rel="noopener noreferrer"
      className="group grid grid-cols-12 items-center gap-5 px-5 py-4 border-b border-dashed transition-colors hover:bg-white/[0.03]"
      style={{ borderColor: color.borderSubtle, backgroundColor: color.bg }}
    >
      <span
        className="col-span-2 md:col-start-1 md:col-span-1"
        style={{
          fontFamily: MONO,
          fontSize: "10px",
          letterSpacing: "0.08em",
          color: color.textMuted,
        }}
      >
        {index}
      </span>

      <span
        className="col-span-10 md:col-start-3 md:col-span-2"
        style={{
          fontFamily: typography.p1.family,
          fontSize: "15px",
          letterSpacing: "-0.01em",
          color: color.textPrimary,
          fontWeight: 500,
        }}
      >
        {c.name}
      </span>

      <code
        className="hidden md:inline-block md:col-start-5 md:col-span-4"
        style={{
          fontFamily: MONO,
          fontSize: "12px",
          letterSpacing: "0.02em",
          color: color.textSecondary,
        }}
      >
        {c.address}
      </code>

      <div className="col-span-12 md:col-start-10 md:col-span-3 inline-grid grid-flow-col auto-cols-max items-center justify-self-end gap-3">
        <span
          className="inline-grid grid-flow-col auto-cols-max items-center gap-1.5"
          style={{
            fontFamily: MONO,
            fontSize: "10px",
            letterSpacing: "0.08em",
            color: colors.green.hex,
          }}
        >
          <span
            className="inline-block w-1.5 h-1.5 rounded-full"
            style={{ backgroundColor: colors.green.hex }}
          />
          VERIFIED
        </span>
        <span
          className="transition-transform group-hover:translate-x-0.5"
          style={{
            fontFamily: MONO,
            fontSize: "11px",
            color: color.textMuted,
          }}
        >
          ↗
        </span>
      </div>
    </a>
  );
}

export function Deployed() {
  return (
    <section className="mx-6 my-1">
      <SectionLabel border chapter="VI" section="05" path="ORBITAL / ON-CHAIN" />

      <div className="pt-10 pb-14">
        <div className="mb-10">
          <h2
            style={{
              fontFamily: typography.h1.family,
              fontSize: typography.h1.size,
              lineHeight: typography.h1.lineHeight,
              letterSpacing: typography.h1.letterSpacing,
              fontWeight: 400,
              color: color.textPrimary,
            }}
          >
            Deployed & verified
          </h2>
        </div>

        <div
          className="grid grid-cols-12 items-center gap-5 mb-6"
          style={{
            fontFamily: MONO,
            fontSize: "11px",
            letterSpacing: "0.06em",
            color: color.textMuted,
          }}
        >
          <span className="col-span-12 md:col-span-6">NETWORK / UNICHAIN SEPOLIA</span>
          <span className="col-span-12 md:col-span-6 md:justify-self-end">CHAIN ID / 1301</span>
        </div>

        <div
          className="border border-dashed"
          style={{ borderColor: color.border }}
        >
          {GROUPS.map((g, gi) => (
            <div key={g.kind} style={gi > 0 ? { borderTop: `1px dashed ${color.border}` } : undefined}>
              <GroupHeader code={`G.${String(gi + 1).padStart(2, "0")} / ${g.kind}`} label={g.label} count={g.items.length} />
              {g.items.map((c, itemIndex) => {
                const running = GROUPS.slice(0, gi).reduce((sum, group) => sum + group.items.length, 0) + itemIndex + 1;
                return <Row key={c.address} c={c} index={`C.${String(running).padStart(2, "0")}`} />;
              })}
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
