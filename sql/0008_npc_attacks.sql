-- Crown & Conquest: established houses march on their own.
-- Review this file, then run it yourself. It is not applied from here.
-- Requires 0002 (marches, cc_attack, cc_settle, alliances). Uses cc_apply_tick
-- from 0001 or 0006, whichever is installed. Does not require 0003.
--
-- Numbers are the same as NPC_WAR in js/combat.js:
--   cooldown 2h + a random extra of up to 2h (one launch per house)
--   send 35–50% of each stack, and always leave at least one soldier home
--   tight networth window 40–140% of the attacker, then 25–180% if nobody fits
--   skip a target whose partial army is under 35% of the defender's defense
--   humans score +40, same realm +15, plus a 0–30 jitter
--   favored (odds >= 120): conquest 60% / plunder 40%
--   even (odds >= 80): plunder 50% / razing 50%
--   otherwise: plunder 70% / razing 30%
--   any one kingdom receives at most 2 NPC attacks per 6 hours
--   (the human cap, also applied to NPC targets so a weak house is not erased at once)
--   at most 12 missed income ticks are caught up per run
-- Player attacks are unchanged: cc_attack now calls cc_open_march, which is
-- the same march insert cc_attack used to do itself.

alter table public.cc_kingdoms
  add column if not exists npc_next_attack_at timestamptz,
  add column if not exists npc_income_at timestamptz;

create index if not exists cc_battle_reports_defender_recent
  on public.cc_battle_reports (defender_id, created_at desc);

-- ---------- shared march launch (players and NPCs) ----------
create or replace function public.cc_open_march(
  p_attacker bigint,
  p_target bigint,
  p_type text,
  p_units jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $fn$
#variable_conflict use_column
declare
  k public.cc_kingdoms;
  target public.cc_kingdoms;
  id text;
  n int;
  total int := 0;
  home int;
  travel int;
begin
  if p_type not in ('conquest', 'plunder', 'razing') then
    raise exception 'Choose a raid.';
  end if;
  if p_units is null or jsonb_typeof(p_units) <> 'object' then
    raise exception 'Choose how many to send.';
  end if;
  select * into k from public.cc_kingdoms where id = p_attacker for update;
  if k.id is null then
    raise exception 'That kingdom is gone.';
  end if;
  select * into target from public.cc_kingdoms where id = p_target for update;
  if target.id is null then
    raise exception 'No kingdom by that name.';
  end if;
  if target.id = k.id then
    raise exception 'You cannot attack your own gates.';
  end if;
  if public.cc_same_alliance(k.id, target.id) then
    raise exception 'You share an alliance.';
  end if;
  if not target.is_npc and target.attacked_at is null and target.protected_until > now() then
    raise exception 'That kingdom is under protection.';
  end if;
  if (select count(*) from public.cc_marches where attacker_id = k.id and kind = 'army') >= 3 then
    raise exception 'Three hosts are already in the field.';
  end if;
  if exists (
    select 1 from public.cc_marches
    where attacker_id = k.id and defender_id = target.id and kind = 'army'
  ) then
    raise exception 'A host is already marching on that kingdom.';
  end if;
  foreach id in array array['militia','footmen','pikemen','archers','knights','siege','warden','spellbow','wyvern']
  loop
    n := public.cc_unit_n(p_units, id);
    if n < 0 or n > 5000 then
      raise exception 'Choose how many to send.';
    end if;
    home := case id
      when 'militia' then k.u_militia when 'footmen' then k.u_footmen when 'pikemen' then k.u_pikemen
      when 'archers' then k.u_archers when 'knights' then k.u_knights when 'siege' then k.u_siege
      when 'warden' then k.u_warden when 'spellbow' then k.u_spellbow else k.u_wyvern end;
    if n > home then
      raise exception 'Not enough soldiers at home.';
    end if;
    total := total + n;
  end loop;
  if total <= 0 then
    raise exception 'Send at least one soldier.';
  end if;
  k := public.cc_apply_loss_units(k, p_units, -1);
  k.attacked_at := coalesce(k.attacked_at, now());
  k.protected_until := now();
  k := public.cc_note(k, now(), 'Your host marched on ' || target.name || '.');
  travel := public.cc_travel_seconds(k.realm_id = target.realm_id, false);
  insert into public.cc_marches (attacker_id, defender_id, kind, attack_type, phase, units, started_at, arrives_at)
  values (k.id, target.id, 'army', p_type, 'out', p_units, now(), now() + make_interval(secs => travel));
  perform public.cc_save_kingdom(k);
end;
$fn$;

create or replace function public.cc_attack(p_target bigint, p_type text, p_units jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
#variable_conflict use_column
declare
  row public.cc_players;
  k public.cc_kingdoms;
begin
  k := public.cc_lock_kingdom();
  perform public.cc_open_march(k.id, p_target, p_type, p_units);
  select * into row from public.cc_players where id = k.owner_id;
  return public.cc_state_json(row, false);
end;
$fn$;

-- ---------- NPC development ----------
create or replace function public.cc_npc_sync_anchor(k public.cc_kingdoms)
returns public.cc_kingdoms
language plpgsql
security definer
set search_path = public
as $fn$
#variable_conflict use_column
declare
  anchor jsonb;
  id text;
  cur int;
  old int;
begin
  if k.npc_anchor is null then
    k.npc_anchor := public.cc_anchor_of(k);
    return k;
  end if;
  anchor := k.npc_anchor;
  anchor := jsonb_set(anchor, '{gold}', to_jsonb(least(coalesce((anchor->>'gold')::int, k.gold), k.gold)));
  anchor := jsonb_set(anchor, '{food}', to_jsonb(least(coalesce((anchor->>'food')::int, k.food), k.food)));
  anchor := jsonb_set(anchor, '{land}', to_jsonb(greatest(coalesce((anchor->>'land')::int, k.land), k.land)));
  foreach id in array array['militia','footmen','pikemen','archers','knights','siege','warden','spellbow','wyvern']
  loop
    cur := public.cc_unit_n(public.cc_units_json(k), id);
    old := public.cc_unit_n(anchor->'units', id);
    anchor := jsonb_set(anchor, array['units', id], to_jsonb(greatest(old, cur)));
  end loop;
  foreach id in array array['farm','granary','home','market','mine','barracks','tower','library','wall','shrine']
  loop
    cur := case id
      when 'farm' then k.b_farm when 'home' then k.b_home when 'market' then k.b_market
      when 'mine' then k.b_mine when 'barracks' then k.b_barracks when 'tower' then k.b_tower
      when 'library' then k.b_library when 'wall' then k.b_wall when 'shrine' then k.b_shrine
      else k.b_granary end;
    old := public.cc_unit_n(anchor->'buildings', id);
    anchor := jsonb_set(anchor, array['buildings', id], to_jsonb(greatest(old, cur)));
  end loop;
  k.npc_anchor := anchor;
  return k;
end;
$fn$;

create or replace function public.cc_npc_develop(k public.cc_kingdoms)
returns public.cc_kingdoms
language plpgsql
security definer
set search_path = public
as $fn$
#variable_conflict use_column
declare
  steps int := 0;
  i int;
  id text;
  best text;
  best_atk int;
  batch int;
  need_gold int;
  need_food int;
  need_peasants int;
  need_housing int;
  atk int;
  bid text;
  cost int;
  trained boolean := false;
begin
  if k.npc_anchor is null then
    k.npc_anchor := public.cc_anchor_of(k);
  end if;
  if k.npc_income_at is not null then
    steps := least(
      12,
      greatest(0, floor(extract(epoch from (now() - k.npc_income_at)) / public.cc_tick_seconds())::int)
    );
  end if;
  for i in 1..steps loop
    k := public.cc_apply_tick(k);
  end loop;
  k.npc_income_at := now();

  if k.b_barracks >= 1 then
    best := null;
    best_atk := -1;
    foreach id in array array['wyvern','siege','spellbow','knights','warden','archers','footmen','pikemen','militia']
    loop
      if k.r_military < coalesce(public.cc_unit(id, 'req_military'), 99) then
        continue;
      end if;
      if k.r_magic < coalesce(public.cc_unit(id, 'req_magic'), 99) then
        continue;
      end if;
      batch := public.cc_unit(id, 'batch');
      if batch is null or batch < 1 then
        continue;
      end if;
      need_gold := public.cc_unit(id, 'gold') * batch;
      need_food := public.cc_unit(id, 'food') * batch;
      need_peasants := public.cc_unit(id, 'peasants') * batch;
      need_housing := public.cc_unit(id, 'housing') * batch;
      if k.gold < need_gold or k.food < need_food then
        continue;
      end if;
      if k.peasants - need_peasants < 20 then
        continue;
      end if;
      if public.cc_housing_used(k.id) + need_housing > (30 + k.b_barracks * 48) then
        continue;
      end if;
      atk := coalesce(public.cc_unit(id, 'attack'), 0);
      if atk > best_atk then
        best := id;
        best_atk := atk;
      end if;
    end loop;
    if best is not null then
      batch := public.cc_unit(best, 'batch');
      k.gold := k.gold - public.cc_unit(best, 'gold') * batch;
      k.food := k.food - public.cc_unit(best, 'food') * batch;
      k.peasants := k.peasants - public.cc_unit(best, 'peasants') * batch;
      k := public.cc_apply_loss_units(k, jsonb_build_object(best, batch), 1);
      k := public.cc_note(k, now(), batch || ' ' || best || ' finished training.');
      trained := true;
    end if;
  end if;

  if not trained then
    foreach bid in array array['barracks','farm','mine','home','granary','tower','wall','market','library','shrine']
    loop
      cost := public.cc_building_cost(bid);
      if cost is null or k.gold < cost then
        continue;
      end if;
      if public.cc_free_land(k.id) < 1 then
        exit;
      end if;
      k.gold := k.gold - cost;
      k := public.cc_apply_buildings(k, jsonb_build_object(bid, 1), 1);
      k := public.cc_note(k, now(), 'A ' || bid || ' was raised.');
      exit;
    end loop;
  end if;

  k := public.cc_npc_sync_anchor(k);
  return k;
end;
$fn$;

-- ---------- targeting ----------
create or replace function public.cc_npc_recent_hits(p_defender bigint)
returns int
language sql
stable
security definer
set search_path = public
as $fn$
  select (
    select count(*)::int
    from public.cc_marches m
    join public.cc_kingdoms a on a.id = m.attacker_id
    where m.defender_id = p_defender
      and m.kind = 'army'
      and m.phase = 'out'
      and a.is_npc
  ) + (
    select count(*)::int
    from public.cc_battle_reports r
    join public.cc_kingdoms a on a.id = r.attacker_id
    where r.defender_id = p_defender
      and a.is_npc
      and r.created_at > now() - interval '6 hours'
      and coalesce(r.payload->>'kind', 'battle') = 'battle'
  );
$fn$;

create or replace function public.cc_npc_pick_target(k public.cc_kingdoms, p_sent jsonb)
returns table (target_id bigint, attack_type text, odds_ratio int)
language plpgsql
security definer
set search_path = public
as $fn$
#variable_conflict use_column
declare
  cand public.cc_kingdoms;
  pass int;
  wide boolean;
  offense int;
  defense int;
  odds int;
  score int;
  best_score int;
  best_id bigint;
  best_odds int;
  att_nw int;
  def_nw int;
  nw_pct int;
begin
  offense := public.cc_force_offense(k.land_type, k.r_military, k.food, k.morale, p_sent);
  if offense < 1 then
    target_id := null;
    attack_type := null;
    odds_ratio := null;
    return next;
    return;
  end if;
  att_nw := public.cc_networth(k);
  for pass in 1..2 loop
    wide := pass = 2;
    best_score := null;
    best_id := null;
    best_odds := null;
    for cand in
      select * from public.cc_kingdoms c
      where c.id <> k.id
      order by c.id
    loop
      if public.cc_same_alliance(k.id, cand.id) then
        continue;
      end if;
      if not cand.is_npc and cand.attacked_at is null and cand.protected_until > now() then
        continue;
      end if;
      if exists (
        select 1 from public.cc_marches m
        where m.attacker_id = k.id and m.defender_id = cand.id and m.kind = 'army'
      ) then
        continue;
      end if;
      if public.cc_npc_recent_hits(cand.id) >= 2 then
        continue;
      end if;
      def_nw := public.cc_networth(cand);
      nw_pct := ((def_nw::bigint * 100) / greatest(att_nw, 1))::int;
      if wide then
        if nw_pct < 25 or nw_pct > 180 then
          continue;
        end if;
      elsif nw_pct < 40 or nw_pct > 140 then
        continue;
      end if;
      defense := public.cc_home_defense(cand);
      if defense <= 0 then
        odds := 200;
      else
        odds := ((offense::bigint * 100) / defense)::int;
      end if;
      if odds < 35 then
        continue;
      end if;
      score := odds
        + case when not cand.is_npc then 40 else 0 end
        + case when cand.realm_id = k.realm_id then 15 else 0 end
        + floor(random() * 31)::int;
      if best_score is null or score > best_score then
        best_score := score;
        best_id := cand.id;
        best_odds := odds;
      end if;
    end loop;
    exit when best_id is not null;
  end loop;
  if best_id is null then
    target_id := null;
    attack_type := null;
    odds_ratio := null;
    return next;
    return;
  end if;
  target_id := best_id;
  odds_ratio := best_odds;
  if best_odds >= 120 then
    attack_type := case when floor(random() * 100)::int < 60 then 'conquest' else 'plunder' end;
  elsif best_odds >= 80 then
    attack_type := case when floor(random() * 100)::int < 50 then 'plunder' else 'razing' end;
  else
    attack_type := case when floor(random() * 100)::int < 70 then 'plunder' else 'razing' end;
  end if;
  return next;
end;
$fn$;

create or replace function public.cc_npc_act()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
#variable_conflict use_column
declare
  npc_id bigint;
  k public.cc_kingdoms;
  choice record;
  launched int := 0;
  developed int := 0;
  held int := 0;
  id text;
  have int;
  n int;
  total int;
  home int;
  pct int;
  sent jsonb;
  armies int;
  errors jsonb := '[]'::jsonb;
begin
  if not pg_try_advisory_xact_lock(842001, 8) then
    return jsonb_build_object('ok', true, 'busy', true, 'launched', 0, 'developed', 0, 'held', 0, 'errors', '[]'::jsonb);
  end if;
  perform set_config('lock_timeout', '1500', true);

  for npc_id in
    select c.id
    from public.cc_kingdoms c
    where c.is_npc and c.owner_id is null
    order by c.id
  loop
    select * into k from public.cc_kingdoms where id = npc_id for update skip locked;
    if k.id is null then
      held := held + 1;
    else
      begin
        perform public.cc_settle(k.id);
        select * into k from public.cc_kingdoms where id = npc_id;
        k := public.cc_npc_develop(k);
        perform public.cc_save_kingdom(k);
        update public.cc_kingdoms
        set npc_income_at = k.npc_income_at
        where id = k.id;
        developed := developed + 1;

        begin
          if k.npc_next_attack_at is not null and k.npc_next_attack_at > now() then
            held := held + 1;
          else
            select count(*) into armies
            from public.cc_marches
            where attacker_id = k.id and kind = 'army';
            if armies >= 3 then
              held := held + 1;
            else
              pct := 35 + floor(random() * 16)::int;
              sent := '{}'::jsonb;
              total := 0;
              home := 0;
              foreach id in array array['militia','footmen','pikemen','archers','knights','siege','warden','spellbow','wyvern']
              loop
                have := case id
                  when 'militia' then k.u_militia when 'footmen' then k.u_footmen when 'pikemen' then k.u_pikemen
                  when 'archers' then k.u_archers when 'knights' then k.u_knights when 'siege' then k.u_siege
                  when 'warden' then k.u_warden when 'spellbow' then k.u_spellbow else k.u_wyvern end;
                n := (have * pct) / 100;
                if n > 5000 then
                  n := 5000;
                end if;
                if n > have then
                  n := have;
                end if;
                if n < 0 then
                  n := 0;
                end if;
                sent := sent || jsonb_build_object(id, n);
                total := total + n;
                home := home + (have - n);
              end loop;
              if total < 1 or home < 1 then
                held := held + 1;
              else
                select * into choice from public.cc_npc_pick_target(k, sent);
                if choice.target_id is null then
                  held := held + 1;
                else
                  perform public.cc_open_march(k.id, choice.target_id, choice.attack_type, sent);
                  update public.cc_kingdoms
                  set npc_next_attack_at = now() + make_interval(secs => 7200 + floor(random() * 7200)::int)
                  where id = k.id;
                  launched := launched + 1;
                end if;
              end if;
            end if;
          end if;
        exception
          when others then
            held := held + 1;
            if jsonb_array_length(errors) < 8 then
              errors := errors || jsonb_build_array(npc_id::text || ': ' || sqlerrm);
            end if;
            raise warning 'cc_npc_act did not march kingdom %: %', npc_id, sqlerrm;
        end;
      exception
        when lock_not_available or deadlock_detected then
          held := held + 1;
        when others then
          held := held + 1;
          if jsonb_array_length(errors) < 8 then
            errors := errors || jsonb_build_array(npc_id::text || ': ' || sqlerrm);
          end if;
          raise warning 'cc_npc_act skipped kingdom %: %', npc_id, sqlerrm;
      end;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'busy', false,
    'launched', launched,
    'developed', developed,
    'held', held,
    'errors', errors
  );
end;
$fn$;

create or replace function public.cc_admin_npc_act_now()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not public.cc_is_admin() then
    raise exception 'Admins only.';
  end if;
  return public.cc_npc_act();
end;
$fn$;

-- War Room reports name the attacker. This adds whether that house is an NPC
-- so the client can label it. Older rows still resolve through the kingdom row.
create or replace function public.cc_reports()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
#variable_conflict use_column
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
      'attacker_npc', a.is_npc,
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
$fn$;

-- ---------- lock the new functions ----------
revoke all on function public.cc_open_march(bigint, bigint, text, jsonb) from public, anon, authenticated;
revoke all on function public.cc_npc_sync_anchor(public.cc_kingdoms) from public, anon, authenticated;
revoke all on function public.cc_npc_develop(public.cc_kingdoms) from public, anon, authenticated;
revoke all on function public.cc_npc_recent_hits(bigint) from public, anon, authenticated;
revoke all on function public.cc_npc_pick_target(public.cc_kingdoms, jsonb) from public, anon, authenticated;
revoke all on function public.cc_npc_act() from public, anon, authenticated;
revoke all on function public.cc_admin_npc_act_now() from public, anon;

grant execute on function public.cc_admin_npc_act_now() to authenticated;

-- ---------- schedule ----------
-- Supabase installs pg_cron into pg_catalog and keeps its tables in schema cron.
-- https://supabase.com/docs/guides/cron/install
create extension if not exists pg_cron with schema pg_catalog;

grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;
grant execute on function public.cc_npc_act() to postgres;

do $unschedule$
declare
  existing bigint;
begin
  for existing in select jobid from cron.job where jobname = 'cc_npc_act' loop
    perform cron.unschedule(existing);
  end loop;
end
$unschedule$;

select cron.schedule(
  'cc_npc_act',
  '*/5 * * * *',
  $cc_npc_job$select public.cc_npc_act();$cc_npc_job$
);
