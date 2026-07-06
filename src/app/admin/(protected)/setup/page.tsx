"use client";

import { useState } from "react";
import { EmployeeUpload } from "@/components/admin/EmployeeUpload";
import { HuntManager } from "@/components/admin/HuntManager";
import { HuntItemBuilder } from "@/components/admin/HuntItemBuilder";

export default function AdminSetupPage() {
  const [selectedHuntId, setSelectedHuntId] = useState<string | null>(null);

  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-2xl font-bold text-brand-navy">Hunt Setup</h1>
      <EmployeeUpload />
      <HuntManager
        selectedHuntId={selectedHuntId}
        onSelectHunt={setSelectedHuntId}
      />
      {selectedHuntId && <HuntItemBuilder huntId={selectedHuntId} />}
    </div>
  );
}
