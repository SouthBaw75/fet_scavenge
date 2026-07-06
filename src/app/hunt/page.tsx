"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getStoredTeamId, clearStoredTeamId } from "@/lib/team-session";
import { seededShuffle } from "@/lib/shuffle";
import { SiteHeader } from "@/components/SiteHeader";
import { HuntTimer } from "@/components/HuntTimer";
import { QrScannerView } from "@/components/QrScanner";
import type { Hunt, PublicHuntItem, Team } from "@/lib/types/hunt";

type LoadState = "loading" | "no-team" | "ready" | "complete";

export default function HuntPage() {
  const router = useRouter();
  const supabase = createClient();

  const [teamId] = useState(() => getStoredTeamId());
  const [state, setState] = useState<LoadState>(teamId ? "loading" : "no-team");
  const [team, setTeam] = useState<Team | null>(null);
  const [items, setItems] = useState<PublicHuntItem[]>([]);
  const [answeredIds, setAnsweredIds] = useState<Set<string>>(new Set());
  const [textAnswer, setTextAnswer] = useState("");
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!teamId) return;
    let cancelled = false;

    async function load() {
      const { data: teamRow, error: teamError } = await supabase
        .from("teams")
        .select(
          "id, hunt_id, employee_id, team_name, created_at, started_at, finished_at",
        )
        .eq("id", teamId)
        .maybeSingle();

      if (cancelled) return;

      if (teamError || !teamRow) {
        clearStoredTeamId();
        setState("no-team");
        return;
      }

      let currentTeam = teamRow as Team;

      if (!currentTeam.started_at) {
        const { data: startedAt } = await supabase.rpc("start_hunt", {
          p_team_id: currentTeam.id,
        });
        if (cancelled) return;
        currentTeam = { ...currentTeam, started_at: startedAt as string };
      }

      const [{ data: huntRow }, { data: huntItems }, { data: progress }] =
        await Promise.all([
          supabase
            .from("hunts")
            .select("id, name, status, settings, created_at")
            .eq("id", currentTeam.hunt_id)
            .maybeSingle(),
          supabase
            .from("public_hunt_items")
            .select("id, hunt_id, order_index, type, prompt, choices, points")
            .eq("hunt_id", currentTeam.hunt_id)
            .order("order_index"),
          supabase.rpc("get_team_status", { p_team_id: currentTeam.id }),
        ]);

      if (cancelled) return;

      let orderedItems = (huntItems as PublicHuntItem[]) ?? [];
      if ((huntRow as Hunt | null)?.settings?.randomize_item_order) {
        orderedItems = seededShuffle(orderedItems, currentTeam.id);
      }

      setTeam(currentTeam);
      setItems(orderedItems);
      setAnsweredIds(
        new Set(
          ((progress as { hunt_item_id: string }[]) ?? []).map(
            (p) => p.hunt_item_id,
          ),
        ),
      );
      setState("ready");
    }

    load();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [teamId]);

  const currentItem = items.find((item) => !answeredIds.has(item.id));

  useEffect(() => {
    if (state === "ready" && items.length > 0 && !currentItem) {
      router.replace("/hunt/complete");
    }
  }, [state, items, currentItem, router]);

  async function submitAnswer(answer: string) {
    if (!team || !currentItem || submitting) return;
    setSubmitting(true);

    await supabase.rpc("submit_answer", {
      p_team_id: team.id,
      p_hunt_item_id: currentItem.id,
      p_answer: answer,
    });

    setAnsweredIds((prev) => new Set(prev).add(currentItem.id));
    setTextAnswer("");
    setSubmitting(false);
  }

  if (state === "loading") {
    return (
      <div className="flex flex-1 flex-col">
        <SiteHeader />
        <main className="flex flex-1 items-center justify-center">
          <p className="text-brand-navy/60">Loading your hunt...</p>
        </main>
      </div>
    );
  }

  if (state === "no-team") {
    return (
      <div className="flex flex-1 flex-col">
        <SiteHeader />
        <main className="flex flex-1 flex-col items-center justify-center gap-4 px-6 text-center">
          <h1 className="text-2xl font-bold text-brand-navy">
            We couldn&apos;t find your team
          </h1>
          <p className="text-brand-navy/70">
            Head back to registration to find or start your team.
          </p>
          <button
            onClick={() => router.push("/register")}
            className="rounded-full bg-brand-navy px-8 py-3 font-semibold text-white"
          >
            Register
          </button>
        </main>
      </div>
    );
  }

  if (!team || !currentItem) {
    return (
      <div className="flex flex-1 flex-col">
        <SiteHeader />
        <main className="flex flex-1 items-center justify-center">
          <p className="text-brand-navy/60">Loading your hunt...</p>
        </main>
      </div>
    );
  }

  const position = items.findIndex((i) => i.id === currentItem.id) + 1;

  return (
    <div className="flex flex-1 flex-col">
      <SiteHeader />
      <main className="mx-auto flex w-full max-w-md flex-1 flex-col gap-6 px-6 py-10">
        <div className="flex items-center justify-between">
          <span className="text-sm font-medium text-brand-navy/60">
            {team.team_name} &middot; Stop {position} of {items.length}
          </span>
          {team.started_at && <HuntTimer startedAt={team.started_at} />}
        </div>

        <div className="rounded-2xl border border-brand-navy/10 bg-white p-6 shadow-sm">
          <p className="text-xl font-semibold text-brand-navy">
            {currentItem.prompt}
          </p>

          {currentItem.type === "multiple_choice" && (
            <div className="mt-6 flex flex-col gap-3">
              {(currentItem.choices ?? []).map((choice) => (
                <button
                  key={choice}
                  disabled={submitting}
                  onClick={() => submitAnswer(choice)}
                  className="rounded-lg border border-brand-navy/20 px-4 py-3 text-left font-medium text-brand-navy transition-colors hover:border-brand-cyan hover:bg-brand-cyan/10 disabled:opacity-40"
                >
                  {choice}
                </button>
              ))}
            </div>
          )}

          {currentItem.type === "text" && (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                submitAnswer(textAnswer);
              }}
              className="mt-6 flex flex-col gap-3"
            >
              <input
                autoFocus
                value={textAnswer}
                onChange={(e) => setTextAnswer(e.target.value)}
                placeholder="Type your answer"
                className="w-full rounded-lg border border-brand-navy/20 px-4 py-3 text-lg outline-none focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/30"
              />
              <button
                type="submit"
                disabled={!textAnswer.trim() || submitting}
                className="rounded-full bg-brand-navy px-8 py-3 font-semibold text-white transition-colors hover:bg-brand-navy-light disabled:opacity-40"
              >
                Submit
              </button>
            </form>
          )}

          {currentItem.type === "qr" && (
            <div className="mt-6">
              <QrScannerView onScan={(value) => submitAnswer(value)} />
            </div>
          )}
        </div>
      </main>
    </div>
  );
}
