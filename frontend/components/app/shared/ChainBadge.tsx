import type { CSSProperties } from "react";
import { UNICHAIN_SEPOLIA_ID, ARBITRUM_SEPOLIA_ID, ROBINHOOD_TESTNET_ID } from "@/lib/crosschain";

/** Chain badge, drawn as ONE svg: rounded-square plate plus the network glyph,
 *  in a single 24x24 coordinate system.
 *
 *  Composing the badge from nested DOM elements (ring > disc > svg) meant its
 *  final position depended on where the parent landed in device pixels. Chromium
 *  snaps that to the pixel grid; WebKit antialiases it, so the glyph sat centred
 *  in Brave but drifted about half a pixel in Safari. Emitting one vector removes
 *  the composition entirely: the glyph is centred relative to its own plate by
 *  construction, at any size, in any engine.
 *
 *  Glyph paths are the "mono" variants from @token-icons/react, inlined so they
 *  can be transformed inside this viewBox rather than laid out as a sibling box.
 */

const GLYPH_SCALE = 0.7; // glyph ink occupies ~70% of the plate

interface ChainArt {
  plate: string;
  glyph: string[];
  /** Glyph fill. Defaults to white, which is right for every dark plate. */
  ink?: string;
  /** Applied inside the glyph group, for art whose native box is not 24x24.
   *  Lets a brand path be pasted verbatim rather than hand-renormalised. */
  transform?: string;
}

const CHAIN_ART: Record<number, ChainArt> = {
  [ARBITRUM_SEPOLIA_ID]: {
    // Arbitrum's navy is illegible on a dark UI; its light blue is the usable mark.
    plate: "#12AAFF",
    glyph: [
      "m13.551 13.523-1.013 2.65a.3.3 0 0 0 0 .234l1.737 4.566 2.019-1.111-2.419-6.34a.17.17 0 0 0-.064-.076.18.18 0 0 0-.196 0 .17.17 0 0 0-.064.077m2.026-4.466a.17.17 0 0 0-.064-.079.18.18 0 0 0-.197 0 .17.17 0 0 0-.063.079l-1.013 2.65a.3.3 0 0 0 0 .233l2.853 7.477 2.014-1.111-3.53-9.256z",
      "M12 3.116q.077 0 .144.04l7.813 4.36a.3.3 0 0 1 .107.1q.038.066.038.14v8.483a.26.26 0 0 1-.039.138.3.3 0 0 1-.106.1l-7.813 4.378a.3.3 0 0 1-.289 0l-7.813-4.37a.3.3 0 0 1-.107-.101.26.26 0 0 1-.038-.14V7.756a.28.28 0 0 1 .145-.24l7.813-4.36A.3.3 0 0 1 12 3.11zM12 2c-.272 0-.55.071-.793.205L3.533 6.444a1.55 1.55 0 0 0-.58.554 1.47 1.47 0 0 0-.213.758v8.483c0 .54.301 1.045.793 1.317l7.674 4.24a1.63 1.63 0 0 0 1.585 0l7.675-4.24a1.53 1.53 0 0 0 .582-.555c.14-.232.212-.495.21-.762V7.756a1.5 1.5 0 0 0-.793-1.312l-7.674-4.24A1.7 1.7 0 0 0 12 2",
      "m6.925 19.428.705-1.85 1.418 1.128-1.324 1.167z",
      "M11.36 7.001H9.407a.36.36 0 0 0-.2.065.34.34 0 0 0-.124.162L4.918 18.3l2.008 1.128 4.595-12.195a.17.17 0 0 0-.021-.158.19.19 0 0 0-.148-.075zm3.402 0h-1.944a.36.36 0 0 0-.198.062.34.34 0 0 0-.126.16l-4.77 12.634 2.015 1.128 5.185-13.756a.16.16 0 0 0 0-.119.17.17 0 0 0-.08-.09.2.2 0 0 0-.082-.019",
    ],
  },
  [UNICHAIN_SEPOLIA_ID]: {
    plate: "#FC0FA4",
    glyph: [
      // Unichain has no icon in the token-icons package; this is the brand mark,
      // renormalised from its native 116x115 box into this 24x24 viewBox.
      "M23.9 11.68C17.44 11.68 12.21 6.44 12.21 0h-.45v11.68H.07v.45c6.46 0 11.69 5.24 11.69 11.68h.45V12.13H23.9v-.45z",
    ],
  },
  [ROBINHOOD_TESTNET_ID]: {
    plate: "#CCFF00",
    ink: "#0A0A0A",
    glyph: [
      // Robinhood feather, from Simple Icons (CC0), native 24x24 box.
      "M2.84 24h.53c.096 0 .192-.048.224-.128C7.591 13.696 11.94 8.656 14.67 5.638c.112-.128.064-.225-.096-.225h-4.88a.55.55 0 0 0-.45.225L5.746 9.972c-.514.642-.642 1.236-.642 2.086v4.43c-1.14 3.194-1.862 5.361-2.392 7.32-.032.125.016.192.129.192M20.447.646c-.754-.802-4.157-.834-5.73-.224a3 3 0 0 0-.786.465 41 41 0 0 0-3.323 3.178c-.112.113-.064.225.097.225h5.409c.497 0 .786.289.786.786v6.1c0 .16.128.208.225.064l3.258-4.254c.53-.69.69-.898.835-1.861.192-1.413.08-3.58-.77-4.479m-6.982 16.18 2.231-3.676a.7.7 0 0 0 .064-.29V6.73c0-.16-.112-.225-.224-.097-3.355 3.74-5.971 7.672-8.395 12.407-.06.12.016.225.16.177l5.009-1.54c.565-.174.882-.402 1.155-.852",
    ],
  },
};

export function chainPlateColor(chainId: number): string {
  return CHAIN_ART[chainId]?.plate ?? "#454545";
}

/** One self-contained svg badge. `size` is the plate's edge length in px. */
export function ChainBadge({
  chainId,
  size = 12,
  style,
}: {
  chainId: number;
  size?: number;
  style?: CSSProperties;
}) {
  const art = CHAIN_ART[chainId];
  if (!art) return null;

  // Glyph ink spans 2..22 of its own 24 box. Scale about the centre so it stays
  // centred no matter what GLYPH_SCALE is set to.
  const offset = 12 * (1 - GLYPH_SCALE);

  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden
      style={{ display: "block", ...style }}
    >
      <rect width="24" height="24" rx="7.2" fill={art.plate} />
      <g transform={`translate(${offset} ${offset}) scale(${GLYPH_SCALE})`}>
        <g transform={art.transform}>
          {art.glyph.map((d, i) => (
            <path key={i} d={d} fill={art.ink ?? "#FFFFFF"} />
          ))}
        </g>
      </g>
    </svg>
  );
}
