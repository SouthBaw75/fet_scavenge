"use client";

/**
 * Downscale + re-encode an image in the browser before upload, so families
 * download a small, fast-loading file instead of a multi-megabyte phone photo.
 *
 * Caps the longest edge (default 1280px — sharp on any phone card, even at 2x
 * retina) and encodes to WebP. Falls back to the original file if the browser
 * can't decode it (e.g. an exotic format) so an upload never gets blocked.
 */
export async function optimizeImage(
  file: File,
  { maxDim = 1280, quality = 0.82 }: { maxDim?: number; quality?: number } = {},
): Promise<{ blob: Blob; ext: string; contentType: string }> {
  const original = { blob: file, ext: file.name.split(".").pop() || "jpg", contentType: file.type };

  if (typeof document === "undefined") return original;

  let bitmap: ImageBitmap | HTMLImageElement;
  try {
    bitmap = await loadBitmap(file);
  } catch {
    return original; // couldn't decode — upload as-is rather than fail
  }

  const srcW = "width" in bitmap ? bitmap.width : 0;
  const srcH = "height" in bitmap ? bitmap.height : 0;
  if (!srcW || !srcH) return original;

  const scale = Math.min(1, maxDim / Math.max(srcW, srcH));
  const w = Math.round(srcW * scale);
  const h = Math.round(srcH * scale);

  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");
  if (!ctx) return original;
  ctx.drawImage(bitmap as CanvasImageSource, 0, 0, w, h);
  if ("close" in bitmap) bitmap.close();

  const blob = await new Promise<Blob | null>((resolve) =>
    canvas.toBlob(resolve, "image/webp", quality),
  );

  // If WebP encoding isn't supported or somehow grew the file, keep the original.
  if (!blob || blob.size >= file.size) return original;

  return { blob, ext: "webp", contentType: "image/webp" };
}

function loadBitmap(file: File): Promise<ImageBitmap | HTMLImageElement> {
  if (typeof createImageBitmap === "function") {
    return createImageBitmap(file);
  }
  // Fallback for browsers without createImageBitmap.
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("decode failed"));
    };
    img.src = url;
  });
}
