# FET Family Fun Day — Scavenger Hunt App
## Phase 1 Plan (web-based, multi-user, live admin view)

## 1. Overview

A web app for FET's Broussard facility family fun day. Families register as a
"team" tied to an employee, pick a fun team name, then get led on a shop tour
where each stop is a hunt item (multiple choice, QR scan, or typed answer).
Admins build the hunt ahead of time and watch live team progress/timers during
the event.

## 2. Stack

- **Frontend**: Next.js (React), deployed on Netlify
- **Backend/DB/Auth/Realtime**: Supabase (Postgres, Auth for admins, Realtime
  for live dashboard updates)
- **QR scanning**: browser camera (`getUserMedia`) + a JS QR decode library,
  no native app needed
- Both Supabase and Netlify are already connected in this workspace, so infra
  setup is fast.

## 3. User Roles & Flows

### Admin
1. Logs in (Supabase Auth — email/password, admin-only accounts we create
   manually, no public signup).
2. **Setup**: uploads employee list (CSV), creates a hunt, adds items
   (question text, type, choices/answer/QR value, order, points), configures
   event settings (see §6).
3. **Live view**: dashboard showing every team, their current item, elapsed
   time, correct/incorrect answers, and a start/pause/reset control per team
   or globally.
4. Post-event: leaderboard/export of results.

### Family Team
1. Registration screen: search/select their employee's name from the
   uploaded list.
2. Pick a fun team name. This creates a team session (stored via a
   browser-persisted token/link — no password).
3. Waits for a volunteer/admin to say "go," or self-starts — starts their
   personal timer.
4. Walks through hunt items in order: answer multiple choice, scan a QR code,
   or type an answer. Immediate right/wrong feedback (configurable).
5. Finishes — sees their total time and, if enabled, the final leaderboard.

## 4. Data Model (Postgres via Supabase)

- **employees**: `id, full_name, department (optional), imported_at`
  — uploaded by admin via CSV, used only to populate the searchable list.
- **hunts**: `id, name, status (draft/active/closed), settings (jsonb: see
  §6), created_at`
- **hunt_items**: `id, hunt_id, order_index, type (multiple_choice | qr |
  text), prompt, choices (jsonb, nullable), correct_answer, qr_value
  (nullable), points`
- **teams**: `id, hunt_id, employee_id, team_name, created_at, started_at,
  finished_at`
- **team_progress**: `id, team_id, hunt_item_id, answer_given, is_correct,
  answered_at` — one row per item attempted, drives both the team's own
  progress and the admin live view.
- **admin_users**: handled by Supabase Auth directly (no custom table needed
  unless we want roles later).

Realtime: admins subscribe to `teams` + `team_progress` changes via Supabase
Realtime channels, so the live dashboard updates as families answer/scan
without polling.

## 5. Key Screens

**Public (family) side**
- `/register` — search employee, pick/create team, name the team
- `/hunt` — current item (question/QR/text), progress indicator, timer
- `/hunt/complete` — finish screen with time + leaderboard (if enabled)

**Admin side** (auth-gated)
- `/admin/login`
- `/admin/setup` — hunt settings, item builder (add/reorder/edit items),
  employee list upload
- `/admin/live` — real-time grid/list of all teams: name, status, current
  item, elapsed time, correct/incorrect count
- `/admin/results` — final times, export CSV

## 6. Configurable Hunt Settings (admin)

- Event/hunt name, active date
- Whether wrong answers block progress or just get logged
- Whether teams see immediate correct/incorrect feedback
- Whether the final leaderboard is shown to teams or admin-only
- Item order: fixed vs. randomized per team (avoids shop-floor bottlenecks)
- Max team size / one team per employee (toggle)

## 7. Phase 1 Scope Boundaries (explicitly deferred)

- No native mobile app — mobile browser only (QR scanning works fine there).
- No team login recovery via email/SMS — a lost session just re-registers
  (acceptable for a one-day event).
- No multi-event/tenant support — single active hunt at a time is fine for
  phase 1.
- No photo upload / social-sharing hunt items — only the three answer types
  agreed on.
- No printed badge/ID integration.

## 8. Build Order (milestones)

1. Supabase schema + Netlify project scaffolding, admin auth
2. Admin setup UI: employee CSV upload, hunt item builder
3. Family registration + team creation flow
4. Hunt-taking flow (all three item types) + timer
5. Admin live dashboard (Realtime wiring)
6. Results/leaderboard + CSV export
7. Visual design pass (fun, on-brand FET styling) across all screens
8. Load-test for concurrent teams, polish edge cases (network hiccups,
   camera permission denial fallback for QR, duplicate team names, etc.)

## 9. Confirmed Decisions

- **Scale**: ~50 family teams, ~15-20 hunt items. Comfortably within a single
  Supabase free/pro project; no special load-testing infra needed beyond
  basic concurrency sanity checks.
- **Feedback timing**: teams get NO correct/incorrect feedback during the
  hunt — every item is answered (or scanned) and the team just moves to the
  next one regardless of correctness. All scoring is revealed at the end
  (their own results, and the leaderboard per the earlier decision). This
  simplifies the hunt-taking UI (no right/wrong state to show) and removes
  the "retry" question — there's no retry since there's no feedback loop.
- **Branding**: FET brand colors/logo will be provided as assets and used
  throughout for a professional, on-brand look.

## 10. Brand Assets

- Logo: `assets/brand/fet-logo.webp`
- Colors (extracted directly from the logo file):
  - Navy: `#003046`
  - Green: `#67BC29`
  - Cyan: `#30CCD8`
