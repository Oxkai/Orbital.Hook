import { color, typography } from "@/constants";

const TEAM = [
  { name: "Ajay Odedra", role: "FOUNDER / ENGINEER", initial: "A" },
  
];

const CHAPTERS = [
  { numeral: "I", label: "Introduction", muted: false },
  { numeral: "II", label: "Swap", muted: false },
  { numeral: "01", label: "Swap Widget", muted: true },
  { numeral: "02", label: "Quotes", muted: true },
  { numeral: "03", label: "Transaction Details", muted: true },
  { numeral: "III", label: "Pools", muted: false },
  { numeral: "01", label: "Pools List", muted: true },
  { numeral: "02", label: "Pool Details", muted: true },
  { numeral: "IV", label: "Positions", muted: false },
  { numeral: "01", label: "Positions Overview", muted: true },
  { numeral: "V", label: "Analytics", muted: false },
  { numeral: "01", label: "Overview", muted: true },
  { numeral: "02", label: "Curve View", muted: true },
  { numeral: "03", label: "Protocols", muted: true },
  { numeral: "04", label: "Advanced Charts", muted: true },
  { numeral: "VI", label: "System", muted: false },
];

const TOOLS = [
  { letter: "A", label: "Next.js + Wagmi" },
  { letter: "B", label: "Foundry" },
  { letter: "C", label: "Figma" },
];

const LINKS = [
  { letter: "A", label: "Paradigm Orbital paper", href: "https://www.paradigm.xyz/2025/06/orbital" },
  { letter: "B", label: "GitHub", href: "https://github.com/Oxkai/orbital-hook" },
];

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        fontFamily: "var(--font-mono)",
        fontSize: "10px",
        letterSpacing: "0.06em",
        color: color.textMuted,
        marginBottom: 24,
      }}
    >
      / {children}
    </div>
  );
}

export function Footer() {
  return (
    <footer
      className="mt-auto mx-6 pt-10 pb-8"
      style={{background: color.bg }}
    >
      <div className="grid grid-cols-12 gap-5 pb-16">
        <div className="col-span-12 md:col-span-4">
          <SectionLabel>PROJECT NAME</SectionLabel>
          <div
            style={{
              fontFamily: typography.h1.family,
              fontSize: "44px",
              lineHeight: "1",
              letterSpacing: "-0.03em",
              fontWeight: 400,
              color: color.textPrimary,
            }}
          >
            Orbital
          </div>
        </div>
        <div className="col-span-12 md:col-span-8">
          <SectionLabel>&nbsp;</SectionLabel>
          <div
            style={{
              fontFamily: typography.h1.family,
              fontSize: "30px",
              lineHeight: "1",
              letterSpacing: "-0.03em",
              fontWeight: 400,
              color: color.textMuted,
            }}
          >
            N-Asset Stablecoin AMM
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-12 gap-5 pb-10">

        <div className="md:col-span-2">
          <SectionLabel>TEAM</SectionLabel>
          <ul className="space-y-5">
            {TEAM.map((m) => (
              <li key={m.name} className="flex items-center gap-3">
                {m.name === "Ajay Odedra" ? (
                  <img
                    src="/profile.JPG"
                    alt={m.name}
                    className="w-9 h-9"
                    style={{
                      objectFit: "cover",
                    }}
                  />
                ) : (
                  <div
                    className="w-9 h-9 flex items-center justify-center"
                    style={{
                      background: color.surface2,
                      color: color.textPrimary,
                      fontFamily: typography.p1.family,
                      fontSize: "14px",
                      fontWeight: 500,
                    }}
                  >
                    {m.initial}
                  </div>
                )}
                <div>
                  <div
                    style={{
                      fontFamily: typography.p2.family,
                      fontSize: typography.p2.size,
                      color: color.textPrimary,
                      lineHeight: "16px",
                    }}
                  >
                    {m.name}
                  </div>
                  <div
                    style={{
                      fontFamily: "var(--font-mono)",
                      fontSize: "10px",
                      letterSpacing: "0.06em",
                      color: color.textMuted,
                      marginTop: 4,
                    }}
                  >
                    {m.role}
                  </div>
                </div>
              </li>
            ))}
          </ul>
        </div>

        <div className="md:col-span-2">
          <SectionLabel>CHAPTERS</SectionLabel>
          <ul>
            {CHAPTERS.map((c, i) => (
              <li
                key={`${c.numeral}-${c.label}-${i}`}
                className="grid"
                style={{
                  gridTemplateColumns: "40px 1fr",
                  paddingTop: 4,
                  paddingBottom: 4,
                }}
              >
                <span
                  style={{
                    fontFamily: typography.p2.family,
                    fontSize: typography.p2.size,
                    color: c.muted ? color.textMuted : color.textPrimary,
                  }}
                >
                  {c.numeral}
                </span>
                <span
                  style={{
                    fontFamily: typography.p2.family,
                    fontSize: typography.p2.size,
                    color: c.muted ? color.textMuted : color.textPrimary,
                  }}
                >
                  {c.label}
                </span>
              </li>
            ))}
          </ul>
        </div>

        <div className="md:col-span-4">
          <SectionLabel>COPYRIGHT</SectionLabel>
          <p
            style={{
              fontFamily: typography.p2.family,
              fontSize: typography.p2.size,
              lineHeight: "22px",
              color: color.textPrimary,
              marginBottom: 12,
            }}
          >
            Research implementation of the Paradigm Orbital paper.
            <br />
            Deployed on X Layer testnet — not production.
          </p>
          <p
            style={{
              fontFamily: typography.p2.family,
              fontSize: typography.p2.size,
              lineHeight: "22px",
              color: color.textMuted,
              marginBottom: 32,
            }}
          >
            Not audited. Not financial advice.
          </p>

          <SectionLabel>WWW</SectionLabel>
          <ul>
            {LINKS.map((l) => (
              <li
                key={l.label}
                className="grid"
                style={{
                  gridTemplateColumns: "40px 1fr",
                  paddingTop: 4,
                  paddingBottom: 4,
                }}
              >
                <span
                  style={{
                    fontFamily: typography.p2.family,
                    fontSize: typography.p2.size,
                    color: color.textMuted,
                  }}
                >
                  {l.letter}
                </span>
                <a
                  href={l.href}
                  style={{
                    fontFamily: typography.p2.family,
                    fontSize: typography.p2.size,
                    color: color.textPrimary,
                    textDecoration: "underline",
                  }}
                >
                  {l.label}
                </a>
              </li>
            ))}
          </ul>
        </div>

        <div className="md:col-span-3">
          <SectionLabel>TOOLS</SectionLabel>
          <ul>
            {TOOLS.map((t) => (
              <li
                key={t.label}
                className="grid"
                style={{
                  gridTemplateColumns: "40px 1fr",
                  paddingTop: 4,
                  paddingBottom: 4,
                }}
              >
                <span
                  style={{
                    fontFamily: typography.p2.family,
                    fontSize: typography.p2.size,
                    color: color.textMuted,
                  }}
                >
                  {t.letter}
                </span>
                <span
                  style={{
                    fontFamily: typography.p2.family,
                    fontSize: typography.p2.size,
                    color: color.textMuted,
                  }}
                >
                  {t.label}
                </span>
              </li>
            ))}
          </ul>
        </div>

        <div className="md:col-span-1">
          <div
            style={{
              fontFamily: "var(--font-mono)",
              fontSize: "10px",
              letterSpacing: "0.06em",
              color: color.textMuted,
              marginTop: 48,
            }}
          >
            © 2026 ORBITAL
          </div>
        </div>
      </div>

      <div
        className="flex flex-col md:flex-row items-start md:items-center justify-between gap-3 pt-6 border-t border-dashed"
        style={{
          borderColor: color.borderSubtle,
          fontFamily: "var(--font-mono)",
          fontSize: "10px",
          color: color.textMuted,
          letterSpacing: "0.04em",
        }}
      >
        <span>
          X LAYER TESTNET · CHAIN ID 1952 · NOT AUDITED · NOT FINANCIAL ADVICE
        </span>
        <span>© 2026 ORBITAL</span>
      </div>
    </footer>
  );
}
