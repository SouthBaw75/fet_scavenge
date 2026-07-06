"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { QrImage } from "@/components/admin/QrImage";
import { Fetch } from "@/components/Fetch";
import type { Hunt } from "@/lib/types/hunt";

function PrintPortalContent() {
  const supabase = createClient();
  const params = useSearchParams();
  const huntId = params.get("hunt");
  // Optional direct override so a poster can be printed without a saved
  // hunt (e.g. before setup is finished, or for a quick test poster).
  const nameOverride = params.get("name");

  const [hunt, setHunt] = useState<Hunt | null>(null);
  const [loading, setLoading] = useState(!!huntId && !nameOverride);
  const [portalUrl, setPortalUrl] = useState("");

  useEffect(() => {
    // The QR always points at THIS site's own register page, whatever
    // domain it's actually deployed/viewed on.
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reading window.location, an external system
    setPortalUrl(`${window.location.origin}/register`);
  }, []);

  useEffect(() => {
    if (!huntId || nameOverride) return;
    let cancelled = false;

    async function load(id: string) {
      const { data } = await supabase
        .from("hunts")
        .select("id, name, status, settings, created_at")
        .eq("id", id)
        .maybeSingle();
      if (cancelled) return;
      setHunt((data as Hunt) ?? null);
      setLoading(false);
    }

    load(huntId);
    return () => {
      cancelled = true;
    };
  }, [huntId, nameOverride, supabase]);

  if (loading || !portalUrl) {
    return <p className="p-8 text-brand-navy/60">Loading...</p>;
  }

  const huntName =
    nameOverride || hunt?.name || "FET Family Fun Day Scavenger Hunt";

  return (
    <div className="mx-auto max-w-2xl p-6">
      {/* Toolbar — hidden when printing */}
      <div className="mb-6 flex items-center justify-between print:hidden">
        <div>
          <h1 className="font-display text-2xl font-bold text-brand-navy">
            Print Team Portal Poster
          </h1>
          <p className="mt-1 text-sm text-brand-navy/60">
            A sign families scan to register their team. Points to{" "}
            <span className="font-mono">{portalUrl}</span>.
          </p>
        </div>
        <button
          onClick={() => window.print()}
          className="btn-springy rounded-full bg-brand-navy px-6 py-2.5 font-semibold text-white"
        >
          🖨 Print
        </button>
      </div>

      {/* The poster itself */}
      <div className="flex flex-col items-center rounded-3xl border-4 border-brand-navy bg-white px-10 py-12 text-center shadow-xl print:border-2 print:shadow-none">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src="/brand/fet-logo.webp"
          alt="Forum Energy Technologies"
          className="h-14 w-auto"
        />

        <Fetch pose="wave" width={200} entrance={false} idle="none" className="mt-4" />

        <h2 className="mt-4 font-display text-3xl font-bold leading-tight text-brand-navy">
          Join the Hunt!
        </h2>

        <p className="mt-3 inline-block rounded-full bg-brand-cyan/10 px-5 py-2 font-display text-lg font-bold text-brand-navy">
          {huntName}
        </p>

        <div className="mt-8 rounded-3xl border-4 border-brand-navy p-4">
          <QrImage value={portalUrl} size={280} />
        </div>

        <p className="mt-6 max-w-sm font-display text-xl font-bold text-brand-navy">
          Scan to register your family team!
        </p>
        <p className="mt-2 font-mono text-sm text-brand-navy/50">
          {portalUrl}
        </p>
      </div>

      <style jsx global>{`
        @media print {
          body {
            background: white;
          }
          @page {
            margin: 0.5in;
          }
        }
      `}</style>
    </div>
  );
}

export default function PrintPortalPage() {
  return (
    <Suspense fallback={<p className="p-8 text-brand-navy/60">Loading...</p>}>
      <PrintPortalContent />
    </Suspense>
  );
}
