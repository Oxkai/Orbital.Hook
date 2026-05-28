"use client";

import dynamic from "next/dynamic";
import type { ReactNode } from "react";

const Web3Provider = dynamic(
  () => import("./Web3Provider").then((m) => m.Web3Provider),
  { ssr: false },
);

export function Web3ProviderShell({ children }: { children: ReactNode }) {
  return <Web3Provider>{children}</Web3Provider>;
}
