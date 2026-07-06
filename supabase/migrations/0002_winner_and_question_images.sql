-- ============================================================
-- Winner declaration + image-question support
-- ============================================================

-- ---------- Admin-declared hunt winner ----------
-- Finishing all questions does NOT auto-win a hunt. An admin confirms the
-- winner in Hunt HQ (guided by the all-correct + fastest-time tiebreaker),
-- and the winning team's app reacts live via realtime.
alter table hunts add column winner_team_id uuid references teams(id) on delete set null;

alter publication supabase_realtime add table hunts;

-- ---------- Optional photo attached to a hunt item ----------
-- e.g. "what is this?" with a picture, answered via the existing
-- multiple-choice workflow. Not a secret, so it's exposed via the public
-- view like prompt/choices.
alter table hunt_items add column image_url text;

create or replace view public_hunt_items
  with (security_invoker = true) as
  select id, hunt_id, order_index, type, prompt, choices, points, reveal_message, image_url
  from hunt_items;

grant select (image_url) on hunt_items to anon;

-- ---------- Storage bucket for question photos ----------
-- Public bucket: reads via the public URL endpoint bypass RLS entirely
-- (Supabase docs), so no SELECT policy is added — one was tried and then
-- removed because it let clients list every filename in the bucket via
-- the table API, which the security advisor flagged.
insert into storage.buckets (id, name, public)
values ('question-images', 'question-images', true)
on conflict (id) do nothing;

create policy "admins upload question images" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'question-images');

create policy "admins update question images" on storage.objects
  for update to authenticated
  using (bucket_id = 'question-images')
  with check (bucket_id = 'question-images');

create policy "admins delete question images" on storage.objects
  for delete to authenticated
  using (bucket_id = 'question-images');
