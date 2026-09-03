"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { useAccount, useConnect, useConnectors, useDisconnect, useChainId, useSwitchChain } from "wagmi";
import { unichainSepolia } from "@/lib/wagmi";
import { color, typography } from "@/constants";
import { List as Menu, X, MagnifyingGlass } from "@phosphor-icons/react";

const LINKS = [
  { href: "/app/swap",         label: "Swap"         },
  { href: "/app/pools",        label: "Pools"        },
  { href: "/app/positions",    label: "Positions"    },
  { href: "/app/transactions", label: "Transactions" },
] as const;

function short(addr: string) {
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}

// Deterministic wallet avatar: a 2-stop gradient seeded by the address.
function avatarGradient(addr: string) {
  const a = addr.toLowerCase().replace("0x", "").padEnd(12, "0");
  const h1 = parseInt(a.slice(0, 6), 16) % 360;
  const h2 = parseInt(a.slice(6, 12), 16) % 360;
  return `linear-gradient(135deg, hsl(${h1} 70% 56%), hsl(${h2} 72% 46%))`;
}

export function AppNav() {
  const pathname = usePathname();
  const { address, isConnected } = useAccount();
  const { connect, isPending }   = useConnect();
  const connectors               = useConnectors();
  const { disconnect }           = useDisconnect();
  const chainId                  = useChainId();
  const { switchChain }          = useSwitchChain();
  const [isMounted, setIsMounted] = useState(false);
  const [menuOpen, setMenuOpen]   = useState(false);

  const [search, setSearch] = useState("");

  useEffect(() => { setIsMounted(true); }, []);
  useEffect(() => { setMenuOpen(false); }, [pathname]);

  const showConnectedWallet = isMounted && isConnected && address;
  const wrongChain = isMounted && isConnected && chainId !== unichainSepolia.id;

  return (
    <>
      <nav
        className="sticky top-0 z-40 flex items-center h-14 px-4 md:px-12 gap-8"
        style={{
          backgroundColor: color.bg,
        }}
      >
        <Link href="/" aria-label="Orbital home" className="flex items-center shrink-0">
          <span
            role="img"
            aria-label="Orbital"
            style={{
              display: "inline-block",
              width: 26,
              height: 26,
              backgroundColor: color.textPrimary,
              WebkitMaskImage: "url(/logo.svg)",
              maskImage: "url(/logo.svg)",
              WebkitMaskSize: "contain",
              maskSize: "contain",
              WebkitMaskRepeat: "no-repeat",
              maskRepeat: "no-repeat",
              WebkitMaskPosition: "center",
              maskPosition: "center",
            }}
          />
        </Link>

        <div className="hidden sm:flex items-center gap-6 shrink-0">
          {LINKS.map(({ href, label }) => {
            const active =
              pathname === href ||
              (href !== "/app/swap" && pathname.startsWith(href));
            return (
              <Link
                key={href}
                href={href}
                style={{
                  fontFamily: typography.p2.family,
                  fontSize: typography.p2.size,
                  letterSpacing: "-0.01em",
                  color: active ? color.textPrimary : color.textMuted,
                }}
              >
                {label}
              </Link>
            );
          })}
        </div>

        {/* push everything below to the right end */}
        <div className="flex-1" />

        <div className="flex items-center gap-2 shrink-0">
          {/* Search */}
          <label
            className="hidden md:flex items-center gap-2 px-3 h-9 w-64"
            style={{ backgroundColor: color.surface1 }}
          >
            <MagnifyingGlass size={13} color={color.textMuted} weight="regular" />
            <input
              type="text"
              value={search}
              onChange={e => setSearch(e.target.value)}
              placeholder="Search pools, tokens…"
              className="flex-1 bg-transparent outline-none min-w-0"
              style={{
                fontFamily: typography.p3.family,
                fontSize: typography.p3.size,
                letterSpacing: typography.p3.letterSpacing,
                color: color.textPrimary,
              }}
            />
            <span
              style={{
                fontFamily: typography.caption.family,
                fontSize: "10px",
                fontWeight: 500,
                letterSpacing: "0.04em",
                color: color.textMuted,
                backgroundColor: color.surface2,
                padding: "2px 6px",
                lineHeight: 1.2,
                borderRadius: 2,
              }}
            >
              ⌘K
            </span>
          </label>

          {wrongChain && (
            <button
              onClick={() => switchChain({ chainId: unichainSepolia.id })}
              className="hidden sm:flex items-center h-9 px-3 hover:opacity-90 transition-opacity"
              style={{
                color: color.error,
                backgroundColor: `${color.error}1f`,
                fontFamily: typography.caption.family,
                fontSize: "11px",
                fontWeight: 500,
                letterSpacing: "0.02em",
                cursor: "pointer",
              }}
            >
              Wrong network, switch
            </button>
          )}
          {showConnectedWallet ? (
            <button
              onClick={() => disconnect()}
              className="flex items-center gap-2 h-9 px-3 hover:bg-(--color-surface-3) transition-colors"
              style={{
                color: color.textPrimary,
                backgroundColor: color.surface2,
                fontFamily: "var(--font-mono)",
                fontSize: "11px",
                letterSpacing: "0.02em",
                cursor: "pointer",
                fontVariantNumeric: "tabular-nums",
              }}
            >
              <span
                aria-hidden
                style={{ width: 16, height: 16, borderRadius: "50%", background: avatarGradient(address), flexShrink: 0 }}
              />
              {short(address)}
            </button>
          ) : (
            <button
              onClick={() => {
                const connector =
                  connectors.find(c => c.type === "injected") ?? connectors[0];
                if (connector) connect({ connector });
              }}
              disabled={isPending}
              className="flex items-center h-9 px-4"
              style={{
                backgroundColor: color.textPrimary,
                color: color.bg,
                opacity: isPending ? 0.6 : 1,
                fontFamily: typography.p2.family,
                fontSize: typography.p2.size,
                letterSpacing: "-0.01em",
                cursor: isPending ? "not-allowed" : "pointer",
                whiteSpace: "nowrap",
              }}
            >
              {isPending ? "Connecting…" : "Connect"}
            </button>
          )}

          <button
            className="sm:hidden flex items-center justify-center w-9 h-9"
            onClick={() => setMenuOpen(v => !v)}
            aria-label="Toggle menu"
          >
            {menuOpen
              ? <X size={16} color={color.textPrimary} weight="regular" />
              : <Menu size={16} color={color.textPrimary} weight="regular" />}
          </button>
        </div>
      </nav>

      {menuOpen && (
        <div
          className="sm:hidden fixed top-14 left-0 right-0 z-50 px-4 md:px-12 py-4"
          style={{ backgroundColor: color.bg }}
        >
          {wrongChain && (
            <button
              onClick={() => { switchChain({ chainId: unichainSepolia.id }); setMenuOpen(false); }}
              className="w-full text-left py-3"
              style={{
                color: color.error,
                fontFamily: typography.p2.family,
                fontSize: typography.p2.size,
                cursor: "pointer",
              }}
            >
              ⚠ Wrong network, tap to switch
            </button>
          )}
          {LINKS.map(({ href, label }) => {
            const active =
              pathname === href ||
              (href !== "/app/swap" && pathname.startsWith(href));
            return (
              <Link
                key={href}
                href={href}
                className="flex items-center py-3"
                style={{
                  fontFamily: typography.p2.family,
                  fontSize: "16px",
                  letterSpacing: "-0.01em",
                  color: active ? color.textPrimary : color.textMuted,
                }}
              >
                {label}
              </Link>
            );
          })}
        </div>
      )}
    </>
  );
}
