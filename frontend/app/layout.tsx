import type { Metadata } from "next";
import { Geist_Mono } from "next/font/google";
import localFont from "next/font/local";
import "./globals.css";
import "katex/dist/katex.min.css";
import LayoutGrid from "@/components/layout/LayoutGrid";
import { getThemeCssVariables } from "@/constants";
import { Web3ProviderShell } from "@/components/providers/Web3ProviderShell";
import { cn } from "@/lib/utils";

// KMR Apparat: the site's display + body sans, loaded locally from /public/TTF.
const apparat = localFont({
  variable: "--font-sans",
  display: "swap",
  src: [
    { path: "../public/TTF/KMR-Apparat-Light.ttf", weight: "300", style: "normal" },
    { path: "../public/TTF/KMR-Apparat-Book.ttf", weight: "350", style: "normal" },
    { path: "../public/TTF/KMR-Apparat-Regular.ttf", weight: "400", style: "normal" },
    { path: "../public/TTF/KMR-Apparat-Medium.ttf", weight: "500", style: "normal" },
    { path: "../public/TTF/KMR-Apparat-Bold.ttf", weight: "700", style: "normal" },
    { path: "../public/TTF/KMR-Apparat-Heavy.ttf", weight: "800", style: "normal" },
    { path: "../public/TTF/KMR-Apparat-Black.ttf", weight: "900", style: "normal" },
  ],
});

const geistMono = Geist_Mono({
  variable: "--font-mono",
  subsets: ["latin"],
});

const SITE_NAME = "Orbital";
const SITE_URL = "https://orbital-hook.vercel.app";
const TITLE = "Orbital - Multitoken stablecoin AMM on Unichain";
// Figures are the ones measured against the live Unichain Sepolia deployment:
// ~154x capital efficiency at N=5. Keep them in step with the README table
// rather than quoting the paper's headline number.
const DESCRIPTION =
  "One pool, N stablecoins. A Uniswap v4 hook that prices a whole basket of dollars on the Orbital sphere, with ~154x the capital efficiency of a full-range pool and automatic depeg isolation. Live on Unichain Sepolia.";

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: TITLE,
  description: DESCRIPTION,
  applicationName: SITE_NAME,
  keywords: [
    "Orbital", "Uniswap v4 hook", "stablecoin AMM", "concentrated liquidity",
    "Unichain", "DeFi", "N-asset AMM", "depeg isolation", "Paradigm Orbital",
  ],
  // `images` and `icons` are intentionally omitted: app/opengraph-image.tsx,
  // app/icon.svg and app/apple-icon.tsx are picked up by Next's file
  // conventions and wired in automatically, with hashed URLs and correct
  // dimensions. Declaring them here as well would emit duplicate tags.
  openGraph: {
    type: "website",
    siteName: SITE_NAME,
    title: TITLE,
    description: DESCRIPTION,
    url: SITE_URL,
  },
  twitter: {
    card: "summary_large_image",
    title: TITLE,
    description: DESCRIPTION,
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={cn("h-full", "antialiased", geistMono.variable, "font-sans", apparat.variable)}
      data-layout-grid="hidden"
      style={getThemeCssVariables("dark")}
    >
      <body
        className="min-h-full flex flex-col"
      >
        <Web3ProviderShell>
          {children}
        </Web3ProviderShell>
        {process.env.NODE_ENV === "development" && <LayoutGrid />}
      </body>
    </html>
  );
}
