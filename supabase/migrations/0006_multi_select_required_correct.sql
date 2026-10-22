-- ============================================================
-- Multi-select multiple choice with a "required correct" threshold
-- ============================================================
-- A multiple_choice item may mark several options correct (stored in
-- correct_answer, pipe-separated). required_correct is how many of those the
-- family must pick. Grading rule: at least required_correct correct options
-- selected AND zero wrong options selected. required_correct NULL = the old
-- single-select behavior (match any one), so existing items are unchanged.

alter table hunt_items add column if not exists required_correct int;

-- Expose a boolean so the player app knows to render checkboxes, WITHOUT
-- revealing how many options are correct or required.
create or replace view public_hunt_items as
  select id, hunt_id, order_index, type, prompt, choices, points,
         reveal_message, image_url,
         (required_correct is not null) as multi_select
  from hunt_items;

grant select on public_hunt_items to anon;

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
  v_required int;
  v_is_correct boolean;
  v_sel_correct int;
  v_sel_wrong int;
  v_total_items int;
  v_answered_items int;
begin
  select hunt_items.hunt_id, hunt_items.correct_answer, hunt_items.qr_value,
         hunt_items.type, hunt_items.required_correct
  into v_hunt_id, v_correct, v_qr, v_type, v_required
  from hunt_items
  where hunt_items.id = p_hunt_item_id;

  if v_hunt_id is null then
    raise exception 'invalid hunt item';
  end if;

  if v_type = 'open' then
    v_is_correct := true;
  elsif v_type = 'qr' then
    v_is_correct := coalesce(p_answer = v_qr, false);
  elsif v_type = 'multiple_choice' and v_required is not null then
    -- Multi-select: count how many picked options are correct vs wrong.
    with cor as (
      select distinct lower(trim(x)) as v
      from unnest(string_to_array(v_correct, '|')) x
      where trim(x) <> ''
    ),
    sel as (
      select distinct lower(trim(x)) as v
      from unnest(string_to_array(p_answer, '|')) x
      where trim(x) <> ''
    )
    select
      count(*) filter (where sel.v in (select v from cor)),
      count(*) filter (where sel.v not in (select v from cor))
    into v_sel_correct, v_sel_wrong
    from sel;

    v_is_correct := coalesce(
      v_sel_correct >= v_required and coalesce(v_sel_wrong, 0) = 0, false);
  else
    -- text or single-select multiple_choice: match ANY accepted answer.
    v_is_correct := coalesce(exists (
      select 1
      from unnest(string_to_array(v_correct, '|')) as ans
      where lower(trim(ans)) = lower(trim(p_answer))
        and trim(ans) <> ''
    ), false);
  end if;

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

  return query select v_is_correct, case when v_type = 'open' then null else v_correct end;
end;
$$;

grant execute on function submit_answer(uuid, uuid, text) to anon;
