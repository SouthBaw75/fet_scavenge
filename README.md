# FET Family Fun Day — Scavenger Hunt

Web app for Forum Energy Technologies' Broussard facility family fun day:
families register as a team, then work through a shop-floor scavenger hunt
(multiple choice, QR scans, typed answers) against a personal timer. Admins
build the hunt and watch every team's live progress.

See [`PLANNING.md`](./PLANNING.md) for the full phase 1 plan (data model,
flows, scope).

## Stack

- Next.js (App Router) + Tailwind
- Supabase (Postgres, Auth, Realtime)
- Deployed on Netlify

## Getting Started

```bash
npm install
cp .env.example .env.local   # fill in Supabase URL + anon key
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Brand assets

Logo and color tokens live in `assets/brand/` and `src/app/globals.css`
(`--brand-navy`, `--brand-green`, `--brand-cyan`).
