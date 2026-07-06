"use client";

import { useEffect, useRef, useState } from "react";
import QrScanner from "qr-scanner";

export function QrScannerView({
  onScan,
}: {
  onScan: (value: string) => void;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  // Keep the latest callback in a ref so the scanner (created once) never
  // fires a stale closure from an earlier render.
  const onScanRef = useRef(onScan);
  const [cameraError, setCameraError] = useState(false);
  const [manualValue, setManualValue] = useState("");

  useEffect(() => {
    onScanRef.current = onScan;
  }, [onScan]);

  useEffect(() => {
    if (!videoRef.current) return;

    const scanner = new QrScanner(
      videoRef.current,
      (result) => onScanRef.current(result.data),
      { highlightScanRegion: true, highlightCodeOutline: true },
    );

    scanner.start().catch(() => setCameraError(true));

    return () => {
      scanner.stop();
      scanner.destroy();
    };
  }, []);

  return (
    <div className="flex flex-col items-center gap-4">
      {!cameraError && (
        <>
          {/* Viewfinder frame with corner accents */}
          <div className="relative w-full max-w-xs rounded-3xl border-4 border-brand-navy bg-brand-navy p-1.5 shadow-xl">
            <video
              ref={videoRef}
              className="aspect-square w-full rounded-2xl bg-black object-cover"
              muted
              playsInline
            />
            <span
              aria-hidden
              className="pointer-events-none absolute left-3 top-3 h-8 w-8 rounded-tl-xl border-l-4 border-t-4 border-brand-cyan"
            />
            <span
              aria-hidden
              className="pointer-events-none absolute right-3 top-3 h-8 w-8 rounded-tr-xl border-r-4 border-t-4 border-brand-cyan"
            />
            <span
              aria-hidden
              className="pointer-events-none absolute bottom-3 left-3 h-8 w-8 rounded-bl-xl border-b-4 border-l-4 border-brand-green"
            />
            <span
              aria-hidden
              className="pointer-events-none absolute bottom-3 right-3 h-8 w-8 rounded-br-xl border-b-4 border-r-4 border-brand-green"
            />
          </div>
          <p className="animate-pulse text-center font-display text-base font-bold text-brand-navy">
            Point your camera at the QR code! 📸
          </p>
        </>
      )}

      {cameraError && (
        <div className="w-full max-w-xs rounded-3xl border-2 border-dashed border-brand-navy/20 bg-brand-navy/5 px-5 py-6 text-center">
          <span className="text-4xl" aria-hidden>
            🙈
          </span>
          <p className="mt-2 font-display text-base font-bold text-brand-navy">
            Couldn&apos;t access the camera
          </p>
          <p className="mt-1 text-sm text-brand-navy/70">
            Ask a volunteer for the code and type it in below.
          </p>
        </div>
      )}

      <details className="w-full max-w-xs" open={cameraError}>
        <summary className="cursor-pointer text-center text-sm font-semibold text-brand-navy/60 underline decoration-brand-cyan decoration-2 underline-offset-4">
          Trouble scanning? Enter the code manually
        </summary>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            if (manualValue.trim()) onScan(manualValue.trim());
          }}
          className="mt-3 flex gap-2"
        >
          <input
            value={manualValue}
            onChange={(e) => setManualValue(e.target.value)}
            placeholder="Enter code"
            className="h-12 min-w-0 flex-1 rounded-2xl border-2 border-brand-navy/15 px-4 text-base font-semibold text-brand-navy outline-none focus:border-brand-cyan focus:ring-4 focus:ring-brand-cyan/25"
          />
          <button
            type="submit"
            className="btn-springy h-12 rounded-2xl bg-brand-navy px-5 font-display text-base font-bold text-white shadow-md"
          >
            Go 🚀
          </button>
        </form>
      </details>
    </div>
  );
}
