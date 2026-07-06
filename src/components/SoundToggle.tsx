"use client";

import { useEffect, useState } from "react";
import { isMuted, playTap, setMuted } from "@/lib/sound";

export function SoundToggle() {
  // Render a stable default on the server; sync from localStorage after mount.
  const [muted, setMutedState] = useState(false);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- syncing from localStorage, an external system
    setMutedState(isMuted());
  }, []);

  function toggle() {
    const next = !muted;
    setMuted(next);
    setMutedState(next);
    if (!next) playTap();
  }

  return (
    <button
      onClick={toggle}
      aria-label={muted ? "Turn sound on" : "Turn sound off"}
      title={muted ? "Turn sound on" : "Turn sound off"}
      className="btn-springy flex h-10 w-10 items-center justify-center rounded-full border border-brand-navy/10 bg-white text-lg shadow-sm"
    >
      {muted ? "🔇" : "🔊"}
    </button>
  );
}
