-- ============================================================
-- Instant correct/incorrect feedback (per-hunt opt-in)
-- ============================================================
-- submit_answer now reports back whether the answer was correct and, for
-- multiple_choice/text items, what the correct answer was — so the family
-- client can show it immediately when the hunt's show_immediate_feedback
-- setting is on. QR items return a null correct_answer: there's nothing
-- meaningful to display for a scanned code, and they already have their
-- own "you found it" reveal.

drop function submit_answer(uuid, uuid, text);

create function submit_answer(p_team_id uuid, p_hunt_item_id uuid, p_answer text)
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
  -- Table columns are qualified below: this function's RETURNS TABLE
  -- declares an implicit `correct_answer` variable that would otherwise
  -- collide with hunt_items.correct_answer ("ambiguous column" error).
  select hunt_items.hunt_id, hunt_items.correct_answer, hunt_items.qr_value, hunt_items.type
  into v_hunt_id, v_correct, v_qr, v_type
  from hunt_items
  where hunt_items.id = p_hunt_item_id;

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

  return query select v_is_correct, v_correct;
end;
$$;

grant execute on function submit_answer(uuid, uuid, text) to anon;
