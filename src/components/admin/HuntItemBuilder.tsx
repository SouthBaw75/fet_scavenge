"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { optimizeImage } from "@/lib/optimize-image";
import { QrImage } from "./QrImage";
import { HuntItemImport } from "./HuntItemImport";
import type { HuntItem, HuntItemType } from "@/lib/types/hunt";

const TYPE_BADGE_STYLES: Record<HuntItemType, string> = {
  multiple_choice: "bg-brand-cyan/10 text-brand-cyan",
  qr: "bg-brand-navy/10 text-brand-navy",
  text: "bg-brand-green/10 text-brand-green",
  open: "bg-amber-100 text-amber-700",
};

// One source of truth for how each item type looks and reads across the
// picker, the item list, and the colored edge. Keeps the four types visually
// distinct so the admin can scan a hunt at a glance.
const TYPE_META: Record<
  HuntItemType,
  { label: string; icon: string; blurb: string; edge: string; picker: string }
> = {
  multiple_choice: {
    label: "Multiple Choice",
    icon: "🔘",
    blurb: "Tap A/B/C/D. One correct answer.",
    edge: "border-l-brand-cyan",
    picker:
      "border-brand-cyan bg-brand-cyan/10 text-brand-navy ring-2 ring-brand-cyan/40",
  },
  text: {
    label: "Typed Answer",
    icon: "⌨️",
    blurb: "Family types a specific correct answer.",
    edge: "border-l-brand-green",
    picker:
      "border-brand-green bg-brand-green/10 text-brand-navy ring-2 ring-brand-green/40",
  },
  qr: {
    label: "QR Scan",
    icon: "📷",
    blurb: "Scan a printed code posted at a spot.",
    edge: "border-l-brand-navy",
    picker:
      "border-brand-navy bg-brand-navy/10 text-brand-navy ring-2 ring-brand-navy/30",
  },
  open: {
    label: "Open Response",
    icon: "✏️",
    blurb: "Any answer counts. No right or wrong.",
    edge: "border-l-amber-400",
    picker:
      "border-amber-400 bg-amber-100 text-amber-800 ring-2 ring-amber-300",
  },
};

const TYPE_ORDER: HuntItemType[] = ["multiple_choice", "text", "qr", "open"];

const EMPTY_FORM = {
  type: "multiple_choice" as HuntItemType,
  prompt: "",
  choicesText: "",
  correct_answer: "",
  qr_value: "",
  reveal_message: "",
  image_url: "",
  points: 1,
};

// Cap on the ORIGINAL file the admin picks. It gets downscaled + re-encoded to
// WebP before upload, so the stored/served file is far smaller than this.
const MAX_IMAGE_BYTES = 25 * 1024 * 1024;

// Generates a unique, hard-to-guess value to encode in a printed QR code.
function generateQrValue() {
  const rand = Math.random().toString(36).slice(2, 8).toUpperCase();
  return `FET-${rand}`;
}

export function HuntItemBuilder({ huntId }: { huntId: string }) {
  const supabase = createClient();
  const [items, setItems] = useState<HuntItem[]>([]);
  const [form, setForm] = useState(EMPTY_FORM);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [uploadingImage, setUploadingImage] = useState(false);
  const [imageError, setImageError] = useState<string | null>(null);

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
      reveal_message: item.reveal_message ?? "",
      image_url: item.image_url ?? "",
      points: item.points,
    });
    setImageError(null);
  }

  function cancelEdit() {
    setEditingId(null);
    setForm(EMPTY_FORM);
    setImageError(null);
  }

  async function uploadImage(file: File) {
    setImageError(null);

    if (!file.type.startsWith("image/")) {
      setImageError("Please choose an image file.");
      return;
    }
    // Guard the original upload size (phone photos can be huge); the file is
    // then downscaled/re-encoded below so what we actually store is tiny.
    if (file.size > MAX_IMAGE_BYTES) {
      setImageError("That image is too large (25MB max).");
      return;
    }

    setUploadingImage(true);

    // Optimize for the web: cap dimensions and re-encode to WebP so families
    // download a small, fast-loading image instead of the full-res photo.
    const { blob, ext, contentType } = await optimizeImage(file);
    const path = `${huntId}/${crypto.randomUUID()}.${ext}`;

    const { error } = await supabase.storage
      .from("question-images")
      .upload(path, blob, { upsert: false, contentType });

    if (error) {
      setImageError(error.message);
      setUploadingImage(false);
      return;
    }

    const {
      data: { publicUrl },
    } = supabase.storage.from("question-images").getPublicUrl(path);

    setForm((f) => ({ ...f, image_url: publicUrl }));
    setUploadingImage(false);
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
      correct_answer:
        form.type === "qr" || form.type === "open"
          ? null
          : form.correct_answer.trim(),
      qr_value: form.type === "qr" ? form.qr_value.trim() : null,
      reveal_message:
        (form.type === "qr" ||
          form.type === "multiple_choice" ||
          form.type === "open") &&
        form.reveal_message.trim()
          ? form.reveal_message.trim()
          : null,
      image_url:
        (form.type === "multiple_choice" || form.type === "text") &&
        form.image_url.trim()
          ? form.image_url.trim()
          : null,
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

    // (hunt_id, order_index) is unique, so a direct swap would collide.
    // Park the moving item on a temporary index, then do the swap in order.
    await supabase
      .from("hunt_items")
      .update({ order_index: -1 })
      .eq("id", item.id);
    await supabase
      .from("hunt_items")
      .update({ order_index: item.order_index })
      .eq("id", swapWith.id);
    await supabase
      .from("hunt_items")
      .update({ order_index: swapWith.order_index })
      .eq("id", item.id);
    await refresh();
  }

  const qrCount = items.filter((i) => i.type === "qr").length;

  return (
    <div className="animate-slide-up rounded-2xl border border-brand-navy/10 bg-white p-6 shadow-sm transition-shadow hover:shadow-md">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-lg font-semibold text-brand-navy">Hunt Items</h2>
        {qrCount > 0 && (
          <a
            href={`/admin/print-qr?hunt=${huntId}`}
            target="_blank"
            rel="noopener noreferrer"
            className="rounded-full border border-brand-navy/20 px-4 py-2 text-sm font-semibold text-brand-navy transition-colors hover:bg-brand-navy/5"
          >
            🖨 Print QR codes ({qrCount})
          </a>
        )}
      </div>

      <div className="mt-4 overflow-hidden rounded-2xl border-2 border-brand-cyan/30 bg-white shadow-sm">
        <div className="flex items-center gap-2 bg-gradient-to-r from-brand-navy to-brand-navy-light px-4 py-3">
          <span className="text-lg" aria-hidden>
            {editingId ? "✏️" : "➕"}
          </span>
          <h3 className="font-display text-base font-bold text-white">
            {editingId ? "Edit Item" : "Add a New Item"}
          </h3>
        </div>
        <div className="flex flex-col gap-3 p-4">
          <div>
            <label className="text-xs font-semibold uppercase tracking-wide text-brand-navy/50">
              Item type
            </label>
            <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-4">
              {TYPE_ORDER.map((t) => {
                const meta = TYPE_META[t];
                const selected = form.type === t;
                return (
                  <button
                    key={t}
                    type="button"
                    onClick={() => {
                      // Give QR items a code up front so it's never blank.
                      setForm({
                        ...form,
                        type: t,
                        qr_value:
                          t === "qr" && !form.qr_value
                            ? generateQrValue()
                            : form.qr_value,
                      });
                    }}
                    className={`btn-springy flex flex-col items-start gap-1 rounded-xl border-2 p-3 text-left transition-all ${
                      selected
                        ? meta.picker
                        : "border-brand-navy/10 bg-white text-brand-navy/70 hover:border-brand-navy/25 hover:bg-brand-navy/[0.02]"
                    }`}
                  >
                    <span className="text-xl" aria-hidden>
                      {meta.icon}
                    </span>
                    <span className="text-sm font-bold leading-tight">
                      {meta.label}
                    </span>
                    <span className="text-[11px] leading-snug opacity-70">
                      {meta.blurb}
                    </span>
                  </button>
                );
              })}
            </div>
          </div>

          <textarea
            value={form.prompt}
            onChange={(e) => setForm({ ...form, prompt: e.target.value })}
            placeholder="Question / clue prompt"
            rows={2}
            className="rounded-lg border border-brand-navy/20 bg-white px-3 py-2 text-sm"
          />

          {(form.type === "multiple_choice" || form.type === "text") && (
            <div className="rounded-lg border border-brand-navy/15 bg-white p-3">
              <label className="text-xs font-semibold text-brand-navy/70">
                Photo (optional) — ask &quot;what is this?&quot; with a picture
              </label>

              {form.image_url && (
                <div className="mt-2 flex items-start gap-3 rounded-lg bg-brand-navy/[0.02] p-2">
                  {/* eslint-disable-next-line @next/next/no-img-element -- external Supabase Storage URL, no build-time optimization needed */}
                  <img
                    src={form.image_url}
                    alt="Question preview"
                    className="h-24 w-24 rounded-md object-cover"
                  />
                  <button
                    type="button"
                    onClick={() => setForm({ ...form, image_url: "" })}
                    className="rounded-full px-3 py-1 text-xs font-semibold text-red-600 hover:bg-red-50"
                  >
                    Remove photo
                  </button>
                </div>
              )}

              <input
                type="file"
                accept="image/*"
                disabled={uploadingImage}
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  if (file) uploadImage(file);
                  e.target.value = "";
                }}
                className="mt-2 block w-full text-xs text-brand-navy/70 file:mr-3 file:rounded-full file:border-0 file:bg-brand-cyan/10 file:px-4 file:py-2 file:text-xs file:font-semibold file:text-brand-navy hover:file:bg-brand-cyan/20"
              />
              {uploadingImage && (
                <p className="mt-1 text-xs font-medium text-brand-navy/60">
                  Optimizing &amp; uploading...
                </p>
              )}
              {imageError && (
                <p className="mt-1 text-xs font-medium text-red-600">
                  {imageError}
                </p>
              )}
            </div>
          )}

          {form.type === "multiple_choice" && (
            <>
              <input
                value={form.choicesText}
                onChange={(e) =>
                  setForm({ ...form, choicesText: e.target.value })
                }
                placeholder="Choices, comma separated"
                className="rounded-lg border border-brand-navy/20 bg-white px-3 py-2 text-sm"
              />
              <input
                value={form.correct_answer}
                onChange={(e) =>
                  setForm({ ...form, correct_answer: e.target.value })
                }
                placeholder="Correct choice (must match one exactly)"
                className="rounded-lg border border-brand-navy/20 bg-white px-3 py-2 text-sm"
              />
              <div>
                <label className="text-xs font-semibold text-brand-navy/70">
                  Comment shown with the answer (optional)
                </label>
                <textarea
                  value={form.reveal_message}
                  onChange={(e) =>
                    setForm({ ...form, reveal_message: e.target.value })
                  }
                  placeholder="e.g. This lathe has been on the floor since 1998!"
                  rows={2}
                  className="mt-1 w-full rounded-lg border border-brand-navy/20 bg-white px-3 py-2 text-sm"
                />
              </div>
            </>
          )}

          {form.type === "text" && (
            <input
              value={form.correct_answer}
              onChange={(e) =>
                setForm({ ...form, correct_answer: e.target.value })
              }
              placeholder="Correct answer (case/whitespace insensitive)"
              className="rounded-lg border border-brand-navy/20 bg-white px-3 py-2 text-sm"
            />
          )}

          {form.type === "open" && (
            <div className="rounded-lg border border-brand-navy/15 bg-brand-green/[0.04] p-3">
              <p className="text-xs font-medium text-brand-navy/70">
                Any answer the family types is accepted and counts toward their
                progress. There&apos;s no right or wrong, and no points
                advantage. Great for participation tasks like &quot;find
                something blue&quot; or &quot;what would you make?&quot;
              </p>
              <label className="mt-3 block text-xs font-semibold text-brand-navy/70">
                Message shown after they answer (optional)
              </label>
              <textarea
                value={form.reveal_message}
                onChange={(e) =>
                  setForm({ ...form, reveal_message: e.target.value })
                }
                placeholder="Default: Answer logged! 📝 On to the next one."
                rows={2}
                className="mt-1 w-full rounded-lg border border-brand-navy/20 bg-white px-3 py-2 text-sm"
              />
            </div>
          )}

          {form.type === "qr" && (
            <div className="rounded-lg border border-brand-navy/15 bg-white p-3">
              <label className="text-xs font-semibold text-brand-navy/70">
                QR code value (encoded in the printed code)
              </label>
              <div className="mt-1 flex flex-col gap-2 sm:flex-row">
                <input
                  value={form.qr_value}
                  onChange={(e) =>
                    setForm({ ...form, qr_value: e.target.value })
                  }
                  placeholder="e.g. FET-A1B2C3"
                  className="h-10 flex-1 rounded-lg border border-brand-navy/20 px-3 text-sm"
                />
                <button
                  type="button"
                  onClick={() =>
                    setForm({ ...form, qr_value: generateQrValue() })
                  }
                  className="btn-springy h-10 shrink-0 rounded-full border border-brand-cyan/50 bg-brand-cyan/10 px-4 text-sm font-semibold text-brand-navy"
                >
                  Generate code
                </button>
              </div>

              {form.qr_value.trim() && (
                <div className="mt-3 flex items-center gap-3 rounded-lg bg-brand-navy/[0.02] p-3">
                  <QrImage value={form.qr_value.trim()} size={96} />
                  <p className="text-xs text-brand-navy/60">
                    This is the QR families will scan at the stop. Print it from
                    the{" "}
                    <span className="font-semibold text-brand-navy">
                      Print QR codes
                    </span>{" "}
                    button once you&apos;ve saved this item.
                  </p>
                </div>
              )}

              <label className="mt-3 block text-xs font-semibold text-brand-navy/70">
                Message shown after scanning (optional)
              </label>
              <textarea
                value={form.reveal_message}
                onChange={(e) =>
                  setForm({ ...form, reveal_message: e.target.value })
                }
                placeholder="e.g. Nice find! This CNC machine cuts valve components for oilfield equipment."
                rows={2}
                className="mt-1 w-full rounded-lg border border-brand-navy/20 px-3 py-2 text-sm"
              />
            </div>
          )}

          <div>
            <label className="text-xs font-semibold text-brand-navy/70">
              Points
            </label>
            <input
              type="number"
              min={1}
              value={form.points}
              onChange={(e) =>
                setForm({ ...form, points: Number(e.target.value) })
              }
              placeholder="Points"
              className="mt-1 block w-24 rounded-lg border border-brand-navy/20 bg-white px-3 py-2 text-sm"
            />
          </div>

          <div className="flex flex-wrap items-center gap-3">
            <button
              onClick={save}
              disabled={!form.prompt.trim() || saving || uploadingImage}
              className="btn-springy rounded-full bg-brand-green px-6 py-2.5 text-sm font-bold text-white shadow-md transition-colors hover:brightness-95 disabled:cursor-not-allowed disabled:opacity-40"
            >
              {saving
                ? "Saving..."
                : editingId
                  ? "💾 Save Changes"
                  : "➕ Add Item to Hunt"}
            </button>
            {editingId && (
              <button
                onClick={cancelEdit}
                className="rounded-full border border-brand-navy/20 px-5 py-2 text-sm font-semibold text-brand-navy transition-colors hover:bg-brand-navy/5"
              >
                Cancel
              </button>
            )}
            {!form.prompt.trim() && (
              <span className="text-xs font-medium text-brand-navy/50">
                Add a question / clue prompt above to enable this.
              </span>
            )}
          </div>
        </div>
      </div>

      <div className="mt-6 border-t border-brand-navy/10 pt-6">
        <HuntItemImport huntId={huntId} onImported={refresh} />
      </div>

      <h3 className="mt-6 flex items-center gap-2 font-display text-lg font-bold text-brand-navy">
        <span className="h-5 w-1.5 rounded-full bg-brand-green" aria-hidden />
        Items in this hunt{items.length > 0 ? ` (${items.length})` : ""}
      </h3>

      <ul className="mt-4 flex flex-col gap-2">
        {items.map((item, i) => (
          <li
            key={item.id}
            className={`flex items-center justify-between gap-3 rounded-xl border border-l-4 bg-white px-4 py-3 shadow-sm transition-colors ${TYPE_META[item.type].edge} ${
              editingId === item.id
                ? "border-brand-cyan bg-brand-cyan/5"
                : "border-brand-navy/10 hover:bg-brand-navy/[0.02]"
            }`}
          >
            <div className="flex min-w-0 items-start gap-3">
              <span className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-brand-navy/5 font-display text-sm font-bold text-brand-navy/50">
                {i + 1}
              </span>
              <div className="min-w-0">
                <span
                  className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold uppercase tracking-wide ${TYPE_BADGE_STYLES[item.type]}`}
                >
                  <span aria-hidden>{TYPE_META[item.type].icon}</span>
                  {TYPE_META[item.type].label}
                </span>
                <span className="ml-1.5 inline-block rounded-full bg-brand-navy/5 px-2 py-0.5 text-xs font-semibold text-brand-navy/60">
                  {item.points} pt
                </span>
                {item.image_url && (
                  <span className="ml-1.5 inline-block rounded-full bg-brand-navy/5 px-2 py-0.5 text-xs font-semibold text-brand-navy/60">
                    📷 photo
                  </span>
                )}
                <p className="mt-1 font-medium text-brand-navy">{item.prompt}</p>
              </div>
            </div>
            <div className="flex items-center gap-2">
              <button
                onClick={() => move(item, -1)}
                disabled={i === 0}
                className="flex h-7 w-7 items-center justify-center rounded-full text-brand-navy/50 transition-colors hover:bg-brand-navy/5 hover:text-brand-navy disabled:opacity-30 disabled:hover:bg-transparent"
                aria-label="Move up"
              >
                ↑
              </button>
              <button
                onClick={() => move(item, 1)}
                disabled={i === items.length - 1}
                className="flex h-7 w-7 items-center justify-center rounded-full text-brand-navy/50 transition-colors hover:bg-brand-navy/5 hover:text-brand-navy disabled:opacity-30 disabled:hover:bg-transparent"
                aria-label="Move down"
              >
                ↓
              </button>
              <button
                onClick={() => startEdit(item)}
                className="rounded-full px-2 py-1 text-sm font-medium text-brand-navy underline-offset-2 transition-colors hover:bg-brand-cyan/10 hover:underline"
              >
                Edit
              </button>
              <button
                onClick={() => remove(item)}
                className="rounded-full px-2 py-1 text-sm font-medium text-red-600 underline-offset-2 transition-colors hover:bg-red-50 hover:underline"
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
    </div>
  );
}
