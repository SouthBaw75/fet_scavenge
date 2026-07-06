"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getStoredTeamId, clearStoredTeamId } from "@/lib/team-session";
import { seededShuffle } from "@/lib/shuffle";
import { SiteHeader } from "@/components/SiteHeader";
import { HuntTimer } from "@/components/HuntTimer";
import { QrScannerView } from "@/components/QrScanner";
import { playTap, playEffect } from "@/lib/sound";
import { burstConfetti } from "@/lib/celebrate";
import { Fetch } from "@/components/Fetch";
import type { Hunt, PublicHuntItem, Team } from "@/lib/types/hunt";

type LoadState = "loading" | "no-team" | "ready" | "complete";

const CHOICE_LETTERS = ["A", "B", "C", "D", "E", "F"];

export default function HuntPage() {
  const router = useRouter();
  const supabase = createClient();

  const [state, setState] = useState<LoadState>("loading");
  const [team, setTeam] = useState<Team | null>(null);
  const [items, setItems] = useState<PublicHuntItem[]>([]);
  const [answeredIds, setAnsweredIds] = useState<Set<string>>(new Set());
  const [textAnswer, setTextAnswer] = useState("");
  const [submitting, setSubmitting] = useState(false);
  // When a scanned QR stop has a reveal message, hold it here and pause on a
  // "You found it!" card until the team taps Continue.
  const [reveal, setReveal] = useState<{ message: string; itemId: string } | null>(
    null,
  );

  useEffect(() => {
    // localStorage is only readable on the client, so the session lookup has
    // to happen here rather than in a state initializer (which would make the
    // server-rendered HTML disagree with the client and break hydration).
    const teamId = getStoredTeamId();
    if (!teamId) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- syncing from localStorage, an external system
      setState("no-team");
      return;
    }
    let cancelled = false;

    async function load(teamId: string) {
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
            .select(
              "id, hunt_id, order_index, type, prompt, choices, points, reveal_message, image_url",
            )
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

    load(teamId);
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const currentItem = items.find((item) => !answeredIds.has(item.id));

  useEffect(() => {
    if (state === "ready" && items.length > 0 && !currentItem) {
      router.replace("/hunt/complete");
    }
  }, [state, items, currentItem, router]);

  async function submitAnswer(answer: string) {
    if (!team || !currentItem || submitting) return;
    setSubmitting(true);
    playEffect("submit");

    await supabase.rpc("submit_answer", {
      p_team_id: team.id,
      p_hunt_item_id: currentItem.id,
      p_answer: answer,
    });

    burstConfetti();
    setTextAnswer("");
    setSubmitting(false);

    // For a QR stop with a reveal message, pause on the message before
    // advancing. Otherwise mark answered immediately (moves to the next stop).
    if (currentItem.type === "qr" && currentItem.reveal_message) {
      setReveal({ message: currentItem.reveal_message, itemId: currentItem.id });
    } else {
      setAnsweredIds((prev) => new Set(prev).add(currentItem.id));
    }
  }

  function dismissReveal() {
    if (!reveal) return;
    setAnsweredIds((prev) => new Set(prev).add(reveal.itemId));
    setReveal(null);
  }

  if (state === "loading") {
    return (
      <div className="flex flex-1 flex-col">
        <SiteHeader />
        <main className="flex flex-1 flex-col items-center justify-center gap-3">
          <Fetch pose="thinking" width={170} />
          <p className="font-display text-lg font-semibold text-brand-navy/70">
            Loading your hunt...
          </p>
        </main>
      </div>
    );
  }

  if (state === "no-team") {
    return (
      <div className="flex flex-1 flex-col">
        <SiteHeader />
        <main className="flex flex-1 flex-col items-center justify-center gap-4 px-6 text-center">
          <Fetch pose="confused" width={200} />
          <h1 className="font-display text-3xl font-bold text-brand-navy">
            We couldn&apos;t find your team
          </h1>
          <p className="text-lg text-brand-navy/70">
            Head back to registration to find or start your team.
          </p>
          <button
            onClick={() => router.push("/register")}
            className="btn-springy h-14 rounded-full bg-brand-navy px-10 font-display text-lg font-bold text-white shadow-lg"
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
        <main className="flex flex-1 flex-col items-center justify-center gap-3">
          <Fetch pose="thinking" width={170} />
          <p className="font-display text-lg font-semibold text-brand-navy/70">
            Loading your hunt...
          </p>
        </main>
      </div>
    );
  }

  const position = items.findIndex((i) => i.id === currentItem.id) + 1;
  const progressPct = Math.round(((position - 1) / items.length) * 100);

  return (
    <div className="flex flex-1 flex-col">
      <SiteHeader />
      <main className="mx-auto flex w-full max-w-md flex-1 flex-col gap-5 px-5 py-8">
        <div className="flex items-center justify-between gap-3">
          <div className="min-w-0">
            <p className="truncate text-sm font-semibold text-brand-navy/60">
              {team.team_name}
            </p>
            <p className="font-display text-2xl font-bold text-brand-navy">
              Stop {position}{" "}
              <span className="text-brand-navy/40">of {items.length}</span>
            </p>
          </div>
          {team.started_at && <HuntTimer startedAt={team.started_at} />}
        </div>

        {/* Level progress bar */}
        <div
          className="h-4 w-full overflow-hidden rounded-full bg-brand-navy/10"
          role="progressbar"
          aria-valuemin={0}
          aria-valuemax={items.length}
          aria-valuenow={position - 1}
          aria-label={`${position - 1} of ${items.length} stops complete`}
        >
          <div
            className="h-full rounded-full bg-gradient-to-r from-brand-cyan to-brand-green"
            style={{
              width: `${Math.max(progressPct, 4)}%`,
              transition: "width 600ms cubic-bezier(0.34, 1.56, 0.64, 1)",
            }}
          />
        </div>

        {reveal ? (
          <div className="animate-pop-in">
            <div className="relative z-10 -mb-10 flex justify-center">
              <Fetch pose="celebrate" width={180} />
            </div>
            <div className="rounded-3xl border-2 border-brand-green/40 bg-white p-6 pt-14 text-center shadow-xl shadow-brand-navy/5">
            <h2 className="mt-2 font-display text-2xl font-bold text-brand-green">
              You found it!
            </h2>
            <p className="mt-3 text-lg leading-relaxed text-brand-navy">
              {reveal.message}
            </p>
            <button
              onClick={dismissReveal}
              className="btn-springy mt-6 h-14 w-full rounded-full bg-brand-navy font-display text-lg font-bold text-white shadow-lg"
            >
              Next Stop →
            </button>
            </div>
          </div>
        ) : (
        <div
          key={currentItem.id}
          className="animate-pop-in rounded-3xl border-2 border-brand-navy/10 bg-white p-6 shadow-xl shadow-brand-navy/5"
        >
          {currentItem.image_url && (
            // eslint-disable-next-line @next/next/no-img-element -- external Supabase Storage URL, no build-time optimization needed
            <img
              src={currentItem.image_url}
              alt="Take a look and answer the question below"
              className="mb-4 max-h-64 w-full rounded-2xl object-cover"
            />
          )}

          <p className="font-display text-2xl font-bold leading-snug text-brand-navy">
            {currentItem.prompt}
          </p>

          {currentItem.type === "multiple_choice" && (
            <div className="stagger-children mt-6 flex flex-col gap-3">
              {(currentItem.choices ?? []).map((choice, idx) => (
                <button
                  key={choice}
                  disabled={submitting}
                  onClick={() => {
                    playTap();
                    submitAnswer(choice);
                  }}
                  className="btn-springy flex min-h-14 items-center gap-3 rounded-2xl border-2 border-brand-navy/15 bg-white px-4 py-3 text-left text-lg font-semibold text-brand-navy shadow-sm transition-colors hover:border-brand-cyan hover:bg-brand-cyan/10 disabled:opacity-40"
                >
                  <span
                    className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-brand-navy font-display text-base font-bold text-white"
                    aria-hidden
                  >
                    {CHOICE_LETTERS[idx] ?? "?"}
                  </span>
                  <span>{choice}</span>
                </button>
              ))}
              {submitting && (
                <p className="animate-pulse text-center font-display font-bold text-brand-green">
                  Locking it in... 🔒
                </p>
              )}
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
                className="h-14 w-full rounded-2xl border-2 border-brand-navy/15 px-5 text-lg font-semibold text-brand-navy outline-none focus:border-brand-cyan focus:ring-4 focus:ring-brand-cyan/25"
              />
              <button
                type="submit"
                disabled={!textAnswer.trim() || submitting}
                className="btn-springy h-14 rounded-full bg-brand-navy px-8 font-display text-lg font-bold text-white shadow-lg transition-colors hover:bg-brand-navy-light disabled:opacity-40"
              >
                {submitting ? "Locking it in... 🔒" : "Submit 🚀"}
              </button>
            </form>
          )}

          {currentItem.type === "qr" && (
            <div className="mt-6">
              {/* key forces a fresh scanner per item so consecutive QR stops
                  never reuse a stale scanner instance */}
              <QrScannerView
                key={currentItem.id}
                onScan={(value) => submitAnswer(value)}
              />
              {submitting && (
                <p className="mt-3 animate-pulse text-center font-display font-bold text-brand-green">
                  Locking it in... 🔒
                </p>
              )}
            </div>
          )}
        </div>
        )}
      </main>
    </div>
  );
}
