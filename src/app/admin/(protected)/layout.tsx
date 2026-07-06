"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { SiteHeader } from "@/components/SiteHeader";

const NAV_ITEMS = [
  { href: "/admin/setup", label: "Setup" },
  { href: "/admin/live", label: "Live" },
  { href: "/admin/results", label: "Results" },
];

export default function AdminProtectedLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();

  async function signOut() {
    await supabase.auth.signOut();
    router.push("/admin/login");
    router.refresh();
  }

  return (
    <div className="flex flex-1 flex-col">
      {/* Chrome is irrelevant to any printed page (poster, QR sheet) — hide it. */}
      <div className="print:hidden">
        <SiteHeader />
        <nav className="border-b border-brand-navy/10 bg-brand-navy">
          <div className="mx-auto flex max-w-5xl items-center justify-between px-6">
            <div className="flex items-center gap-1">
              <span className="mr-3 hidden text-xs font-semibold uppercase tracking-[0.2em] text-brand-cyan sm:inline">
                Hunt HQ
              </span>
              {NAV_ITEMS.map((item) => (
                <Link
                  key={item.href}
                  href={item.href}
                  className={`px-4 py-3 text-sm font-medium transition-colors ${
                    pathname.startsWith(item.href)
                      ? "border-b-2 border-brand-cyan text-white"
                      : "text-white/60 hover:text-white"
                  }`}
                >
                  {item.label}
                </Link>
              ))}
            </div>
            <button
              onClick={signOut}
              className="rounded-full px-3 py-1 text-sm font-medium text-white/60 transition-colors hover:bg-white/10 hover:text-white"
            >
              Sign Out
            </button>
          </div>
        </nav>
      </div>
      <main className="mx-auto w-full max-w-5xl flex-1 px-6 py-8 print:p-0">
        {children}
      </main>
    </div>
  );
}
