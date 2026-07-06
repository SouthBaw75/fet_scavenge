"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Hunt, Team } from "@/lib/types/hunt";

function durationSeconds(team: Team) {
  if (!team.started_at || !team.finished_at) return null;
  return Math.round(
    (new Date(team.finished_at).getTime() -
      new Date(team.started_at).getTime()) /
      1000,
  );
}

function formatDuration(seconds: number) {
  const minutes = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return `${minutes}m ${secs.toString().padStart(2, "0")}s`;
}

function downloadCsv(teams: Team[]) {
  const header = "Team Name,Started At,Finished At,Duration (s)\n";
  const rows = teams
    .map((t) => {
      const duration = durationSeconds(t);
      return [
        `"${t.team_name.replace(/"/g, '""')}"`,
        t.started_at ?? "",
        t.finished_at ?? "",
        duration ?? "",
      ].join(",");
    })
    .join("\n");

  const blob = new Blob([header + rows], { type: "text/csv" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "hunt-results.csv";
  a.click();
  URL.revokeObjectURL(url);
}

export default function AdminResultsPage() {
  const supabase = createClient();
  const [hunts, setHunts] = useState<Hunt[]>([]);
  const [huntId, setHuntId] = useState<string | null>(null);
  const [teams, setTeams] = useState<Team[]>([]);

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

    async function loadTeams() {
      const { data } = await supabase
        .from("teams")
        .select(
          "id, hunt_id, employee_id, team_name, created_at, started_at, finished_at",
        )
        .eq("hunt_id", huntId)
        .order("finished_at", { ascending: true });
      setTeams((data as Team[]) ?? []);
    }
    loadTeams();
  }, [huntId, supabase]);

  const finished = teams
    .filter((t) => t.finished_at)
    .sort((a, b) => (durationSeconds(a) ?? 0) - (durationSeconds(b) ?? 0));
  const inProgress = teams.filter((t) => t.started_at && !t.finished_at);
  const notStarted = teams.filter((t) => !t.started_at);

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-brand-navy">Results</h1>
        <div className="flex gap-2">
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
          <button
            onClick={() => downloadCsv(teams)}
            disabled={teams.length === 0}
            className="rounded-lg bg-brand-navy px-4 py-2 text-sm font-semibold text-white disabled:opacity-40"
          >
            Export CSV
          </button>
        </div>
      </div>

      <div className="rounded-2xl border border-brand-navy/10 bg-white p-6 shadow-sm">
        <h2 className="text-lg font-semibold text-brand-navy">
          Leaderboard ({finished.length} finished)
        </h2>
        <ol className="mt-4 flex flex-col gap-2">
          {finished.map((team, i) => (
            <li
              key={team.id}
              className="flex items-center justify-between rounded-lg border border-brand-navy/10 px-4 py-2"
            >
              <span className="font-medium text-brand-navy">
                {i + 1}. {team.team_name}
              </span>
              <span className="font-mono text-brand-navy/70">
                {formatDuration(durationSeconds(team)!)}
              </span>
            </li>
          ))}
          {finished.length === 0 && (
            <p className="text-sm text-brand-navy/50">
              No teams have finished yet.
            </p>
          )}
        </ol>
      </div>

      <div className="grid grid-cols-2 gap-4 text-sm text-brand-navy/70">
        <div className="rounded-2xl border border-brand-navy/10 bg-white p-4">
          <p className="font-semibold text-brand-navy">
            {inProgress.length} in progress
          </p>
        </div>
        <div className="rounded-2xl border border-brand-navy/10 bg-white p-4">
          <p className="font-semibold text-brand-navy">
            {notStarted.length} not started
          </p>
        </div>
      </div>
    </div>
  );
}
