import Image from "next/image";
import clsx from "clsx";

/** FETch — the FET triangle mascot. Poses live in /public/brand/fetch. */
export type FetchPose =
  | "wave"
  | "wink-wave"
  | "thinking"
  | "thumbs-up"
  | "confused"
  | "celebrate"
  | "yay";

// Natural (tight-cropped) dimensions of each pose asset, used to keep
// aspect ratios exact so FETch never squishes.
const DIMS: Record<FetchPose, { w: number; h: number }> = {
  wave: { w: 539, h: 520 },
  "wink-wave": { w: 537, h: 520 },
  thinking: { w: 451, h: 520 },
  "thumbs-up": { w: 547, h: 520 },
  confused: { w: 564, h: 520 },
  celebrate: { w: 579, h: 520 },
  yay: { w: 660, h: 520 },
};

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
  width = 180,
  className,
  priority = false,
  idle = "sway",
  entrance = true,
  shadow = true,
}: {
  pose: FetchPose;
  /** Rendered width in px; height follows the pose's natural ratio. */
  width?: number;
  className?: string;
  priority?: boolean;
  /** Subtle looping motion so FETch feels alive. */
  idle?: "sway" | "bounce" | "none";
  /** Springy pop-in when the screen appears. */
  entrance?: boolean;
  /** Soft elliptical ground shadow under his feet. */
  shadow?: boolean;
}) {
  const dims = DIMS[pose];
  const height = Math.round((width * dims.h) / dims.w);

  return (
    <span
      className={clsx(
        "relative inline-block",
        entrance && "animate-fetch-in",
        className,
      )}
      style={{ width, height: shadow ? height + 10 : height }}
    >
      <Image
        src={`/brand/fetch/${pose}.webp`}
        alt={ALT[pose]}
        width={width}
        height={height}
        priority={priority}
        className={clsx(
          "relative z-[1]",
          idle === "sway" && "animate-fetch-sway",
          idle === "bounce" && "animate-bounce-soft",
        )}
      />
      {shadow && (
        <span
          aria-hidden
          className="fetch-shadow absolute bottom-0 left-1/2 z-0 -translate-x-1/2"
          style={{ width: width * 0.55, height: Math.max(8, width * 0.06) }}
        />
      )}
    </span>
  );
}
