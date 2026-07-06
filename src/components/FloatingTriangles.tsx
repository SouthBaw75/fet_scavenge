/**
 * Decorative drifting brand triangles (echoing the FET logo marks).
 * Purely cosmetic — pointer-events-none, aria-hidden, and each triangle's
 * float animation is disabled under prefers-reduced-motion via globals.css.
 */
const TRIANGLES: {
  left: string;
  top: string;
  scale: number;
  green?: boolean;
  delay: string;
}[] = [
  { left: "6%", top: "12%", scale: 1, delay: "0s" },
  { left: "88%", top: "18%", scale: 0.7, green: true, delay: "1.2s" },
  { left: "12%", top: "72%", scale: 0.8, green: true, delay: "2.1s" },
  { left: "80%", top: "68%", scale: 1.2, delay: "0.6s" },
  { left: "45%", top: "8%", scale: 0.5, green: true, delay: "2.8s" },
  { left: "60%", top: "85%", scale: 0.6, delay: "1.7s" },
];

export function FloatingTriangles() {
  return (
    <div
      aria-hidden
      className="pointer-events-none absolute inset-0 overflow-hidden"
    >
      {TRIANGLES.map((t, i) => (
        <div
          key={i}
          className={`brand-triangle animate-float absolute ${t.green ? "green" : ""}`}
          style={{
            left: t.left,
            top: t.top,
            transform: `scale(${t.scale})`,
            animationDelay: t.delay,
            opacity: 0.35,
          }}
        />
      ))}
    </div>
  );
}
