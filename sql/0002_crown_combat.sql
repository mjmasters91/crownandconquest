-- Crown & Conquest combat and alliances. Not applied.
-- Run this after 0001_crown_core.sql / migration cc_0001_crown_core.
-- It does not edit that file. It adds columns, tables, and replaces functions
-- that must learn about marches, protection, and pact tags.
-- A shared realm is not an alliance. Only members of the same pact are immune.
-- Keep the integer math in step with crown/js/combat.js.
-- Hosted Supabase rejects DELETE and UPDATE with no WHERE. This file has neither.

-- ---------- columns on the kingdom ----------
alter table public.cc_kingdoms add column if not exists morale int not null default 100;
alter table public.cc_kingdoms add column if not exists spies int not null default 2;
alter table public.cc_kingdoms add column if not exists protected_until timestamptz;
alter table public.cc_kingdoms add column if not exists attacked_at timestamptz;
alter table public.cc_kingdoms add column if not exists last_hit_at timestamptz;
alter table public.cc_kingdoms add column if not exists npc_tier int not null default 0;
alter table public.cc_kingdoms add column if not exists npc_anchor jsonb;

alter table public.cc_kingdoms drop constraint if exists cc_kingdoms_morale_range;
alter table public.cc_kingdoms add constraint cc_kingdoms_morale_range check (morale between 0 and 100);
alter table public.cc_kingdoms drop constraint if exists cc_kingdoms_spies_range;
alter table public.cc_kingdoms add constraint cc_kingdoms_spies_range check (spies between 0 and 100);

update public.cc_kingdoms
set protected_until = created_at + interval '24 hours',
    morale = 100,
    spies = 2
where not is_npc and protected_until is null;

-- ---------- marches and pacts ----------
create table if not exists public.cc_marches (
  id bigint generated always as identity primary key,
  attacker_id bigint not null references public.cc_kingdoms (id) on delete cascade,
  defender_id bigint not null references public.cc_kingdoms (id) on delete cascade,
  kind text not null check (kind in ('army', 'spy')),
  attack_type text check (attack_type in ('conquest', 'plunder', 'razing')),
  phase text not null check (phase in ('out', 'back')),
  units jsonb not null default '{}'::jsonb,
  loot jsonb not null default '{}'::jsonb,
  detail jsonb not null default '{}'::jsonb,
  started_at timestamptz not null,
  arrives_at timestamptz not null
);

create index if not exists cc_marches_attacker on public.cc_marches (attacker_id, arrives_at);
create index if not exists cc_marches_defender on public.cc_marches (defender_id, arrives_at);

create table if not exists public.cc_alliances (
  id bigint generated always as identity primary key,
  name text not null,
  tag text not null,
  description text not null default '',
  leader_kingdom_id bigint not null references public.cc_kingdoms (id) on delete cascade,
  created_at timestamptz not null default now()
);

create unique index if not exists cc_alliances_name_lower on public.cc_alliances (lower(name));
create unique index if not exists cc_alliances_tag_lower on public.cc_alliances (lower(tag));

create table if not exists public.cc_alliance_members (
  kingdom_id bigint primary key references public.cc_kingdoms (id) on delete cascade,
  alliance_id bigint not null references public.cc_alliances (id) on delete cascade,
  role text not null check (role in ('leader', 'officer', 'member')),
  joined_at timestamptz not null default now()
);

create index if not exists cc_alliance_members_alliance on public.cc_alliance_members (alliance_id);

create table if not exists public.cc_alliance_requests (
  id bigint generated always as identity primary key,
  alliance_id bigint not null references public.cc_alliances (id) on delete cascade,
  kingdom_id bigint not null references public.cc_kingdoms (id) on delete cascade,
  kind text not null check (kind in ('join', 'invite')),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now()
);

create unique index if not exists cc_alliance_requests_pending
  on public.cc_alliance_requests (alliance_id, kingdom_id, kind)
  where status = 'pending';

alter table public.cc_marches enable row level security;
alter table public.cc_alliances enable row level security;
alter table public.cc_alliance_members enable row level security;
alter table public.cc_alliance_requests enable row level security;

drop policy if exists cc_reports_involved on public.cc_battle_reports;
create policy cc_reports_involved on public.cc_battle_reports
  for select to authenticated using (
    exists (select 1 from public.cc_kingdoms a where a.id = attacker_id and a.owner_id = auth.uid())
    or exists (select 1 from public.cc_kingdoms d where d.id = defender_id and d.owner_id = auth.uid())
  );

revoke all on public.cc_marches from public, anon, authenticated;
revoke all on public.cc_alliances from public, anon, authenticated;
revoke all on public.cc_alliance_members from public, anon, authenticated;
revoke all on public.cc_alliance_requests from public, anon, authenticated;
grant select on public.cc_battle_reports to authenticated;

-- ---------- combat math (mirrors js/combat.js) ----------
create or replace function public.cc_unit_n(p_units jsonb, p_id text)
returns int
language sql
immutable
as $$
  select coalesce((p_units->>p_id)::int, 0);
$$;

create or replace function public.cc_force_offense(
  p_land text, p_military int, p_food int, p_morale int, p_units jsonb
) returns int
language plpgsql
immutable
as $$
declare
  raw int := 0;
  atk_pct int;
  starve int;
  morale_pct int;
begin
  raw := public.cc_unit_n(p_units, 'militia') * 1
    + public.cc_unit_n(p_units, 'footmen') * 4
    + public.cc_unit_n(p_units, 'pikemen') * 3
    + public.cc_unit_n(p_units, 'archers') * 7
    + public.cc_unit_n(p_units, 'knights') * 12
    + public.cc_unit_n(p_units, 'siege') * 16
    + public.cc_unit_n(p_units, 'warden') * 9
    + public.cc_unit_n(p_units, 'spellbow') * 14
    + public.cc_unit_n(p_units, 'wyvern') * 22;
  atk_pct := (public.cc_land(p_land, 'attack') * (100 + coalesce(p_military, 0) * 3)) / 100;
  starve := case when coalesce(p_food, 0) <= 0 then 62 else 100 end;
  morale_pct := case when coalesce(p_morale, 100) >= 70 then 100 else 95 end;
  return ((raw * atk_pct / 100) * starve / 100) * morale_pct / 100;
end;
$$;

create or replace function public.cc_home_defense(k public.cc_kingdoms)
returns int
language plpgsql
immutable
as $$
declare
  raw int;
  def_pct int;
  starve int;
  fortified int;
  fort int;
  morale_pct int;
begin
  raw := k.u_militia * 2 + k.u_footmen * 5 + k.u_pikemen * 8 + k.u_archers * 3
    + k.u_knights * 10 + k.u_siege * 4 + k.u_warden * 12 + k.u_spellbow * 5 + k.u_wyvern * 16;
  def_pct := (public.cc_land(k.land_type, 'defense') * (100 + k.r_military * 3)) / 100;
  starve := case when k.food <= 0 then 75 else 100 end;
  fortified := ((raw * def_pct / 100) * starve / 100);
  fort := 1000 + k.b_wall * 40 + k.b_tower * 30;
  morale_pct := case when k.morale >= 70 then 100 else 95 end;
  return (fortified * fort / 1000) * morale_pct / 100;
end;
$$;

create or replace function public.cc_units_json(k public.cc_kingdoms)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'militia', k.u_militia, 'footmen', k.u_footmen, 'pikemen', k.u_pikemen,
    'archers', k.u_archers, 'knights', k.u_knights, 'siege', k.u_siege,
    'warden', k.u_warden, 'spellbow', k.u_spellbow, 'wyvern', k.u_wyvern
  );
$$;

create or replace function public.cc_size_scale(p_att int, p_def int)
returns int
language sql
immutable
as $$
  select case
    when greatest(p_att, 1) > greatest(p_def, 1) * 2
      then greatest(25, (200 * greatest(p_def, 1)) / greatest(p_att, 1))
    when greatest(p_def, 1) > greatest(p_att, 1)
      then least(160, 100 + ((greatest(p_def, 1) - greatest(p_att, 1)) * 40) / greatest(p_att, 1))
    else 100
  end;
$$;

create or replace function public.cc_hit_scale(p_last timestamptz, p_now timestamptz)
returns int
language sql
stable
as $$
  select case
    when p_last is null then 100
    when p_now - p_last < interval '30 minutes' then 25
    when p_now - p_last < interval '3 hours' then 50
    when p_now - p_last < interval '8 hours' then 75
    else 100
  end;
$$;

create or replace function public.cc_loss_pct(p_offense int, p_defense int, p_win boolean)
returns table (attacker int, defender int)
language plpgsql
immutable
as $$
declare
  off int := greatest(1, p_offense);
  def int := greatest(1, p_defense);
  att int;
  hold int;
begin
  att := 10 + least(35, (def * 40) / off);
  hold := 15 + least(45, (off * 35) / def);
  if p_win then
    att := greatest(6, att - 8);
    hold := least(70, hold + 10);
  else
    att := least(55, att + 12);
    hold := greatest(5, hold - 8);
  end if;
  attacker := att;
  defender := hold;
  return next;
end;
$$;

create or replace function public.cc_losses(p_units jsonb, p_pct int)
returns jsonb
language plpgsql
immutable
as $$
declare
  result jsonb := '{}'::jsonb;
  id text;
  count int;
  lost int;
begin
  foreach id in array array['militia','footmen','pikemen','archers','knights','siege','warden','spellbow','wyvern']
  loop
    count := public.cc_unit_n(p_units, id);
    lost := (count * p_pct) / 100;
    if count >= 8 and lost = 0 and p_pct >= 8 then
      lost := 1;
    end if;
    lost := least(count, lost);
    result := result || jsonb_build_object(id, lost);
  end loop;
  return result;
end;
$$;

create or replace function public.cc_living(p_units jsonb, p_lost jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  result jsonb := '{}'::jsonb;
  id text;
begin
  foreach id in array array['militia','footmen','pikemen','archers','knights','siege','warden','spellbow','wyvern']
  loop
    result := result || jsonb_build_object(id, greatest(0, public.cc_unit_n(p_units, id) - public.cc_unit_n(p_lost, id)));
  end loop;
  return result;
end;
$$;

create or replace function public.cc_unit_sum(p_units jsonb)
returns int
language sql
immutable
as $$
  select public.cc_unit_n(p_units, 'militia') + public.cc_unit_n(p_units, 'footmen')
    + public.cc_unit_n(p_units, 'pikemen') + public.cc_unit_n(p_units, 'archers')
    + public.cc_unit_n(p_units, 'knights') + public.cc_unit_n(p_units, 'siege')
    + public.cc_unit_n(p_units, 'warden') + public.cc_unit_n(p_units, 'spellbow')
    + public.cc_unit_n(p_units, 'wyvern');
$$;

create or replace function public.cc_take_buildings(k public.cc_kingdoms, p_acres int)
returns jsonb
language plpgsql
immutable
as $$
declare
  built int;
  taken int;
  id text;
  ids text[] := array['farm','home','market','mine','barracks','tower','library','wall','shrine','granary'];
  counts int[];
  removed int[];
  exact numeric;
  base int;
  assigned int := 0;
  i int;
  best int;
  best_i int;
begin
  counts := array[k.b_farm, k.b_home, k.b_market, k.b_mine, k.b_barracks, k.b_tower, k.b_library, k.b_wall, k.b_shrine, k.b_granary];
  removed := array[0,0,0,0,0,0,0,0,0,0];
  built := counts[1]+counts[2]+counts[3]+counts[4]+counts[5]+counts[6]+counts[7]+counts[8]+counts[9]+counts[10];
  if p_acres <= 0 or built <= 0 or k.land <= 0 then
    return jsonb_build_object('farm',0,'home',0,'market',0,'mine',0,'barracks',0,'tower',0,'library',0,'wall',0,'shrine',0,'granary',0);
  end if;
  taken := least(built, (p_acres * built) / k.land);
  for i in 1..10 loop
    exact := taken::numeric * counts[i] / built;
    base := floor(exact)::int;
    removed[i] := base;
    assigned := assigned + base;
  end loop;
  while assigned < taken loop
    best := -1;
    best_i := 0;
    for i in 1..10 loop
      if removed[i] < counts[i] and (taken::numeric * counts[i] / built - removed[i]) > best then
        best := (taken::numeric * counts[i] / built - removed[i]);
        best_i := i;
      end if;
    end loop;
    exit when best_i = 0;
    removed[best_i] := removed[best_i] + 1;
    assigned := assigned + 1;
  end loop;
  return jsonb_build_object(
    'farm', removed[1], 'home', removed[2], 'market', removed[3], 'mine', removed[4],
    'barracks', removed[5], 'tower', removed[6], 'library', removed[7], 'wall', removed[8],
    'shrine', removed[9], 'granary', removed[10]
  );
end;
$$;

create or replace function public.cc_raze_buildings(k public.cc_kingdoms, p_razes int)
returns jsonb
language plpgsql
immutable
as $$
declare
  counts int[] := array[k.b_farm, k.b_home, k.b_market, k.b_mine, k.b_barracks, k.b_tower, k.b_library, k.b_wall, k.b_shrine, k.b_granary];
  removed int[] := array[0,0,0,0,0,0,0,0,0,0];
  left_n int := p_razes;
  best int;
  best_i int;
  i int;
begin
  while left_n > 0 loop
    best := 0;
    best_i := 0;
    for i in 1..10 loop
      if counts[i] - removed[i] > best then
        best := counts[i] - removed[i];
        best_i := i;
      end if;
    end loop;
    exit when best_i = 0 or best <= 0;
    removed[best_i] := removed[best_i] + 1;
    left_n := left_n - 1;
  end loop;
  return jsonb_build_object(
    'farm', removed[1], 'home', removed[2], 'market', removed[3], 'mine', removed[4],
    'barracks', removed[5], 'tower', removed[6], 'library', removed[7], 'wall', removed[8],
    'shrine', removed[9], 'granary', removed[10]
  );
end;
$$;

create or replace function public.cc_resolve_battle(
  att public.cc_kingdoms,
  def public.cc_kingdoms,
  p_sent jsonb,
  p_type text,
  p_roll int,
  p_now timestamptz
) returns jsonb
language plpgsql
stable
as $$
declare
  offense int;
  defense int;
  roll int;
  struck int;
  win boolean;
  percents record;
  att_loss jsonb;
  def_loss jsonb;
  living jsonb;
  scale int;
  recent int;
  loot_scale int;
  acres int := 0;
  gold int := 0;
  food int := 0;
  buildings jsonb := '{}'::jsonb;
  razed jsonb := '{}'::jsonb;
  margin int;
  built int;
  razes int;
  living_n int;
  who text;
  text_att text;
  text_def text;
begin
  offense := public.cc_force_offense(att.land_type, att.r_military, att.food, att.morale, p_sent);
  defense := public.cc_home_defense(def);
  roll := least(115, greatest(85, p_roll));
  struck := (offense * roll) / 100;
  win := struck > defense;
  select * into percents from public.cc_loss_pct(offense, defense, win);
  att_loss := public.cc_losses(p_sent, percents.attacker);
  def_loss := public.cc_losses(public.cc_units_json(def), percents.defender);
  living := public.cc_living(p_sent, att_loss);
  living_n := public.cc_unit_sum(living);
  scale := public.cc_size_scale(public.cc_networth(att), public.cc_networth(def));
  recent := public.cc_hit_scale(def.last_hit_at, p_now);
  loot_scale := (scale * recent) / 100;
  if win and living_n > 0 then
    if p_type = 'conquest' then
      acres := greatest(1, def.land / 25);
      margin := least(150, (struck * 100) / greatest(1, defense));
      acres := (acres * margin) / 100;
      acres := (acres * loot_scale) / 100;
      acres := least(acres, def.land / 8, 80);
      acres := least(acres, greatest(0, def.land - 40));
      buildings := public.cc_take_buildings(def, acres);
    elsif p_type = 'plunder' then
      gold := least(def.gold / 4, greatest(50, offense * 2));
      food := least(def.food / 4, greatest(50, offense * 2));
      gold := least((def.gold * 30) / 100, (gold * loot_scale) / 100);
      food := least((def.food * 30) / 100, (food * loot_scale) / 100);
    elsif p_type = 'razing' then
      built := def.b_farm + def.b_home + def.b_market + def.b_mine + def.b_barracks
        + def.b_tower + def.b_library + def.b_wall + def.b_shrine + def.b_granary;
      razes := greatest(1, built / 12);
      razes := (razes * loot_scale) / 100;
      razes := least(razes, 12, built);
      razed := public.cc_raze_buildings(def, razes);
    end if;
  end if;
  who := case
    when public.cc_unit_n(p_sent, 'footmen') >= public.cc_unit_n(p_sent, 'militia')
      and public.cc_unit_n(p_sent, 'footmen') >= public.cc_unit_n(p_sent, 'archers')
      and public.cc_unit_n(p_sent, 'footmen') >= public.cc_unit_n(p_sent, 'knights')
      and public.cc_unit_n(p_sent, 'footmen') > 0 then 'footmen'
    when public.cc_unit_n(p_sent, 'knights') > 0
      and public.cc_unit_n(p_sent, 'knights') >= public.cc_unit_n(p_sent, 'archers') then 'knights'
    when public.cc_unit_n(p_sent, 'archers') > 0 then 'archers'
    else 'host'
  end;
  if not win then
    text_att := 'Your ' || who || ' were thrown back from ' || def.name || '.';
    text_def := att.name || ' broke against your walls.';
  elsif p_type = 'conquest' and acres > 0 then
    text_att := 'Your ' || who || ' stormed ' || def.name || ' and took ' || acres || ' acres.';
    text_def := att.name || ' stormed your gates and took ' || acres || ' acres.';
  elsif p_type = 'plunder' and (gold > 0 or food > 0) then
    text_att := 'Your ' || who || ' plundered ' || def.name || ' and carried off ' || gold || ' gold and ' || food || ' food.';
    text_def := att.name || ' plundered ' || gold || ' gold and ' || food || ' food.';
  elsif p_type = 'razing' then
    built := public.cc_unit_n(razed, 'farm') + public.cc_unit_n(razed, 'home') + public.cc_unit_n(razed, 'market')
      + public.cc_unit_n(razed, 'mine') + public.cc_unit_n(razed, 'barracks') + public.cc_unit_n(razed, 'tower')
      + public.cc_unit_n(razed, 'library') + public.cc_unit_n(razed, 'wall') + public.cc_unit_n(razed, 'shrine')
      + public.cc_unit_n(razed, 'granary');
    text_att := 'Your ' || who || ' razed ' || built || ' buildings at ' || def.name || '.';
    text_def := att.name || ' razed ' || built || ' of your buildings.';
  else
    text_att := 'Your ' || who || ' won at ' || def.name || ', but there was nothing left to carry.';
    text_def := att.name || ' won at your gates, but carried nothing off.';
  end if;
  return jsonb_build_object(
    'win', win,
    'roll', roll,
    'offense', offense,
    'defense', defense,
    'att_loss', att_loss,
    'def_loss', def_loss,
    'living', living,
    'scale', scale,
    'recent', recent,
    'loot_scale', loot_scale,
    'acres', acres,
    'gold', gold,
    'food', food,
    'buildings', buildings,
    'razed', razed,
    'att_morale', case when win then least(100, att.morale + 3) else greatest(40, att.morale - 8) end,
    'def_morale', case when win then greatest(40, def.morale - 6) else least(100, def.morale + 2) end,
    'text', text_att,
    'defender_text', text_def
  );
end;
$$;

-- ---------- applying hits and regrowth ----------
create or replace function public.cc_apply_loss_units(k public.cc_kingdoms, p_loss jsonb, p_sign int)
returns public.cc_kingdoms
language plpgsql
as $$
begin
  k.u_militia := greatest(0, k.u_militia + p_sign * public.cc_unit_n(p_loss, 'militia'));
  k.u_footmen := greatest(0, k.u_footmen + p_sign * public.cc_unit_n(p_loss, 'footmen'));
  k.u_pikemen := greatest(0, k.u_pikemen + p_sign * public.cc_unit_n(p_loss, 'pikemen'));
  k.u_archers := greatest(0, k.u_archers + p_sign * public.cc_unit_n(p_loss, 'archers'));
  k.u_knights := greatest(0, k.u_knights + p_sign * public.cc_unit_n(p_loss, 'knights'));
  k.u_siege := greatest(0, k.u_siege + p_sign * public.cc_unit_n(p_loss, 'siege'));
  k.u_warden := greatest(0, k.u_warden + p_sign * public.cc_unit_n(p_loss, 'warden'));
  k.u_spellbow := greatest(0, k.u_spellbow + p_sign * public.cc_unit_n(p_loss, 'spellbow'));
  k.u_wyvern := greatest(0, k.u_wyvern + p_sign * public.cc_unit_n(p_loss, 'wyvern'));
  return k;
end;
$$;

create or replace function public.cc_apply_buildings(k public.cc_kingdoms, p_delta jsonb, p_sign int)
returns public.cc_kingdoms
language plpgsql
as $$
begin
  k.b_farm := greatest(0, k.b_farm + p_sign * public.cc_unit_n(p_delta, 'farm'));
  k.b_home := greatest(0, k.b_home + p_sign * public.cc_unit_n(p_delta, 'home'));
  k.b_market := greatest(0, k.b_market + p_sign * public.cc_unit_n(p_delta, 'market'));
  k.b_mine := greatest(0, k.b_mine + p_sign * public.cc_unit_n(p_delta, 'mine'));
  k.b_barracks := greatest(0, k.b_barracks + p_sign * public.cc_unit_n(p_delta, 'barracks'));
  k.b_tower := greatest(0, k.b_tower + p_sign * public.cc_unit_n(p_delta, 'tower'));
  k.b_library := greatest(0, k.b_library + p_sign * public.cc_unit_n(p_delta, 'library'));
  k.b_wall := greatest(0, k.b_wall + p_sign * public.cc_unit_n(p_delta, 'wall'));
  k.b_shrine := greatest(0, k.b_shrine + p_sign * public.cc_unit_n(p_delta, 'shrine'));
  k.b_granary := greatest(0, k.b_granary + p_sign * public.cc_unit_n(p_delta, 'granary'));
  return k;
end;
$$;

create or replace function public.cc_save_kingdom(k public.cc_kingdoms)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.cc_kingdoms set
    gold = k.gold,
    gold_bank = k.gold_bank,
    food = k.food,
    food_bank = k.food_bank,
    mana = k.mana,
    mana_bank = k.mana_bank,
    research_points = k.research_points,
    research_bank = k.research_bank,
    pop_progress = k.pop_progress,
    peasants = k.peasants,
    land = k.land,
    explored_today = k.explored_today,
    explore_reset_at = k.explore_reset_at,
    last_tick_at = k.last_tick_at,
    b_farm = k.b_farm,
    b_home = k.b_home,
    b_market = k.b_market,
    b_mine = k.b_mine,
    b_barracks = k.b_barracks,
    b_tower = k.b_tower,
    b_library = k.b_library,
    b_wall = k.b_wall,
    b_shrine = k.b_shrine,
    b_granary = k.b_granary,
    u_militia = k.u_militia,
    u_footmen = k.u_footmen,
    u_pikemen = k.u_pikemen,
    u_archers = k.u_archers,
    u_knights = k.u_knights,
    u_siege = k.u_siege,
    u_warden = k.u_warden,
    u_spellbow = k.u_spellbow,
    u_wyvern = k.u_wyvern,
    r_economy = k.r_economy,
    r_population = k.r_population,
    r_food = k.r_food,
    r_military = k.r_military,
    r_magic = k.r_magic,
    chronicle = k.chronicle,
    morale = k.morale,
    spies = k.spies,
    protected_until = k.protected_until,
    attacked_at = k.attacked_at,
    last_hit_at = k.last_hit_at,
    npc_tier = k.npc_tier,
    npc_anchor = k.npc_anchor
  where id = k.id;
end;
$$;

create or replace function public.cc_anchor_of(k public.cc_kingdoms)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'land', k.land,
    'gold', k.gold,
    'food', k.food,
    'morale', 100,
    'units', public.cc_units_json(k),
    'buildings', jsonb_build_object(
      'farm', k.b_farm, 'home', k.b_home, 'market', k.b_market, 'mine', k.b_mine,
      'barracks', k.b_barracks, 'tower', k.b_tower, 'library', k.b_library,
      'wall', k.b_wall, 'shrine', k.b_shrine, 'granary', k.b_granary
    )
  );
$$;


create or replace function public.cc_regrow_until(k public.cc_kingdoms, p_until timestamptz)
returns public.cc_kingdoms
language plpgsql
as $$
declare
  steps int := 0;
  anchor jsonb;
  gap int;
  best text;
  id text;
  missing int;
  have int;
begin
  if not k.is_npc or k.npc_anchor is null then
    return k;
  end if;
  anchor := k.npc_anchor;
  while steps < 200 and k.last_tick_at + interval '60 seconds' <= p_until loop
    if k.land < coalesce((anchor->>'land')::int, k.land) then
      k.land := least(2000000, k.land + 1);
    end if;
    if k.gold < coalesce((anchor->>'gold')::int, k.gold) then
      k.gold := least(1000000000, k.gold + greatest(1, (coalesce((anchor->>'gold')::int, k.gold) - k.gold) / 30));
    end if;
    if k.food < coalesce((anchor->>'food')::int, k.food) then
      k.food := least(1000000000, k.food + greatest(1, (coalesce((anchor->>'food')::int, k.food) - k.food) / 30));
    end if;
    best := null;
    gap := 0;
    foreach id in array array['militia','footmen','pikemen','archers','knights','siege','warden','spellbow','wyvern']
    loop
      have := public.cc_unit_n(public.cc_units_json(k), id);
      missing := public.cc_unit_n(anchor->'units', id) - have;
      if missing > gap then
        gap := missing;
        best := id;
      end if;
    end loop;
    if best is not null then
      k := public.cc_apply_loss_units(k, jsonb_build_object(best, greatest(1, gap / 40)), 1);
    end if;
    if steps % 2 = 0 then
      best := null;
      gap := 0;
      foreach id in array array['farm','granary','home','market','mine','barracks','tower','library','wall','shrine']
      loop
        have := case id
          when 'farm' then k.b_farm when 'home' then k.b_home when 'market' then k.b_market
          when 'mine' then k.b_mine when 'barracks' then k.b_barracks when 'tower' then k.b_tower
          when 'library' then k.b_library when 'wall' then k.b_wall when 'shrine' then k.b_shrine
          else k.b_granary end;
        missing := public.cc_unit_n(anchor->'buildings', id) - have;
        if missing > gap then
          gap := missing;
          best := id;
        end if;
      end loop;
      if best is not null then
        k := public.cc_apply_buildings(k, jsonb_build_object(best, 1), 1);
      end if;
    end if;
    if k.morale < 100 then
      k.morale := least(100, k.morale + 1);
    end if;
    k.last_tick_at := k.last_tick_at + interval '60 seconds';
    steps := steps + 1;
  end loop;
  return k;
end;
$$;

create or replace function public.cc_travel_seconds(p_same boolean, p_spy boolean)
returns int
language sql
immutable
as $$
  select case
    when p_spy and p_same then 90
    when p_spy then 240
    when p_same then 180
    else 480
  end;
$$;

create or replace function public.cc_tag(p_kingdom bigint)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select a.tag
  from public.cc_alliance_members m
  join public.cc_alliances a on a.id = m.alliance_id
  where m.kingdom_id = p_kingdom;
$$;

create or replace function public.cc_same_alliance(p_a bigint, p_b bigint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.cc_alliance_members a
    join public.cc_alliance_members b on a.alliance_id = b.alliance_id
    where a.kingdom_id = p_a and b.kingdom_id = p_b
  );
$$;

create or replace function public.cc_write_report(
  p_attacker bigint,
  p_defender bigint,
  p_outcome text,
  p_payload jsonb
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  rid bigint;
begin
  insert into public.cc_battle_reports (attacker_id, defender_id, outcome, payload)
  values (p_attacker, p_defender, p_outcome, p_payload)
  returning id into rid;
  return rid;
end;
$$;

create or replace function public.cc_resolve_march(k public.cc_kingdoms, m public.cc_marches, p_until timestamptz)
returns public.cc_kingdoms
language plpgsql
security definer
set search_path = public
as $$
declare
  other public.cc_kingdoms;
  result jsonb;
  roll int;
  spy_roll int;
  caught boolean;
  need int;
  fuzz int;
  travel int;
  same_realm boolean;
  scout jsonb;
begin
  if m.phase = 'out' and m.kind = 'army' then
    if m.attacker_id = k.id then
      select * into other from public.cc_kingdoms where id = m.defender_id for update;
      other := public.cc_regrow_until(other, p_until);
      roll := 85 + floor(random() * 31)::int;
      result := public.cc_resolve_battle(k, other, m.units, m.attack_type, roll, p_until);
      other := public.cc_apply_loss_units(other, result->'def_loss', -1);
      other.morale := (result->>'def_morale')::int;
      other.last_hit_at := p_until;
      other.land := greatest(0, other.land - (result->>'acres')::int);
      other.gold := greatest(0, other.gold - (result->>'gold')::int);
      other.food := greatest(0, other.food - (result->>'food')::int);
      other := public.cc_apply_buildings(other, coalesce(result->'buildings', '{}'::jsonb), -1);
      other := public.cc_apply_buildings(other, coalesce(result->'razed', '{}'::jsonb), -1);
      other := public.cc_note(other, p_until, result->>'defender_text');
      perform public.cc_save_kingdom(other);
      k.morale := (result->>'att_morale')::int;
      k := public.cc_note(k, p_until, 'Your host reached ' || other.name || '.');
    else
      select * into other from public.cc_kingdoms where id = m.attacker_id for update;
      k := public.cc_regrow_until(k, p_until);
      roll := 85 + floor(random() * 31)::int;
      result := public.cc_resolve_battle(other, k, m.units, m.attack_type, roll, p_until);
      k := public.cc_apply_loss_units(k, result->'def_loss', -1);
      k.morale := (result->>'def_morale')::int;
      k.last_hit_at := p_until;
      k.land := greatest(0, k.land - (result->>'acres')::int);
      k.gold := greatest(0, k.gold - (result->>'gold')::int);
      k.food := greatest(0, k.food - (result->>'food')::int);
      k := public.cc_apply_buildings(k, coalesce(result->'buildings', '{}'::jsonb), -1);
      k := public.cc_apply_buildings(k, coalesce(result->'razed', '{}'::jsonb), -1);
      k := public.cc_note(k, p_until, result->>'defender_text');
      other.morale := (result->>'att_morale')::int;
      other := public.cc_note(other, p_until, 'Your host reached ' || k.name || '.');
      perform public.cc_save_kingdom(other);
    end if;
    perform public.cc_write_report(
      m.attacker_id,
      m.defender_id,
      case when (result->>'win')::boolean then 'win' else 'loss' end,
      result || jsonb_build_object('attack_type', m.attack_type, 'kind', 'battle')
    );
    select (a.realm_id = d.realm_id) into same_realm
    from public.cc_kingdoms a, public.cc_kingdoms d
    where a.id = m.attacker_id and d.id = m.defender_id;
    travel := public.cc_travel_seconds(coalesce(same_realm, false), false);
    update public.cc_marches
    set phase = 'back',
        units = result->'living',
        loot = jsonb_build_object(
          'acres', result->'acres',
          'gold', result->'gold',
          'food', result->'food',
          'buildings', coalesce(result->'buildings', '{}'::jsonb),
          'text', result->>'text'
        ),
        arrives_at = p_until + make_interval(secs => travel)
    where id = m.id;
    return k;
  end if;

  if m.phase = 'back' and m.kind = 'army' then
    if m.attacker_id = k.id then
      k := public.cc_apply_loss_units(k, m.units, 1);
      k.land := least(2000000, k.land + coalesce((m.loot->>'acres')::int, 0));
      k.gold := least(1000000000, k.gold + coalesce((m.loot->>'gold')::int, 0));
      k.food := least(1000000000, k.food + coalesce((m.loot->>'food')::int, 0));
      k := public.cc_apply_buildings(k, coalesce(m.loot->'buildings', '{}'::jsonb), 1);
      k := public.cc_note(k, p_until, coalesce(m.loot->>'text', 'Your host returned.'));
    else
      select * into other from public.cc_kingdoms where id = m.attacker_id for update;
      other := public.cc_apply_loss_units(other, m.units, 1);
      other.land := least(2000000, other.land + coalesce((m.loot->>'acres')::int, 0));
      other.gold := least(1000000000, other.gold + coalesce((m.loot->>'gold')::int, 0));
      other.food := least(1000000000, other.food + coalesce((m.loot->>'food')::int, 0));
      other := public.cc_apply_buildings(other, coalesce(m.loot->'buildings', '{}'::jsonb), 1);
      other := public.cc_note(other, p_until, coalesce(m.loot->>'text', 'Your host returned.'));
      perform public.cc_save_kingdom(other);
    end if;
    delete from public.cc_marches where id = m.id;
    return k;
  end if;

  if m.phase = 'out' and m.kind = 'spy' then
    select * into other from public.cc_kingdoms where id = case when m.attacker_id = k.id then m.defender_id else m.attacker_id end for update;
    if m.attacker_id = k.id then
      other := public.cc_regrow_until(other, p_until);
      perform public.cc_save_kingdom(other);
      need := least(90, 70 + k.r_magic * 2);
    else
      k := public.cc_regrow_until(k, p_until);
      need := least(90, 70 + other.r_magic * 2);
    end if;
    spy_roll := 1 + floor(random() * 100)::int;
    caught := spy_roll > need;
    fuzz := 85 + floor(random() * 31)::int;
    if m.attacker_id = k.id then
      if caught then
        k := public.cc_note(k, p_until, 'Your spy was caught at ' || other.name || '.');
        perform public.cc_write_report(k.id, other.id, 'caught', jsonb_build_object('kind', 'spy', 'text', 'Your spy was caught at ' || other.name || '.'));
        delete from public.cc_marches where id = m.id;
      else
        scout := jsonb_build_object(
          'land', (other.land * fuzz) / 100,
          'gold', (other.gold * fuzz) / 100,
          'food', (other.food * fuzz) / 100,
          'defense', (public.cc_home_defense(other) * fuzz) / 100,
          'units', public.cc_units_json(other)
        );
        k := public.cc_note(k, p_until, 'A spy reports on ' || other.name || '.');
        perform public.cc_write_report(k.id, other.id, 'scouted', jsonb_build_object('kind', 'spy', 'text', 'A spy reports on ' || other.name || '.', 'scout', scout));
        travel := public.cc_travel_seconds(k.realm_id = other.realm_id, true);
        update public.cc_marches set phase = 'back', arrives_at = p_until + make_interval(secs => travel) where id = m.id;
      end if;
    else
      if caught then
        other := public.cc_note(other, p_until, 'Your spy was caught at ' || k.name || '.');
        perform public.cc_save_kingdom(other);
        perform public.cc_write_report(other.id, k.id, 'caught', jsonb_build_object('kind', 'spy', 'text', 'Your spy was caught at ' || k.name || '.'));
        delete from public.cc_marches where id = m.id;
      else
        scout := jsonb_build_object(
          'land', (k.land * fuzz) / 100,
          'gold', (k.gold * fuzz) / 100,
          'food', (k.food * fuzz) / 100,
          'defense', (public.cc_home_defense(k) * fuzz) / 100
        );
        other := public.cc_note(other, p_until, 'A spy reports on ' || k.name || '.');
        perform public.cc_save_kingdom(other);
        perform public.cc_write_report(other.id, k.id, 'scouted', jsonb_build_object('kind', 'spy', 'text', 'A spy reports on ' || k.name || '.', 'scout', scout));
        travel := public.cc_travel_seconds(other.realm_id = k.realm_id, true);
        update public.cc_marches set phase = 'back', arrives_at = p_until + make_interval(secs => travel) where id = m.id;
      end if;
    end if;
    return k;
  end if;

  if m.phase = 'back' and m.kind = 'spy' then
    if m.attacker_id = k.id then
      k.spies := least(25, k.spies + 1);
      k := public.cc_note(k, p_until, 'Your spy slipped home.');
    else
      select * into other from public.cc_kingdoms where id = m.attacker_id for update;
      other.spies := least(25, other.spies + 1);
      other := public.cc_note(other, p_until, 'Your spy slipped home.');
      perform public.cc_save_kingdom(other);
    end if;
    delete from public.cc_marches where id = m.id;
    return k;
  end if;
  return k;
end;
$$;

create or replace function public.cc_complete_marches(k public.cc_kingdoms, p_until timestamptz)
returns public.cc_kingdoms
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.cc_marches;
begin
  for m in
    select * from public.cc_marches
    where (attacker_id = k.id or defender_id = k.id)
      and arrives_at <= p_until
    order by arrives_at, id
    for update
  loop
    k := public.cc_resolve_march(k, m, p_until);
  end loop;
  return k;
end;
$$;

create or replace function public.cc_settle(p_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  boundary timestamptz;
  ticks int := 0;
  guard int := 0;
  behind boolean;
begin
  select * into k from public.cc_kingdoms where id = p_id for update;
  if k.id is null then
    raise exception 'That kingdom is gone.';
  end if;
  if k.is_npc then
    k := public.cc_regrow_until(k, now());
    k := public.cc_complete_marches(k, now());
    perform public.cc_save_kingdom(k);
    return false;
  end if;
  while k.explore_reset_at <= now() and guard < 40 loop
    k.explored_today := 0;
    k.explore_reset_at := k.explore_reset_at + interval '1 day';
    guard := guard + 1;
  end loop;
  while ticks < 2000 loop
    boundary := k.last_tick_at + make_interval(secs => public.cc_tick_seconds());
    exit when boundary > now();
    k := public.cc_complete_marches(k, boundary);
    k := public.cc_complete_due(k, boundary);
    k := public.cc_apply_tick(k);
    k.last_tick_at := boundary;
    ticks := ticks + 1;
  end loop;
  behind := k.last_tick_at + make_interval(secs => public.cc_tick_seconds()) <= now();
  if not behind then
    k := public.cc_complete_marches(k, now());
    k := public.cc_complete_due(k, now());
  end if;
  perform public.cc_save_kingdom(k);
  return behind;
end;
$$;

-- ---------- state ----------
create or replace function public.cc_state_json(p_player public.cc_players, p_behind boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  r public.cc_realms;
  jobs jsonb;
  marches jsonb;
  realm_count int;
  pact_id bigint;
  pact_name text;
  pact_tag text;
  pact_role text;
  under_attack boolean;
begin
  select * into k from public.cc_kingdoms where owner_id = p_player.id;
  if k.id is null then
    return jsonb_build_object(
      'player', jsonb_build_object(
        'username', p_player.username,
        'admin', public.cc_is_admin(),
        'banned', p_player.banned,
        'ban_reason', p_player.ban_reason
      ),
      'kingdom', null,
      'behind', false
    );
  end if;
  select * into r from public.cc_realms where id = k.realm_id;
  select count(*) into realm_count from public.cc_kingdoms where realm_id = k.realm_id;
  select a.id, a.name, a.tag, m.role
  into pact_id, pact_name, pact_tag, pact_role
  from public.cc_alliance_members m
  join public.cc_alliances a on a.id = m.alliance_id
  where m.kingdom_id = k.id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', j.id, 'kind', j.kind, 'building', j.building, 'unit', j.unit_id,
    'count', j.count, 'settlers', j.settlers, 'started_at', j.started_at, 'completes_at', j.completes_at
  ) order by j.id), '[]'::jsonb)
  into jobs
  from public.cc_jobs j
  where j.kingdom_id = k.id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'kind', m.kind,
    'phase', m.phase,
    'attack_type', m.attack_type,
    'target', d.name,
    'target_tag', public.cc_tag(d.id),
    'you_attack', m.attacker_id = k.id,
    'started_at', m.started_at,
    'arrives_at', m.arrives_at
  ) order by m.arrives_at), '[]'::jsonb)
  into marches
  from public.cc_marches m
  join public.cc_kingdoms d on d.id = case when m.attacker_id = k.id then m.defender_id else m.attacker_id end
  where m.attacker_id = k.id or m.defender_id = k.id;
  select exists (
    select 1 from public.cc_marches m
    where m.defender_id = k.id and m.kind = 'army' and m.phase = 'out' and m.arrives_at > now()
  ) into under_attack;
  return jsonb_build_object(
    'player', jsonb_build_object(
      'username', p_player.username,
      'admin', public.cc_is_admin(),
      'banned', p_player.banned,
      'ban_reason', p_player.ban_reason
    ),
    'kingdom', jsonb_build_object(
      'id', k.id,
      'name', k.name,
      'land_type', k.land_type,
      'realm_id', k.realm_id,
      'realm_name', r.name,
      'realm_seat', r.seat,
      'realm_count', realm_count,
      'gold', k.gold,
      'gold_bank', k.gold_bank,
      'food', k.food,
      'food_bank', k.food_bank,
      'mana', k.mana,
      'mana_bank', k.mana_bank,
      'research_points', k.research_points,
      'research_bank', k.research_bank,
      'pop_progress', k.pop_progress,
      'peasants', k.peasants,
      'land', k.land,
      'explored_today', k.explored_today,
      'explore_reset_at', k.explore_reset_at,
      'last_tick_at', k.last_tick_at,
      'morale', k.morale,
      'spies', k.spies,
      'protected_until', k.protected_until,
      'attacked_at', k.attacked_at,
      'last_hit_at', k.last_hit_at,
      'under_attack', under_attack,
      'alliance', case when pact_id is null then null else jsonb_build_object(
        'id', pact_id, 'name', pact_name, 'tag', pact_tag, 'role', pact_role
      ) end,
      'buildings', jsonb_build_object(
        'farm', k.b_farm, 'home', k.b_home, 'market', k.b_market, 'mine', k.b_mine,
        'barracks', k.b_barracks, 'tower', k.b_tower, 'library', k.b_library,
        'wall', k.b_wall, 'shrine', k.b_shrine, 'granary', k.b_granary
      ),
      'units', public.cc_units_json(k),
      'research', jsonb_build_object(
        'economy', k.r_economy, 'population', k.r_population, 'food', k.r_food,
        'military', k.r_military, 'magic', k.r_magic
      ),
      'jobs', jobs,
      'marches', marches,
      'chronicle', k.chronicle
    ),
    'behind', coalesce(p_behind, false)
  );
end;
$$;

create or replace function public.cc_create_kingdom(p_name text, p_land_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  chosen text := trim(coalesce(p_name, ''));
  rid bigint;
  existing int;
  catalog text[] := array[
    'The Amber March', 'Valeward Reach', 'Cinderfold', 'Saltmere Compact',
    'Greenwerge', 'Ostmark Crowns', 'Lyrewell', 'Dunhollow Pact',
    'Brindle Coast', 'The Sable Verge', 'Hearthland Union', 'Mistcrown Isles'
  ];
  seats text[] := array[
    'Western vales', 'The river spine', 'Ashen highlands', 'The inner sea',
    'Old forest', 'Eastern marches', 'Lake country', 'Hill country',
    'Southern shore', 'Northern dark', 'Central plain', 'Outer isles'
  ];
  idx int;
  realm_name text;
begin
  row := public.cc_load_player();
  if p_land_type not in ('highlands', 'forest', 'desert', 'volcanic', 'coastal', 'arcane') then
    raise exception 'Choose a land type.';
  end if;
  if chosen !~ '^[A-Za-z][A-Za-z0-9'' -]{1,22}[A-Za-z0-9]$' or position('  ' in chosen) > 0 then
    raise exception 'Use 3-24 letters, and spaces or apostrophes.';
  end if;
  if exists (select 1 from public.cc_kingdoms where owner_id = row.id) then
    raise exception 'You already rule a kingdom.';
  end if;
  if exists (select 1 from public.cc_kingdoms where lower(name) = lower(chosen)) then
    raise exception 'That kingdom name is already claimed.';
  end if;
  select r.id into rid
  from public.cc_realms r
  where (select count(*) from public.cc_kingdoms k where k.realm_id = r.id) < 20
  order by r.id
  limit 1
  for update skip locked;
  if rid is null then
    select count(*) into existing from public.cc_realms;
    idx := (existing % 12) + 1;
    realm_name := catalog[idx];
    if exists (select 1 from public.cc_realms where name = realm_name) then
      realm_name := realm_name || ' ' || (existing + 1);
    end if;
    insert into public.cc_realms (name, seat) values (realm_name, seats[idx]) returning id into rid;
    perform public.cc_seed_realm(rid);
  end if;
  insert into public.cc_kingdoms (
    owner_id, realm_id, name, land_type, is_npc,
    gold, food, mana, research_points, peasants, land,
    explore_reset_at, last_tick_at, protected_until, morale, spies,
    b_farm, b_home, b_market, b_mine, b_barracks, b_tower, b_library, b_wall, b_shrine, b_granary,
    u_militia, u_footmen, u_pikemen, u_archers, u_knights, u_siege, u_warden, u_spellbow, u_wyvern,
    chronicle
  ) values (
    row.id, rid, chosen, p_land_type, false,
    6500, 4200, 80, 70, 300, 240,
    now() + interval '1 day', now(), now() + interval '24 hours', 100, 2,
    16, 14, 4, 2, 2, 1, 1, 2, 1, 2,
    36, 12, 0, 8, 2, 0, 0, 0, 0,
    jsonb_build_array(jsonb_build_object('at', now(), 'text', 'The banner of ' || chosen || ' was raised.'))
  );
  select * into row from public.cc_players where id = row.id;
  return public.cc_state_json(row, false);
exception
  when unique_violation then
    raise exception 'That kingdom name is already claimed.';
end;
$$;

create or replace function public.cc_public_rows(p_realm bigint, p_self bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  rows jsonb;
begin
  select coalesce(jsonb_agg(s.item order by s.networth desc, s.name), '[]'::jsonb)
  into rows
  from (
    select k.name, public.cc_networth(k) as networth, jsonb_build_object(
      'name', k.name,
      'land_type', k.land_type,
      'land', k.land,
      'networth', public.cc_networth(k),
      'is_npc', k.is_npc,
      'is_you', k.id = p_self,
      'realm_name', r.name,
      'tag', public.cc_tag(k.id),
      'protected', (not k.is_npc and k.attacked_at is null and k.protected_until > now())
    ) as item
    from public.cc_kingdoms k
    join public.cc_realms r on r.id = k.realm_id
    where p_realm is null or k.realm_id = p_realm
  ) s;
  return rows;
end;
$$;

create or replace function public.cc_leaderboard()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
  rows jsonb;
begin
  row := public.cc_load_player();
  select * into k from public.cc_kingdoms where owner_id = row.id;
  if k.id is not null then
    perform public.cc_settle(k.id);
    select * into k from public.cc_kingdoms where id = k.id;
  end if;
  select coalesce(jsonb_agg(s.item order by s.networth desc, s.name), '[]'::jsonb)
  into rows
  from (
    select public.cc_networth(c) as networth, c.name, jsonb_build_object(
      'name', c.name,
      'land_type', c.land_type,
      'land', c.land,
      'networth', public.cc_networth(c),
      'is_npc', c.is_npc,
      'is_you', c.id = k.id,
      'realm_name', r.name,
      'tag', public.cc_tag(c.id)
    ) as item
    from public.cc_kingdoms c
    join public.cc_realms r on r.id = c.realm_id
    order by public.cc_networth(c) desc, c.name
    limit 20
  ) s;
  return jsonb_build_object('kingdoms', rows);
end;
$$;

-- ---------- war rpcs ----------
create or replace function public.cc_targets(p_query text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
  raw text := left(trim(coalesce(p_query, '')), 32);
  q text := replace(replace(replace(raw, '\', '\\'), '%', '\%'), '_', '\_');
  rows jsonb;
begin
  row := public.cc_load_player();
  select * into k from public.cc_kingdoms where owner_id = row.id;
  if k.id is null then
    raise exception 'Raise a banner before you march.';
  end if;
  perform public.cc_settle(k.id);
  select * into k from public.cc_kingdoms where id = k.id;
  select coalesce(jsonb_agg(s.item order by s.networth desc), '[]'::jsonb)
  into rows
  from (
    select public.cc_networth(c) as networth, jsonb_build_object(
      'id', c.id,
      'name', c.name,
      'land_type', c.land_type,
      'land', c.land,
      'networth', public.cc_networth(c),
      'is_npc', c.is_npc,
      'realm_name', r.name,
      'same_realm', c.realm_id = k.realm_id,
      'tag', public.cc_tag(c.id),
      'allied', public.cc_same_alliance(k.id, c.id),
      'protected', (not c.is_npc and c.attacked_at is null and c.protected_until > now()),
      'tier', c.npc_tier
    ) as item
    from public.cc_kingdoms c
    join public.cc_realms r on r.id = c.realm_id
    where c.id <> k.id
      and (q = '' or c.name ilike '%' || q || '%' escape '\')
    order by public.cc_networth(c) desc, c.name
    limit 40
  ) s;
  return jsonb_build_object('kingdoms', rows);
end;
$$;

create or replace function public.cc_odds(p_target bigint, p_units jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  target public.cc_kingdoms;
  offense int;
  defense int;
  ratio int;
  band text;
  scale int;
begin
  k := public.cc_lock_kingdom();
  select * into target from public.cc_kingdoms where id = p_target;
  if target.id is null then
    raise exception 'No kingdom by that name.';
  end if;
  if target.is_npc then
    target := public.cc_regrow_until(target, now());
    perform public.cc_save_kingdom(target);
  end if;
  offense := public.cc_force_offense(k.land_type, k.r_military, k.food, k.morale, coalesce(p_units, '{}'::jsonb));
  defense := public.cc_home_defense(target);
  if defense <= 0 then
    band := 'favored';
  else
    ratio := (offense * 100) / defense;
    band := case when ratio >= 120 then 'favored' when ratio <= 80 then 'outmatched' else 'even' end;
  end if;
  scale := public.cc_size_scale(public.cc_networth(k), public.cc_networth(target));
  return jsonb_build_object(
    'band', band,
    'offense', offense,
    'scale', scale,
    'note', case
      when scale < 100 then 'A heavier crown takes less from a smaller house.'
      when scale > 100 then 'A larger prize yields a richer haul.'
      else 'The houses are close in worth.'
    end
  );
end;
$$;

create or replace function public.cc_attack(p_target bigint, p_type text, p_units jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  row public.cc_players;
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
  k := public.cc_lock_kingdom();
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
  if exists (select 1 from public.cc_marches where attacker_id = k.id and defender_id = target.id and kind = 'army') then
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
  select * into row from public.cc_players where id = k.owner_id;
  return public.cc_state_json(row, false);
end;
$$;

create or replace function public.cc_buy_spy(p_count int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
  cost int;
begin
  if p_count is null or p_count < 1 or p_count > 10 then
    raise exception 'Buy between 1 and 10 spies.';
  end if;
  k := public.cc_lock_kingdom();
  cost := p_count * 150;
  if k.gold < cost then
    raise exception 'Not enough gold.';
  end if;
  if k.spies + p_count > 25 then
    raise exception 'The spyhall cannot house that many.';
  end if;
  k.gold := k.gold - cost;
  k.spies := k.spies + p_count;
  perform public.cc_save_kingdom(k);
  select * into row from public.cc_players where id = k.owner_id;
  return public.cc_state_json(row, false);
end;
$$;

create or replace function public.cc_spy(p_target bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
  target public.cc_kingdoms;
  travel int;
begin
  k := public.cc_lock_kingdom();
  select * into target from public.cc_kingdoms where id = p_target;
  if target.id is null then
    raise exception 'No kingdom by that name.';
  end if;
  if target.id = k.id then
    raise exception 'You already know your own stores.';
  end if;
  if k.spies < 1 then
    raise exception 'You have no spies to send.';
  end if;
  if (select count(*) from public.cc_marches where attacker_id = k.id and kind = 'spy') >= 3 then
    raise exception 'Three spies are already abroad.';
  end if;
  if exists (select 1 from public.cc_marches where attacker_id = k.id and defender_id = target.id and kind = 'spy') then
    raise exception 'A spy is already watching that kingdom.';
  end if;
  k.spies := k.spies - 1;
  k := public.cc_note(k, now(), 'A spy slipped toward ' || target.name || '.');
  travel := public.cc_travel_seconds(k.realm_id = target.realm_id, true);
  insert into public.cc_marches (attacker_id, defender_id, kind, phase, units, started_at, arrives_at)
  values (k.id, target.id, 'spy', 'out', '{}'::jsonb, now(), now() + make_interval(secs => travel));
  perform public.cc_save_kingdom(k);
  select * into row from public.cc_players where id = k.owner_id;
  return public.cc_state_json(row, false);
end;
$$;

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
      'acres', r.payload->>'acres',
      'gold', r.payload->>'gold',
      'food', r.payload->>'food',
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

-- ---------- alliances ----------
create or replace function public.cc_alliance_create(p_name text, p_tag text, p_description text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  named text := trim(coalesce(p_name, ''));
  pact_tag text := upper(trim(coalesce(p_tag, '')));
  blurb text := left(trim(coalesce(p_description, '')), 200);
  aid bigint;
begin
  k := public.cc_lock_kingdom();
  if exists (select 1 from public.cc_alliance_members where kingdom_id = k.id) then
    raise exception 'You already belong to a pact.';
  end if;
  if named !~ '^[A-Za-z][A-Za-z0-9'' -]{1,30}[A-Za-z0-9]$' or position('  ' in named) > 0 then
    raise exception 'Use 3-32 letters for the pact name.';
  end if;
  if pact_tag !~ '^[A-Z0-9]{2,5}$' then
    raise exception 'Use a tag of 2-5 letters or numbers.';
  end if;
  if exists (select 1 from public.cc_alliances where lower(name) = lower(named)) then
    raise exception 'That pact name is already claimed.';
  end if;
  if exists (select 1 from public.cc_alliances where lower(tag) = lower(pact_tag)) then
    raise exception 'That tag is already carried.';
  end if;
  insert into public.cc_alliances (name, tag, description, leader_kingdom_id)
  values (named, pact_tag, blurb, k.id)
  returning id into aid;
  insert into public.cc_alliance_members (kingdom_id, alliance_id, role)
  values (k.id, aid, 'leader');
  return public.cc_alliance_state();
exception
  when unique_violation then
    raise exception 'That pact name or tag is already claimed.';
end;
$$;

create or replace function public.cc_alliance_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  aid bigint;
  role text;
  alliance jsonb;
  members jsonb;
  requests jsonb;
begin
  k := public.cc_lock_kingdom();
  select m.alliance_id, m.role into aid, role
  from public.cc_alliance_members m
  where m.kingdom_id = k.id;
  if aid is null then
    return jsonb_build_object('alliance', null, 'members', '[]'::jsonb, 'requests', '[]'::jsonb);
  end if;
  select jsonb_build_object('id', a.id, 'name', a.name, 'tag', a.tag, 'description', a.description, 'role', role)
  into alliance
  from public.cc_alliances a
  where a.id = aid;
  select coalesce(jsonb_agg(jsonb_build_object(
    'name', c.name,
    'role', m.role,
    'land', c.land,
    'networth', public.cc_networth(c),
    'is_npc', c.is_npc,
    'you', c.id = k.id
  ) order by public.cc_networth(c) desc), '[]'::jsonb)
  into members
  from public.cc_alliance_members m
  join public.cc_kingdoms c on c.id = m.kingdom_id
  where m.alliance_id = aid;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', q.id,
    'kind', q.kind,
    'name', c.name,
    'tag', a.tag,
    'alliance', a.name,
    'alliance_id', a.id
  ) order by q.created_at), '[]'::jsonb)
  into requests
  from public.cc_alliance_requests q
  join public.cc_alliances a on a.id = q.alliance_id
  join public.cc_kingdoms c on c.id = q.kingdom_id
  where q.status = 'pending'
    and (
      q.kingdom_id = k.id
      or (q.alliance_id = aid and q.kind = 'join' and role in ('leader', 'officer'))
    );
  return jsonb_build_object('alliance', alliance, 'members', members, 'requests', coalesce(requests, '[]'::jsonb));
end;
$$;

create or replace function public.cc_alliance_browse(p_query text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  raw text := left(trim(coalesce(p_query, '')), 32);
  q text := replace(replace(replace(raw, '\', '\\'), '%', '\%'), '_', '\_');
  rows jsonb;
begin
  k := public.cc_lock_kingdom();
  select coalesce(jsonb_agg(s.item order by s.networth desc, s.name), '[]'::jsonb)
  into rows
  from (
    select a.name, coalesce(sum(public.cc_networth(c)), 0) as networth, jsonb_build_object(
      'id', a.id,
      'name', a.name,
      'tag', a.tag,
      'description', a.description,
      'members', count(m.kingdom_id),
      'networth', coalesce(sum(public.cc_networth(c)), 0),
      'yours', exists (select 1 from public.cc_alliance_members me where me.alliance_id = a.id and me.kingdom_id = k.id)
    ) as item
    from public.cc_alliances a
    left join public.cc_alliance_members m on m.alliance_id = a.id
    left join public.cc_kingdoms c on c.id = m.kingdom_id
    where q = '' or a.name ilike '%' || q || '%' escape '\' or a.tag ilike '%' || q || '%' escape '\'
    group by a.id
    order by coalesce(sum(public.cc_networth(c)), 0) desc, a.name
    limit 40
  ) s;
  return jsonb_build_object('alliances', rows);
end;
$$;

create or replace function public.cc_alliance_board()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rows jsonb;
begin
  if public.cc_load_player() is null then
    raise exception 'Log in first.';
  end if;
  select coalesce(jsonb_agg(s.item order by s.networth desc), '[]'::jsonb)
  into rows
  from (
    select coalesce(sum(public.cc_networth(c)), 0) as networth, jsonb_build_object(
      'name', a.name,
      'tag', a.tag,
      'members', count(m.kingdom_id),
      'networth', coalesce(sum(public.cc_networth(c)), 0)
    ) as item
    from public.cc_alliances a
    left join public.cc_alliance_members m on m.alliance_id = a.id
    left join public.cc_kingdoms c on c.id = m.kingdom_id
    group by a.id
    order by coalesce(sum(public.cc_networth(c)), 0) desc
    limit 20
  ) s;
  return jsonb_build_object('alliances', rows);
end;
$$;

create or replace function public.cc_alliance_request(p_alliance bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
begin
  k := public.cc_lock_kingdom();
  if exists (select 1 from public.cc_alliance_members where kingdom_id = k.id) then
    raise exception 'You already belong to a pact.';
  end if;
  if not exists (select 1 from public.cc_alliances where id = p_alliance) then
    raise exception 'That pact does not exist.';
  end if;
  if (select count(*) from public.cc_alliance_members where alliance_id = p_alliance) >= 20 then
    raise exception 'That pact is full.';
  end if;
  insert into public.cc_alliance_requests (alliance_id, kingdom_id, kind)
  values (p_alliance, k.id, 'join');
  return public.cc_alliance_state();
exception
  when unique_violation then
    raise exception 'You already asked to join that pact.';
end;
$$;

create or replace function public.cc_alliance_invite(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  aid bigint;
  target public.cc_kingdoms;
begin
  k := public.cc_lock_kingdom();
  select alliance_id into aid from public.cc_alliance_members where kingdom_id = k.id and role = 'leader';
  if aid is null then
    raise exception 'Only the leader can invite.';
  end if;
  select * into target from public.cc_kingdoms where lower(name) = lower(trim(p_name));
  if target.id is null then
    raise exception 'No kingdom by that name.';
  end if;
  if exists (select 1 from public.cc_alliance_members where kingdom_id = target.id) then
    raise exception 'That kingdom already has a pact.';
  end if;
  if (select count(*) from public.cc_alliance_members where alliance_id = aid) >= 20 then
    raise exception 'Your pact is full.';
  end if;
  if target.is_npc then
    insert into public.cc_alliance_members (kingdom_id, alliance_id, role) values (target.id, aid, 'member');
  else
    insert into public.cc_alliance_requests (alliance_id, kingdom_id, kind) values (aid, target.id, 'invite');
  end if;
  return public.cc_alliance_state();
exception
  when unique_violation then
    raise exception 'That invitation is already waiting.';
end;
$$;

create or replace function public.cc_alliance_answer(p_request bigint, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  q public.cc_alliance_requests;
  role text;
  members int;
begin
  k := public.cc_lock_kingdom();
  select * into q from public.cc_alliance_requests where id = p_request and status = 'pending' for update;
  if q.id is null then
    raise exception 'That request is already settled.';
  end if;
  select m.role into role from public.cc_alliance_members m where m.kingdom_id = k.id and m.alliance_id = q.alliance_id;
  if q.kind = 'join' then
    if role not in ('leader', 'officer') then
      raise exception 'Only the leader or an officer can answer that.';
    end if;
  elsif q.kingdom_id <> k.id then
    raise exception 'That invitation is not yours.';
  end if;
  if not coalesce(p_accept, false) then
    update public.cc_alliance_requests set status = 'declined' where id = q.id;
    return public.cc_alliance_state();
  end if;
  if exists (select 1 from public.cc_alliance_members where kingdom_id = q.kingdom_id) then
    raise exception 'That kingdom already has a pact.';
  end if;
  select count(*) into members from public.cc_alliance_members where alliance_id = q.alliance_id;
  if members >= 20 then
    raise exception 'That pact is full.';
  end if;
  insert into public.cc_alliance_members (kingdom_id, alliance_id, role) values (q.kingdom_id, q.alliance_id, 'member');
  update public.cc_alliance_requests set status = 'accepted' where id = q.id;
  update public.cc_alliance_requests set status = 'declined'
  where kingdom_id = q.kingdom_id and status = 'pending' and id <> q.id;
  return public.cc_alliance_state();
end;
$$;

create or replace function public.cc_alliance_leave()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  role text;
begin
  k := public.cc_lock_kingdom();
  select m.role into role from public.cc_alliance_members m where m.kingdom_id = k.id;
  if role is null then
    raise exception 'You are not in a pact.';
  end if;
  if role = 'leader' then
    raise exception 'Transfer the crown or disband the pact.';
  end if;
  delete from public.cc_alliance_members where kingdom_id = k.id;
  return public.cc_alliance_state();
end;
$$;

create or replace function public.cc_alliance_kick(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  aid bigint;
  target public.cc_kingdoms;
begin
  k := public.cc_lock_kingdom();
  select alliance_id into aid from public.cc_alliance_members where kingdom_id = k.id and role = 'leader';
  if aid is null then
    raise exception 'Only the leader can dismiss a house.';
  end if;
  select * into target from public.cc_kingdoms where lower(name) = lower(trim(p_name));
  if target.id is null or target.id = k.id then
    raise exception 'That house is not in your pact.';
  end if;
  if not exists (select 1 from public.cc_alliance_members where alliance_id = aid and kingdom_id = target.id) then
    raise exception 'That house is not in your pact.';
  end if;
  delete from public.cc_alliance_members where kingdom_id = target.id;
  return public.cc_alliance_state();
end;
$$;

create or replace function public.cc_alliance_set_role(p_name text, p_officer boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  aid bigint;
  target public.cc_kingdoms;
begin
  k := public.cc_lock_kingdom();
  select alliance_id into aid from public.cc_alliance_members where kingdom_id = k.id and role = 'leader';
  if aid is null then
    raise exception 'Only the leader can name officers.';
  end if;
  select * into target from public.cc_kingdoms where lower(name) = lower(trim(p_name));
  if target.id is null then
    raise exception 'That house is not in your pact.';
  end if;
  update public.cc_alliance_members
  set role = case when coalesce(p_officer, false) then 'officer' else 'member' end
  where alliance_id = aid and kingdom_id = target.id and role <> 'leader';
  if not found then
    raise exception 'That house cannot take that rank.';
  end if;
  return public.cc_alliance_state();
end;
$$;

create or replace function public.cc_alliance_transfer(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  aid bigint;
  target public.cc_kingdoms;
begin
  k := public.cc_lock_kingdom();
  select alliance_id into aid from public.cc_alliance_members where kingdom_id = k.id and role = 'leader';
  if aid is null then
    raise exception 'Only the leader can hand over the pact.';
  end if;
  select * into target from public.cc_kingdoms where lower(name) = lower(trim(p_name));
  if target.id is null or not exists (
    select 1 from public.cc_alliance_members where alliance_id = aid and kingdom_id = target.id and role <> 'leader'
  ) then
    raise exception 'That house is not in your pact.';
  end if;
  update public.cc_alliance_members set role = 'officer' where kingdom_id = k.id;
  update public.cc_alliance_members set role = 'leader' where kingdom_id = target.id;
  update public.cc_alliances set leader_kingdom_id = target.id where id = aid;
  return public.cc_alliance_state();
end;
$$;

create or replace function public.cc_alliance_disband()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  aid bigint;
begin
  k := public.cc_lock_kingdom();
  select alliance_id into aid from public.cc_alliance_members where kingdom_id = k.id and role = 'leader';
  if aid is null then
    raise exception 'Only the leader can disband the pact.';
  end if;
  delete from public.cc_alliances where id = aid;
  return public.cc_alliance_state();
end;
$$;

-- ---------- npc anchors and starter pacts ----------
create or replace function public.cc_finish_npcs(p_realm bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  npc public.cc_kingdoms;
begin
  for npc in
    select * from public.cc_kingdoms
    where is_npc and npc_anchor is null and (p_realm is null or realm_id = p_realm)
  loop
    update public.cc_kingdoms
    set npc_anchor = public.cc_anchor_of(npc),
        npc_tier = case
          when public.cc_networth(npc) < 3500 then 1
          when public.cc_networth(npc) < 5200 then 2
          when public.cc_networth(npc) < 6800 then 3
          else 4
        end,
        spies = 0,
        protected_until = null,
        morale = 100
    where id = npc.id;
  end loop;
end;
$$;

create or replace function public.cc_seed_realm(p_realm bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.cc_insert_npc(p_realm, 'Ashford Keep', 'volcanic', 360, 14000, 7000, 160, 480, 20, 18, 16, 5, 9, 4, 2, 1, 3, 2, 2, 40, 70, 20, 24, 10, 3, 0, 0, 0, 1, 0, 0, 3, 1);
  perform public.cc_insert_npc(p_realm, 'Briarholt', 'forest', 410, 8000, 14000, 90, 640, 10, 36, 24, 3, 1, 2, 1, 2, 2, 1, 4, 90, 20, 16, 40, 2, 0, 0, 0, 0, 0, 2, 3, 0, 1);
  perform public.cc_insert_npc(p_realm, 'Saltfen Watch', 'coastal', 300, 18000, 9000, 40, 390, 0, 22, 14, 8, 1, 2, 1, 1, 1, 1, 3, 30, 24, 10, 18, 4, 1, 0, 0, 0, 3, 1, 1, 0, 0);
  perform public.cc_insert_npc(p_realm, 'Qasira', 'desert', 280, 26000, 3200, 120, 260, 40, 12, 10, 12, 4, 3, 2, 1, 2, 1, 2, 20, 30, 8, 16, 8, 2, 0, 0, 0, 4, 0, 1, 1, 1);
  perform public.cc_insert_npc(p_realm, 'Dun Mere', 'highlands', 250, 6000, 5000, 30, 240, 0, 14, 12, 2, 3, 2, 2, 0, 4, 0, 1, 50, 16, 28, 6, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0);
  perform public.cc_insert_npc(p_realm, 'Vel Islet', 'arcane', 220, 9000, 4000, 420, 210, 180, 10, 8, 2, 1, 1, 1, 6, 1, 5, 1, 12, 8, 0, 10, 0, 0, 0, 16, 0, 0, 1, 0, 1, 6);
  perform public.cc_insert_npc(p_realm, 'Harrowgate', 'highlands', 340, 11000, 8000, 50, 360, 0, 20, 16, 4, 5, 4, 3, 1, 5, 1, 2, 40, 50, 40, 12, 8, 2, 6, 0, 0, 1, 1, 1, 4, 0);
  perform public.cc_insert_npc(p_realm, 'Mossfen', 'forest', 190, 2400, 3600, 20, 180, 0, 12, 8, 1, 0, 1, 0, 0, 1, 0, 2, 24, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0);
  perform public.cc_insert_npc(p_realm, 'Cinderwell', 'volcanic', 310, 16000, 4500, 200, 340, 30, 14, 12, 4, 8, 5, 2, 1, 3, 2, 1, 20, 40, 10, 10, 14, 6, 0, 0, 0, 1, 0, 0, 2, 2);
  perform public.cc_insert_npc(p_realm, 'Pearlwatch', 'coastal', 270, 10000, 6400, 60, 300, 0, 16, 12, 6, 1, 2, 1, 1, 1, 1, 2, 28, 18, 8, 14, 3, 1, 0, 0, 0, 2, 1, 1, 0, 0);
  perform public.cc_finish_npcs(p_realm);
  perform public.cc_enlist_pacts();
end;
$$;

create or replace function public.cc_enlist_pacts()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  iron bigint;
  green bigint;
  leader bigint;
  npc public.cc_kingdoms;
  n int;
begin
  select id into leader
  from public.cc_kingdoms
  where is_npc and name ilike 'Ashford Keep%'
  order by public.cc_networth(cc_kingdoms) desc
  limit 1;
  if leader is not null and not exists (select 1 from public.cc_alliances where tag = 'IRN') then
    insert into public.cc_alliances (name, tag, description, leader_kingdom_id)
    values ('The Iron Covenant', 'IRN', 'Ash, pikes, and the oath of the high gates.', leader)
    returning id into iron;
    insert into public.cc_alliance_members (kingdom_id, alliance_id, role) values (leader, iron, 'leader');
  else
    select id into iron from public.cc_alliances where tag = 'IRN';
  end if;
  if iron is not null then
    for npc in
      select * from public.cc_kingdoms
      where is_npc and (
        name ilike 'Ashford Keep%' or name ilike 'Harrowgate%' or name ilike 'Cinderwell%' or name ilike 'Qasira%'
      )
      and not exists (select 1 from public.cc_alliance_members m where m.kingdom_id = cc_kingdoms.id)
      order by public.cc_networth(cc_kingdoms) desc
    loop
      select count(*) into n from public.cc_alliance_members where alliance_id = iron;
      exit when n >= 20;
      insert into public.cc_alliance_members (kingdom_id, alliance_id, role) values (npc.id, iron, 'member');
    end loop;
  end if;
  select id into leader
  from public.cc_kingdoms
  where is_npc and name ilike 'Briarholt%'
  order by public.cc_networth(cc_kingdoms) desc
  limit 1;
  if leader is not null and not exists (select 1 from public.cc_alliances where tag = 'VERD') then
    insert into public.cc_alliances (name, tag, description, leader_kingdom_id)
    values ('The Green Company', 'VERD', 'Timber, harbors, and a shared granary.', leader)
    returning id into green;
    insert into public.cc_alliance_members (kingdom_id, alliance_id, role) values (leader, green, 'leader');
  else
    select id into green from public.cc_alliances where tag = 'VERD';
  end if;
  if green is not null then
    for npc in
      select * from public.cc_kingdoms
      where is_npc and (
        name ilike 'Briarholt%' or name ilike 'Mossfen%' or name ilike 'Pearlwatch%' or name ilike 'Saltfen Watch%'
      )
      and not exists (select 1 from public.cc_alliance_members m where m.kingdom_id = cc_kingdoms.id)
      order by public.cc_networth(cc_kingdoms) desc
    loop
      select count(*) into n from public.cc_alliance_members where alliance_id = green;
      exit when n >= 20;
      insert into public.cc_alliance_members (kingdom_id, alliance_id, role) values (npc.id, green, 'member');
    end loop;
  end if;
end;
$$;

select public.cc_finish_npcs(null);
select public.cc_enlist_pacts();

-- ---------- privileges ----------
revoke all on function public.cc_unit_n(jsonb, text) from public, anon, authenticated;
revoke all on function public.cc_force_offense(text, int, int, int, jsonb) from public, anon, authenticated;
revoke all on function public.cc_home_defense(public.cc_kingdoms) from public, anon, authenticated;
revoke all on function public.cc_units_json(public.cc_kingdoms) from public, anon, authenticated;
revoke all on function public.cc_size_scale(int, int) from public, anon, authenticated;
revoke all on function public.cc_hit_scale(timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.cc_loss_pct(int, int, boolean) from public, anon, authenticated;
revoke all on function public.cc_losses(jsonb, int) from public, anon, authenticated;
revoke all on function public.cc_living(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.cc_unit_sum(jsonb) from public, anon, authenticated;
revoke all on function public.cc_take_buildings(public.cc_kingdoms, int) from public, anon, authenticated;
revoke all on function public.cc_raze_buildings(public.cc_kingdoms, int) from public, anon, authenticated;
revoke all on function public.cc_resolve_battle(public.cc_kingdoms, public.cc_kingdoms, jsonb, text, int, timestamptz) from public, anon, authenticated;
revoke all on function public.cc_apply_loss_units(public.cc_kingdoms, jsonb, int) from public, anon, authenticated;
revoke all on function public.cc_apply_buildings(public.cc_kingdoms, jsonb, int) from public, anon, authenticated;
revoke all on function public.cc_anchor_of(public.cc_kingdoms) from public, anon, authenticated;
revoke all on function public.cc_regrow_until(public.cc_kingdoms, timestamptz) from public, anon, authenticated;
revoke all on function public.cc_travel_seconds(boolean, boolean) from public, anon, authenticated;
revoke all on function public.cc_tag(bigint) from public, anon, authenticated;
revoke all on function public.cc_same_alliance(bigint, bigint) from public, anon, authenticated;
revoke all on function public.cc_write_report(bigint, bigint, text, jsonb) from public, anon, authenticated;
revoke all on function public.cc_resolve_march(public.cc_kingdoms, public.cc_marches, timestamptz) from public, anon, authenticated;
revoke all on function public.cc_complete_marches(public.cc_kingdoms, timestamptz) from public, anon, authenticated;
revoke all on function public.cc_finish_npcs(bigint) from public, anon, authenticated;
revoke all on function public.cc_enlist_pacts() from public, anon, authenticated;

revoke all on function public.cc_targets(text) from public, anon;
revoke all on function public.cc_odds(bigint, jsonb) from public, anon;
revoke all on function public.cc_attack(bigint, text, jsonb) from public, anon;
revoke all on function public.cc_buy_spy(int) from public, anon;
revoke all on function public.cc_spy(bigint) from public, anon;
revoke all on function public.cc_reports() from public, anon;
revoke all on function public.cc_alliance_create(text, text, text) from public, anon;
revoke all on function public.cc_alliance_state() from public, anon;
revoke all on function public.cc_alliance_browse(text) from public, anon;
revoke all on function public.cc_alliance_board() from public, anon;
revoke all on function public.cc_alliance_request(bigint) from public, anon;
revoke all on function public.cc_alliance_invite(text) from public, anon;
revoke all on function public.cc_alliance_answer(bigint, boolean) from public, anon;
revoke all on function public.cc_alliance_leave() from public, anon;
revoke all on function public.cc_alliance_kick(text) from public, anon;
revoke all on function public.cc_alliance_set_role(text, boolean) from public, anon;
revoke all on function public.cc_alliance_transfer(text) from public, anon;
revoke all on function public.cc_alliance_disband() from public, anon;

grant execute on function public.cc_targets(text) to authenticated;
grant execute on function public.cc_odds(bigint, jsonb) to authenticated;
grant execute on function public.cc_attack(bigint, text, jsonb) to authenticated;
grant execute on function public.cc_buy_spy(int) to authenticated;
grant execute on function public.cc_spy(bigint) to authenticated;
grant execute on function public.cc_reports() to authenticated;
grant execute on function public.cc_alliance_create(text, text, text) to authenticated;
grant execute on function public.cc_alliance_state() to authenticated;
grant execute on function public.cc_alliance_browse(text) to authenticated;
grant execute on function public.cc_alliance_board() to authenticated;
grant execute on function public.cc_alliance_request(bigint) to authenticated;
grant execute on function public.cc_alliance_invite(text) to authenticated;
grant execute on function public.cc_alliance_answer(bigint, boolean) to authenticated;
grant execute on function public.cc_alliance_leave() to authenticated;
grant execute on function public.cc_alliance_kick(text) to authenticated;
grant execute on function public.cc_alliance_set_role(text, boolean) to authenticated;
grant execute on function public.cc_alliance_transfer(text) to authenticated;
grant execute on function public.cc_alliance_disband() to authenticated;
