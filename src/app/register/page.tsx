"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getStoredTeamId, storeTeamId } from "@/lib/team-session";
import { SiteHeader } from "@/components/SiteHeader";
import { FloatingTriangles } from "@/components/FloatingTriangles";
import { playTap, playSuccess } from "@/lib/sound";
import { burstConfetti } from "@/lib/celebrate";
import { randomTeamName } from "@/lib/fun-names";
import type { Employee, Hunt, Team } from "@/lib/types/hunt";

type Step = "loading" | "no-hunt" | "find-employee" | "name-team" | "creating";

export default function RegisterPage() {
  const router = useRouter();
  const supabase = createClient();

  const [step, setStep] = useState<Step>("loading");
  const [hunt, setHunt] = useState<Hunt | null>(null);
  const [resumeTeam, setResumeTeam] = useState<Team | null>(null);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Employee[]>([]);
  const [searching, setSearching] = useState(false);
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [teamName, setTeamName] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function loadActiveHunt() {
      const { data, error } = await supabase
        .from("hunts")
        .select("id, name, status, settings, created_at")
        .eq("status", "active")
        .limit(1)
        .maybeSingle();

      if (cancelled) return;

      if (error || !data) {
        setStep("no-hunt");
        return;
      }

      // If this device already registered a team for this hunt, offer to
      // resume it instead of silently creating a duplicate with a fresh timer.
      const storedTeamId = getStoredTeamId();
      if (storedTeamId) {
        const { data: existingTeam } = await supabase
          .from("teams")
          .select(
            "id, hunt_id, employee_id, team_name, created_at, started_at, finished_at",
          )
          .eq("id", storedTeamId)
          .eq("hunt_id", data.id)
          .maybeSingle();

        if (cancelled) return;
        if (existingTeam) setResumeTeam(existingTeam as Team);
      }

      setHunt(data as Hunt);
      setStep("find-employee");
    }

    loadActiveHunt();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const trimmedQuery = query.trim();
  const visibleResults = trimmedQuery.length >= 1 ? results : [];

  useEffect(() => {
    if (step !== "find-employee" || trimmedQuery.length < 1) return;
    let cancelled = false;

    async function search() {
      await new Promise((resolve) => setTimeout(resolve, 150));
      if (cancelled) return;

      setSearching(true);
      const { data } = await supabase
        .from("employees")
        .select("id, full_name, department")
        .ilike("full_name", `%${trimmedQuery}%`)
        .order("full_name")
        .limit(10);

      if (cancelled) return;
      setResults((data as Employee[]) ?? []);
      setSearching(false);
    }

    search();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [trimmedQuery, step]);

  function pickEmployee(emp: Employee) {
    playTap();
    setEmployee(emp);
    setStep("name-team");
  }

  async function createTeam() {
    if (!hunt || !employee || !teamName.trim()) return;
    setStep("creating");
    setError(null);

    const { data, error } = await supabase
      .from("teams")
      .insert({
        hunt_id: hunt.id,
        employee_id: employee.id,
        team_name: teamName.trim(),
      })
      .select("id")
      .single();

    if (error || !data) {
      setError("Something went wrong creating your team. Please try again.");
      setStep("name-team");
      return;
    }

    storeTeamId(data.id);
    playSuccess();
    burstConfetti();
    router.push("/hunt");
  }

  return (
    <div className="flex flex-1 flex-col bg-brand-navy">
      <SiteHeader />
      <main className="relative mx-auto flex w-full flex-1 flex-col items-center justify-center overflow-hidden px-5 py-12">
        <FloatingTriangles />

        <div className="relative z-10 mx-auto flex w-full max-w-md flex-col items-center gap-6">
          {step === "loading" && (
            <div className="flex flex-col items-center gap-4 text-center">
              <span
                className="brand-triangle animate-bounce-soft"
                aria-hidden="true"
              />
              <p className="font-display text-lg text-white/70">
                Warming up the hunt...
              </p>
            </div>
          )}

          {step === "no-hunt" && (
            <div className="animate-pop-in w-full rounded-3xl bg-white p-8 text-center shadow-xl">
              <span className="text-5xl" aria-hidden="true">
                ⏳
              </span>
              <h1 className="mt-4 font-display text-3xl font-bold text-brand-navy">
                No hunt is active... yet!
              </h1>
              <p className="mt-3 text-brand-navy/70">
                Check with an FET team member to find out when the scavenger
                hunt kicks off. It&apos;s going to be awesome!
              </p>
            </div>
          )}

          {step === "find-employee" && resumeTeam && (
            <div className="animate-slide-up w-full rounded-3xl border-2 border-brand-cyan/60 bg-white p-6 text-center shadow-xl">
              <span className="text-4xl" aria-hidden="true">
                👋
              </span>
              <p className="mt-2 font-display text-2xl font-bold text-brand-navy">
                Welcome back, {resumeTeam.team_name}!
              </p>
              <button
                onClick={() =>
                  router.push(
                    resumeTeam.finished_at ? "/hunt/complete" : "/hunt",
                  )
                }
                className="btn-springy mt-4 flex h-14 w-full items-center justify-center rounded-full bg-brand-cyan px-6 font-display text-lg font-bold text-brand-navy shadow-md"
              >
                {resumeTeam.finished_at
                  ? "See Your Results 🏆"
                  : "Continue Your Hunt 🔍"}
              </button>
              <p className="mt-3 text-xs font-medium text-brand-navy/50">
                Or register a brand-new team below.
              </p>
            </div>
          )}

          {step === "find-employee" && (
            <div className="animate-pop-in w-full rounded-3xl bg-white p-6 shadow-xl sm:p-8">
              <div className="text-center">
                <span className="text-4xl" aria-hidden="true">
                  🔎
                </span>
                <h1 className="mt-2 font-display text-3xl font-bold text-brand-navy">
                  Find Your Family
                </h1>
                <p className="mt-2 text-brand-navy/70">
                  Search for the FET employee your family is here with.
                </p>
              </div>
              <input
                autoFocus
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Start typing a name..."
                className="mt-6 h-14 w-full rounded-2xl border-2 border-brand-navy/15 bg-brand-cyan/5 px-4 text-lg outline-none transition-colors focus:border-brand-cyan focus:ring-4 focus:ring-brand-cyan/20"
              />
              <ul className="stagger-children mt-4 flex flex-col gap-2">
                {searching && (
                  <li className="flex items-center justify-center gap-2 rounded-2xl bg-brand-cyan/10 px-4 py-4 text-sm font-semibold text-brand-navy/60">
                    <span
                      className="animate-bounce-soft inline-block"
                      aria-hidden="true"
                    >
                      🔍
                    </span>
                    Searching...
                  </li>
                )}
                {!searching &&
                  visibleResults.map((emp) => (
                    <li key={emp.id}>
                      <button
                        onClick={() => pickEmployee(emp)}
                        className="btn-springy flex min-h-14 w-full items-center justify-between gap-3 rounded-2xl border-2 border-brand-navy/10 bg-white px-4 py-3 text-left shadow-sm hover:border-brand-cyan hover:bg-brand-cyan/10"
                      >
                        <span>
                          <span className="block font-display text-lg font-semibold text-brand-navy">
                            {emp.full_name}
                          </span>
                          {emp.department && (
                            <span className="block text-sm text-brand-navy/50">
                              {emp.department}
                            </span>
                          )}
                        </span>
                        <span
                          className="text-xl text-brand-green"
                          aria-hidden="true"
                        >
                          →
                        </span>
                      </button>
                    </li>
                  ))}
                {!searching &&
                  trimmedQuery.length >= 1 &&
                  visibleResults.length === 0 && (
                    <li className="rounded-2xl bg-brand-navy/5 px-4 py-4 text-center text-sm font-medium text-brand-navy/60">
                      🤔 No matches yet — keep typing or check the spelling.
                    </li>
                  )}
              </ul>
            </div>
          )}

          {(step === "name-team" || step === "creating") && employee && (
            <div className="animate-pop-in w-full rounded-3xl bg-white p-6 text-center shadow-xl sm:p-8">
              <span className="animate-wiggle inline-block text-5xl" aria-hidden="true">
                🎉
              </span>
              <h1 className="mt-2 font-display text-3xl font-bold text-brand-navy">
                Welcome, {employee.full_name.split(" ")[0]}&apos;s family!
              </h1>
              <p className="mt-2 text-brand-navy/70">
                Give your team an epic name for the hunt.
              </p>
              <input
                autoFocus
                value={teamName}
                onChange={(e) => setTeamName(e.target.value)}
                placeholder="e.g. The Torque Squad"
                maxLength={40}
                className="mt-6 h-16 w-full rounded-2xl border-2 border-brand-navy/15 bg-brand-green/5 px-4 text-center font-display text-xl font-semibold text-brand-navy outline-none transition-colors focus:border-brand-green focus:ring-4 focus:ring-brand-green/20"
              />
              <button
                type="button"
                onClick={() => {
                  playTap();
                  setTeamName(randomTeamName());
                }}
                className="btn-springy mt-3 inline-flex h-12 items-center justify-center rounded-full border-2 border-brand-cyan/50 bg-brand-cyan/10 px-6 font-display font-semibold text-brand-navy"
              >
                🎲 Surprise me!
              </button>
              {error && (
                <p className="mt-3 rounded-xl bg-red-50 px-4 py-2 text-sm font-medium text-red-600">
                  {error}
                </p>
              )}
              <button
                onClick={createTeam}
                disabled={!teamName.trim() || step === "creating"}
                className="btn-springy animate-pulse-glow mt-6 flex h-16 w-full items-center justify-center rounded-full bg-brand-green px-8 font-display text-2xl font-bold text-white shadow-lg disabled:animate-none disabled:opacity-40"
              >
                {step === "creating" ? (
                  <span className="inline-flex items-center gap-2">
                    <span
                      className="animate-bounce-soft inline-block"
                      aria-hidden="true"
                    >
                      🚀
                    </span>
                    Creating your team...
                  </span>
                ) : (
                  <>Let&apos;s Go! 🚀</>
                )}
              </button>
              <button
                onClick={() => {
                  setEmployee(null);
                  setStep("find-employee");
                }}
                className="mt-4 min-h-12 text-sm font-medium text-brand-navy/50 underline underline-offset-2"
              >
                Not your family? Go back
              </button>
            </div>
          )}
        </div>
      </main>
    </div>
  );
}
