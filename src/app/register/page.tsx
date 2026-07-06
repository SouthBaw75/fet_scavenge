"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { storeTeamId } from "@/lib/team-session";
import { SiteHeader } from "@/components/SiteHeader";
import type { Employee, Hunt } from "@/lib/types/hunt";

type Step = "loading" | "no-hunt" | "find-employee" | "name-team" | "creating";

export default function RegisterPage() {
  const router = useRouter();
  const supabase = createClient();

  const [step, setStep] = useState<Step>("loading");
  const [hunt, setHunt] = useState<Hunt | null>(null);
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
  const visibleResults = trimmedQuery.length >= 2 ? results : [];

  useEffect(() => {
    if (step !== "find-employee" || trimmedQuery.length < 2) return;
    let cancelled = false;

    async function search() {
      await new Promise((resolve) => setTimeout(resolve, 250));
      if (cancelled) return;

      setSearching(true);
      const { data } = await supabase
        .from("employees")
        .select("id, full_name, department")
        .ilike("full_name", `%${trimmedQuery}%`)
        .order("full_name")
        .limit(8);

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
    router.push("/hunt");
  }

  return (
    <div className="flex flex-1 flex-col">
      <SiteHeader />
      <main className="mx-auto flex w-full max-w-md flex-1 flex-col items-center justify-center gap-6 px-6 py-16">
        {step === "loading" && (
          <p className="text-brand-navy/60">Loading...</p>
        )}

        {step === "no-hunt" && (
          <div className="text-center">
            <h1 className="text-2xl font-bold text-brand-navy">
              No hunt is active yet
            </h1>
            <p className="mt-2 text-brand-navy/70">
              Check with an FET team member to find out when the scavenger
              hunt kicks off.
            </p>
          </div>
        )}

        {step === "find-employee" && (
          <div className="w-full">
            <h1 className="text-center text-2xl font-bold text-brand-navy">
              Find your family
            </h1>
            <p className="mt-2 text-center text-brand-navy/70">
              Search for the FET employee your family is here with.
            </p>
            <input
              autoFocus
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Start typing a name..."
              className="mt-6 w-full rounded-lg border border-brand-navy/20 px-4 py-3 text-lg outline-none focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/30"
            />
            <ul className="mt-3 divide-y divide-brand-navy/10 overflow-hidden rounded-lg border border-brand-navy/10">
              {searching && (
                <li className="px-4 py-3 text-sm text-brand-navy/50">
                  Searching...
                </li>
              )}
              {!searching &&
                visibleResults.map((emp) => (
                  <li key={emp.id}>
                    <button
                      onClick={() => pickEmployee(emp)}
                      className="w-full px-4 py-3 text-left transition-colors hover:bg-brand-cyan/10"
                    >
                      <span className="font-medium text-brand-navy">
                        {emp.full_name}
                      </span>
                      {emp.department && (
                        <span className="ml-2 text-sm text-brand-navy/50">
                          {emp.department}
                        </span>
                      )}
                    </button>
                  </li>
                ))}
              {!searching && trimmedQuery.length >= 2 && visibleResults.length === 0 && (
                <li className="px-4 py-3 text-sm text-brand-navy/50">
                  No matches yet — keep typing or check the spelling.
                </li>
              )}
            </ul>
          </div>
        )}

        {(step === "name-team" || step === "creating") && employee && (
          <div className="w-full text-center">
            <h1 className="text-2xl font-bold text-brand-navy">
              Welcome, {employee.full_name.split(" ")[0]}&apos;s family!
            </h1>
            <p className="mt-2 text-brand-navy/70">
              Give your team a fun name for the hunt.
            </p>
            <input
              autoFocus
              value={teamName}
              onChange={(e) => setTeamName(e.target.value)}
              placeholder="e.g. The Torque Squad"
              maxLength={40}
              className="mt-6 w-full rounded-lg border border-brand-navy/20 px-4 py-3 text-center text-lg outline-none focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/30"
            />
            {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
            <button
              onClick={createTeam}
              disabled={!teamName.trim() || step === "creating"}
              className="mt-6 w-full rounded-full bg-brand-navy px-8 py-3 text-lg font-semibold text-white transition-colors hover:bg-brand-navy-light disabled:opacity-40"
            >
              {step === "creating" ? "Creating your team..." : "Start the Hunt"}
            </button>
            <button
              onClick={() => {
                setEmployee(null);
                setStep("find-employee");
              }}
              className="mt-3 text-sm text-brand-navy/50 underline"
            >
              Not your family? Go back
            </button>
          </div>
        )}
      </main>
    </div>
  );
}
