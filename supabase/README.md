# Supabase

`migrations/0001_initial_schema.sql` is the consolidated, verified schema
for the scavenger hunt (tables, RLS, column grants, security-definer RPCs,
and Realtime setup). `migrations/0002_winner_and_question_images.sql` adds
the admin-declared winner and image-question support. Both are already
applied to the hosted project.

## Storage

The `question-images` bucket holds photos attached to multiple-choice
items (e.g. "what is this?" questions). It's a **public** bucket — files
are served by URL without needing a read policy. Only `insert`/`update`/
`delete` policies exist, scoped to `authenticated` (admins), so a family's
phone can view images but never upload/replace/delete them.

## Backend verification (done)

The full family flow was exercised end-to-end against the RPCs:

- anon can register a team, read questions (without answers), start the
  timer, and submit answers
- grading is correct (right/wrong, case- and whitespace-insensitive text
  matching, exact QR matching)
- `finished_at` is stamped only once every item is answered
- `start_hunt` and the finish stamp are idempotent
- anon cannot read `correct_answer` / `qr_value` (blocked by column grants)

## Admin accounts

There is no public admin signup. An initial admin login exists (created
during setup — rotate its password in **Authentication → Users**). Add more
admins the same way in the dashboard: **Authentication → Users → Add User**.
Any authenticated user is treated as an admin in phase 1.
