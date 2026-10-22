-- ============================================================
-- Open-response item type (any answer accepted, honor-system)
-- ============================================================
-- A new item type `open` accepts whatever the family types: there is no
-- right answer. It always records is_correct = true so it counts toward
-- hunt completion, and the client shows a neutral "answer logged" message
-- instead of CORRECT/INCORRECT. Good for participation/open-ended tasks
-- ("find something blue", "what would you make?").

-- 1) Allow the new type.
alter table hunt_items drop constraint hunt_items_type_check;
alter table hunt_items add constraint hunt_items_type_check
  check (type in ('multiple_choice', 'qr', 'text', 'open'));

-- 2) Grade it: open always counts as answered/correct. The returned
--    correct_answer is null (nothing to reveal), so the client branches
--    on type to show its neutral message.
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

  -- For open items, never leak/echo a correct answer.
  return query select v_is_correct, case when v_type = 'open' then null else v_correct end;
end;
$$;

grant execute on function submit_answer(uuid, uuid, text) to anon;
