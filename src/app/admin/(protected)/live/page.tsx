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

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-brand-navy">Live Progress</h1>
        <select
          value={huntId ?? ""}
          onChange={(e) => setHuntId(e.target.value)}
          className="rounded-lg border border-brand-navy/20 px-3 py-2 text-sm"
        >
          {hunts.map((h) => (
            <option key={h.id} value={h.id}>
              {h.name} ({h.status})
            </option>
          ))}
        </select>
      </div>

      <div className="overflow-hidden rounded-2xl border border-brand-navy/10 bg-white shadow-sm">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-brand-navy/10 bg-brand-navy/5 text-brand-navy/70">
            <tr>
              <th className="px-4 py-3">Team</th>
              <th className="px-4 py-3">Status</th>
              <th className="px-4 py-3">Progress</th>
              <th className="px-4 py-3">Time</th>
            </tr>
          </thead>
          <tbody>
            {teams.map((team) => {
              const answered = progressCounts[team.id] ?? 0;
              const status = team.finished_at
                ? "Finished"
                : team.started_at
                  ? "In Progress"
                  : "Not Started";

              return (
                <tr
                  key={team.id}
                  className="border-b border-brand-navy/5 last:border-0"
                >
                  <td className="px-4 py-3 font-medium text-brand-navy">
                    {team.team_name}
                  </td>
                  <td className="px-4 py-3">
                    <span
                      className={`rounded-full px-3 py-1 text-xs font-semibold ${
                        status === "Finished"
                          ? "bg-brand-green/10 text-brand-green"
                          : status === "In Progress"
                            ? "bg-brand-cyan/10 text-brand-cyan"
                            : "bg-brand-navy/10 text-brand-navy/60"
                      }`}
                    >
                      {status}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-brand-navy/70">
                    {answered} / {itemCount}
                  </td>
                  <td className="px-4 py-3 font-mono text-brand-navy">
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
                  </td>
                </tr>
              );
            })}
            {teams.length === 0 && (
              <tr>
                <td
                  colSpan={4}
                  className="px-4 py-6 text-center text-brand-navy/50"
                >
                  No teams registered yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
