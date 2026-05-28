"use client";

export default function LayoutGrid() {
  return (
    <div id="layout-grid-overlay" className="pointer-events-none fixed inset-0 z-[9999]">
      <div className="grid h-full w-full grid-cols-12 gap-5 px-6">
        {Array.from({ length: 12 }).map((_, i) => (
          <div key={i} className="bg-blue-500/10" />
        ))}
      </div>
    </div>
  );
}