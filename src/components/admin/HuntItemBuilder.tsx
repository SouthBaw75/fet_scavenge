"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { HuntItem, HuntItemType } from "@/lib/types/hunt";

const EMPTY_FORM = {
  type: "multiple_choice" as HuntItemType,
  prompt: "",
  choicesText: "",
  correct_answer: "",
  qr_value: "",
  points: 1,
};

export function HuntItemBuilder({ huntId }: { huntId: string }) {
  const supabase = createClient();
  const [items, setItems] = useState<HuntItem[]>([]);
  const [form, setForm] = useState(EMPTY_FORM);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  async function refresh() {
    const { data } = await supabase
      .from("hunt_items")
      .select("*")
      .eq("hunt_id", huntId)
      .order("order_index");
    setItems((data as HuntItem[]) ?? []);
  }

  useEffect(() => {
    /* eslint-disable react-hooks/set-state-in-effect -- reset + fetch when the selected hunt changes */
    refresh();
    setForm(EMPTY_FORM);
    setEditingId(null);
    /* eslint-enable react-hooks/set-state-in-effect */
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [huntId]);

  function startEdit(item: HuntItem) {
    setEditingId(item.id);
    setForm({
      type: item.type,
      prompt: item.prompt,
      choicesText: (item.choices ?? []).join(", "),
      correct_answer: item.correct_answer ?? "",
      qr_value: item.qr_value ?? "",
      points: item.points,
    });
  }

  function cancelEdit() {
    setEditingId(null);
    setForm(EMPTY_FORM);
  }

  async function save() {
    if (!form.prompt.trim()) return;
    setSaving(true);

    const payload = {
      hunt_id: huntId,
      type: form.type,
      prompt: form.prompt.trim(),
      choices:
        form.type === "multiple_choice"
          ? form.choicesText
              .split(",")
              .map((c) => c.trim())
              .filter(Boolean)
          : null,
      correct_answer: form.type === "qr" ? null : form.correct_answer.trim(),
      qr_value: form.type === "qr" ? form.qr_value.trim() : null,
      points: form.points,
    };

    if (editingId) {
      await supabase.from("hunt_items").update(payload).eq("id", editingId);
    } else {
      const nextOrder =
        items.length > 0
          ? Math.max(...items.map((i) => i.order_index)) + 1
          : 1;
      await supabase
        .from("hunt_items")
        .insert({ ...payload, order_index: nextOrder });
    }

    setSaving(false);
    cancelEdit();
    await refresh();
  }

  async function remove(item: HuntItem) {
    await supabase.from("hunt_items").delete().eq("id", item.id);
    await refresh();
  }

  async function move(item: HuntItem, direction: -1 | 1) {
    const index = items.findIndex((i) => i.id === item.id);
    const swapWith = items[index + direction];
    if (!swapWith) return;

    await Promise.all([
      supabase
        .from("hunt_items")
        .update({ order_index: swapWith.order_index })
        .eq("id", item.id),
      supabase
        .from("hunt_items")
        .update({ order_index: item.order_index })
        .eq("id", swapWith.id),
    ]);
    await refresh();
  }

  return (
    <div className="rounded-2xl border border-brand-navy/10 bg-white p-6 shadow-sm">
      <h2 className="text-lg font-semibold text-brand-navy">Hunt Items</h2>

      <ul className="mt-4 flex flex-col gap-2">
        {items.map((item, i) => (
          <li
            key={item.id}
            className="flex items-center justify-between rounded-lg border border-brand-navy/10 px-4 py-3"
          >
            <div>
              <span className="text-xs font-semibold uppercase tracking-wide text-brand-cyan">
                {item.type.replace("_", " ")}
              </span>
              <p className="font-medium text-brand-navy">{item.prompt}</p>
            </div>
            <div className="flex items-center gap-2">
              <button
                onClick={() => move(item, -1)}
                disabled={i === 0}
                className="text-brand-navy/50 disabled:opacity-30"
                aria-label="Move up"
              >
                ↑
              </button>
              <button
                onClick={() => move(item, 1)}
                disabled={i === items.length - 1}
                className="text-brand-navy/50 disabled:opacity-30"
                aria-label="Move down"
              >
                ↓
              </button>
              <button
                onClick={() => startEdit(item)}
                className="text-sm font-medium text-brand-navy underline"
              >
                Edit
              </button>
              <button
                onClick={() => remove(item)}
                className="text-sm font-medium text-red-600 underline"
              >
                Delete
              </button>
            </div>
          </li>
        ))}
        {items.length === 0 && (
          <p className="text-sm text-brand-navy/50">No items yet.</p>
        )}
      </ul>

      <div className="mt-6 border-t border-brand-navy/10 pt-6">
        <h3 className="font-semibold text-brand-navy">
          {editingId ? "Edit Item" : "Add Item"}
        </h3>
        <div className="mt-3 flex flex-col gap-3">
          <select
            value={form.type}
            onChange={(e) =>
              setForm({ ...form, type: e.target.value as HuntItemType })
            }
            className="rounded-lg border border-brand-navy/20 px-3 py-2 text-sm"
          >
            <option value="multiple_choice">Multiple Choice</option>
            <option value="qr">QR Scan</option>
            <option value="text">Typed Answer</option>
          </select>

          <textarea
            value={form.prompt}
            onChange={(e) => setForm({ ...form, prompt: e.target.value })}
            placeholder="Question / clue prompt"
            rows={2}
            className="rounded-lg border border-brand-navy/20 px-3 py-2 text-sm"
          />

          {form.type === "multiple_choice" && (
            <>
              <input
                value={form.choicesText}
                onChange={(e) =>
                  setForm({ ...form, choicesText: e.target.value })
                }
                placeholder="Choices, comma separated"
                className="rounded-lg border border-brand-navy/20 px-3 py-2 text-sm"
              />
              <input
                value={form.correct_answer}
                onChange={(e) =>
                  setForm({ ...form, correct_answer: e.target.value })
                }
                placeholder="Correct choice (must match one exactly)"
                className="rounded-lg border border-brand-navy/20 px-3 py-2 text-sm"
              />
            </>
          )}

          {form.type === "text" && (
            <input
              value={form.correct_answer}
              onChange={(e) =>
                setForm({ ...form, correct_answer: e.target.value })
              }
              placeholder="Correct answer (case/whitespace insensitive)"
              className="rounded-lg border border-brand-navy/20 px-3 py-2 text-sm"
            />
          )}

          {form.type === "qr" && (
            <input
              value={form.qr_value}
              onChange={(e) => setForm({ ...form, qr_value: e.target.value })}
              placeholder="Value encoded in the physical QR code"
              className="rounded-lg border border-brand-navy/20 px-3 py-2 text-sm"
            />
          )}

          <input
            type="number"
            min={1}
            value={form.points}
            onChange={(e) =>
              setForm({ ...form, points: Number(e.target.value) })
            }
            placeholder="Points"
            className="w-24 rounded-lg border border-brand-navy/20 px-3 py-2 text-sm"
          />

          <div className="flex gap-2">
            <button
              onClick={save}
              disabled={!form.prompt.trim() || saving}
              className="rounded-full bg-brand-navy px-5 py-2 text-sm font-semibold text-white disabled:opacity-40"
            >
              {editingId ? "Save Changes" : "Add Item"}
            </button>
            {editingId && (
              <button
                onClick={cancelEdit}
                className="rounded-full border border-brand-navy/20 px-5 py-2 text-sm font-semibold text-brand-navy"
              >
                Cancel
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
