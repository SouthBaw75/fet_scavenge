"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getStoredTeamId } from "@/lib/team-session";
import { SiteHeader } from "@/components/SiteHeader";
import type { Hunt, Team } from "@/lib/types/hunt";

function formatDuration(ms: number) {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}m ${seconds.toString().padStart(2, "0")}s`;
}

interface LeaderboardRow {
  team_name: string;
  duration_ms: number;
}

export default function HuntCompletePage() {
  const router = useRouter();
  const supabase = createClient();

  const [team, setTeam] = useState<Team | null>(null);
  const [hunt, setHunt] = useState<Hunt | null>(null);
  const [leaderboard, setLeaderboard] = useState<LeaderboardRow[] | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      const teamId = getStoredTeamId();
      if (!teamId) {
        router.replace("/register");
        return;
      }

      const { data: teamRow } = await supabase
        .from("teams")
        .select("id, hunt_id, employee_id, team_name, created_at, started_at, finished_at")
        .eq("id", teamId)
        .maybeSingle();

      if (!teamRow) {
        router.replace("/register");
        return;
      }

      setTeam(teamRow as Team);

      const { data: huntRow } = await supabase
        .from("hunts")
        .select("id, name, status, settings, created_at")
        .eq("id", teamRow.hunt_id)
        .maybeSingle();

      setHunt((huntRow as Hunt) ?? null);

      if (huntRow?.settings?.show_leaderboard_to_teams) {
        const { data: finishedTeams } = await supabase
          .from("teams")
          .select("team_name, started_at, finished_at")
          .eq("hunt_id", teamRow.hunt_id)
          .not("finished_at", "is", null);

        const rows = (finishedTeams ?? [])
          .map((t) => ({
            team_name: t.team_name as string,
            duration_ms:
              new Date(t.finished_at as string).getTime() -
              new Date(t.started_at as string).getTime(),
          }))
          .sort((a, b) => a.duration_ms - b.duration_ms);

        setLeaderboard(rows);
      }

      setLoading(false);
    }

    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (loading || !team) {
    return (
      <div className="flex flex-1 flex-col">
        <SiteHeader />
        <main className="flex flex-1 items-center justify-center">
          <p className="text-brand-navy/60">Loading...</p>
        </main>
      </div>
    );
  }

  const duration =
    team.started_at && team.finished_at
      ? new Date(team.finished_at).getTime() - new Date(team.started_at).getTime()
      : null;

  return (
    <div className="flex flex-1 flex-col">
      <SiteHeader />
      <main className="mx-auto flex w-full max-w-md flex-1 flex-col items-center gap-8 px-6 py-16 text-center">
        <div>
          <span className="rounded-full bg-brand-green/10 px-4 py-1 text-sm font-semibold tracking-wide text-brand-green">
            HUNT COMPLETE
          </span>
          <h1 className="mt-3 text-3xl font-bold text-brand-navy">
            Nice work, {team.team_name}!
          </h1>
          {duration !== null && (
            <p className="mt-2 text-lg text-brand-navy/70">
              Your time: <span className="font-semibold">{formatDuration(duration)}</span>
            </p>
          )}
        </div>

        {leaderboard && leaderboard.length > 0 && (
          <div className="w-full rounded-2xl border border-brand-navy/10 bg-white p-6 text-left shadow-sm">
            <h2 className="mb-4 text-center text-lg font-semibold text-brand-navy">
              Leaderboard
            </h2>
            <ol className="flex flex-col gap-2">
              {leaderboard.map((row, i) => (
                <li
                  key={row.team_name + i}
                  className={`flex items-center justify-between rounded-lg px-3 py-2 ${
                    row.team_name === team.team_name
                      ? "bg-brand-cyan/10 font-semibold"
                      : ""
                  }`}
                >
                  <span className="text-brand-navy">
                    {i + 1}. {row.team_name}
                  </span>
                  <span className="font-mono text-brand-navy/70">
                    {formatDuration(row.duration_ms)}
                  </span>
                </li>
              ))}
            </ol>
          </div>
        )}

        {hunt && !hunt.settings?.show_leaderboard_to_teams && (
          <p className="text-sm text-brand-navy/50">
            Ask an FET volunteer for the final results!
          </p>
        )}
      </main>
    </div>
  );
}
