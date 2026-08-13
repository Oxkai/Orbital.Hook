// IBM Plex Mono — used only by the ASCII canvas background (AsciiBackground).
// The canvas draws with a fixed-width font so the glyph grid stays aligned;
// `.style.fontFamily` gives the resolved family name for ctx.font.
import { IBM_Plex_Mono } from "next/font/google";

export const ibmPlexMono = IBM_Plex_Mono({
  subsets: ["latin"],
  weight: "400",
  display: "swap",
});
