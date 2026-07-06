import Image from "next/image";

/** FETch — the FET triangle mascot. Poses live in /public/brand/fetch. */
export type FetchPose =
  | "wave"
  | "wink-wave"
  | "thinking"
  | "thumbs-up"
  | "confused"
  | "celebrate"
  | "yay";

const ALT: Record<FetchPose, string> = {
  wave: "FETch the mascot waving hello",
  "wink-wave": "FETch the mascot winking",
  thinking: "FETch the mascot thinking",
  "thumbs-up": "FETch the mascot giving a thumbs up",
  confused: "FETch the mascot looking confused",
  celebrate: "FETch the mascot celebrating",
  yay: "FETch the mascot waving a YAY flag",
};

export function Fetch({
  pose,
  width = 200,
  className,
  priority = false,
}: {
  pose: FetchPose;
  width?: number;
  className?: string;
  priority?: boolean;
}) {
  // Source images are 600x400 (3:2).
  const height = Math.round((width * 2) / 3);
  return (
    <Image
      src={`/brand/fetch/${pose}.webp`}
      alt={ALT[pose]}
      width={width}
      height={height}
      priority={priority}
      className={className}
    />
  );
}
