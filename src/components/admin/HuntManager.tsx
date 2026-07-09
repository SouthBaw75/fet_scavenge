"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Hunt, HuntStatus } from "@/lib/types/hunt";

const STATUS_BADGE_STYLES: Record<HuntStatus, string> = {
  active: "bg-brand-green/10 text-brand-green",
  draft: "bg-brand-navy/10 text-brand-navy/70",
  closed: "bg-brand-navy/5 text-brand-navy/40",
};

const STATUS_LABELS: Record<HuntStatus, string> = {
  active: "Live",
  draft: "Draft",
  closed: "Closed",
};

interface HuntCounts {
  items: number;
  teams: number;
}

export function HuntManager({
  selectedHuntId,
  onSelectHunt,
}: {
  selectedHuntId: string | null;
  onSelectHunt: (huntId: string) => void;
}) {
  const supabase = createClient();
  const [hunts, setHunts] = useState<Hunt[]>([]);
  const [counts, setCounts] = useState<Record<string, HuntCounts>>({});
  const [newName, setNewName] = useState("");
  const [creating, setCreating] = useState(false);
  const [resettingId, setResettingId] = useState<string | null>(null);
  const [resetMessage, setResetMessage] = useState<string | null>(null);
  const [showClosed, setShowClosed] = useState(false);

  async function refresh() {
    const { data } = await supabase
      .from("hunts")
      .select("id, name, status, settings, created_at, winner_team_id")
      .order("created_at", { ascending: false });
    const huntsList = (data as Hunt[]) ?? [];
    setHunts(huntsList);

    const pairs = await Promise.all(
      huntsList.map(async (hunt) => {
        const [{ count: items }, { count: teams }] = await Promise.all([
          supabase
            .from("hunt_items")
            .select("id", { count: "exact", head: true })
            .eq("hunt_id", hunt.id),
          supabase
            .from("teams")
            .select("id", { count: "exact", head: true })
            .eq("hunt_id", hunt.id),
        ]);
        return [hunt.id, { items: items ?? 0, teams: teams ?? 0 }] as const;
      }),
    );
    setCounts(Object.fromEntries(pairs));
  }

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial fetch on mount
    refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function createHunt() {
    if (!newName.trim()) return;
    setCreating(true);
    const { data } = await supabase
      .from("hunts")
      .insert({ name: newName.trim(), status: "draft", settings: {} })
      .select("id")
      .single();
    setNewName("");
    setCreating(false);
    await refresh();
    if (data) onSelectHunt(data.id);
  }

  async function setStatus(hunt: Hunt, status: HuntStatus) {
    if (status === "active") {
      await supabase
        .from("hunts")
        .update({ status: "closed" })
        .eq("status", "active");
    }
    await supabase.from("hunts").update({ status }).eq("id", hunt.id);
    await refresh();
  }

  async function updateSetting(
    hunt: Hunt,
    key:
      | "randomize_item_order"
      | "show_leaderboard_to_teams"
      | "show_immediate_feedback",
    value: boolean,
  ) {
    const settings = { ...hunt.settings, [key]: value };
    await supabase.from("hunts").update({ settings }).eq("id", hunt.id);
    await refresh();
  }

  // Deletes every team registered for the hunt; team_progress rows cascade.
  // Questions, settings, and the employee list are untouched.
  async function resetHunt(hunt: Hunt) {
    setResetMessage(null);

    const teamCount = counts[hunt.id]?.teams ?? 0;
    if (teamCount === 0) {
      setResetMessage(`"${hunt.name}" has no teams to reset.`);
      return;
    }

    const typed = window.prompt(
      `⚠️ Reset "${hunt.name}"?\n\n` +
        `This permanently deletes ${teamCount} team${teamCount === 1 ? "" : "s"} ` +
        `and ALL of their answers and times. Questions and settings are kept.\n\n` +
        `This cannot be undone. Type RESET to confirm:`,
    );
    if (typed?.trim().toUpperCase() !== "RESET") return;

    setResettingId(hunt.id);
    const { error } = await supabase
      .from("teams")
      .delete()
      .eq("hunt_id", hunt.id);
    setResettingId(null);

    setResetMessage(
      error
        ? `Reset failed: ${error.message}`
        : `"${hunt.name}" reset — ${teamCount} team${teamCount === 1 ? "" : "s"} and all progress deleted.`,
    );
    await refresh();
  }

  const activeHunts = hunts.filter((h) => h.status === "active");
  const draftHunts = hunts.filter((h) => h.status === "draft");
  const closedHunts = hunts.filter((h) => h.status === "closed");

  function renderHunt(hunt: Hunt) {
    const isSelected = selectedHuntId === hunt.id;
    const huntCounts = counts[hunt.id];

    return (
      <li
        key={hunt.id}
        className={`rounded-xl border transition-all ${
          isSelected
            ? "border-brand-cyan bg-brand-cyan/5 shadow-sm ring-1 ring-brand-cyan/30"
            : "border-brand-navy/10 hover:border-brand-cyan/40 hover:bg-brand-cyan/[0.03]"
        }`}
      >
        <button
          onClick={() => onSelectHunt(hunt.id)}
          className="flex w-full items-center justify-between gap-3 px-4 py-3 text-left"
        >
          <span className="flex min-w-0 items-center gap-2">
            <span className="truncate font-semibold text-brand-navy">
              {hunt.name}
            </span>
            <span
              className={`inline-block shrink-0 rounded-full px-2 py-0.5 text-xs font-semibold ${STATUS_BADGE_STYLES[hunt.status]}`}
            >
              {STATUS_LABELS[hunt.status]}
            </span>
          </span>
          <span className="shrink-0 text-xs text-brand-navy/50">
            {huntCounts ? (
              <>
                {huntCounts.items} item{huntCounts.items === 1 ? "" : "s"} ·{" "}
                {huntCounts.teams} team{huntCounts.teams === 1 ? "" : "s"}
              </>
            ) : (
              "…"
            )}
          </span>
        </button>

        {isSelected && (
          <div className="animate-slide-up border-t border-brand-navy/10 px-4 pb-4 pt-3">
            <div className="flex items-center justify-between gap-3">
              <label className="text-xs font-semibold uppercase tracking-wide text-brand-navy/50">
                Status
              </label>
              <select
                value={hunt.status}
                onChange={(e) =>
                  setStatus(hunt, e.target.value as HuntStatus)
                }
                className="rounded-md border border-brand-navy/20 px-2 py-1 text-sm"
              >
                <option value="draft">Draft</option>
                <option value="active">Active</option>
                <option value="closed">Closed</option>
              </select>
            </div>

            <div className="mt-3 flex flex-col gap-2 text-sm text-brand-navy/70">
              <label className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={!!hunt.settings.randomize_item_order}
                  onChange={(e) =>
                    updateSetting(
                      hunt,
                      "randomize_item_order",
                      e.target.checked,
                    )
                  }
                />
                Randomize item order per team
              </label>
              <label className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={!!hunt.settings.show_leaderboard_to_teams}
                  onChange={(e) =>
                    updateSetting(
                      hunt,
                      "show_leaderboard_to_teams",
                      e.target.checked,
                    )
                  }
                />
                Show leaderboard to teams after they finish
              </label>
              <label className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={!!hunt.settings.show_immediate_feedback}
                  onChange={(e) =>
                    updateSetting(
                      hunt,
                      "show_immediate_feedback",
                      e.target.checked,
                    )
                  }
                />
                Show CORRECT!/INCORRECT right after each answer (off = reveal
                only at the end)
              </label>
            </div>

            <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-brand-navy/10 pt-3">
              <a
                href={`/admin/print-portal?hunt=${hunt.id}`}
                target="_blank"
                rel="noopener noreferrer"
                className="rounded-full border border-brand-navy/20 px-4 py-1.5 text-xs font-semibold text-brand-navy transition-colors hover:bg-brand-navy/5"
              >
                🎫 Print join poster
              </a>
              <button
                onClick={() => resetHunt(hunt)}
                disabled={resettingId === hunt.id}
                className="rounded-full border border-red-200 px-4 py-1.5 text-xs font-semibold text-red-600 transition-colors hover:bg-red-50 disabled:opacity-40"
              >
                {resettingId === hunt.id
                  ? "Resetting..."
                  : "↺ Reset hunt (delete all teams & progress)"}
              </button>
            </div>
          </div>
        )}
      </li>
    );
  }

  return (
    <div className="rounded-2xl border border-brand-navy/10 bg-white p-6 shadow-sm transition-shadow hover:shadow-md">
      <h2 className="text-lg font-semibold text-brand-navy">Hunts</h2>

      <div className="mt-4 flex gap-2">
        <input
          value={newName}
          onChange={(e) => setNewName(e.target.value)}
          placeholder="New hunt name, e.g. 2026 Family Fun Day"
          className="flex-1 rounded-lg border border-brand-navy/20 px-3 py-2 text-sm outline-none focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/30"
        />
        <button
          onClick={createHunt}
          disabled={!newName.trim() || creating}
          className="btn-springy rounded-full bg-brand-navy px-5 py-2 text-sm font-semibold text-white transition-colors hover:bg-brand-navy-light disabled:opacity-40"
        >
          Create
        </button>
      </div>

      {activeHunts.length > 0 && (
        <ul className="mt-4 flex flex-col gap-2">
          {activeHunts.map(renderHunt)}
        </ul>
      )}

      {draftHunts.length > 0 && (
        <ul className="mt-2 flex flex-col gap-2">
          {draftHunts.map(renderHunt)}
        </ul>
      )}

      {hunts.length === 0 && (
        <p className="mt-4 text-sm text-brand-navy/50">
          No hunts yet. Create one above.
        </p>
      )}

      {closedHunts.length > 0 && (
        <div className="mt-4 border-t border-brand-navy/10 pt-3">
          <button
            onClick={() => setShowClosed((s) => !s)}
            className="text-sm font-semibold text-brand-navy/60 hover:text-brand-navy"
          >
            {showClosed ? "▾" : "▸"} Closed hunts ({closedHunts.length})
          </button>
          {showClosed && (
            <ul className="mt-2 flex flex-col gap-2">
              {closedHunts.map(renderHunt)}
            </ul>
          )}
        </div>
      )}

      {resetMessage && (
        <p
          className={`mt-4 rounded-lg px-4 py-2 text-sm font-medium ${
            resetMessage.startsWith("Reset failed")
              ? "bg-red-50 text-red-600"
              : "bg-brand-green/10 text-brand-green"
          }`}
        >
          {resetMessage}
        </p>
      )}
    </div>
  );
}
