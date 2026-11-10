-- Crown & Conquest: send the battle tally to the client.
-- Review this file, then run it yourself. It is not applied from the client.
-- It does not depend on 0003_crown_crews.sql. Apply the two in either order.
-- 0003 is still unapplied and stays a separate crews migration.
--
-- cc_resolve_battle already stores per-unit losses, survivors, acres, gold,
-- food, buildings taken, and buildings razed inside cc_battle_reports.payload.
-- This only teaches cc_reports to return those fields. No rows are deleted
-- and no columns are added. A report written before those keys existed still
-- comes back; the missing fields are null and the client keeps the old sentence.

create or replace function public.cc_reports()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  rows jsonb;
begin
  k := public.cc_lock_kingdom();
  select coalesce(jsonb_agg(s.item order by s.created_at desc), '[]'::jsonb)
  into rows
  from (
    select r.created_at, jsonb_build_object(
      'id', r.id,
      'at', r.created_at,
      'outcome', r.outcome,
      'kind', coalesce(r.payload->>'kind', 'battle'),
      'attack_type', r.payload->>'attack_type',
      'text', case when r.attacker_id = k.id then coalesce(r.payload->>'text', r.outcome) else coalesce(r.payload->>'defender_text', r.payload->>'text', r.outcome) end,
      'you_attacked', r.attacker_id = k.id,
      'attacker', a.name,
      'defender', d.name,
      'attacker_tag', public.cc_tag(a.id),
      'defender_tag', public.cc_tag(d.id),
      'offense', r.payload->>'offense',
      'defense', case when r.attacker_id = k.id then r.payload->>'defense' else null end,
      'roll', r.payload->>'roll',
      'acres', case when r.payload ? 'acres' then (r.payload->>'acres')::int else null end,
      'gold', case when r.payload ? 'gold' then (r.payload->>'gold')::int else null end,
      'food', case when r.payload ? 'food' then (r.payload->>'food')::int else null end,
      'buildings', r.payload->'buildings',
      'razed', r.payload->'razed',
      'att_loss', r.payload->'att_loss',
      'def_loss', r.payload->'def_loss',
      'living', r.payload->'living',
      'att_morale', case when r.payload ? 'att_morale' then (r.payload->>'att_morale')::int else null end,
      'def_morale', case when r.payload ? 'def_morale' then (r.payload->>'def_morale')::int else null end,
      'scout', case when r.attacker_id = k.id then r.payload->'scout' else null end
    ) as item
    from public.cc_battle_reports r
    join public.cc_kingdoms a on a.id = r.attacker_id
    join public.cc_kingdoms d on d.id = r.defender_id
    where r.attacker_id = k.id or r.defender_id = k.id
    order by r.created_at desc
    limit 30
  ) s;
  return jsonb_build_object('reports', rows);
end;
$$;
