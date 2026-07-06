import Link from "next/link";
import { SiteHeader } from "@/components/SiteHeader";

export default function Home() {
  return (
    <div className="flex flex-1 flex-col">
      <SiteHeader />
      <main className="flex flex-1 flex-col items-center justify-center gap-8 bg-gradient-to-b from-white to-brand-cyan/10 px-6 py-24 text-center">
        <div className="flex flex-col items-center gap-3">
          <span className="rounded-full bg-brand-green/10 px-4 py-1 text-sm font-semibold tracking-wide text-brand-green">
            FAMILY FUN DAY
          </span>
          <h1 className="max-w-2xl text-4xl font-bold tracking-tight text-brand-navy sm:text-5xl">
            Shop Floor Scavenger Hunt
          </h1>
          <p className="max-w-xl text-lg text-brand-navy/70">
            Gather your family, pick a team name, and race through the shop
            answering clues, cracking codes, and scanning QR stops along the
            way.
          </p>
        </div>
        <Link
          href="/register"
          className="rounded-full bg-brand-navy px-8 py-3 text-lg font-semibold text-white shadow-sm transition-colors hover:bg-brand-navy-light"
        >
          Register Your Team
        </Link>
      </main>
    </div>
  );
}
