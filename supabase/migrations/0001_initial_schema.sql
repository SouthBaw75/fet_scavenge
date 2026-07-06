-- ============================================================
-- FET Family Fun Day Scavenger Hunt — consolidated schema
--
-- This is the full, verified schema for the Supabase project. It
-- reflects the final state after end-to-end backend verification,
-- including the anon (browser) access model that keeps correct
-- answers and QR values hidden from the client.
--
-- Security model:
--   * Admins = any authenticated Supabase user (accounts are created
--     manually in the dashboard; there is no public admin signup).
--   * Families use the anon role. They never touch answer columns:
--     they read questions through the `public_hunt_items` view (which
--     omits correct_answer/qr_value) and submit through the
--     security-definer RPCs, which grade server-side.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- Tables ----------

create table employees (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  department text,
  imported_at timestamptz not null default now()
);

create table hunts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  status text not null default 'draft' check (status in ('draft', 'active', 'closed')),
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table hunt_items (
  id uuid primary key default gen_random_uuid(),
  hunt_id uuid not null references hunts(id) on delete cascade,
  order_index int not null,
  type text not null check (type in ('multiple_choice', 'qr', 'text')),
  prompt text not null,
  choices jsonb,
  correct_answer text,
  qr_value text,
  -- Optional flavor/educational message shown after a QR stop is scanned.
  -- Non-secret (it is not an answer), so it is exposed via the public view.
  reveal_message text,
  points int not null default 1,
  unique (hunt_id, order_index)
);

create table teams (
  id uuid primary key default gen_random_uuid(),
  hunt_id uuid not null references hunts(id) on delete cascade,
  employee_id uuid references employees(id) on delete set null,
  team_name text not null,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
);

create table team_progress (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references teams(id) on delete cascade,
  hunt_item_id uuid not null references hunt_items(id) on delete cascade,
  answer_given text,
  is_correct boolean not null,
  answered_at timestamptz not null default now(),
  unique (team_id, hunt_item_id)
);

create index on hunt_items (hunt_id, order_index);
create index on teams (hunt_id);
create index on team_progress (team_id);
create index on team_progress (hunt_item_id);

-- ---------- Public-safe view (no answer columns) ----------
-- security_invoker so it respects the caller's RLS/column grants.

create view public_hunt_items
  with (security_invoker = true) as
  select id, hunt_id, order_index, type, prompt, choices, points, reveal_message
  from hunt_items;

-- ---------- Row Level Security ----------

alter table employees enable row level security;
alter table hunts enable row level security;
alter table hunt_items enable row level security;
alter table teams enable row level security;
alter table team_progress enable row level security;

-- Admins (any authenticated user) get full access.
create policy "admins full access" on employees     for all to authenticated using (true) with check (true);
create policy "admins full access" on hunts          for all to authenticated using (true) with check (true);
create policy "admins full access" on hunt_items     for all to authenticated using (true) with check (true);
create policy "admins full access" on teams          for all to authenticated using (true) with check (true);
create policy "admins full access" on team_progress  for all to authenticated using (true) with check (true);

-- Anon: search employees + see if a hunt is active during registration.
create policy "public read employees" on employees for select to anon using (true);
create policy "public read hunts"     on hunts     for select to anon using (true);

-- Anon: read hunt items, but only the safe columns (enforced by the
-- column grants below). RLS lets anon see the rows; the missing grants
-- on correct_answer / qr_value keep the answers hidden.
create policy "public read hunt items" on hunt_items for select to anon using (true);

-- Anon: register a team (only for an active hunt) and read teams back
-- (needed for the hunt page and the end-of-hunt leaderboard). Starting
-- and finishing happen only through the security-definer RPCs, so anon
-- gets no UPDATE/DELETE policy.
create policy "public can register teams" on teams
  for insert to anon
  with check (
    exists (select 1 from hunts h where h.id = hunt_id and h.status = 'active')
  );

create policy "public can read teams" on teams
  for select to anon
  using (true);

-- ---------- Column-level grants ----------
-- anon may read every hunt_items column EXCEPT correct_answer/qr_value.

revoke all on hunt_items from anon;
grant select (id, hunt_id, order_index, type, prompt, choices, points, reveal_message)
  on hunt_items to anon;

grant select on public_hunt_items to anon;
grant select, insert on teams to anon;

-- ---------- RPCs (security definer) ----------
-- These are the ONLY write path for the anon (family) client. Grading
-- happens here so answers never reach the browser.

create function start_hunt(p_team_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_started timestamptz;
begin
  update teams
  set started_at = coalesce(started_at, now())
  where id = p_team_id
  returning started_at into v_started;

  return v_started;
end;
$$;

grant execute on function start_hunt(uuid) to anon;

create function submit_answer(p_team_id uuid, p_hunt_item_id uuid, p_answer text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hunt_id uuid;
  v_correct text;
  v_qr text;
  v_type text;
  v_is_correct boolean;
  v_total_items int;
  v_answered_items int;
begin
  select hunt_id, correct_answer, qr_value, type
  into v_hunt_id, v_correct, v_qr, v_type
  from hunt_items
  where id = p_hunt_item_id;

  if v_hunt_id is null then
    raise exception 'invalid hunt item';
  end if;

  -- coalesce: a misconfigured item (null correct_answer / qr_value) grades
  -- as incorrect instead of erroring, so teams are never blocked mid-hunt.
  v_is_correct := coalesce(
    case
      when v_type = 'qr' then p_answer = v_qr
      else lower(trim(p_answer)) = lower(trim(v_correct))
    end,
    false);

  insert into team_progress (team_id, hunt_item_id, answer_given, is_correct)
  values (p_team_id, p_hunt_item_id, p_answer, v_is_correct)
  on conflict (team_id, hunt_item_id) do update
    set answer_given = excluded.answer_given,
        is_correct = excluded.is_correct,
        answered_at = now();

  select count(*) into v_total_items from hunt_items where hunt_id = v_hunt_id;
  select count(*) into v_answered_items
    from team_progress tp
    join hunt_items hi on hi.id = tp.hunt_item_id
    where tp.team_id = p_team_id and hi.hunt_id = v_hunt_id;

  if v_answered_items >= v_total_items then
    update teams set finished_at = coalesce(finished_at, now()) where id = p_team_id;
  end if;
end;
$$;

grant execute on function submit_answer(uuid, uuid, text) to anon;

create function get_team_status(p_team_id uuid)
returns table (hunt_item_id uuid, answered_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select hunt_item_id, answered_at
  from team_progress
  where team_id = p_team_id;
$$;

grant execute on function get_team_status(uuid) to anon;

-- ---------- Realtime ----------
-- The admin live dashboard subscribes to these tables.

alter publication supabase_realtime add table teams;
alter publication supabase_realtime add table team_progress;
