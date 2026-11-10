-- Crown & Conquest: multiple construction crews.
-- Review this file, then run it yourself. It is not applied from the client.
-- It does not delete kingdom rows. The only drop is the unique index that
-- allowed one job of each kind. Existing job rows stay. Explore and train
-- stay unique; build jobs may stack up to the crew cap.
--
-- Crews = least(4, 1 + least(2, b_guild) + (1 if r_masons >= 1 else 0)).
-- Master Masons is 2 levels. Each level shortens build time by 5%
-- (integer division, after the land's build percent).
-- Masons' Guild: 860 gold, 360 seconds, networth 64.
-- cc_get_state adds kingdom.crew_cap. The client treats a missing crew_cap
-- as the old one-crew ledger and locks the new building and study.

alter table public.cc_kingdoms
  add column if not exists b_guild int not null default 0;

alter table public.cc_kingdoms
  add column if not exists r_masons int not null default 0;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'cc_kingdoms_b_guild_check') then
    alter table public.cc_kingdoms
      add constraint cc_kingdoms_b_guild_check check (b_guild between 0 and 20000);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cc_kingdoms_r_masons_check') then
    alter table public.cc_kingdoms
      add constraint cc_kingdoms_r_masons_check check (r_masons between 0 and 2);
  end if;
end $$;

drop index if exists public.cc_jobs_one_kind;
create unique index if not exists cc_jobs_one_explore on public.cc_jobs (kingdom_id) where kind = 'explore';
create unique index if not exists cc_jobs_one_train on public.cc_jobs (kingdom_id) where kind = 'train';

create or replace function public.cc_building_cost(p_id text)
returns int
language sql
immutable
as $$
  select case p_id
    when 'farm' then 180 when 'home' then 220 when 'market' then 340 when 'mine' then 420
    when 'barracks' then 480 when 'tower' then 520 when 'library' then 640 when 'wall' then 700
    when 'shrine' then 660 when 'granary' then 260 when 'guild' then 860
  end;
$$;

create or replace function public.cc_building_seconds(p_id text)
returns int
language sql
immutable
as $$
  select case p_id
    when 'farm' then 120 when 'home' then 150 when 'market' then 180 when 'mine' then 240
    when 'barracks' then 240 when 'tower' then 210 when 'library' then 300 when 'wall' then 300
    when 'shrine' then 280 when 'granary' then 160 when 'guild' then 360
  end;
$$;

create or replace function public.cc_building_name(p_id text)
returns text
language sql
immutable
as $$
  select case p_id
    when 'farm' then 'Farmstead' when 'home' then 'Homestead' when 'market' then 'Market'
    when 'mine' then 'Mine' when 'barracks' then 'Barracks' when 'tower' then 'Watchtower'
    when 'library' then 'Library' when 'wall' then 'Curtain Wall' when 'shrine' then 'Ley Shrine'
    when 'granary' then 'Granary' when 'guild' then 'Masons'' Guild'
    else p_id
  end;
$$;

create or replace function public.cc_crew_cap(k public.cc_kingdoms)
returns int
language sql
immutable
as $$
  select least(4, 1 + least(2, coalesce(k.b_guild, 0)) + case when coalesce(k.r_masons, 0) >= 1 then 1 else 0 end);
$$;

create or replace function public.cc_networth(k public.cc_kingdoms)
returns int
language sql
immutable
as $$
  select (
    k.land * 8 + (k.peasants * 5) / 2
    + k.gold / 80 + k.food / 80 + k.mana / 40
    + k.b_farm * 12 + k.b_home * 16 + k.b_market * 28 + k.b_mine * 32
    + k.b_barracks * 36 + k.b_tower * 40 + k.b_library * 48 + k.b_wall * 52
    + k.b_shrine * 44 + k.b_granary * 18 + k.b_guild * 64
    + k.u_militia * 2 + k.u_footmen * 5 + k.u_pikemen * 6 + k.u_archers * 7
    + k.u_knights * 18 + k.u_siege * 22 + k.u_warden * 14 + k.u_spellbow * 16
    + k.u_wyvern * 40
    + (k.r_economy + k.r_population + k.r_food + k.r_military + k.r_magic + k.r_masons) * 60
  )::int;
$$;

create or replace function public.cc_free_land(p_id bigint)
returns int
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  built int;
  pending int;
begin
  select * into k from public.cc_kingdoms where id = p_id;
  built := k.b_farm + k.b_home + k.b_market + k.b_mine + k.b_barracks
    + k.b_tower + k.b_library + k.b_wall + k.b_shrine + k.b_granary + k.b_guild;
  select coalesce(sum(count), 0) into pending from public.cc_jobs where kingdom_id = p_id and kind = 'build';
  return k.land - built - pending;
end;
$$;

create or replace function public.cc_complete_due(k public.cc_kingdoms, p_until timestamptz)
returns public.cc_kingdoms
language plpgsql
security definer
set search_path = public
as $$
declare
  job public.cc_jobs;
begin
  for job in
    select * from public.cc_jobs
    where kingdom_id = k.id and completes_at <= p_until
    order by completes_at, id
  loop
    if job.kind = 'build' then
      if job.building = 'farm' then k.b_farm := k.b_farm + job.count;
      elsif job.building = 'home' then k.b_home := k.b_home + job.count;
      elsif job.building = 'market' then k.b_market := k.b_market + job.count;
      elsif job.building = 'mine' then k.b_mine := k.b_mine + job.count;
      elsif job.building = 'barracks' then k.b_barracks := k.b_barracks + job.count;
      elsif job.building = 'tower' then k.b_tower := k.b_tower + job.count;
      elsif job.building = 'library' then k.b_library := k.b_library + job.count;
      elsif job.building = 'wall' then k.b_wall := k.b_wall + job.count;
      elsif job.building = 'shrine' then k.b_shrine := k.b_shrine + job.count;
      elsif job.building = 'granary' then k.b_granary := k.b_granary + job.count;
      elsif job.building = 'guild' then k.b_guild := k.b_guild + job.count;
      end if;
      k := public.cc_note(k, p_until, public.cc_building_name(job.building) || ' finished (' || job.count || ').');
    elsif job.kind = 'explore' then
      k.land := least(2000000, k.land + job.count);
      k.peasants := least(2000000, k.peasants + job.settlers);
      k := public.cc_note(k, p_until, 'Scouts claimed ' || job.count || ' acres.');
    elsif job.kind = 'train' then
      if job.unit_id = 'militia' then k.u_militia := k.u_militia + job.count;
      elsif job.unit_id = 'footmen' then k.u_footmen := k.u_footmen + job.count;
      elsif job.unit_id = 'pikemen' then k.u_pikemen := k.u_pikemen + job.count;
      elsif job.unit_id = 'archers' then k.u_archers := k.u_archers + job.count;
      elsif job.unit_id = 'knights' then k.u_knights := k.u_knights + job.count;
      elsif job.unit_id = 'siege' then k.u_siege := k.u_siege + job.count;
      elsif job.unit_id = 'warden' then k.u_warden := k.u_warden + job.count;
      elsif job.unit_id = 'spellbow' then k.u_spellbow := k.u_spellbow + job.count;
      elsif job.unit_id = 'wyvern' then k.u_wyvern := k.u_wyvern + job.count;
      end if;
      k := public.cc_note(k, p_until, case job.unit_id
        when 'militia' then 'Militia'
        when 'footmen' then 'Footmen'
        when 'pikemen' then 'Pikemen'
        when 'archers' then 'Archers'
        when 'knights' then 'Knights'
        when 'siege' then 'Siege Engines'
        when 'warden' then 'Crownwardens'
        when 'spellbow' then 'Spellbows'
        when 'wyvern' then 'Wyvern Guard'
        else job.unit_id
      end || ' finished training (' || job.count || ').');
    end if;
    delete from public.cc_jobs where id = job.id;
  end loop;
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
    b_guild = k.b_guild,
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
    r_masons = k.r_masons,
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
  k.b_guild := greatest(0, k.b_guild + p_sign * public.cc_unit_n(p_delta, 'guild'));
  return k;
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
      'wall', k.b_wall, 'shrine', k.b_shrine, 'granary', k.b_granary, 'guild', k.b_guild
    )
  );
$$;

create or replace function public.cc_take_buildings(k public.cc_kingdoms, p_acres int)
returns jsonb
language plpgsql
immutable
as $$
declare
  built int;
  taken int;
  counts int[];
  removed int[];
  exact numeric;
  base int;
  assigned int := 0;
  i int;
  best numeric;
  best_i int;
begin
  counts := array[k.b_farm, k.b_home, k.b_market, k.b_mine, k.b_barracks, k.b_tower, k.b_library, k.b_wall, k.b_shrine, k.b_granary, k.b_guild];
  removed := array[0,0,0,0,0,0,0,0,0,0,0];
  built := counts[1]+counts[2]+counts[3]+counts[4]+counts[5]+counts[6]+counts[7]+counts[8]+counts[9]+counts[10]+counts[11];
  if p_acres <= 0 or built <= 0 or k.land <= 0 then
    return jsonb_build_object(
      'farm',0,'home',0,'market',0,'mine',0,'barracks',0,'tower',0,'library',0,'wall',0,'shrine',0,'granary',0,'guild',0
    );
  end if;
  taken := least(built, (p_acres * built) / k.land);
  for i in 1..11 loop
    exact := taken::numeric * counts[i] / built;
    base := floor(exact)::int;
    removed[i] := base;
    assigned := assigned + base;
  end loop;
  while assigned < taken loop
    best := -1;
    best_i := 0;
    for i in 1..11 loop
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
    'shrine', removed[9], 'granary', removed[10], 'guild', removed[11]
  );
end;
$$;

create or replace function public.cc_raze_buildings(k public.cc_kingdoms, p_razes int)
returns jsonb
language plpgsql
immutable
as $$
declare
  counts int[] := array[k.b_farm, k.b_home, k.b_market, k.b_mine, k.b_barracks, k.b_tower, k.b_library, k.b_wall, k.b_shrine, k.b_granary, k.b_guild];
  removed int[] := array[0,0,0,0,0,0,0,0,0,0,0];
  left_n int := p_razes;
  best int;
  best_i int;
  i int;
begin
  while left_n > 0 loop
    best := 0;
    best_i := 0;
    for i in 1..11 loop
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
    'shrine', removed[9], 'granary', removed[10], 'guild', removed[11]
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
        + def.b_tower + def.b_library + def.b_wall + def.b_shrine + def.b_granary + def.b_guild;
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
      + public.cc_unit_n(razed, 'granary') + public.cc_unit_n(razed, 'guild');
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
      foreach id in array array['farm','granary','home','market','mine','barracks','tower','library','wall','shrine','guild']
      loop
        have := case id
          when 'farm' then k.b_farm when 'home' then k.b_home when 'market' then k.b_market
          when 'mine' then k.b_mine when 'barracks' then k.b_barracks when 'tower' then k.b_tower
          when 'library' then k.b_library when 'wall' then k.b_wall when 'shrine' then k.b_shrine
          when 'guild' then k.b_guild
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
      'crew_cap', public.cc_crew_cap(k),
      'alliance', case when pact_id is null then null else jsonb_build_object(
        'id', pact_id, 'name', pact_name, 'tag', pact_tag, 'role', pact_role
      ) end,
      'buildings', jsonb_build_object(
        'farm', k.b_farm, 'home', k.b_home, 'market', k.b_market, 'mine', k.b_mine,
        'barracks', k.b_barracks, 'tower', k.b_tower, 'library', k.b_library,
        'wall', k.b_wall, 'shrine', k.b_shrine, 'granary', k.b_granary, 'guild', k.b_guild
      ),
      'units', public.cc_units_json(k),
      'research', jsonb_build_object(
        'economy', k.r_economy, 'population', k.r_population, 'food', k.r_food,
        'military', k.r_military, 'magic', k.r_magic, 'masons', k.r_masons
      ),
      'jobs', jobs,
      'marches', marches,
      'chronicle', k.chronicle
    ),
    'behind', coalesce(p_behind, false)
  );
end;
$$;

create or replace function public.cc_build(p_building text, p_count int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
  cost int;
  seconds int;
  busy int;
  cap int;
begin
  if public.cc_building_cost(p_building) is null then
    raise exception 'Unknown building.';
  end if;
  if p_count is null or p_count < 1 or p_count > 40 then
    raise exception 'Build between 1 and 40.';
  end if;
  k := public.cc_lock_kingdom();
  select count(*) into busy from public.cc_jobs where kingdom_id = k.id and kind = 'build';
  cap := public.cc_crew_cap(k);
  if busy >= cap then
    raise exception 'All construction crews are busy (%/%).', busy, cap;
  end if;
  if p_count > public.cc_free_land(k.id) then
    raise exception 'Not enough open land.';
  end if;
  cost := public.cc_building_cost(p_building) * p_count;
  if k.gold < cost then
    raise exception 'Not enough gold.';
  end if;
  seconds := (public.cc_building_seconds(p_building) * p_count * public.cc_land(k.land_type, 'build')) / 100;
  seconds := greatest(1, (seconds * (100 - 5 * least(2, k.r_masons))) / 100);
  update public.cc_kingdoms set gold = gold - cost where id = k.id;
  insert into public.cc_jobs (kingdom_id, kind, building, count, settlers, started_at, completes_at)
  values (k.id, 'build', p_building, p_count, 0, now(), now() + make_interval(secs => seconds));
  select * into k from public.cc_kingdoms where id = k.id;
  k := public.cc_note(k, now(), 'Work began on ' || p_count || ' ' || public.cc_building_name(p_building) || '.');
  perform public.cc_save_kingdom(k);
  select * into row from public.cc_players where id = k.owner_id;
  return public.cc_state_json(row, k.last_tick_at + make_interval(secs => public.cc_tick_seconds()) <= now());
end;
$$;

create or replace function public.cc_research(p_track text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
  level int;
  cost int;
  label text;
  max_level int;
begin
  if p_track not in ('economy', 'population', 'food', 'military', 'magic', 'masons') then
    raise exception 'Unknown college.';
  end if;
  k := public.cc_lock_kingdom();
  level := case p_track
    when 'economy' then k.r_economy
    when 'population' then k.r_population
    when 'food' then k.r_food
    when 'military' then k.r_military
    when 'masons' then k.r_masons
    else k.r_magic
  end;
  max_level := case when p_track = 'masons' then 2 else 10 end;
  if level >= max_level then
    raise exception 'That college is fully studied.';
  end if;
  cost := 20 * (level + 1) * (level + 2);
  if k.research_points < cost then
    raise exception 'Not enough research.';
  end if;
  label := case p_track
    when 'economy' then 'Coinwright' when 'population' then 'Hearthcraft' when 'food' then 'Harvest Lore'
    when 'military' then 'War College' when 'masons' then 'Master Masons' else 'Ley Studies'
  end;
  if p_track = 'economy' then k.r_economy := level + 1;
  elsif p_track = 'population' then k.r_population := level + 1;
  elsif p_track = 'food' then k.r_food := level + 1;
  elsif p_track = 'military' then k.r_military := level + 1;
  elsif p_track = 'masons' then k.r_masons := level + 1;
  else k.r_magic := level + 1;
  end if;
  k.research_points := k.research_points - cost;
  k := public.cc_note(k, now(), label || ' reached level ' || (level + 1) || '.');
  perform public.cc_save_kingdom(k);
  select * into row from public.cc_players where id = k.owner_id;
  return public.cc_state_json(row, k.last_tick_at + make_interval(secs => public.cc_tick_seconds()) <= now());
end;
$$;

revoke all on function public.cc_building_name(text) from public, anon, authenticated;
revoke all on function public.cc_crew_cap(public.cc_kingdoms) from public, anon, authenticated;
