"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { SiteHeader } from "@/components/SiteHeader";

export default function AdminLoginPage() {
  const router = useRouter();
  const supabase = createClient();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);

    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (error) {
      setError("Invalid email or password.");
      setLoading(false);
      return;
    }

    router.push("/admin/live");
    router.refresh();
  }

  return (
    <div className="flex flex-1 flex-col">
      <SiteHeader />
      <main
        className="flex flex-1 flex-col items-center justify-center bg-brand-navy px-6 py-16"
        style={{
          backgroundImage:
            "radial-gradient(ellipse 80% 60% at 50% 0%, rgba(48, 204, 216, 0.18), transparent 70%), radial-gradient(ellipse 60% 50% at 85% 100%, rgba(103, 188, 41, 0.1), transparent 70%)",
        }}
      >
        <div className="animate-pop-in w-full max-w-sm rounded-2xl border border-brand-navy/10 bg-white p-8 shadow-xl sm:p-10">
          <div className="flex flex-col gap-1 text-center">
            <p className="text-xs font-semibold uppercase tracking-[0.2em] text-brand-cyan">
              FET Family Fun Day
            </p>
            <h1 className="font-display text-3xl font-semibold text-brand-navy">
              Admin Sign In
            </h1>
            <p className="text-sm text-brand-navy/60">
              Hunt HQ access for organizers
            </p>
          </div>
          <form onSubmit={handleSubmit} className="mt-8 flex flex-col gap-4">
            <input
              type="email"
              required
              autoFocus
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="Email"
              className="w-full rounded-lg border border-brand-navy/20 px-4 py-3 outline-none transition-shadow focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/30"
            />
            <input
              type="password"
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="Password"
              className="w-full rounded-lg border border-brand-navy/20 px-4 py-3 outline-none transition-shadow focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/30"
            />
            {error && (
              <p className="animate-slide-up rounded-lg bg-red-50 px-3 py-2 text-sm text-red-600">
                {error}
              </p>
            )}
            <button
              type="submit"
              disabled={loading}
              className="btn-springy mt-2 rounded-full bg-brand-navy px-8 py-3 font-semibold text-white transition-colors hover:bg-brand-navy-light disabled:opacity-40"
            >
              {loading ? "Signing in..." : "Sign In"}
            </button>
          </form>
        </div>
      </main>
    </div>
  );
}
