"use client";

import { useState } from "react";
import Papa from "papaparse";
import { createClient } from "@/lib/supabase/client";

interface ParsedRow {
  full_name: string;
  department: string | null;
}

function normalizeHeader(header: string) {
  return header.trim().toLowerCase().replace(/\s+/g, "_");
}

export function EmployeeUpload() {
  const supabase = createClient();
  const [rows, setRows] = useState<ParsedRow[]>([]);
  const [fileName, setFileName] = useState<string | null>(null);
  const [replaceExisting, setReplaceExisting] = useState(true);
  const [status, setStatus] = useState<"idle" | "uploading" | "done" | "error">(
    "idle",
  );
  const [message, setMessage] = useState<string | null>(null);

  function handleFile(file: File) {
    setFileName(file.name);
    setStatus("idle");
    setMessage(null);

    Papa.parse<Record<string, string>>(file, {
      header: true,
      skipEmptyLines: true,
      transformHeader: normalizeHeader,
      complete: (results) => {
        const parsed = results.data
          .map((row) => ({
            full_name: (row.full_name ?? row.name ?? "").trim(),
            department: (row.department ?? "").trim() || null,
          }))
          .filter((row) => row.full_name.length > 0);

        setRows(parsed);
        if (parsed.length === 0) {
          setMessage(
            "No rows found. Make sure the CSV has a 'full_name' column.",
          );
        }
      },
    });
  }

  async function upload() {
    if (rows.length === 0) return;
    setStatus("uploading");
    setMessage(null);

    if (replaceExisting) {
      const { error } = await supabase
        .from("employees")
        .delete()
        .not("id", "is", null);
      if (error) {
        setStatus("error");
        setMessage(error.message);
        return;
      }
    }

    const chunkSize = 500;
    for (let i = 0; i < rows.length; i += chunkSize) {
      const chunk = rows.slice(i, i + chunkSize);
      const { error } = await supabase.from("employees").insert(chunk);
      if (error) {
        setStatus("error");
        setMessage(error.message);
        return;
      }
    }

    setStatus("done");
    setMessage(`Uploaded ${rows.length} employees.`);
    setRows([]);
    setFileName(null);
  }

  return (
    <div className="rounded-2xl border border-brand-navy/10 bg-white p-6 shadow-sm">
      <h2 className="text-lg font-semibold text-brand-navy">
        Upload Employee List
      </h2>
      <p className="mt-1 text-sm text-brand-navy/60">
        CSV with a <code>full_name</code> column (and optional{" "}
        <code>department</code>). Families search this list during
        registration.
      </p>

      <input
        type="file"
        accept=".csv"
        onChange={(e) => {
          const file = e.target.files?.[0];
          if (file) handleFile(file);
        }}
        className="mt-4 text-sm"
      />

      {fileName && rows.length > 0 && (
        <div className="mt-4 flex flex-wrap items-center gap-4">
          <p className="text-sm text-brand-navy/70">
            {fileName}: {rows.length} employees ready to upload.
          </p>
          <label className="flex items-center gap-2 text-sm text-brand-navy/70">
            <input
              type="checkbox"
              checked={replaceExisting}
              onChange={(e) => setReplaceExisting(e.target.checked)}
            />
            Replace existing list
          </label>
          <button
            onClick={upload}
            disabled={status === "uploading"}
            className="rounded-full bg-brand-navy px-5 py-2 text-sm font-semibold text-white transition-colors hover:bg-brand-navy-light disabled:opacity-40"
          >
            {status === "uploading" ? "Uploading..." : "Upload"}
          </button>
        </div>
      )}

      {message && (
        <p
          className={`mt-3 text-sm ${
            status === "error" ? "text-red-600" : "text-brand-green"
          }`}
        >
          {message}
        </p>
      )}
    </div>
  );
}
