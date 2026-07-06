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
  const [correctCounts, setCorrectCounts] = useState<Record<string, number>>(
    {},
  );
  const [itemCount, setItemCount] = useState(0);
  const [refreshKey, setRefreshKey] = useState(0);
  const [showAllFinished, setShowAllFinished] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    async function loadHunts() {
      const { data } = await supabase
        .from("hunts")
        .select("id, name, status, settings, created_at, winner_team_id")
        .order("created_at", { ascending: false });
      const list = (data as Hunt[]) ?? [];
      setHunts(list);
      if (!huntId && list.length > 0) {
        setHuntId(list.find((h) => h.status === "active")?.id ?? list[0].id);
      }
    }
    loadHunts();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refreshKey]);

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
      const list = (data as Team[]) ?? [];
      setTeams(list);

      const teamIds = list.map((t) => t.id);
      if (teamIds.length > 0) {
        const { data: progress } = await supabase
          .from("team_progress")
          .select("team_id, is_correct")
          .in("team_id", teamIds);
        const counts: Record<string, number> = {};
        for (const row of (progress as
          | { team_id: string; is_correct: boolean }[]
          | null) ?? []) {
          if (row.is_correct) {
            counts[row.team_id] = (counts[row.team_id] ?? 0) + 1;
          }
        }
        setCorrectCounts(counts);
      } else {
        setCorrectCounts({});
      }

      const { count } = await supabase
        .from("hunt_items")
        .select("id", { count: "exact", head: true })
        .eq("hunt_id", huntId);
      setItemCount(count ?? 0);
    }
    loadTeams();
  }, [huntId, refreshKey, supabase]);

  const hunt = hunts.find((h) => h.id === huntId) ?? null;

  const finished = teams
    .filter((t) => t.finished_at)
    .sort((a, b) => (durationSeconds(a) ?? 0) - (durationSeconds(b) ?? 0));
  const inProgress = teams.filter((t) => t.started_at && !t.finished_at);
  const notStarted = teams.filter((t) => !t.started_at);

  const winner = hunt?.winner_team_id
    ? (teams.find((t) => t.id === hunt.winner_team_id) ?? null)
    : null;

  // Recommended candidates: finished AND answered every question correctly.
  const candidates = finished.filter(
    (t) => itemCount > 0 && (correctCounts[t.id] ?? 0) === itemCount,
  );

  function correctLabel(team: Team) {
    return `${correctCounts[team.id] ?? 0}/${itemCount} correct`;
  }

  async function declareWinner(team: Team) {
    if (!hunt || saving) return;
    const ok = window.confirm(
      `Declare "${team.team_name}" the winner of "${hunt.name}"? Their app will show the winner celebration immediately.`,
    );
    if (!ok) return;
    setSaving(true);
    await supabase
      .from("hunts")
      .update({ winner_team_id: team.id })
      .eq("id", hunt.id);
    setSaving(false);
    setRefreshKey((k) => k + 1);
  }

  async function clearWinner() {
    if (!hunt || saving) return;
    const ok = window.confirm(
      `Clear the winner of "${hunt.name}"? The winning team's celebration screen will be removed.`,
    );
    if (!ok) return;
    setSaving(true);
    await supabase
      .from("hunts")
      .update({ winner_team_id: null })
      .eq("id", hunt.id);
    setSaving(false);
    setRefreshKey((k) => k + 1);
  }

  const MEDALS = ["🥇", "🥈", "🥉"];

  function candidateRow(team: Team, recommended: boolean) {
    const duration = durationSeconds(team);
    return (
      <li
        key={team.id}
        className={`flex flex-wrap items-center justify-between gap-3 rounded-xl border px-4 py-3 transition-colors ${
          recommended
            ? "border-brand-green/40 bg-brand-green/5 ring-1 ring-brand-green/25"
            : "border-brand-navy/10 hover:bg-brand-navy/[0.02]"
        }`}
      >
        <div className="flex flex-col">
          <span
            className={`font-semibold text-brand-navy ${recommended ? "text-lg" : ""}`}
          >
            {team.team_name}
          </span>
          {recommended && (
            <span className="text-xs font-semibold text-brand-green">
              ⭐ Recommended — perfect score, fastest time
            </span>
          )}
          <span className="mt-0.5 text-xs text-brand-navy/60">
            {duration !== null ? formatDuration(duration) : "—"} ·{" "}
            {correctLabel(team)}
          </span>
        </div>
        <button
          onClick={() => declareWinner(team)}
          disabled={saving}
          className="btn-springy rounded-full bg-brand-navy px-5 py-2 text-sm font-semibold text-white transition-colors hover:bg-brand-navy-light disabled:opacity-40"
        >
          Declare Winner 🏆
        </button>
      </li>
    );
  }

  return (
    <div className="stagger-children flex flex-col gap-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="font-display text-3xl font-semibold text-brand-navy">
            Results
          </h1>
          <p className="mt-1 text-sm text-brand-navy/60">
            Final standings for the family scavenger hunt.
          </p>
        </div>
        <div className="flex gap-2">
          <select
            value={huntId ?? ""}
            onChange={(e) => {
              setHuntId(e.target.value);
              setShowAllFinished(false);
            }}
            className="rounded-lg border border-brand-navy/20 bg-white px-3 py-2 text-sm shadow-sm outline-none transition-shadow focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/30"
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
            className="btn-springy rounded-full bg-brand-navy px-5 py-2 text-sm font-semibold text-white transition-colors hover:bg-brand-navy-light disabled:opacity-40"
          >
            Export CSV
          </button>
        </div>
      </div>

      {/* Winner section */}
      {winner ? (
        <div className="rounded-2xl border border-brand-green/40 bg-white p-6 shadow-sm ring-2 ring-brand-green/30 transition-shadow hover:shadow-md">
          <div className="flex flex-wrap items-center justify-between gap-4">
            <div className="flex items-center gap-4">
              <span className="text-4xl" aria-hidden>
                🏆
              </span>
              <div>
                <p className="text-xs font-semibold tracking-wide text-brand-green uppercase">
                  Declared Winner
                </p>
                <h2 className="font-display text-2xl font-bold text-brand-navy">
                  {winner.team_name}
                </h2>
                <p className="mt-0.5 text-sm text-brand-navy/60">
                  {durationSeconds(winner) !== null
                    ? formatDuration(durationSeconds(winner)!)
                    : "—"}{" "}
                  · {correctLabel(winner)}
                </p>
              </div>
            </div>
            <div className="flex flex-col items-end gap-1">
              <button
                onClick={clearWinner}
                disabled={saving}
                className="text-xs font-semibold text-brand-navy/50 underline-offset-2 transition-colors hover:text-brand-navy hover:underline disabled:opacity-40"
              >
                Change or clear winner
              </button>
              <p className="text-xs text-brand-navy/40">
                Clearing lets you declare a different team.
              </p>
            </div>
          </div>
        </div>
      ) : (
        <div className="rounded-2xl border border-brand-navy/10 bg-white p-6 shadow-sm transition-shadow hover:shadow-md">
          <h2 className="font-display text-lg font-semibold text-brand-navy">
            Pick the Winner
          </h2>
          <p className="mt-1 text-sm text-brand-navy/60">
            Finishing the hunt doesn&apos;t crown a champion — you do. Teams
            below answered every question correctly, fastest first.
          </p>
          {candidates.length > 0 ? (
            <ul className="mt-4 flex flex-col gap-2">
              {candidates.map((team, i) => candidateRow(team, i === 0))}
            </ul>
          ) : (
            <div className="mt-4 flex flex-col gap-3">
              <p className="rounded-xl border border-dashed border-brand-navy/20 px-4 py-6 text-center text-sm text-brand-navy/50">
                No team has answered every question correctly yet.
              </p>
              {finished.length > 0 &&
                (showAllFinished ? (
                  <ul className="flex flex-col gap-2">
                    {finished.map((team) => candidateRow(team, false))}
                  </ul>
                ) : (
                  <button
                    onClick={() => setShowAllFinished(true)}
                    className="self-start text-sm font-semibold text-brand-cyan underline-offset-2 transition-colors hover:text-brand-navy hover:underline"
                  >
                    Show all finished teams — declare one anyway
                  </button>
                ))}
            </div>
          )}
          <p className="mt-3 text-xs text-brand-navy/50">
            The winning team&apos;s phone will celebrate the moment you
            confirm.
          </p>
        </div>
      )}

      <div className="rounded-2xl border border-brand-navy/10 bg-white p-6 shadow-sm transition-shadow hover:shadow-md">
        <h2 className="text-lg font-semibold text-brand-navy">
          Leaderboard ({finished.length} finished)
        </h2>
        <ol className="mt-4 flex flex-col gap-2">
          {finished.map((team, i) => (
            <li
              key={team.id}
              className={`flex items-center justify-between rounded-xl border px-4 transition-colors ${
                i === 0
                  ? "border-brand-green/40 bg-brand-green/5 py-4 ring-1 ring-brand-green/25"
                  : i < 3
                    ? "border-brand-cyan/30 bg-brand-cyan/5 py-3"
                    : "border-brand-navy/10 py-2 hover:bg-brand-navy/[0.02]"
              }`}
            >
              <span
                className={`flex items-center gap-2 font-medium text-brand-navy ${
                  i === 0 ? "text-lg font-bold" : i < 3 ? "font-semibold" : ""
                }`}
              >
                <span className="w-8 text-center">
                  {i < 3 ? (
                    <span className={i === 0 ? "text-2xl" : "text-xl"}>
                      {MEDALS[i]}
                    </span>
                  ) : (
                    <span className="text-sm text-brand-navy/50">{i + 1}</span>
                  )}
                </span>
                {team.team_name}
                {hunt?.winner_team_id === team.id && (
                  <span className="ml-1 rounded-full bg-brand-green px-2.5 py-0.5 text-xs font-bold tracking-wide text-white">
                    🏆 WINNER
                  </span>
                )}
              </span>
              <span className="flex items-center gap-3">
                <span className="text-xs text-brand-navy/50">
                  {correctLabel(team)}
                </span>
                <span
                  className={`font-mono ${
                    i === 0
                      ? "font-semibold text-brand-green"
                      : "text-brand-navy/70"
                  }`}
                >
                  {formatDuration(durationSeconds(team)!)}
                </span>
              </span>
            </li>
          ))}
          {finished.length === 0 && (
            <p className="rounded-xl border border-dashed border-brand-navy/20 px-4 py-6 text-center text-sm text-brand-navy/50">
              No teams have finished yet — the podium is still up for grabs.
            </p>
          )}
        </ol>
      </div>

      <div className="grid grid-cols-2 gap-4 text-sm text-brand-navy/70">
        <div className="rounded-2xl border border-brand-navy/10 bg-white p-4 shadow-sm transition-shadow hover:shadow-md">
          <p className="text-2xl font-bold text-brand-cyan">
            {inProgress.length}
          </p>
          <p className="mt-0.5 font-semibold text-brand-navy">in progress</p>
        </div>
        <div className="rounded-2xl border border-brand-navy/10 bg-white p-4 shadow-sm transition-shadow hover:shadow-md">
          <p className="text-2xl font-bold text-brand-navy/50">
            {notStarted.length}
          </p>
          <p className="mt-0.5 font-semibold text-brand-navy">not started</p>
        </div>
      </div>
    </div>
  );
}
