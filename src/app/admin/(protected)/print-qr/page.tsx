"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { QrImage } from "@/components/admin/QrImage";
import type { Hunt, HuntItem } from "@/lib/types/hunt";

function PrintQrContent() {
  const supabase = createClient();
  const params = useSearchParams();
  const huntId = params.get("hunt");

  const [hunt, setHunt] = useState<Hunt | null>(null);
  const [items, setItems] = useState<HuntItem[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!huntId) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- nothing to load without a hunt id
      setLoading(false);
      return;
    }
    let cancelled = false;

    async function load(id: string) {
      const [{ data: huntRow }, { data: itemRows }] = await Promise.all([
        supabase
          .from("hunts")
          .select("id, name, status, settings, created_at")
          .eq("id", id)
          .maybeSingle(),
        supabase
          .from("hunt_items")
          .select("*")
          .eq("hunt_id", id)
          .eq("type", "qr")
          .order("order_index"),
      ]);

      if (cancelled) return;
      setHunt((huntRow as Hunt) ?? null);
      setItems((itemRows as HuntItem[]) ?? []);
      setLoading(false);
    }

    load(huntId);
    return () => {
      cancelled = true;
    };
  }, [huntId, supabase]);

  if (loading) {
    return <p className="p-8 text-brand-navy/60">Loading QR codes...</p>;
  }

  if (!huntId || !hunt) {
    return <p className="p-8 text-brand-navy/60">Hunt not found.</p>;
  }

  if (items.length === 0) {
    return (
      <p className="p-8 text-brand-navy/60">
        This hunt has no QR-code stops yet. Add a QR item in Setup first.
      </p>
    );
  }

  return (
    <div className="mx-auto max-w-5xl p-6">
      {/* Toolbar — hidden when printing */}
      <div className="mb-6 flex items-center justify-between print:hidden">
        <div>
          <h1 className="font-display text-2xl font-bold text-brand-navy">
            Print QR Stops — {hunt.name}
          </h1>
          <p className="mt-1 text-sm text-brand-navy/60">
            {items.length} QR {items.length === 1 ? "stop" : "stops"}. Print
            this page, then cut out and post each code at its station.
          </p>
        </div>
        <button
          onClick={() => window.print()}
          className="btn-springy rounded-full bg-brand-navy px-6 py-2.5 font-semibold text-white"
        >
          🖨 Print
        </button>
      </div>

      {/* Print grid — 2 cards per row, each card avoids breaking across pages */}
      <div className="grid grid-cols-1 gap-6 sm:grid-cols-2">
        {items.map((item, i) => (
          <div
            key={item.id}
            className="flex break-inside-avoid flex-col items-center rounded-2xl border-2 border-brand-navy/15 p-6 text-center"
          >
            <p className="text-xs font-semibold uppercase tracking-wide text-brand-cyan">
              Stop {i + 1}
            </p>
            <p className="mt-1 font-display text-lg font-bold text-brand-navy">
              {item.prompt}
            </p>
            <div className="my-4">
              <QrImage value={item.qr_value ?? ""} size={220} />
            </div>
            <p className="font-mono text-xs text-brand-navy/40">
              {item.qr_value}
            </p>
            <div className="mt-3 flex items-center gap-2">
              {/* Small FET wordmark for a branded, official look */}
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                src="/brand/fet-logo.webp"
                alt="FET"
                className="h-5 w-auto opacity-70"
              />
              <span className="text-xs text-brand-navy/50">
                Family Fun Day Scavenger Hunt
              </span>
            </div>
          </div>
        ))}
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

export default function PrintQrPage() {
  return (
    <Suspense fallback={<p className="p-8 text-brand-navy/60">Loading...</p>}>
      <PrintQrContent />
    </Suspense>
  );
}
