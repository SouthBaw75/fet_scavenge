"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Hunt, HuntStatus } from "@/lib/types/hunt";

export function HuntManager({
  selectedHuntId,
  onSelectHunt,
}: {
  selectedHuntId: string | null;
  onSelectHunt: (huntId: string) => void;
}) {
  const supabase = createClient();
  const [hunts, setHunts] = useState<Hunt[]>([]);
  const [newName, setNewName] = useState("");
  const [creating, setCreating] = useState(false);

  async function refresh() {
    const { data } = await supabase
      .from("hunts")
      .select("id, name, status, settings, created_at")
      .order("created_at", { ascending: false });
    setHunts((data as Hunt[]) ?? []);
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
    key: "randomize_item_order" | "show_leaderboard_to_teams",
    value: boolean,
  ) {
    const settings = { ...hunt.settings, [key]: value };
    await supabase.from("hunts").update({ settings }).eq("id", hunt.id);
    await refresh();
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

      <ul className="mt-4 flex flex-col gap-3">
        {hunts.map((hunt) => (
          <li
            key={hunt.id}
            className={`rounded-xl border p-4 transition-all ${
              selectedHuntId === hunt.id
                ? "border-brand-cyan bg-brand-cyan/5 shadow-sm ring-1 ring-brand-cyan/30"
                : "border-brand-navy/10 hover:border-brand-cyan/40 hover:bg-brand-cyan/[0.03]"
            }`}
          >
            <div className="flex items-center justify-between">
              <button
                onClick={() => onSelectHunt(hunt.id)}
                className="text-left font-semibold text-brand-navy transition-colors hover:text-brand-cyan"
              >
                {hunt.name}
                {hunt.status === "active" && (
                  <span className="ml-2 inline-block rounded-full bg-brand-green/10 px-2 py-0.5 align-middle text-xs font-semibold text-brand-green">
                    Live
                  </span>
                )}
              </button>
              <select
                value={hunt.status}
                onChange={(e) => setStatus(hunt, e.target.value as HuntStatus)}
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
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
