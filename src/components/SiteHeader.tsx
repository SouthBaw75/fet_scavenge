import Image from "next/image";
import Link from "next/link";

export function SiteHeader() {
  return (
    <header className="border-b border-brand-navy/10 bg-white">
      <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
        <Link href="/" className="flex items-center gap-3">
          <Image
            src="/brand/fet-logo.webp"
            alt="Forum Energy Technologies"
            width={120}
            height={60}
            priority
            className="h-10 w-auto"
          />
          <span className="hidden text-sm font-semibold text-brand-navy/70 sm:inline">
            Family Fun Day Scavenger Hunt
          </span>
        </Link>
      </div>
    </header>
  );
}
