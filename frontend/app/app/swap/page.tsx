import { SwapWidget } from "@/components/app/swap/SwapWidget";
import { AsciiBackground } from "@/components/app/shared/AsciiBackground";

// Radial vignette so the scrolling ASCII field fades out around the widget and
// toward the edges, keeping the swap card readable.
const BG_MASK =
  "radial-gradient(120% 90% at 50% 45%, rgba(0,0,0,0.9) 0%, rgba(0,0,0,0.55) 38%, rgba(0,0,0,0.12) 70%, transparent 100%)";

export default function SwapPage() {
  return (
    <section className="relative flex-1 flex items-center justify-center py-16">
      {/* ASCII code-field background */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-y-0 left-1/2 -translate-x-1/2 w-screen overflow-hidden"
        style={{ maskImage: BG_MASK, WebkitMaskImage: BG_MASK }}
      >
        <AsciiBackground colorMode="dark" fontSize={9} asciiChars="@" showPattern isPlaying />
      </div>

      <div className="relative z-10 w-full max-w-md">
        <SwapWidget />
      </div>
    </section>
  );
}
