import { color, typography } from "@/constants";
import type { ReactNode } from "react";

interface PageHeaderProps {
  title: string;
  meta?: string;
  actions?: ReactNode;
}

export function PageHeader({ title, meta, actions }: PageHeaderProps) {
  return (
    <div className="flex flex-col sm:flex-row sm:items-end justify-between gap-4 pt-12 pb-10">
      <div className="flex flex-col gap-3">
        <span
          style={{
            fontFamily: "var(--font-mono)",
            fontSize: "11px",
            letterSpacing: "0.1em",
            color: color.textMuted,
            textTransform: "uppercase",
          }}
        >
          {meta ?? " "}
        </span>
        <h1
          style={{
            fontFamily: typography.h1.family,
            fontSize: "clamp(40px, 6vw, 72px)",
            fontWeight: 500,
            letterSpacing: "-0.04em",
            lineHeight: "0.95",
            color: color.textPrimary,
          }}
        >
          {title}
        </h1>
      </div>
      {actions && <div className="flex items-center gap-3 shrink-0">{actions}</div>}
    </div>
  );
}
