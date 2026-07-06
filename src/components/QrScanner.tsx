"use client";

import { useEffect, useRef, useState } from "react";
import QrScanner from "qr-scanner";

export function QrScannerView({
  onScan,
}: {
  onScan: (value: string) => void;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [cameraError, setCameraError] = useState(false);
  const [manualValue, setManualValue] = useState("");

  useEffect(() => {
    if (!videoRef.current) return;

    const scanner = new QrScanner(
      videoRef.current,
      (result) => onScan(result.data),
      { highlightScanRegion: true, highlightCodeOutline: true },
    );

    scanner.start().catch(() => setCameraError(true));

    return () => {
      scanner.stop();
      scanner.destroy();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className="flex flex-col items-center gap-4">
      {!cameraError && (
        <video
          ref={videoRef}
          className="aspect-square w-full max-w-xs rounded-xl bg-black object-cover"
          muted
          playsInline
        />
      )}

      {cameraError && (
        <p className="text-center text-sm text-brand-navy/70">
          Couldn&apos;t access the camera. Ask a volunteer for the code and
          type it in below.
        </p>
      )}

      <details className="w-full max-w-xs" open={cameraError}>
        <summary className="cursor-pointer text-center text-sm text-brand-navy/50 underline">
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
            className="flex-1 rounded-lg border border-brand-navy/20 px-3 py-2 outline-none focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/30"
          />
          <button
            type="submit"
            className="rounded-lg bg-brand-navy px-4 py-2 font-semibold text-white"
          >
            Submit
          </button>
        </form>
      </details>
    </div>
  );
}
