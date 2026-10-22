-- ============================================================
-- Multiple accepted answers for typed items
-- ============================================================
-- correct_answer may now hold several acceptable answers separated by "|"
-- (e.g. "Forum Energy Technologies|FET"). A typed/multiple-choice answer is
-- correct if it matches ANY of them (case- and whitespace-insensitive).
-- A single answer with no "|" behaves exactly as before, so existing items
-- keep working.

create or replace function submit_answer(p_team_id uuid, p_hunt_item_id uuid, p_answer text)
returns table (is_correct boolean, correct_answer text)
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
  select hunt_items.hunt_id, hunt_items.correct_answer, hunt_items.qr_value, hunt_items.type
  into v_hunt_id, v_correct, v_qr, v_type
  from hunt_items
  where hunt_items.id = p_hunt_item_id;

  if v_hunt_id is null then
    raise exception 'invalid hunt item';
  end if;

  v_is_correct := coalesce(
    case
      when v_type = 'open' then true
      when v_type = 'qr' then p_answer = v_qr
      else exists (
        select 1
        from unnest(string_to_array(v_correct, '|')) as ans
        where lower(trim(ans)) = lower(trim(p_answer))
          and trim(ans) <> ''
      )
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

  -- open items reveal nothing; others return the stored answer(s) as-is.
  return query select v_is_correct, case when v_type = 'open' then null else v_correct end;
end;
$$;

grant execute on function submit_answer(uuid, uuid, text) to anon;
