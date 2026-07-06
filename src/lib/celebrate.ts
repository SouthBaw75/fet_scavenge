"use client";

import confetti from "canvas-confetti";

/** FET brand palette — matches the triangles in the logo. */
const BRAND_COLORS = ["#30ccd8", "#67bc29", "#0d4a68", "#ffffff"];

// shapeFromPath needs Path2D, which only exists in the browser — build the
// triangle lazily on first use (module load happens during SSR prerender too).
let triangleShape: confetti.Shape | null | undefined;
function shapes(): confetti.Shape[] {
  if (triangleShape === undefined) {
    try {
      triangleShape = confetti.shapeFromPath({ path: "M0 10 L5 0 L10 10 Z" });
    } catch {
      triangleShape = null; // Path2D unsupported — fall back to built-ins
    }
  }
  return triangleShape ? [triangleShape, "circle"] : ["circle", "square"];
}

const reducedMotion = () =>
  typeof window !== "undefined" &&
  window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/** Small burst from a point — e.g. right after submitting an answer. */
export function burstConfetti(origin?: { x: number; y: number }) {
  if (reducedMotion()) return;
  confetti({
    particleCount: 24,
    spread: 55,
    startVelocity: 28,
    scalar: 0.9,
    ticks: 90,
    colors: BRAND_COLORS,
    shapes: shapes(),
    origin: origin ?? { x: 0.5, y: 0.6 },
    disableForReducedMotion: true,
  });
}

/** The big one — hunt complete. Multi-wave cannon from both corners. */
export function finishConfetti() {
  if (reducedMotion()) return;
  const waves = [0, 250, 550, 900];
  for (const delay of waves) {
    setTimeout(() => {
      confetti({
        particleCount: 60,
        angle: 60,
        spread: 65,
        startVelocity: 45,
        colors: BRAND_COLORS,
        shapes: shapes(),
        origin: { x: 0, y: 0.8 },
        disableForReducedMotion: true,
      });
      confetti({
        particleCount: 60,
        angle: 120,
        spread: 65,
        startVelocity: 45,
        colors: BRAND_COLORS,
        shapes: shapes(),
        origin: { x: 1, y: 0.8 },
        disableForReducedMotion: true,
      });
    }, delay);
  }
}
