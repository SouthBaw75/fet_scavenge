import Link from "next/link";
import { SiteHeader } from "@/components/SiteHeader";
import { FloatingTriangles } from "@/components/FloatingTriangles";
import { Fetch } from "@/components/Fetch";

export default function Home() {
  return (
    <div className="flex flex-1 flex-col bg-brand-navy">
      <SiteHeader />
      <main className="relative flex flex-1 flex-col items-center justify-center overflow-hidden px-6 py-16 text-center">
        <FloatingTriangles />

        <div className="stagger-children relative z-10 flex w-full max-w-2xl flex-col items-center gap-8">
          {/* Badge */}
          <span className="animate-pop-in inline-flex items-center gap-2 rounded-full border-2 border-brand-green/50 bg-brand-green/15 px-5 py-2 font-display text-sm font-semibold tracking-widest text-brand-green">
            <span className="animate-bounce-soft inline-block">🎉</span>
            FET FAMILY FUN DAY
            <span
              className="animate-bounce-soft inline-block"
              style={{ animationDelay: "0.2s" }}
            >
              🎉
            </span>
          </span>

          {/* FETch says hi — tucked right up against the headline */}
          <Fetch pose="wave" width={230} priority className="-mb-3" />

          {/* Headline */}
          <h1 className="font-display text-5xl font-bold leading-[1.05] tracking-tight text-white sm:text-7xl">
            Shop Floor
            <br />
            <span className="brand-gradient-text">Scavenger Hunt</span>
          </h1>

          {/* Triangle accents */}
          <div className="flex items-end gap-3" aria-hidden="true">
            <span className="brand-triangle animate-float" />
            <span
              className="brand-triangle green animate-float"
              style={{ animationDelay: "0.4s" }}
            />
            <span
              className="brand-triangle animate-float"
              style={{ animationDelay: "0.8s" }}
            />
          </div>

          {/* Subhead */}
          <p className="max-w-xl text-lg leading-relaxed text-white/80 sm:text-xl">
            Grab your crew, pick an awesome team name, and race through the
            shop cracking clues, breaking codes, and scanning secret QR stops!
          </p>

          {/* Giant CTA */}
          <Link
            href="/register"
            className="btn-springy animate-pulse-glow inline-flex h-16 w-full max-w-sm items-center justify-center rounded-full bg-brand-green px-10 font-display text-2xl font-bold text-white shadow-lg"
          >
            Start the Hunt! 🚀
          </Link>

          {/* How it works */}
          <div className="mt-2 flex flex-wrap items-center justify-center gap-x-3 gap-y-2 text-sm font-semibold text-white/70 sm:text-base">
            <span className="inline-flex items-center gap-1.5 rounded-full bg-white/10 px-4 py-2">
              👨‍👩‍👧 Register
            </span>
            <span className="text-brand-cyan" aria-hidden="true">
              →
            </span>
            <span className="inline-flex items-center gap-1.5 rounded-full bg-white/10 px-4 py-2">
              🔍 Hunt
            </span>
            <span className="text-brand-cyan" aria-hidden="true">
              →
            </span>
            <span className="inline-flex items-center gap-1.5 rounded-full bg-white/10 px-4 py-2">
              🏆 Finish
            </span>
          </div>
        </div>
      </main>
    </div>
  );
}
