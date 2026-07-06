"use client";

import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { EmployeeUpload } from "./EmployeeUpload";
import type { Employee } from "@/lib/types/hunt";

const PAGE_SIZE = 25;

export function EmployeeManager() {
  const supabase = createClient();

  const [employees, setEmployees] = useState<Employee[]>([]);
  const [total, setTotal] = useState(0);
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(0);
  const [loading, setLoading] = useState(true);

  // Add form
  const [newName, setNewName] = useState("");
  const [newDept, setNewDept] = useState("");
  const [adding, setAdding] = useState(false);

  // Inline edit
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editName, setEditName] = useState("");
  const [editDept, setEditDept] = useState("");

  const [error, setError] = useState<string | null>(null);
  const [showUpload, setShowUpload] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    const trimmed = search.trim();
    let query = supabase
      .from("employees")
      .select("id, full_name, department", { count: "exact" })
      .order("full_name")
      .range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1);

    if (trimmed.length > 0) {
      query = query.ilike("full_name", `%${trimmed}%`);
    }

    const { data, count, error } = await query;
    if (error) {
      setError(error.message);
    } else {
      setEmployees((data as Employee[]) ?? []);
      setTotal(count ?? 0);
    }
    setLoading(false);
  }, [supabase, search, page]);

  useEffect(() => {
    // load() flips the loading flag then fetches — the standard
    // data-fetch-with-spinner pattern; the sync setState is intentional.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load();
  }, [load]);

  function onSearchChange(value: string) {
    setSearch(value);
    setPage(0); // new search always starts from the first page
  }

  async function addEmployee() {
    const name = newName.trim();
    if (!name || adding) return;
    setAdding(true);
    setError(null);

    const { error } = await supabase
      .from("employees")
      .insert({ full_name: name, department: newDept.trim() || null });

    setAdding(false);
    if (error) {
      setError(error.message);
      return;
    }
    setNewName("");
    setNewDept("");
    await load();
  }

  function startEdit(emp: Employee) {
    setEditingId(emp.id);
    setEditName(emp.full_name);
    setEditDept(emp.department ?? "");
  }

  function cancelEdit() {
    setEditingId(null);
    setEditName("");
    setEditDept("");
  }

  async function saveEdit(id: string) {
    const name = editName.trim();
    if (!name) return;
    setError(null);

    const { error } = await supabase
      .from("employees")
      .update({ full_name: name, department: editDept.trim() || null })
      .eq("id", id);

    if (error) {
      setError(error.message);
      return;
    }
    cancelEdit();
    await load();
  }

  async function remove(emp: Employee) {
    if (
      !window.confirm(
        `Remove "${emp.full_name}" from the employee list?\n\nAny team already registered under this name will stay, but will no longer be linked to it.`,
      )
    ) {
      return;
    }
    setError(null);

    const { error } = await supabase.from("employees").delete().eq("id", emp.id);
    if (error) {
      setError(error.message);
      return;
    }
    // If we just emptied the last page, step back one.
    if (employees.length === 1 && page > 0) {
      setPage((p) => p - 1);
    } else {
      await load();
    }
  }

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));

  return (
    <div className="animate-slide-up rounded-2xl border border-brand-navy/10 bg-white p-6 shadow-sm transition-shadow hover:shadow-md">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold text-brand-navy">
            Employee List
          </h2>
          <p className="mt-1 text-sm text-brand-navy/60">
            {total} {total === 1 ? "name" : "names"}. Families search this list
            to find their team.
          </p>
        </div>
        <button
          onClick={() => setShowUpload((s) => !s)}
          className="rounded-full border border-brand-navy/20 px-4 py-2 text-sm font-semibold text-brand-navy transition-colors hover:bg-brand-navy/5"
        >
          {showUpload ? "Hide bulk upload" : "Bulk upload (CSV)"}
        </button>
      </div>

      {showUpload && (
        <div className="mt-4">
          <EmployeeUpload onUploaded={load} />
        </div>
      )}

      {error && (
        <p className="mt-4 rounded-lg bg-red-50 px-4 py-2 text-sm font-medium text-red-600">
          {error}
        </p>
      )}

      {/* Add a single employee */}
      <div className="mt-5 rounded-xl border border-brand-navy/10 bg-brand-navy/[0.02] p-4">
        <p className="text-sm font-semibold text-brand-navy">Add a name</p>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            addEmployee();
          }}
          className="mt-3 flex flex-col gap-2 sm:flex-row"
        >
          <input
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder="Full name (e.g. SONNIER, BRIAN)"
            className="h-11 flex-1 rounded-lg border border-brand-navy/20 px-3 text-sm outline-none focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/25"
          />
          <input
            value={newDept}
            onChange={(e) => setNewDept(e.target.value)}
            placeholder="Department (optional)"
            className="h-11 w-full rounded-lg border border-brand-navy/20 px-3 text-sm outline-none focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/25 sm:w-48"
          />
          <button
            type="submit"
            disabled={!newName.trim() || adding}
            className="btn-springy h-11 rounded-full bg-brand-navy px-5 text-sm font-semibold text-white disabled:opacity-40"
          >
            {adding ? "Adding..." : "Add"}
          </button>
        </form>
      </div>

      {/* Search */}
      <input
        value={search}
        onChange={(e) => onSearchChange(e.target.value)}
        placeholder="Search names..."
        className="mt-5 h-11 w-full rounded-lg border border-brand-navy/20 px-3 text-sm outline-none focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/25"
      />

      {/* List */}
      <ul className="mt-3 flex flex-col divide-y divide-brand-navy/5">
        {loading && (
          <li className="py-6 text-center text-sm text-brand-navy/50">
            Loading...
          </li>
        )}
        {!loading && employees.length === 0 && (
          <li className="py-6 text-center text-sm text-brand-navy/50">
            {search.trim()
              ? "No names match your search."
              : "No employees yet. Add one above or bulk upload a CSV."}
          </li>
        )}
        {!loading &&
          employees.map((emp) =>
            editingId === emp.id ? (
              <li
                key={emp.id}
                className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center"
              >
                <input
                  value={editName}
                  onChange={(e) => setEditName(e.target.value)}
                  className="h-10 flex-1 rounded-lg border border-brand-cyan px-3 text-sm outline-none focus:ring-2 focus:ring-brand-cyan/25"
                  autoFocus
                />
                <input
                  value={editDept}
                  onChange={(e) => setEditDept(e.target.value)}
                  placeholder="Department"
                  className="h-10 w-full rounded-lg border border-brand-navy/20 px-3 text-sm outline-none focus:border-brand-cyan focus:ring-2 focus:ring-brand-cyan/25 sm:w-40"
                />
                <div className="flex gap-2">
                  <button
                    onClick={() => saveEdit(emp.id)}
                    disabled={!editName.trim()}
                    className="btn-springy h-10 rounded-full bg-brand-green px-4 text-sm font-semibold text-white disabled:opacity-40"
                  >
                    Save
                  </button>
                  <button
                    onClick={cancelEdit}
                    className="h-10 rounded-full px-3 text-sm font-medium text-brand-navy/60 hover:bg-brand-navy/5"
                  >
                    Cancel
                  </button>
                </div>
              </li>
            ) : (
              <li
                key={emp.id}
                className="flex items-center justify-between gap-3 py-3"
              >
                <div className="min-w-0">
                  <p className="truncate font-medium text-brand-navy">
                    {emp.full_name}
                  </p>
                  {emp.department && (
                    <p className="truncate text-xs text-brand-navy/50">
                      {emp.department}
                    </p>
                  )}
                </div>
                <div className="flex shrink-0 items-center gap-1">
                  <button
                    onClick={() => startEdit(emp)}
                    className="rounded-full px-3 py-1 text-sm font-medium text-brand-navy transition-colors hover:bg-brand-cyan/10"
                  >
                    Edit
                  </button>
                  <button
                    onClick={() => remove(emp)}
                    className="rounded-full px-3 py-1 text-sm font-medium text-red-600 transition-colors hover:bg-red-50"
                  >
                    Delete
                  </button>
                </div>
              </li>
            ),
          )}
      </ul>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="mt-4 flex items-center justify-between text-sm">
          <button
            onClick={() => setPage((p) => Math.max(0, p - 1))}
            disabled={page === 0}
            className="rounded-full border border-brand-navy/20 px-4 py-1.5 font-medium text-brand-navy transition-colors hover:bg-brand-navy/5 disabled:opacity-30"
          >
            ← Prev
          </button>
          <span className="text-brand-navy/60">
            Page {page + 1} of {totalPages}
          </span>
          <button
            onClick={() => setPage((p) => Math.min(totalPages - 1, p + 1))}
            disabled={page >= totalPages - 1}
            className="rounded-full border border-brand-navy/20 px-4 py-1.5 font-medium text-brand-navy transition-colors hover:bg-brand-navy/5 disabled:opacity-30"
          >
            Next →
          </button>
        </div>
      )}
    </div>
  );
}
