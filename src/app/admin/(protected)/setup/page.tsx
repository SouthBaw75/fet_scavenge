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
      <div>
        <h1 className="font-display text-3xl font-semibold text-brand-navy">
          Hunt Setup
        </h1>
        <p className="mt-1 text-sm text-brand-navy/60">
          Build the employee list, create hunts, and craft the clues.
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
          {selectedHuntId && <HuntItemBuilder huntId={selectedHuntId} />}
        </div>
      )}
    </div>
  );
}
