"use client";

import { useState } from "react";
import { EmployeeUpload } from "@/components/admin/EmployeeUpload";
import { HuntManager } from "@/components/admin/HuntManager";
import { HuntItemBuilder } from "@/components/admin/HuntItemBuilder";

export default function AdminSetupPage() {
  const [selectedHuntId, setSelectedHuntId] = useState<string | null>(null);

  return (
    <div className="stagger-children flex flex-col gap-6">
      <div>
        <h1 className="font-display text-3xl font-semibold text-brand-navy">
          Hunt Setup
        </h1>
        <p className="mt-1 text-sm text-brand-navy/60">
          Build the employee list, create hunts, and craft the clues.
        </p>
      </div>
      <EmployeeUpload />
      <HuntManager
        selectedHuntId={selectedHuntId}
        onSelectHunt={setSelectedHuntId}
      />
      {selectedHuntId && <HuntItemBuilder huntId={selectedHuntId} />}
    </div>
  );
}
