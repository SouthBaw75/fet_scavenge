"use client";

import { useState } from "react";
import { EmployeeManager } from "@/components/admin/EmployeeManager";
import { HuntManager } from "@/components/admin/HuntManager";
import { HuntItemBuilder } from "@/components/admin/HuntItemBuilder";

type SetupTab = "hunts" | "employees";

export default function AdminSetupPage() {
  const [tab, setTab] = useState<SetupTab>("hunts");
  const [selectedHuntId, setSelectedHuntId] = useState<string | null>(null);

  return (
    <div className="flex flex-col gap-6">
      <div className="overflow-hidden rounded-2xl bg-gradient-to-r from-brand-navy to-brand-navy-light p-6 shadow-sm">
        <h1 className="font-display text-3xl font-bold text-white">
          Hunt Setup
        </h1>
        <p className="mt-1 text-sm text-white/70">
          Build your employee list, create a hunt, and add the questions and
          clues families will play.
        </p>
      </div>

      <div className="flex gap-2 border-b border-brand-navy/10 pb-4">
        <button
          onClick={() => setTab("hunts")}
          className={`rounded-full px-5 py-2 text-sm font-semibold transition-colors ${
            tab === "hunts"
              ? "bg-brand-navy text-white"
              : "border border-brand-navy/20 text-brand-navy hover:bg-brand-navy/5"
          }`}
        >
          Hunts &amp; Questions
        </button>
        <button
          onClick={() => setTab("employees")}
          className={`rounded-full px-5 py-2 text-sm font-semibold transition-colors ${
            tab === "employees"
              ? "bg-brand-navy text-white"
              : "border border-brand-navy/20 text-brand-navy hover:bg-brand-navy/5"
          }`}
        >
          Employee List
        </button>
      </div>

      {tab === "employees" && <EmployeeManager />}

      {tab === "hunts" && (
        <div className="stagger-children flex flex-col gap-6">
          <HuntManager
            selectedHuntId={selectedHuntId}
            onSelectHunt={setSelectedHuntId}
          />
          {selectedHuntId ? (
            <HuntItemBuilder huntId={selectedHuntId} />
          ) : (
            <div className="rounded-2xl border-2 border-dashed border-brand-cyan/40 bg-brand-cyan/[0.04] px-6 py-10 text-center">
              <p className="font-display text-lg font-bold text-brand-navy">
                Pick a hunt above to add questions
              </p>
              <p className="mt-1 text-sm text-brand-navy/60">
                Select a hunt (or create one) and its questions and clues show
                up here.
              </p>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
