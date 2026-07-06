"use client";

import { useEffect, useState } from "react";
import QRCode from "qrcode";

/**
 * Renders a QR code image (as a PNG data URL) encoding `value`.
 * Used for the live preview in the item builder and the printable sheet.
 */
export function QrImage({
  value,
  size = 160,
  className,
}: {
  value: string;
  size?: number;
  className?: string;
}) {
  const [dataUrl, setDataUrl] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    if (!value.trim()) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- clearing a derived render when there's nothing to encode
      setDataUrl(null);
      return;
    }
    QRCode.toDataURL(value, {
      width: size,
      margin: 1,
      errorCorrectionLevel: "M",
      color: { dark: "#003046", light: "#ffffff" },
    })
      .then((url) => {
        if (!cancelled) setDataUrl(url);
      })
      .catch(() => {
        if (!cancelled) setDataUrl(null);
      });
    return () => {
      cancelled = true;
    };
  }, [value, size]);

  if (!dataUrl) {
    return (
      <div
        className={className}
        style={{ width: size, height: size }}
        aria-hidden
      />
    );
  }

  return (
    // eslint-disable-next-line @next/next/no-img-element -- data URL, no Next image optimization needed
    <img
      src={dataUrl}
      alt={`QR code for ${value}`}
      width={size}
      height={size}
      className={className}
    />
  );
}
