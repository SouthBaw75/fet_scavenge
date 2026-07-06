"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getStoredTeamId } from "@/lib/team-session";
import { SiteHeader } from "@/components/SiteHeader";
import { FloatingTriangles } from "@/components/FloatingTriangles";
import { playEffect } from "@/lib/sound";
import { finishConfetti } from "@/lib/celebrate";
import { Fetch } from "@/components/Fetch";
import type { Hunt, Team } from "@/lib/types/hunt";

function formatDuration(ms: number) {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}m ${seconds.toString().padStart(2, "0")}s`;
}

const MEDALS = ["🥇", "🥈", "🥉"];

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
  const [winnerTeamId, setWinnerTeamId] = useState<string | null>(null);
  const [winnerName, setWinnerName] = useState<string | null>(null);
  // Ensures the fanfare + confetti celebration only ever fires once.
  const celebratedRef = useRef(false);
  // Ensures the winner fanfare + confetti only ever fires once.
  const winnerCelebratedRef = useRef(false);

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
        .select("id, name, status, settings, created_at, winner_team_id")
        .eq("id", teamRow.hunt_id)
        .maybeSingle();

      setHunt((huntRow as Hunt) ?? null);
      setWinnerTeamId((huntRow as Hunt | null)?.winner_team_id ?? null);

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

      // Celebration! Cosmetic only — fires once when results are in.
      if (!celebratedRef.current) {
        celebratedRef.current = true;
        playEffect("questComplete");
        finishConfetti();
      }
    }

    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Live winner announcements — the admin can declare a winner at any moment
  // and the family's phone should react without a refresh.
  useEffect(() => {
    if (!hunt?.id) return;

    const channel = supabase
      .channel(`hunt-winner-${hunt.id}`)
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "hunts", filter: `id=eq.${hunt.id}` },
        (payload) => {
          const next = (payload.new as { winner_team_id?: string | null }).winner_team_id ?? null;
          setWinnerTeamId(next);
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hunt?.id]);

  // Winner celebration! Fires once if/when this team is declared the winner.
  useEffect(() => {
    if (team && winnerTeamId === team.id && !winnerCelebratedRef.current) {
      winnerCelebratedRef.current = true;
      playEffect("winnerFanfare");
      finishConfetti();
    }
  }, [winnerTeamId, team]);

  // Resolve the winning team's name for the banner shown to non-winners.
  useEffect(() => {
    if (!winnerTeamId) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- sync reset when winner is cleared (established codebase pattern)
      setWinnerName(null);
      return;
    }
    if (team && winnerTeamId === team.id) {
      setWinnerName(team.team_name);
      return;
    }

    let cancelled = false;
    supabase
      .from("teams")
      .select("team_name")
      .eq("id", winnerTeamId)
      .maybeSingle()
      .then(({ data }) => {
        if (!cancelled) setWinnerName((data?.team_name as string) ?? null);
      });

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [winnerTeamId, team]);

  if (loading || !team) {
    return (
      <div className="flex flex-1 flex-col">
        <SiteHeader />
        <main className="flex flex-1 flex-col items-center justify-center gap-3">
          <Fetch pose="thinking" width={170} />
          <p className="font-display text-lg font-semibold text-brand-navy/70">
            Tallying your results...
          </p>
        </main>
      </div>
    );
  }

  const duration =
    team.started_at && team.finished_at
      ? new Date(team.finished_at).getTime() - new Date(team.started_at).getTime()
      : null;

  const isWinner = winnerTeamId !== null && winnerTeamId === team.id;
  const showWinnerBanner = winnerTeamId !== null && !isWinner && winnerName !== null;

  return (
    <div className="flex flex-1 flex-col">
      <SiteHeader />
      <main className="flex flex-1 flex-col">
        {/* Full-bleed navy hero */}
        <section
          className={`relative overflow-hidden bg-brand-navy px-6 text-center ${
            isWinner ? "pb-16 pt-12" : "pb-14 pt-12"
          }`}
        >
          <FloatingTriangles />
          {isWinner && (
            /* Gold glow wash behind the winner announcement */
            <div
              className="pointer-events-none absolute inset-0 bg-gradient-to-b from-amber-400/20 via-transparent to-amber-400/10"
              aria-hidden
            />
          )}
          <div className="relative mx-auto flex w-full max-w-md flex-col items-center gap-4">
            <Fetch pose="yay" width={isWinner ? 250 : 230} priority className="-mb-1" />
            {isWinner ? (
              <>
                <span className="animate-pop-in rounded-full bg-amber-400/20 px-5 py-1.5 font-display text-sm font-bold tracking-widest text-amber-400 ring-2 ring-amber-400/60">
                  WINNERS ANNOUNCED
                </span>
                <h1 className="animate-pop-in font-display text-5xl font-bold leading-tight text-amber-400 drop-shadow-[0_2px_12px_rgba(251,191,36,0.45)]">
                  🏆 YOU&apos;RE THE HUNT WINNERS! 🏆
                </h1>
                <p className="font-display text-2xl font-bold text-white">
                  Champions: {team.team_name}!
                </p>
                <p className="font-display text-base font-semibold text-white/80">
                  Take a bow — you conquered the whole hunt!
                </p>
              </>
            ) : (
              <>
                <span className="rounded-full bg-brand-green/20 px-5 py-1.5 font-display text-sm font-bold tracking-widest text-brand-green">
                  HUNT COMPLETE
                </span>
                <h1 className="brand-gradient-text font-display text-5xl font-bold leading-tight">
                  YOU DID IT!
                </h1>
                <p className="font-display text-xl font-semibold text-white/90">
                  Nice work, {team.team_name}!
                </p>
              </>
            )}
            {duration !== null && (
              <div
                className={`animate-pop-in mt-2 w-full rounded-3xl border-2 px-6 py-5 shadow-xl backdrop-blur-sm ${
                  isWinner
                    ? "border-amber-400/60 bg-amber-400/10"
                    : "border-brand-cyan/40 bg-white/10"
                }`}
              >
                <p
                  className={`text-sm font-semibold uppercase tracking-widest ${
                    isWinner ? "text-amber-400" : "text-brand-cyan"
                  }`}
                >
                  Your time
                </p>
                <p className="font-display text-5xl font-bold text-white">
                  {formatDuration(duration)}
                </p>
              </div>
            )}
          </div>
        </section>

        <div className="mx-auto flex w-full max-w-md flex-1 flex-col items-center gap-8 px-6 py-10 text-center">
          {showWinnerBanner && (
            <div className="animate-pop-in w-full rounded-3xl border-2 border-amber-400/50 bg-amber-50 px-6 py-4 shadow-xl shadow-brand-navy/5">
              <p className="font-display text-lg font-bold text-brand-navy">
                🏆 Hunt Winner: {winnerName}
              </p>
              <p className="text-sm font-semibold text-brand-navy/60">
                Congrats to them — and great hunting, {team.team_name}!
              </p>
            </div>
          )}

          {leaderboard && leaderboard.length > 0 && (
            <div className="animate-slide-up w-full rounded-3xl border-2 border-brand-navy/10 bg-white p-6 text-left shadow-xl shadow-brand-navy/5">
              <h2 className="mb-4 text-center font-display text-2xl font-bold text-brand-navy">
                Leaderboard 🏅
              </h2>
              <ol className="stagger-children flex flex-col gap-2">
                {leaderboard.map((row, i) => {
                  const isYou = row.team_name === team.team_name;
                  const isHuntWinner = winnerName !== null && row.team_name === winnerName;
                  return (
                    <li
                      key={row.team_name + i}
                      className={`flex min-h-12 items-center justify-between gap-2 rounded-2xl px-3 py-2 ${
                        isYou
                          ? "bg-brand-cyan/10 font-semibold ring-2 ring-brand-cyan"
                          : "bg-brand-navy/[0.03]"
                      }`}
                    >
                      <span className="flex min-w-0 items-center gap-2 text-brand-navy">
                        <span
                          className="w-8 shrink-0 text-center font-display text-lg font-bold"
                          aria-hidden
                        >
                          {MEDALS[i] ?? i + 1}
                        </span>
                        <span className="truncate">{row.team_name}</span>
                        {isHuntWinner && (
                          <span className="shrink-0" title="Hunt winner" aria-label="Hunt winner">
                            🏆
                          </span>
                        )}
                        {isYou && (
                          <span className="shrink-0 rounded-full bg-brand-cyan px-2 py-0.5 font-display text-xs font-bold text-brand-navy">
                            That&apos;s you!
                          </span>
                        )}
                      </span>
                      <span className="shrink-0 font-mono text-brand-navy/70">
                        {formatDuration(row.duration_ms)}
                      </span>
                    </li>
                  );
                })}
              </ol>
            </div>
          )}

          {hunt && !hunt.settings?.show_leaderboard_to_teams && (
            <p className="animate-slide-up font-display text-base font-semibold text-brand-navy/60">
              Ask an FET volunteer for the final results! 🎉
            </p>
          )}
        </div>
      </main>
    </div>
  );
}
