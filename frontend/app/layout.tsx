import type { Metadata } from "next";
import { Roboto, Geist_Mono, Geist } from "next/font/google";
import "./globals.css";
import "katex/dist/katex.min.css";
import LayoutGrid from "@/components/layout/LayoutGrid";
import { getThemeCssVariables } from "@/constants";
import { Web3ProviderShell } from "@/components/providers/Web3ProviderShell";
import { cn } from "@/lib/utils";

const geist = Geist({subsets:['latin'],variable:'--font-sans'});

const geistMono = Geist_Mono({
  variable: "--font-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Orbital — N-asset stablecoin AMM",
  description:
    "One pool. N stablecoins. 154× the capital efficiency of a flat sphere. Concentrated liquidity with automatic depeg isolation. Derived from the Paradigm Orbital paper.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={cn("h-full", "antialiased", geistMono.variable, "font-sans", geist.variable)}
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
