import { color } from "@/constants";

export function SectionLabel({
  chapter,
  section,
  path,
  border = false,
}: {
  chapter: string;
  section: string;
  path: string;
  border?: boolean;
}) {
  return (
    <div
      className={`grid grid-cols-12 items-center py-2 gap-5${border ? " border-t" : ""}`}
      style={{
        ...(border ? { borderColor: color.border } : {}),
        fontFamily: "var(--font-mono)",
        fontSize: "11px",
        letterSpacing: "0.08em",
        color: color.textMuted,
        textTransform: "uppercase",
      }}
    >
      <span className="col-span-12 md:col-span-2">
        {"//"} {chapter} / {section}
      </span>
      <span className="col-span-12 md:col-span-2">
        {"//"} {path}
      </span>
    </div>
  );
}
