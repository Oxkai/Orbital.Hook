import type { ReactNode } from "react";
import { AppNav } from "@/components/app/layout/AppNav";
import { AppFooter } from "@/components/app/layout/AppFooter";

export default function AppLayout({ children }: { children: ReactNode }) {
  return (
    <div className="min-h-screen flex flex-col">
      <AppNav />
      {/*
        Grid spec — desktop (≥md): max-w 1440px, 48px side margins, 24px gutters (12 cols)
                  — mobile  (<md): full width, 16px side margins, 16px gutters (4 cols)
      */}
      <main className="flex-1 flex flex-col w-full mx-auto px-4 md:px-12">
        {children}
      </main>
      <AppFooter />
    </div>
  );
}
