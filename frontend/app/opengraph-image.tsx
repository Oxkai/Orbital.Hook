import { ImageResponse } from "next/og";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export const alt = "Orbital: N-asset stablecoin AMM on Unichain";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

// The brand mark, inlined as a data URI. Satori renders <img> from data URIs
// reliably, which is steadier than asking it to lay out the raw SVG paths.
const logo = `data:image/svg+xml;base64,${readFileSync(
  join(process.cwd(), "public", "logo.svg"),
).toString("base64")}`;

export default function OpengraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          background: "#0A0A0A",
          padding: 72,
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 28 }}>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={logo} width={92} height={92} alt="" />
          <div
            style={{
              fontSize: 84,
              fontWeight: 600,
              color: "#EDEDED",
              letterSpacing: "-0.04em",
            }}
          >
            ORBITAL
          </div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 18 }}>
          <div style={{ fontSize: 40, color: "#EDEDED", letterSpacing: "-0.02em", lineHeight: 1.2 }}>
            One pool, N stablecoins.
          </div>
          <div style={{ fontSize: 28, color: "#8A8A8A", letterSpacing: "-0.01em", lineHeight: 1.35 }}>
            A Uniswap v4 hook pricing a basket of dollars on the Orbital sphere.
            ~154x the capital efficiency of a full-range pool.
          </div>
        </div>

        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            fontSize: 22,
            color: "#8A8A8A",
            letterSpacing: "0.08em",
            borderTop: "1px solid #262626",
            paddingTop: 24,
          }}
        >
          <div>UNICHAIN SEPOLIA · CHAIN ID 1301</div>
          <div>121 TESTS PASSING</div>
        </div>
      </div>
    ),
    size,
  );
}
