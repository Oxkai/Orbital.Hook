"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { Moon, Palette, Sun } from "lucide-react";
import { color, getThemeCssVariables, typography, type ThemeName } from "@/constants";

const THEME_CYCLE: ThemeName[] = ["dark", "light", "purple"];

export function Nav() {
  const [theme, setTheme] = useState<ThemeName>(() => {
    if (typeof window === "undefined") return "dark";
    const saved = window.localStorage.getItem("theme");
    if (saved === "dark" || saved === "light" || saved === "purple") return saved;
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  });

  const applyTheme = useCallback((nextTheme: ThemeName) => {
    const vars = getThemeCssVariables(nextTheme);
    const root = document.documentElement;
    Object.entries(vars).forEach(([key, value]) => root.style.setProperty(key, value));
    root.dataset.theme = nextTheme;
  }, []);

  useEffect(() => { applyTheme(theme); }, [applyTheme, theme]);

  const toggleTheme = () => {
    const idx = THEME_CYCLE.indexOf(theme);
    const next = THEME_CYCLE[(idx + 1) % THEME_CYCLE.length];
    setTheme(next);
    applyTheme(next);
    window.localStorage.setItem("theme", next);
  };

  const themeIcon = theme === "dark"
    ? <Sun size={16} strokeWidth={1.8} aria-hidden="true" />
    : theme === "light"
      ? <Palette size={16} strokeWidth={1.8} aria-hidden="true" />
      : <Moon size={16} strokeWidth={1.8} aria-hidden="true" />;

  const themeTitle = theme === "dark"
    ? "Switch to light mode"
    : theme === "light"
      ? "Switch to purple mode"
      : "Switch to dark mode";

  return (
    <nav
      className="sticky top-0 z-40 grid h-14 grid-cols-12 items-center gap-5 px-6 border-b"
      style={{
        borderColor: color.borderSubtle,
        backgroundColor: color.bg,
      }}
    >
      <div className="col-span-4 grid items-center">
        <Link href="/" aria-label="Orbital home" className="inline-grid grid-flow-col auto-cols-max items-center gap-2">
          <span
            role="img"
            aria-label="Orbital"
            style={{
              display: "inline-block",
              width: 26,
              height: 26,
              backgroundColor: color.textPrimary,
              WebkitMaskImage: "url(/logo.svg)",
              maskImage: "url(/logo.svg)",
              WebkitMaskSize: "contain",
              maskSize: "contain",
              WebkitMaskRepeat: "no-repeat",
              maskRepeat: "no-repeat",
              WebkitMaskPosition: "center",
              maskPosition: "center",
            }}
          />
        </Link>
      </div>

      <div className="col-span-8 grid grid-flow-col auto-cols-max items-center justify-self-end gap-3 md:col-start-9 md:col-end-13">
        <button
          onClick={toggleTheme}
          className="grid place-items-center px-2 py-1.5 border transition-colors hover:opacity-90"
          style={{
            borderColor: color.border,
            color: color.textPrimary,
            aspectRatio: "1 / 1",
          }}
          aria-label="Cycle color theme"
          title={themeTitle}
        >
          {themeIcon}
        </button>

        <Link
          href="/app/swap"
          style={{
            border: `1px solid ${color.border}`,
            color: color.textPrimary,
            fontFamily: typography.p2.family,
            fontSize: typography.p2.size,
            letterSpacing: typography.p2.letterSpacing,
            background: "none",
            padding: "6px 16px",
            display: "flex",
            alignItems: "center",
            gap: "8px",
          }}
        >
          Launch App
          <span aria-hidden>→</span>
        </Link>
      </div>
    </nav>
  );
}
