"use client";

import { useEffect, useState } from "react";

function formatElapsed(ms: number) {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes.toString().padStart(2, "0")}:${seconds
    .toString()
    .padStart(2, "0")}`;
}

export function HuntTimer({ startedAt }: { startedAt: string }) {
  const startMs = new Date(startedAt).getTime();
  const [elapsed, setElapsed] = useState(() => Date.now() - startMs);

  useEffect(() => {
    const interval = setInterval(() => {
      setElapsed(Date.now() - startMs);
    }, 1000);
    return () => clearInterval(interval);
  }, [startMs]);

  return (
    <span className="inline-flex items-center gap-1.5 rounded-full bg-brand-navy px-4 py-1.5 font-mono text-lg font-bold tabular-nums text-white shadow-md">
      <span aria-hidden className="text-sm">
        ⏱
      </span>
      {formatElapsed(elapsed)}
    </span>
  );
}
