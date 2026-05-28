"use client";

import { useEffect, useRef } from "react";

const DENSITY = 1 / 14000;
const DOT_R = 1;
const GRID = 10;
const NEIGHBORS = 3;
const WANDER = 0.25;
const SCATTER_RATIO = 0.45;

function weight(nx: number, ny: number) {
  const v = Math.pow(Math.max(0, ny - 0.15) / 0.85, 1.8);
  const h = Math.pow(Math.abs(nx - 0.5) * 2, 2.2);
  return v * h;
}

function hash(i: number, j: number, x: number, y: number, salt: number) {
  let h = i * 374761393 + j * 668265263 + x * 1442695040 + y * 2654435761 + (salt | 0) * 40503;
  h = (h ^ (h >>> 13)) * 1274126177;
  h = h ^ (h >>> 16);
  return ((h >>> 0) % 10000) / 10000;
}

function readDotColor(): string {
  if (typeof window === "undefined") return "rgba(180,180,180,0.7)";
  const styles = getComputedStyle(document.documentElement);
  const text = styles.getPropertyValue("--color-text-primary").trim() || "#ffffff";
  // Normalize to rgba with alpha 0.55. If hex, parse manually.
  const hex = text.replace("#", "");
  if (/^[0-9a-fA-F]{6}$/.test(hex)) {
    const r = parseInt(hex.slice(0, 2), 16);
    const g = parseInt(hex.slice(2, 4), 16);
    const b = parseInt(hex.slice(4, 6), 16);
    return `rgba(${r},${g},${b},0.55)`;
  }
  return text;
}

type Pt = { x: number; y: number; gx: number; gy: number };

export function DotNetworkBackground() {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    function render() {
      if (!canvas || !ctx) return;
      const dpr = window.devicePixelRatio || 1;
      const w = (canvas.width = window.innerWidth * dpr);
      const h = (canvas.height = window.innerHeight * dpr);
      canvas.style.width = window.innerWidth + "px";
      canvas.style.height = window.innerHeight + "px";

      ctx.clearRect(0, 0, w, h);

      const g = GRID * dpr;
      const margin = 20 * dpr;
      const cols = Math.floor((w - 2 * margin) / g);
      const rows = Math.floor((h - 2 * margin) / g);
      if (cols <= 0 || rows <= 0) return;

      const cssArea = window.innerWidth * window.innerHeight;
      const targetCount = Math.max(8, Math.round(cssArea * DENSITY));
      const MIN_SPACING = Math.max(6, Math.round(Math.sqrt((cols * rows) / targetCount) * 0.65));

      const pts: Pt[] = [];
      let attempts = 0;
      while (pts.length < targetCount && attempts < 20000) {
        attempts++;
        const cx = Math.floor(Math.random() * cols);
        const cy = Math.floor(Math.random() * rows);
        const nx = cx / cols;
        const ny = cy / rows;
        const wv = weight(nx, ny);
        if (Math.random() > wv) continue;
        let ok = true;
        for (const p of pts) {
          const d = Math.abs(p.gx - cx) + Math.abs(p.gy - cy);
          if (d < MIN_SPACING) { ok = false; break; }
        }
        if (!ok) continue;
        pts.push({ x: margin + cx * g, y: margin + cy * g, gx: cx, gy: cy });
      }

      const edges = new Set<string>();
      const addEdge = (i: number, j: number) => {
        const a = Math.min(i, j);
        const b = Math.max(i, j);
        edges.add(a + "-" + b);
      };
      const dist = (i: number, j: number) =>
        Math.abs(pts[i].gx - pts[j].gx) + Math.abs(pts[i].gy - pts[j].gy);
      const isDead = (i: number, j: number) => {
        const mx = (pts[i].gx + pts[j].gx) / 2 / cols;
        const my = (pts[i].gy + pts[j].gy) / 2 / rows;
        return weight(mx, my) < 0.05;
      };

      for (let i = 0; i < pts.length; i++) {
        const dists: { j: number; d: number }[] = [];
        for (let j = 0; j < pts.length; j++) {
          if (i === j) continue;
          dists.push({ j, d: dist(i, j) });
        }
        dists.sort((a, b) => a.d - b.d);
        let added = 0;
        for (let k = 0; k < dists.length && added < NEIGHBORS; k++) {
          if (isDead(i, dists[k].j)) continue;
          addEdge(i, dists[k].j);
          added++;
        }
      }

      ctx.fillStyle = readDotColor();
      const tr = DOT_R * dpr;
      const painted = new Set<string>();
      const paintCell = (cx: number, cy: number) => {
        const key = cx + "|" + cy;
        if (painted.has(key)) return;
        painted.add(key);
        const px = margin + cx * g;
        const py = margin + cy * g;
        ctx.fillRect(px - tr, py - tr, tr * 2, tr * 2);
      };

      for (const key of edges) {
        const [i, j] = key.split("-").map(Number);
        const a = pts[i];
        const b = pts[j];
        let cx = a.gx;
        let cy = a.gy;
        const tx = b.gx;
        const ty = b.gy;
        let safety = (Math.abs(tx - a.gx) + Math.abs(ty - a.gy)) * 4 + 50;

        while ((cx !== tx || cy !== ty) && safety-- > 0) {
          paintCell(cx, cy);
          const dx = tx - cx;
          const dy = ty - cy;
          const adx = Math.abs(dx);
          const ady = Math.abs(dy);
          const r = hash(i, j, cx, cy, 0);

          let stepX = 0;
          let stepY = 0;
          if (r < WANDER && adx + ady > 1) {
            const sideways = hash(i, j, cx, cy, 1) < 0.5;
            if (sideways) stepX = hash(i, j, cx, cy, 2) < 0.5 ? -1 : 1;
            else stepY = hash(i, j, cx, cy, 3) < 0.5 ? -1 : 1;
          } else {
            const goH = adx > 0 && ady === 0
              ? true
              : ady > 0 && adx === 0
              ? false
              : hash(i, j, cx, cy, 4) < adx / (adx + ady);
            if (goH) stepX = Math.sign(dx);
            else stepY = Math.sign(dy);
          }
          const ncx = cx + stepX;
          const ncy = cy + stepY;
          if (ncx < 0 || ncx >= cols || ncy < 0 || ncy >= rows) {
            if (adx >= ady && dx !== 0) cx += Math.sign(dx);
            else if (dy !== 0) cy += Math.sign(dy);
          } else {
            cx = ncx;
            cy = ncy;
          }
        }
        paintCell(cx, cy);
      }

      const scatterCount = Math.round(painted.size * SCATTER_RATIO);
      let placed = 0;
      let scTries = 0;
      while (placed < scatterCount && scTries < scatterCount * 20) {
        scTries++;
        const cx = Math.floor(Math.random() * cols);
        const cy = Math.floor(Math.random() * rows);
        const key = cx + "|" + cy;
        if (painted.has(key)) continue;
        const nx = cx / cols;
        const ny = cy / rows;
        if (Math.random() > weight(nx, ny)) continue;
        let nearTrail = false;
        for (let k = -2; k <= 2 && !nearTrail; k++) {
          for (let l = -2; l <= 2 && !nearTrail; l++) {
            if (k === 0 && l === 0) continue;
            if (painted.has((cx + k) + "|" + (cy + l))) nearTrail = true;
          }
        }
        if (!nearTrail && Math.random() > 0.35) continue;
        paintCell(cx, cy);
        placed++;
      }
    }

    render();

    const onResize = () => render();
    window.addEventListener("resize", onResize);

    const observer = new MutationObserver(() => render());
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme", "style"],
    });

    return () => {
      window.removeEventListener("resize", onResize);
      observer.disconnect();
    };
  }, []);

  return (
    <canvas
      ref={canvasRef}
      aria-hidden="true"
      className="fixed inset-0 pointer-events-none"
      style={{ zIndex: 0 }}
    />
  );
}
