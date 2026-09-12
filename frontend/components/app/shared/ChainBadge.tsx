import type { CSSProperties } from "react";
import { UNICHAIN_SEPOLIA_ID, ARBITRUM_SEPOLIA_ID, ARC_TESTNET_ID } from "@/lib/crosschain";

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
  [ARC_TESTNET_ID]: {
    // Circle's Arc: the arch symbol from the official wordmark, taken verbatim
    // as the first subpath of arc.io's `logo-ondark.svg`.
    //
    // Arc's mark is monochrome (the source draws it in flat white for dark
    // backgrounds), so the plate carries the contrast rather than a brand hue.
    // White plate with black ink for the same reason Arbitrum uses its light
    // blue above: the badge is 11px on a near-black UI, and a dark plate would
    // dissolve into the surface it sits on.
    //
    // Native box is 47.7168 x 50, so it is fitted rather than renormalised:
    // scale 20/50 = 0.4 gives a 19.087 x 20 ink area, then centre it in the
    // 24 box (x (24-19.087)/2 = 2.4566, y (24-20)/2 = 2).
    plate: "#FFFFFF",
    ink: "#000000",
    transform: "translate(2.4566 2) scale(0.4)",
    glyph: [
      "M23.8574 0C31.0115 0 37.371 6.19775 41.7656 17.4521C44.0513 23.3056 45.7332 30.2603 46.7295 37.8262C46.8186 38.5019 46.8939 39.1888 46.9717 39.874C46.9969 39.9162 47.0119 39.9553 47.0068 39.9873C47.0068 39.9873 47.5924 43.6447 47.7168 50H47.6514C46.7829 49.2873 36.54 41.2389 19.5615 43.5693C19.8177 40.6962 20.1699 37.9004 20.625 35.2207C20.6482 35.0838 20.6755 34.9514 20.6992 34.8154C27.3585 34.6146 33.1876 35.3879 37.6572 36.4014C37.6406 36.2954 37.6263 36.1865 37.6094 36.0811C36.6906 30.3599 35.3355 25.1217 33.5879 20.6455C30.7304 13.3264 27.001 8.77832 23.8574 8.77832C20.7141 8.77863 16.9853 13.3266 14.1279 20.6455C13.4363 22.4157 12.8068 24.3036 12.2422 26.2949C11.4483 29.0854 10.7807 32.0773 10.248 35.2207C9.45968 39.8629 8.96755 44.8418 8.78613 50H0C0.405408 37.7593 2.48104 26.3352 5.9502 17.4521C10.3437 6.19798 16.7036 0.000184295 23.8574 0Z",
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
