"use client";

import { useState } from "react";
import * as XLSX from "xlsx";
import { createClient } from "@/lib/supabase/client";
import type { HuntItemType } from "@/lib/types/hunt";

interface ImportRow {
  order: number;
  type: HuntItemType;
  prompt: string;
  choice_a?: string;
  choice_b?: string;
  choice_c?: string;
  choice_d?: string;
  correct_answer?: string;
  qr_value?: string;
  reveal_message?: string;
  points: number;
}

interface ValidationError {
  row: number;
  message: string;
}

const VALID_TYPES: HuntItemType[] = ["multiple_choice", "text", "qr"];

function generateQrValue() {
  const rand = Math.random().toString(36).slice(2, 8).toUpperCase();
  return `FET-${rand}`;
}

function validateRows(rows: Record<string, unknown>[]): {
  valid: ImportRow[];
  errors: ValidationError[];
} {
  const valid: ImportRow[] = [];
  const errors: ValidationError[] = [];

  rows.forEach((raw, i) => {
    const rowNum = i + 2; // +2 because row 1 is header
    const type = String(raw.type ?? "").trim().toLowerCase() as HuntItemType;
    const prompt = String(raw.prompt ?? "").trim();
    const points = Number(raw.points ?? 100);

    if (!VALID_TYPES.includes(type)) {
      errors.push({ row: rowNum, message: `Invalid type "${raw.type}". Must be multiple_choice, text, or qr.` });
      return;
    }
    if (!prompt) {
      errors.push({ row: rowNum, message: "Missing prompt / question text." });
      return;
    }
    if (isNaN(points) || points < 1) {
      errors.push({ row: rowNum, message: `Invalid points value "${raw.points}".` });
      return;
    }

    if (type === "multiple_choice") {
      const choices = [raw.choice_a, raw.choice_b, raw.choice_c, raw.choice_d]
        .map((c) => String(c ?? "").trim())
        .filter(Boolean);
      if (choices.length < 2) {
        errors.push({ row: rowNum, message: "multiple_choice needs at least 2 choices (choice_a, choice_b)." });
        return;
      }
      const answer = String(raw.correct_answer ?? "").trim();
      if (!answer) {
        errors.push({ row: rowNum, message: "multiple_choice is missing correct_answer." });
        return;
      }
      if (!choices.includes(answer)) {
        errors.push({ row: rowNum, message: `correct_answer "${answer}" doesn't match any choice.` });
        return;
      }
    }

    if (type === "text" && !String(raw.correct_answer ?? "").trim()) {
      errors.push({ row: rowNum, message: "text type is missing correct_answer." });
      return;
    }

    valid.push({
      order: Number(raw.order ?? i + 1),
      type,
      prompt,
      choice_a: String(raw.choice_a ?? "").trim() || undefined,
      choice_b: String(raw.choice_b ?? "").trim() || undefined,
      choice_c: String(raw.choice_c ?? "").trim() || undefined,
      choice_d: String(raw.choice_d ?? "").trim() || undefined,
      correct_answer: String(raw.correct_answer ?? "").trim() || undefined,
      qr_value: String(raw.qr_value ?? "").trim() || undefined,
      reveal_message: String(raw.reveal_message ?? "").trim() || undefined,
      points,
    });
  });

  return { valid, errors };
}

export function HuntItemImport({
  huntId,
  onImported,
}: {
  huntId: string;
  onImported: () => void;
}) {
  const supabase = createClient();
  const [fileName, setFileName] = useState<string | null>(null);
  const [preview, setPreview] = useState<ImportRow[]>([]);
  const [errors, setErrors] = useState<ValidationError[]>([]);
  const [status, setStatus] = useState<"idle" | "importing" | "done" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);

  function handleFile(file: File) {
    setFileName(file.name);
    setStatus("idle");
    setMessage(null);
    setPreview([]);
    setErrors([]);

    const reader = new FileReader();
    reader.onload = (e) => {
      const data = new Uint8Array(e.target?.result as ArrayBuffer);
      const workbook = XLSX.read(data, { type: "array" });
      const sheet = workbook.Sheets[workbook.SheetNames[0]];
      const rows = XLSX.utils.sheet_to_json<Record<string, unknown>>(sheet, {
        defval: "",
      });

      const { valid, errors } = validateRows(rows);
      setPreview(valid);
      setErrors(errors);
    };
    reader.readAsArrayBuffer(file);
  }

  async function importItems() {
    if (preview.length === 0) return;
    setStatus("importing");
    setMessage(null);

    // Get current max order_index so we don't collide with existing items
    const { data: existing } = await supabase
      .from("hunt_items")
      .select("order_index")
      .eq("hunt_id", huntId)
      .order("order_index", { ascending: false })
      .limit(1);

    const baseOrder = existing?.[0]?.order_index ?? 0;

    const payload = preview.map((row, i) => ({
      hunt_id: huntId,
      order_index: baseOrder + (row.order ?? i + 1),
      type: row.type,
      prompt: row.prompt,
      choices:
        row.type === "multiple_choice"
          ? [row.choice_a, row.choice_b, row.choice_c, row.choice_d].filter(Boolean)
          : null,
      correct_answer: row.type === "qr" ? null : row.correct_answer ?? null,
      qr_value: row.type === "qr" ? (row.qr_value || generateQrValue()) : null,
      reveal_message: row.type === "qr" ? (row.reveal_message ?? null) : null,
      image_url: null,
      points: row.points,
    }));

    const { error } = await supabase.from("hunt_items").insert(payload);

    if (error) {
      setStatus("error");
      setMessage(error.message);
      return;
    }

    setStatus("done");
    setMessage(`Successfully imported ${payload.length} hunt items!`);
    setPreview([]);
    setErrors([]);
    setFileName(null);
    onImported();
  }

  function reset() {
    setFileName(null);
    setPreview([]);
    setErrors([]);
    setStatus("idle");
    setMessage(null);
  }

  return (
    <div className="rounded-xl border border-brand-cyan/20 bg-brand-cyan/[0.03] p-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h3 className="text-sm font-semibold text-brand-navy">
            Import from Excel
          </h3>
          <p className="mt-0.5 text-xs text-brand-navy/60">
            Upload a filled-in template to bulk-add hunt items.
          </p>
        </div>
        <a
          href="/FET_Hunt_Items_Template.xlsx"
          download
          className="rounded-full border border-brand-navy/20 px-4 py-2 text-xs font-semibold text-brand-navy transition-colors hover:bg-brand-navy/5"
        >
          ⬇ Download Template
        </a>
      </div>

      <input
        type="file"
        accept=".xlsx,.xls"
        onChange={(e) => {
          const file = e.target.files?.[0];
          if (file) handleFile(file);
          e.target.value = "";
        }}
        className="mt-4 text-sm file:mr-3 file:cursor-pointer file:rounded-full file:border-0 file:bg-brand-navy/5 file:px-4 file:py-2 file:text-sm file:font-semibold file:text-brand-navy file:transition-colors hover:file:bg-brand-cyan/15"
      />

      {errors.length > 0 && (
        <div className="animate-slide-up mt-4 rounded-lg bg-red-50 p-3">
          <p className="text-xs font-semibold text-red-700">
            Fix these errors before importing:
          </p>
          <ul className="mt-1 list-inside list-disc space-y-0.5">
            {errors.map((e, i) => (
              <li key={i} className="text-xs text-red-600">
                Row {e.row}: {e.message}
              </li>
            ))}
          </ul>
        </div>
      )}

      {preview.length > 0 && (
        <div className="animate-slide-up mt-4">
          <p className="text-xs font-semibold text-brand-navy">
            {preview.length} item{preview.length !== 1 ? "s" : ""} ready to import
            {errors.length > 0 ? ` (${errors.length} rows skipped due to errors)` : ""}
          </p>
          <ul className="mt-2 max-h-48 overflow-y-auto rounded-lg border border-brand-navy/10 bg-white divide-y divide-brand-navy/5">
            {preview.map((row, i) => (
              <li key={i} className="flex items-center gap-3 px-3 py-2">
                <span className="text-xs font-mono text-brand-navy/40 w-5">{row.order}</span>
                <span className={`shrink-0 rounded-full px-2 py-0.5 text-xs font-semibold uppercase tracking-wide ${
                  row.type === "multiple_choice" ? "bg-brand-cyan/10 text-brand-cyan" :
                  row.type === "qr" ? "bg-brand-navy/10 text-brand-navy" :
                  "bg-brand-green/10 text-brand-green"
                }`}>
                  {row.type.replace("_", " ")}
                </span>
                <span className="text-xs text-brand-navy truncate">{row.prompt}</span>
                <span className="ml-auto shrink-0 text-xs font-semibold text-brand-navy/50">{row.points}pt</span>
              </li>
            ))}
          </ul>
          <div className="mt-3 flex gap-3">
            <button
              onClick={importItems}
              disabled={status === "importing"}
              className="btn-springy rounded-full bg-brand-navy px-5 py-2 text-sm font-semibold text-white transition-colors hover:bg-brand-navy-light disabled:opacity-40"
            >
              {status === "importing" ? "Importing..." : `Import ${preview.length} Items`}
            </button>
            <button
              onClick={reset}
              className="rounded-full border border-brand-navy/20 px-5 py-2 text-sm font-semibold text-brand-navy transition-colors hover:bg-brand-navy/5"
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {message && (
        <p className={`animate-slide-up mt-3 rounded-lg px-3 py-2 text-sm font-medium ${
          status === "error" ? "bg-red-50 text-red-600" : "bg-brand-green/10 text-brand-green"
        }`}>
          {message}
        </p>
      )}
    </div>
  );
}
