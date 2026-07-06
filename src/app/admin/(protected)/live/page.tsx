"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { HuntTimer } from "@/components/HuntTimer";
import { durationSecondsBetween, formatDurationSeconds } from "@/lib/time";
import type { Hunt, Team } from "@/lib/types/hunt";

export default function AdminLivePage() {
  const supabase = createClient();
  const [hunts, setHunts] = useState<Hunt[]>([]);
  const [huntId, setHuntId] = useState<string | null>(null);
  const [itemCount, setItemCount] = useState(0);
  const [teams, setTeams] = useState<Team[]>([]);
  const [progressCounts, setProgressCounts] = useState<Record<string, number>>(
    {},
  );

  useEffect(() => {
    async function loadHunts() {
      const { data } = await supabase
        .from("hunts")
        .select("id, name, status, settings, created_at")
        .order("created_at", { ascending: false });
      const list = (data as Hunt[]) ?? [];
      setHunts(list);
      if (!huntId && list.length > 0) {
        setHuntId(list.find((h) => h.status === "active")?.id ?? list[0].id);
      }
    }
    loadHunts();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!huntId) return;
    let cancelled = false;

    async function loadTeamsAndProgress() {
      const [{ count }, { data: teamRows }] = await Promise.all([
        supabase
          .from("hunt_items")
          .select("id", { count: "exact", head: true })
          .eq("hunt_id", huntId),
        supabase
          .from("teams")
          .select(
            "id, hunt_id, employee_id, team_name, created_at, started_at, finished_at",
          )
          .eq("hunt_id", huntId)
          .order("team_name"),
      ]);

      if (cancelled) return;
      setItemCount(count ?? 0);
      const currentTeams = (teamRows as Team[]) ?? [];
      setTeams(currentTeams);

      const teamIds = currentTeams.map((t) => t.id);
      if (teamIds.length > 0) {
        const { data: progressRows } = await supabase
          .from("team_progress")
          .select("team_id")
          .in("team_id", teamIds);

        if (cancelled) return;
        const counts: Record<string, number> = {};
        for (const row of progressRows ?? []) {
          counts[row.team_id] = (counts[row.team_id] ?? 0) + 1;
        }
        setProgressCounts(counts);
      } else {
        setProgressCounts({});
      }
    }

    loadTeamsAndProgress();

    const teamsChannel = supabase
      .channel(`admin-teams-${huntId}`)
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "teams",
          filter: `hunt_id=eq.${huntId}`,
        },
        () => loadTeamsAndProgress(),
      )
      .subscribe();

    const progressChannel = supabase
      .channel(`admin-progress-${huntId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "team_progress" },
        () => loadTeamsAndProgress(),
      )
      .subscribe();

    return () => {
      cancelled = true;
      supabase.removeChannel(teamsChannel);
      supabase.removeChannel(progressChannel);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [huntId]);

  const huntingCount = teams.filter(
    (t) => t.started_at && !t.finished_at,
  ).length;
  const finishedCount = teams.filter((t) => t.finished_at).length;

  return (
    <div className="flex flex-col gap-6">
      <div className="animate-slide-up flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="font-display text-3xl font-semibold text-brand-navy">
            Live Hunt Tracker
          </h1>
          <p className="mt-1 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-brand-navy/60">
            <span className="inline-flex items-center gap-1.5">
              <span className="relative flex h-2 w-2">
                <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-brand-cyan opacity-60" />
                <span className="relative inline-flex h-2 w-2 rounded-full bg-brand-cyan" />
              </span>
              {huntingCount} hunting
            </span>
            <span className="font-medium text-brand-green">
              {finishedCount} finished
            </span>
            <span>{teams.length} teams total</span>
          </p>
        </div>
        <select
          value={huntId ?? ""}
          onChange={(e) => setHuntId(e.target.value)}
          className="rounded-lg border border-brand-navy/20 bg-white px-3 py-2 text-sm shadow-sm outline-none transition-shadow focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/30"
        >
          {hunts.map((h) => (
            <option key={h.id} value={h.id}>
              {h.name} ({h.status})
            </option>
          ))}
        </select>
      </div>

      <div className="stagger-children grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {teams.map((team) => {
          const answered = progressCounts[team.id] ?? 0;
          const status = team.finished_at
            ? "Finished"
            : team.started_at
              ? "Hunting"
              : "Not Started";
          const pct =
            itemCount > 0
              ? Math.min(100, Math.round((answered / itemCount) * 100))
              : 0;

          return (
            <div
              key={team.id}
              className={`rounded-2xl border bg-white p-5 shadow-sm transition-shadow hover:shadow-md ${
                status === "Finished"
                  ? "border-brand-green/40 ring-2 ring-brand-green/25"
                  : status === "Hunting"
                    ? "border-brand-navy/10 border-l-4 border-l-brand-cyan"
                    : "border-brand-navy/10 opacity-80"
              }`}
            >
              <div className="flex items-start justify-between gap-2">
                <p className="font-semibold text-brand-navy">
                  {team.team_name}
                </p>
                <span
                  className={`shrink-0 rounded-full px-3 py-1 text-xs font-semibold ${
                    status === "Finished"
                      ? "bg-brand-green/10 text-brand-green"
                      : status === "Hunting"
                        ? "bg-brand-cyan/10 text-brand-cyan"
                        : "bg-brand-navy/10 text-brand-navy/60"
                  }`}
                >
                  {status === "Finished" ? "✓ Finished" : status}
                </span>
              </div>

              <div className="mt-4">
                <div className="flex items-baseline justify-between text-xs text-brand-navy/60">
                  <span>
                    {answered} / {itemCount} items
                  </span>
                  <span className="font-mono text-sm text-brand-navy">
                    {team.started_at && !team.finished_at && (
                      <HuntTimer startedAt={team.started_at} />
                    )}
                    {team.started_at && team.finished_at && (
                      <span>
                        {formatDurationSeconds(
                          durationSecondsBetween(
                            team.started_at,
                            team.finished_at,
                          ),
                        )}
                      </span>
                    )}
                  </span>
                </div>
                <div className="mt-2 h-2 overflow-hidden rounded-full bg-brand-navy/10">
                  <div
                    className="h-full rounded-full bg-gradient-to-r from-brand-cyan to-brand-green transition-[width] duration-700 ease-out"
                    style={{ width: `${pct}%` }}
                  />
                </div>
              </div>
            </div>
          );
        })}
        {teams.length === 0 && (
          <div className="col-span-full rounded-2xl border border-dashed border-brand-navy/20 bg-white px-4 py-10 text-center text-brand-navy/50">
            No teams registered yet — cards will appear here live as families
            join.
          </div>
        )}
      </div>
    </div>
  );
}
