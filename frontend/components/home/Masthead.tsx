import { color, typography } from "@/constants";
import { Emphasized } from "./Emphasized";
import { SectionLabel } from "./SectionLabel";

const INDEX = [
  ["01", "Principles"],
  ["02", "Mechanics"],
  ["03", "Architecture"],
  ["04", "Versus"],
  ["05", "Deployed"],
  ["06", "References"],
] as const;

export function Masthead() {
  return (
    <>
      {/* I. Giant title */}
      <section
        className="mx-6"
      >
        <SectionLabel  chapter="I" section="00" path="Orbital" />
        <div className="relative pt-16 pb-10 md:pt-24 md:pb-16">
          <div className="grid grid-cols-12 gap-5">
            <h1
              aria-label="I. Orbital"
              className="grid w-full col-span-12"
              style={{
                fontFamily: typography.h1.family,
                fontWeight: 400,
                letterSpacing: "-0.05em",
                lineHeight: "0.85",
              }}
            >
              
              <span
                className="justify-self-end  text-right mr-2"
                style={{
                  fontSize: "clamp(72px, 13vw, 200px)",
                  color: color.textPrimary,
                  fontWeight: 500,
                  letterSpacing: "-0.055em",
                }}
              >
                ORBITAL
              </span>
            </h1>
          </div>
        </div>
      </section>

      {/* I. Intro with emphasized copy */}
      <section
        className=" mx-6"
        style={{ borderColor: color.border }}
      >
        <SectionLabel border chapter="I" section="00" path="ORBITAL / INTRODUCTION" />
        <div className="grid grid-cols-12 gap-5 pt-14 pb-16">
          <div className="col-span-12">
          <Emphasized
            size="clamp(30px, 4.2vw, 56px)"
            lineHeight="1.1"
            segments={[
              { t: "One pool", v: "on" },
              { t: " for ", v: "off" },
              { t: "any number", v: "on" },
              { t: " of ", v: "off" },
              { t: "stablecoins", v: "on" },
              { t: ".", v: "green" },
              " ",
              { t: "Concentrated liquidity", v: "off" },
              { t: " that stays ", v: "on" },
              { t: "pegged,", v: "on" },
              { t: " and ", v: "off" },
              { t: "isolates", v: "on" },
              { t: " a single asset when it ", v: "off" },
              { t: "breaks peg", v: "on" },
              { t: ".", v: "green" },
              " ",
              { t: "Derived from the ", v: "off" },
              { t: "Paradigm Orbital paper", v: "u" },
              { t: ", built as a ", v: "off" },
              { t: "Uniswap v4 hook", v: "on" },
              { t: " and live on ", v: "off" },
              { t: "X Layer", v: "on" },
              { t: ".", v: "green" },
            ]}
          />
          </div>

          {/* CTA row */}
          <div className="col-span-12 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-[auto_auto] gap-5 mt-12 w-fit">
            <a
              href="/app/swap"
              className="inline-grid grid-flow-col auto-cols-max items-center gap-3 px-6 py-3 transition-colors hover:opacity-90"
              style={{
                backgroundColor: color.textPrimary,
                color: color.bg,
                fontFamily: typography.p1.family,
                fontSize: typography.p1.size,
                fontWeight: 500,
                letterSpacing: typography.p1.letterSpacing,
              }}
            >
              Launch App
              <span aria-hidden>→</span>
            </a>
            <a
              href="https://www.paradigm.xyz/2025/06/orbital"
              target="_blank"
              rel="noopener noreferrer"
              className="inline-grid grid-flow-col auto-cols-max items-center gap-3 px-6 py-3 border transition-colors hover:bg-white/4"
              style={{
                borderColor: color.border,
                color: color.textPrimary,
                fontFamily: typography.p1.family,
                fontSize: typography.p1.size,
                letterSpacing: typography.p1.letterSpacing,
              }}
            >
              Read the paper
              <span aria-hidden>↗</span>
            </a>
            
          </div>

          {/* /INDEX */}
          <div
            className="col-span-12 grid grid-cols-12 gap-5 mt-24 pt-2 border-t "
            style={{ borderColor: color.borderSubtle }}
          >
            <div
              className="col-span-12 md:col-span-2 mb-2 md:mb-0 md:pt-2"
              style={{
                fontFamily: "var(--font-mono)",
                fontSize: "10px",
                letterSpacing: "0.1em",
                color: color.textMuted,
                textTransform: "uppercase",
              }}
            >
              / INDEX
            </div>
            <ul className="col-span-12 md:col-span-10 grid grid-cols-2 md:grid-cols-3 gap-5 md:gap-x-10">
              {INDEX.map(([n, label]) => (
                <li
                  key={n}
                  className="grid grid-cols-[24px_1fr] items-baseline gap-5 py-2 border-b border-dashed"
                  style={{ borderColor: color.borderSubtle }}
                >
                  <span
                    style={{
                      fontFamily: "var(--font-mono)",
                      fontSize: "13px",
                      color: color.textMuted,
                      letterSpacing: "0.04em",
                      minWidth: 24,
                    }}
                  >
                    {n}
                  </span>
                  <span
                    style={{
                      fontFamily: typography.p1.family,
                      fontSize: "17px",
                      color: color.textPrimary,
                      letterSpacing: "-0.02em",
                    }}
                  >
                    {label}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        </div>
      </section>
    </>
  );
}
