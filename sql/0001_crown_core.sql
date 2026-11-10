-- Crown & Conquest core. Not applied.
-- Review this file, then run it in the Supabase SQL editor for project orbzytpukjywqkbkbtcs.
-- It does not alter Toon Orbit Battle or Aetherfall tables. It only reads public.profiles
-- to seed cc_admins and to recognize an existing admin role.
-- Players sign in with the same username and password as Toon Orbit Battle.
-- The client stores that username as <username>@players.toonorbit.app.
-- Hosted Supabase rejects DELETE and UPDATE with no WHERE. This file has neither.
--
-- Tick length is 60 seconds (cc_tick_seconds). Rates are per real hour.
-- Keep the numbers in this file in sync with crown/js/rules.js and crown/js/engine.js.
-- A fresh Highlands kingdom (the starting kit) is networth 3965:
--   240*8 + 300*5/2 + 6500/80 + 4200/80 + 80/40 + buildings 936 + units 224.
-- Its first tick ends at food 4202 (bank 1680), gold 6501 (bank 780),
-- mana bank 180, research bank 1680, pop_progress 42.
--
-- Combat is not implemented. cc_battle_reports is an empty slot for a later attack RPC.
-- Established NPC houses are seeded when a realm is created. They do not tick.

-- ---------- tables ----------
create table if not exists public.cc_players (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null,
  banned boolean not null default false,
  ban_reason text,
  created_at timestamptz not null default now()
);

create unique index if not exists cc_players_username_lower on public.cc_players (lower(username));

create table if not exists public.cc_admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  username text not null
);

insert into public.cc_admins (user_id, username)
select p.id, p.username
from public.profiles p
where lower(p.username) in ('mjmasters91', 'sender')
on conflict (user_id) do nothing;

create table if not exists public.cc_realms (
  id bigint generated always as identity primary key,
  name text not null,
  seat text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.cc_kingdoms (
  id bigint generated always as identity primary key,
  owner_id uuid references public.cc_players (id) on delete cascade,
  realm_id bigint not null references public.cc_realms (id),
  name text not null,
  land_type text not null check (land_type in ('highlands', 'forest', 'desert', 'volcanic', 'coastal', 'arcane')),
  is_npc boolean not null default false,
  gold int not null default 0 check (gold >= 0 and gold <= 1000000000),
  gold_bank int not null default 0 check (gold_bank >= 0 and gold_bank < 3600),
  food int not null default 0 check (food >= 0 and food <= 1000000000),
  food_bank int not null default 0 check (food_bank >= 0 and food_bank < 3600),
  mana int not null default 0 check (mana >= 0 and mana <= 1000000000),
  mana_bank int not null default 0 check (mana_bank >= 0 and mana_bank < 3600),
  research_points int not null default 0 check (research_points >= 0 and research_points <= 1000000000),
  research_bank int not null default 0 check (research_bank >= 0 and research_bank < 3600),
  pop_progress int not null default 0,
  peasants int not null default 0 check (peasants >= 0 and peasants <= 2000000),
  land int not null default 0 check (land >= 0 and land <= 2000000),
  explored_today int not null default 0 check (explored_today >= 0),
  explore_reset_at timestamptz not null default now(),
  last_tick_at timestamptz not null default now(),
  b_farm int not null default 0 check (b_farm between 0 and 20000),
  b_home int not null default 0 check (b_home between 0 and 20000),
  b_market int not null default 0 check (b_market between 0 and 20000),
  b_mine int not null default 0 check (b_mine between 0 and 20000),
  b_barracks int not null default 0 check (b_barracks between 0 and 20000),
  b_tower int not null default 0 check (b_tower between 0 and 20000),
  b_library int not null default 0 check (b_library between 0 and 20000),
  b_wall int not null default 0 check (b_wall between 0 and 20000),
  b_shrine int not null default 0 check (b_shrine between 0 and 20000),
  b_granary int not null default 0 check (b_granary between 0 and 20000),
  u_militia int not null default 0 check (u_militia between 0 and 200000),
  u_footmen int not null default 0 check (u_footmen between 0 and 200000),
  u_pikemen int not null default 0 check (u_pikemen between 0 and 200000),
  u_archers int not null default 0 check (u_archers between 0 and 200000),
  u_knights int not null default 0 check (u_knights between 0 and 200000),
  u_siege int not null default 0 check (u_siege between 0 and 200000),
  u_warden int not null default 0 check (u_warden between 0 and 200000),
  u_spellbow int not null default 0 check (u_spellbow between 0 and 200000),
  u_wyvern int not null default 0 check (u_wyvern between 0 and 200000),
  r_economy int not null default 0 check (r_economy between 0 and 10),
  r_population int not null default 0 check (r_population between 0 and 10),
  r_food int not null default 0 check (r_food between 0 and 10),
  r_military int not null default 0 check (r_military between 0 and 10),
  r_magic int not null default 0 check (r_magic between 0 and 10),
  chronicle jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  constraint cc_kingdoms_owner_npc check (
    (is_npc and owner_id is null) or (not is_npc and owner_id is not null)
  )
);

create unique index if not exists cc_kingdoms_name_lower on public.cc_kingdoms (lower(name));
create unique index if not exists cc_kingdoms_one_owner on public.cc_kingdoms (owner_id) where owner_id is not null;
create index if not exists cc_kingdoms_realm on public.cc_kingdoms (realm_id);

create table if not exists public.cc_jobs (
  id bigint generated always as identity primary key,
  kingdom_id bigint not null references public.cc_kingdoms (id) on delete cascade,
  kind text not null check (kind in ('build', 'explore', 'train')),
  building text,
  unit_id text,
  count int not null check (count > 0 and count <= 500),
  settlers int not null default 0 check (settlers >= 0),
  started_at timestamptz not null,
  completes_at timestamptz not null,
  constraint cc_jobs_shape check (
    (kind = 'build' and building is not null and unit_id is null)
    or (kind = 'train' and unit_id is not null and building is null)
    or (kind = 'explore' and building is null and unit_id is null)
  )
);

create unique index if not exists cc_jobs_one_kind on public.cc_jobs (kingdom_id, kind);
create index if not exists cc_jobs_due on public.cc_jobs (kingdom_id, completes_at);

create table if not exists public.cc_admin_log (
  id bigint generated always as identity primary key,
  admin_id uuid not null,
  action text not null check (action in ('grant', 'ban', 'unban')),
  target_player_id uuid,
  target_kingdom_id bigint,
  target_label text,
  gold int not null default 0,
  food int not null default 0,
  land int not null default 0,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists cc_admin_log_created on public.cc_admin_log (created_at desc);

-- Slot for the next slice. No attack RPC writes this yet.
create table if not exists public.cc_battle_reports (
  id bigint generated always as identity primary key,
  attacker_id bigint not null references public.cc_kingdoms (id),
  defender_id bigint not null references public.cc_kingdoms (id),
  outcome text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.cc_players enable row level security;
alter table public.cc_admins enable row level security;
alter table public.cc_realms enable row level security;
alter table public.cc_kingdoms enable row level security;
alter table public.cc_jobs enable row level security;
alter table public.cc_admin_log enable row level security;
alter table public.cc_battle_reports enable row level security;

drop policy if exists cc_players_read_own on public.cc_players;
create policy cc_players_read_own on public.cc_players
  for select to authenticated using (id = auth.uid());

drop policy if exists cc_kingdoms_read_own on public.cc_kingdoms;
create policy cc_kingdoms_read_own on public.cc_kingdoms
  for select to authenticated using (owner_id = auth.uid());

drop policy if exists cc_jobs_read_own on public.cc_jobs;
create policy cc_jobs_read_own on public.cc_jobs
  for select to authenticated using (
    exists (
      select 1 from public.cc_kingdoms k
      where k.id = kingdom_id and k.owner_id = auth.uid()
    )
  );

revoke all on public.cc_players from public, anon, authenticated;
revoke all on public.cc_admins from public, anon, authenticated;
revoke all on public.cc_realms from public, anon, authenticated;
revoke all on public.cc_kingdoms from public, anon, authenticated;
revoke all on public.cc_jobs from public, anon, authenticated;
revoke all on public.cc_admin_log from public, anon, authenticated;
revoke all on public.cc_battle_reports from public, anon, authenticated;

grant select on public.cc_players to authenticated;
grant select on public.cc_kingdoms to authenticated;
grant select on public.cc_jobs to authenticated;

-- ---------- constants (mirrors crown/js/rules.js) ----------
create or replace function public.cc_tick_seconds()
returns int
language sql
immutable
as $$
  select 60;
$$;

create or replace function public.cc_land(p_type text, p_key text)
returns int
language sql
immutable
as $$
  select case p_type
    when 'highlands' then case p_key
      when 'food' then 90 when 'gold' then 100 when 'birth' then 85 when 'housing' then 112
      when 'attack' then 100 when 'defense' then 118 when 'mana' then 90 when 'research' then 100
      when 'explore_gold' then 22 when 'explore_seconds' then 40 when 'build' then 110 when 'train' then 100
    end
    when 'forest' then case p_key
      when 'food' then 128 when 'gold' then 86 when 'birth' then 116 when 'housing' then 100
      when 'attack' then 96 when 'defense' then 104 when 'mana' then 105 when 'research' then 105
      when 'explore_gold' then 18 when 'explore_seconds' then 32 when 'build' then 90 when 'train' then 110
    end
    when 'desert' then case p_key
      when 'food' then 72 when 'gold' then 132 when 'birth' then 90 when 'housing' then 90
      when 'attack' then 100 when 'defense' then 95 when 'mana' then 110 when 'research' then 100
      when 'explore_gold' then 24 when 'explore_seconds' then 42 when 'build' then 100 when 'train' then 100
    end
    when 'volcanic' then case p_key
      when 'food' then 78 when 'gold' then 110 when 'birth' then 88 when 'housing' then 92
      when 'attack' then 120 when 'defense' then 105 when 'mana' then 115 when 'research' then 95
      when 'explore_gold' then 21 when 'explore_seconds' then 36 when 'build' then 90 when 'train' then 80
    end
    when 'coastal' then case p_key
      when 'food' then 116 when 'gold' then 116 when 'birth' then 105 when 'housing' then 100
      when 'attack' then 98 when 'defense' then 84 when 'mana' then 100 when 'research' then 100
      when 'explore_gold' then 15 when 'explore_seconds' then 30 when 'build' then 100 when 'train' then 100
    end
    when 'arcane' then case p_key
      when 'food' then 90 when 'gold' then 92 when 'birth' then 94 when 'housing' then 96
      when 'attack' then 80 when 'defense' then 92 when 'mana' then 145 when 'research' then 135
      when 'explore_gold' then 19 when 'explore_seconds' then 36 when 'build' then 110 when 'train' then 120
    end
  end;
$$;

create or replace function public.cc_building_cost(p_id text)
returns int
language sql
immutable
as $$
  select case p_id
    when 'farm' then 180 when 'home' then 220 when 'market' then 340 when 'mine' then 420
    when 'barracks' then 480 when 'tower' then 520 when 'library' then 640 when 'wall' then 700
    when 'shrine' then 660 when 'granary' then 260
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
    when 'shrine' then 280 when 'granary' then 160
  end;
$$;

-- key: attack, defense, gold, food, peasants, housing, upkeep, seconds, batch, networth, req_military, req_magic
create or replace function public.cc_unit(p_id text, p_key text)
returns int
language sql
immutable
as $$
  select case p_id
    when 'militia' then case p_key
      when 'attack' then 1 when 'defense' then 2 when 'gold' then 12 when 'food' then 8
      when 'peasants' then 1 when 'housing' then 1 when 'upkeep' then 6 when 'seconds' then 40
      when 'batch' then 10 when 'networth' then 2 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'footmen' then case p_key
      when 'attack' then 4 when 'defense' then 5 when 'gold' then 40 when 'food' then 16
      when 'peasants' then 1 when 'housing' then 1 when 'upkeep' then 12 when 'seconds' then 60
      when 'batch' then 8 when 'networth' then 5 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'pikemen' then case p_key
      when 'attack' then 3 when 'defense' then 8 when 'gold' then 48 when 'food' then 18
      when 'peasants' then 1 when 'housing' then 1 when 'upkeep' then 12 when 'seconds' then 60
      when 'batch' then 8 when 'networth' then 6 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'archers' then case p_key
      when 'attack' then 7 when 'defense' then 3 when 'gold' then 52 when 'food' then 14
      when 'peasants' then 1 when 'housing' then 1 when 'upkeep' then 10 when 'seconds' then 60
      when 'batch' then 8 when 'networth' then 7 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'knights' then case p_key
      when 'attack' then 12 when 'defense' then 10 when 'gold' then 160 when 'food' then 48
      when 'peasants' then 1 when 'housing' then 2 when 'upkeep' then 28 when 'seconds' then 100
      when 'batch' then 4 when 'networth' then 18 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'siege' then case p_key
      when 'attack' then 16 when 'defense' then 4 when 'gold' then 240 when 'food' then 36
      when 'peasants' then 2 when 'housing' then 4 when 'upkeep' then 22 when 'seconds' then 120
      when 'batch' then 2 when 'networth' then 22 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'warden' then case p_key
      when 'attack' then 9 when 'defense' then 12 when 'gold' then 130 when 'food' then 32
      when 'peasants' then 1 when 'housing' then 2 when 'upkeep' then 20 when 'seconds' then 100
      when 'batch' then 4 when 'networth' then 14 when 'req_military' then 4 when 'req_magic' then 0
    end
    when 'spellbow' then case p_key
      when 'attack' then 14 when 'defense' then 5 when 'gold' then 150 when 'food' then 28
      when 'peasants' then 1 when 'housing' then 1 when 'upkeep' then 16 when 'seconds' then 100
      when 'batch' then 4 when 'networth' then 16 when 'req_military' then 0 when 'req_magic' then 4
    end
    when 'wyvern' then case p_key
      when 'attack' then 22 when 'defense' then 16 when 'gold' then 380 when 'food' then 70
      when 'peasants' then 2 when 'housing' then 3 when 'upkeep' then 40 when 'seconds' then 160
      when 'batch' then 2 when 'networth' then 40 when 'req_military' then 7 when 'req_magic' then 5
    end
  end;
$$;

create or replace function public.cc_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.cc_admins where user_id = auth.uid())
    or exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.cc_reject_banned(p_row public.cc_players)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_row.banned then
    raise exception 'This account is banned: %', coalesce(nullif(trim(p_row.ban_reason), ''), 'No reason was recorded.');
  end if;
end;
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
    + k.b_shrine * 44 + k.b_granary * 18
    + k.u_militia * 2 + k.u_footmen * 5 + k.u_pikemen * 6 + k.u_archers * 7
    + k.u_knights * 18 + k.u_siege * 22 + k.u_warden * 14 + k.u_spellbow * 16
    + k.u_wyvern * 40
    + (k.r_economy + k.r_population + k.r_food + k.r_military + k.r_magic) * 60
  )::int;
$$;

create or replace function public.cc_food_rates(k public.cc_kingdoms)
returns table (produced int, consumed int)
language plpgsql
immutable
as $$
declare
  food_pct int;
  upkeep int;
begin
  food_pct := (public.cc_land(k.land_type, 'food') * (100 + k.r_food * 4)) / 100;
  produced := ((k.b_farm * 14 + k.b_granary * 6) * food_pct) / 100;
  upkeep := k.peasants * 20
    + k.u_militia * 6 + k.u_footmen * 12 + k.u_pikemen * 12 + k.u_archers * 10
    + k.u_knights * 28 + k.u_siege * 22 + k.u_warden * 20 + k.u_spellbow * 16 + k.u_wyvern * 40;
  consumed := upkeep / 100;
  return next;
end;
$$;

create or replace function public.cc_apply_tick(k public.cc_kingdoms)
returns public.cc_kingdoms
language plpgsql
as $$
declare
  rates record;
  tick int := public.cc_tick_seconds();
  gold_pct int;
  gold_base int;
  gold_hour int;
  mana_pct int;
  mana_hour int;
  mana_cap int;
  study_pct int;
  study_hour int;
  scholars int;
  bank bigint;
  gain bigint;
  starve_seconds int := 0;
  unpaid bigint;
  cap int;
  housing_pct int;
  thin int;
  birth_pct int;
  research_birth int;
  milli_per_hour bigint;
begin
  select * into rates from public.cc_food_rates(k);
  gold_pct := (public.cc_land(k.land_type, 'gold') * (100 + k.r_economy * 4)) / 100;
  gold_base := k.b_market * 10 + k.b_mine * 12 + (k.peasants * 3) / 100;
  gold_hour := (gold_base * gold_pct) / 100;
  bank := k.gold_bank::bigint + gold_hour::bigint * tick;
  if bank >= 3600 then
    gain := bank / 3600;
    k.gold := least(1000000000, k.gold + least(gain, 1000000000)::int);
    bank := bank - (bank / 3600) * 3600;
  end if;
  if k.gold >= 1000000000 then
    bank := 0;
  end if;
  k.gold_bank := bank::int;

  bank := k.food_bank::bigint + (rates.produced::bigint - rates.consumed::bigint) * tick;
  if bank >= 3600 then
    gain := bank / 3600;
    k.food := least(1000000000, k.food + least(gain, 1000000000)::int);
    bank := bank - (bank / 3600) * 3600;
  end if;
  if k.food >= 1000000000 then
    bank := 0;
  end if;
  if bank < 0 then
    gain := ((-bank) + 3599) / 3600;
    if gain > k.food then
      gain := k.food;
    end if;
    k.food := k.food - gain::int;
    bank := bank + gain * 3600;
  end if;
  if bank < 0 then
    unpaid := -bank;
    if rates.consumed > 0 then
      starve_seconds := least(tick, (unpaid / rates.consumed)::int);
    else
      starve_seconds := tick;
    end if;
    bank := 0;
    k.food := 0;
  end if;
  k.food_bank := bank::int;

  mana_pct := (public.cc_land(k.land_type, 'mana') * (100 + k.r_magic * 5)) / 100;
  mana_hour := (k.b_shrine * 4 * mana_pct) / 100;
  mana_cap := 250 + k.b_shrine * 90;
  bank := k.mana_bank::bigint + mana_hour::bigint * tick;
  if bank >= 3600 then
    gain := bank / 3600;
    k.mana := least(1000000000, k.mana + least(gain, 1000000000)::int);
    bank := bank - (bank / 3600) * 3600;
  end if;
  if k.mana >= mana_cap then
    k.mana := mana_cap;
    bank := 0;
  end if;
  k.mana_bank := bank::int;

  scholars := least(k.peasants, k.b_library * 14);
  study_pct := (public.cc_land(k.land_type, 'research') * (100 + k.r_magic * 4)) / 100;
  study_hour := (scholars * 2 * study_pct) / 100;
  bank := k.research_bank::bigint + study_hour::bigint * tick;
  if bank >= 3600 then
    gain := bank / 3600;
    k.research_points := least(1000000000, k.research_points + least(gain, 1000000000)::int);
    bank := bank - (bank / 3600) * 3600;
  end if;
  if k.research_points >= 1000000000 then
    bank := 0;
  end if;
  k.research_bank := bank::int;

  housing_pct := (public.cc_land(k.land_type, 'housing') * (100 + k.r_population * 2)) / 100;
  cap := ((90 + k.b_home * 24) * housing_pct) / 100;
  if k.food <= 0 then
    cap := (cap * 72) / 100;
  end if;
  if k.food >= 1 and k.peasants < cap then
    if rates.consumed > 0 and k.food < rates.consumed * 6 then
      thin := 35;
    else
      thin := 100;
    end if;
    birth_pct := public.cc_land(k.land_type, 'birth');
    research_birth := 100 + k.r_population * 3;
    milli_per_hour := (k.peasants::bigint * 10 * birth_pct * research_birth * thin) / 1000000;
    k.pop_progress := k.pop_progress + ((milli_per_hour * tick) / 3600)::int;
  end if;
  if starve_seconds > 0 and k.food <= 0 then
    k.pop_progress := k.pop_progress - ((k.peasants::bigint * 18 * starve_seconds) / 3600)::int;
  end if;
  if k.peasants > cap then
    k.pop_progress := k.pop_progress - ((((k.peasants - cap)::bigint) * 80 * tick) / 3600)::int;
  end if;
  if k.pop_progress >= 1000 and k.peasants < cap then
    gain := k.pop_progress / 1000;
    if gain > (cap - k.peasants) then
      gain := cap - k.peasants;
    end if;
    k.peasants := k.peasants + gain::int;
    k.pop_progress := k.pop_progress - (gain * 1000)::int;
  end if;
  if k.peasants >= cap and k.pop_progress > 0 then
    k.pop_progress := 0;
  end if;
  if k.pop_progress <= -1000 then
    gain := (-k.pop_progress) / 1000;
    if gain > k.peasants then
      gain := k.peasants;
    end if;
    k.peasants := k.peasants - gain::int;
    k.pop_progress := k.pop_progress + (gain * 1000)::int;
  end if;
  if k.peasants > 2000000 then
    k.peasants := 2000000;
  end if;
  return k;
end;
$$;

create or replace function public.cc_note(k public.cc_kingdoms, p_at timestamptz, p_text text)
returns public.cc_kingdoms
language plpgsql
as $$
begin
  k.chronicle := k.chronicle || jsonb_build_array(jsonb_build_object('at', p_at, 'text', p_text));
  while jsonb_array_length(k.chronicle) > 14 loop
    k.chronicle := k.chronicle - 0;
  end loop;
  return k;
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
      end if;
      k := public.cc_note(k, p_until, case job.building
        when 'farm' then 'Farmstead'
        when 'home' then 'Homestead'
        when 'market' then 'Market'
        when 'mine' then 'Mine'
        when 'barracks' then 'Barracks'
        when 'tower' then 'Watchtower'
        when 'library' then 'Library'
        when 'wall' then 'Curtain Wall'
        when 'shrine' then 'Ley Shrine'
        when 'granary' then 'Granary'
        else job.building
      end || ' finished (' || job.count || ').');
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
    chronicle = k.chronicle
  where id = k.id;
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
    k := public.cc_complete_due(k, boundary);
    k := public.cc_apply_tick(k);
    k.last_tick_at := boundary;
    ticks := ticks + 1;
  end loop;
  behind := k.last_tick_at + make_interval(secs => public.cc_tick_seconds()) <= now();
  if not behind then
    k := public.cc_complete_due(k, now());
  end if;
  perform public.cc_save_kingdom(k);
  return behind;
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
  realm_count int;
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
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', j.id,
    'kind', j.kind,
    'building', j.building,
    'unit', j.unit_id,
    'count', j.count,
    'settlers', j.settlers,
    'started_at', j.started_at,
    'completes_at', j.completes_at
  ) order by j.id), '[]'::jsonb)
  into jobs
  from public.cc_jobs j
  where j.kingdom_id = k.id;
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
      'buildings', jsonb_build_object(
        'farm', k.b_farm, 'home', k.b_home, 'market', k.b_market, 'mine', k.b_mine,
        'barracks', k.b_barracks, 'tower', k.b_tower, 'library', k.b_library,
        'wall', k.b_wall, 'shrine', k.b_shrine, 'granary', k.b_granary
      ),
      'units', jsonb_build_object(
        'militia', k.u_militia, 'footmen', k.u_footmen, 'pikemen', k.u_pikemen,
        'archers', k.u_archers, 'knights', k.u_knights, 'siege', k.u_siege,
        'warden', k.u_warden, 'spellbow', k.u_spellbow, 'wyvern', k.u_wyvern
      ),
      'research', jsonb_build_object(
        'economy', k.r_economy, 'population', k.r_population, 'food', k.r_food,
        'military', k.r_military, 'magic', k.r_magic
      ),
      'jobs', jobs,
      'chronicle', k.chronicle
    ),
    'behind', coalesce(p_behind, false)
  );
end;
$$;

create or replace function public.cc_load_player()
returns public.cc_players
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  row public.cc_players;
begin
  if uid is null then
    raise exception 'Log in first.';
  end if;
  select * into row from public.cc_players where id = uid;
  if row.id is null then
    raise exception 'Log in first.';
  end if;
  perform public.cc_reject_banned(row);
  return row;
end;
$$;

-- ---------- realm seed ----------
create or replace function public.cc_insert_npc(
  p_realm bigint,
  p_name text,
  p_land text,
  p_land_n int,
  p_gold int,
  p_food int,
  p_mana int,
  p_peasants int,
  p_points int,
  p_farm int, p_home int, p_market int, p_mine int, p_barracks int,
  p_tower int, p_library int, p_wall int, p_shrine int, p_granary int,
  p_militia int, p_footmen int, p_pikemen int, p_archers int, p_knights int,
  p_siege int, p_warden int, p_spellbow int, p_wyvern int,
  p_economy int, p_population int, p_food_r int, p_military int, p_magic int
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  chosen text := p_name;
begin
  if exists (select 1 from public.cc_kingdoms where lower(name) = lower(chosen)) then
    chosen := p_name || ' ' || p_realm;
  end if;
  insert into public.cc_kingdoms (
    owner_id, realm_id, name, land_type, is_npc,
    gold, food, mana, research_points, peasants, land,
    explore_reset_at, last_tick_at,
    b_farm, b_home, b_market, b_mine, b_barracks, b_tower, b_library, b_wall, b_shrine, b_granary,
    u_militia, u_footmen, u_pikemen, u_archers, u_knights, u_siege, u_warden, u_spellbow, u_wyvern,
    r_economy, r_population, r_food, r_military, r_magic
  ) values (
    null, p_realm, chosen, p_land, true,
    p_gold, p_food, p_mana, p_points, p_peasants, p_land_n,
    now() + interval '1 day', now(),
    p_farm, p_home, p_market, p_mine, p_barracks, p_tower, p_library, p_wall, p_shrine, p_granary,
    p_militia, p_footmen, p_pikemen, p_archers, p_knights, p_siege, p_warden, p_spellbow, p_wyvern,
    p_economy, p_population, p_food_r, p_military, p_magic
  );
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
end;
$$;

-- ---------- player rpcs ----------
create or replace function public.cc_ensure_player()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  uname text;
  row public.cc_players;
  kid bigint;
  behind boolean := false;
begin
  if uid is null then
    raise exception 'Log in first.';
  end if;
  select coalesce(nullif(trim(u.raw_user_meta_data->>'username'), ''), split_part(u.email, '@', 1))
  into uname
  from auth.users u
  where u.id = uid;
  if uname is null or uname = '' then
    uname := 'player' || substr(replace(uid::text, '-', ''), 1, 8);
  end if;
  insert into public.cc_players (id, username)
  values (uid, uname)
  on conflict (id) do nothing;
  select * into row from public.cc_players where id = uid;
  perform public.cc_reject_banned(row);
  select id into kid from public.cc_kingdoms where owner_id = uid;
  if kid is not null then
    behind := public.cc_settle(kid);
  end if;
  select * into row from public.cc_players where id = uid;
  return public.cc_state_json(row, behind);
end;
$$;

create or replace function public.cc_get_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  kid bigint;
  behind boolean := false;
begin
  row := public.cc_load_player();
  select id into kid from public.cc_kingdoms where owner_id = row.id;
  if kid is not null then
    behind := public.cc_settle(kid);
  end if;
  select * into row from public.cc_players where id = row.id;
  return public.cc_state_json(row, behind);
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
    explore_reset_at, last_tick_at,
    b_farm, b_home, b_market, b_mine, b_barracks, b_tower, b_library, b_wall, b_shrine, b_granary,
    u_militia, u_footmen, u_pikemen, u_archers, u_knights, u_siege, u_warden, u_spellbow, u_wyvern,
    chronicle
  ) values (
    row.id, rid, chosen, p_land_type, false,
    6500, 4200, 80, 70, 300, 240,
    now() + interval '1 day', now(),
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

create or replace function public.cc_lock_kingdom()
returns public.cc_kingdoms
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
begin
  row := public.cc_load_player();
  select * into k from public.cc_kingdoms where owner_id = row.id for update;
  if k.id is null then
    raise exception 'Raise a banner before you give orders.';
  end if;
  perform public.cc_settle(k.id);
  select * into k from public.cc_kingdoms where id = k.id for update;
  return k;
end;
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
    + k.b_tower + k.b_library + k.b_wall + k.b_shrine + k.b_granary;
  select coalesce(sum(count), 0) into pending from public.cc_jobs where kingdom_id = p_id and kind = 'build';
  return k.land - built - pending;
end;
$$;

create or replace function public.cc_housing_used(p_id bigint)
returns int
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  k public.cc_kingdoms;
  n int;
  extra int;
begin
  select * into k from public.cc_kingdoms where id = p_id;
  n := k.u_militia * 1 + k.u_footmen * 1 + k.u_pikemen * 1 + k.u_archers * 1
    + k.u_knights * 2 + k.u_siege * 4 + k.u_warden * 2 + k.u_spellbow * 1 + k.u_wyvern * 3;
  select coalesce(sum(j.count * public.cc_unit(j.unit_id, 'housing')), 0) into extra
  from public.cc_jobs j
  where j.kingdom_id = p_id and j.kind = 'train';
  return n + extra;
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
  label text;
begin
  if public.cc_building_cost(p_building) is null then
    raise exception 'Unknown building.';
  end if;
  if p_count is null or p_count < 1 or p_count > 40 then
    raise exception 'Build between 1 and 40.';
  end if;
  k := public.cc_lock_kingdom();
  if exists (select 1 from public.cc_jobs where kingdom_id = k.id and kind = 'build') then
    raise exception 'A construction crew is already at work.';
  end if;
  if p_count > public.cc_free_land(k.id) then
    raise exception 'Not enough open land.';
  end if;
  cost := public.cc_building_cost(p_building) * p_count;
  if k.gold < cost then
    raise exception 'Not enough gold.';
  end if;
  seconds := (public.cc_building_seconds(p_building) * p_count * public.cc_land(k.land_type, 'build')) / 100;
  update public.cc_kingdoms set gold = gold - cost where id = k.id;
  insert into public.cc_jobs (kingdom_id, kind, building, count, settlers, started_at, completes_at)
  values (k.id, 'build', p_building, p_count, 0, now(), now() + make_interval(secs => seconds));
  label := case p_building
    when 'farm' then 'Farmstead' when 'home' then 'Homestead' when 'market' then 'Market'
    when 'mine' then 'Mine' when 'barracks' then 'Barracks' when 'tower' then 'Watchtower'
    when 'library' then 'Library' when 'wall' then 'Curtain Wall' when 'shrine' then 'Ley Shrine'
    when 'granary' then 'Granary' else p_building
  end;
  select * into k from public.cc_kingdoms where id = k.id;
  k := public.cc_note(k, now(), 'Work began on ' || p_count || ' ' || label || '.');
  perform public.cc_save_kingdom(k);
  select * into row from public.cc_players where id = k.owner_id;
  return public.cc_state_json(row, k.last_tick_at + make_interval(secs => public.cc_tick_seconds()) <= now());
end;
$$;

create or replace function public.cc_explore(p_acres int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
  cap int;
  per int;
  cost int;
  settlers int;
  seconds int;
begin
  if p_acres is null or p_acres < 1 or p_acres > 200 then
    raise exception 'Explore between 1 and 200 acres.';
  end if;
  k := public.cc_lock_kingdom();
  if exists (select 1 from public.cc_jobs where kingdom_id = k.id and kind = 'explore') then
    raise exception 'An expedition is already in the field.';
  end if;
  cap := greatest(8, (k.land * 8) / 100);
  if k.explored_today + p_acres > cap then
    raise exception 'That exceeds today''s charter.';
  end if;
  per := public.cc_land(k.land_type, 'explore_gold') + (k.land / 50);
  cost := p_acres * per;
  settlers := (p_acres + 5) / 6;
  if k.gold < cost then
    raise exception 'Not enough gold.';
  end if;
  if k.peasants - settlers < 20 then
    raise exception 'Leave at least 20 peasants at home.';
  end if;
  seconds := p_acres * public.cc_land(k.land_type, 'explore_seconds');
  update public.cc_kingdoms
  set gold = gold - cost, peasants = peasants - settlers, explored_today = explored_today + p_acres
  where id = k.id;
  insert into public.cc_jobs (kingdom_id, kind, count, settlers, started_at, completes_at)
  values (k.id, 'explore', p_acres, settlers, now(), now() + make_interval(secs => seconds));
  select * into k from public.cc_kingdoms where id = k.id;
  k := public.cc_note(k, now(), 'Scouts left to claim ' || p_acres || ' acres.');
  perform public.cc_save_kingdom(k);
  select * into row from public.cc_players where id = k.owner_id;
  return public.cc_state_json(row, k.last_tick_at + make_interval(secs => public.cc_tick_seconds()) <= now());
end;
$$;

create or replace function public.cc_train(p_unit text, p_count int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
  batches int;
  seconds int;
  need_gold int;
  need_food int;
  need_peasants int;
  need_housing int;
  req_m int;
  req_g int;
begin
  if public.cc_unit(p_unit, 'gold') is null then
    raise exception 'Unknown unit.';
  end if;
  if p_count is null or p_count < 1 or p_count > 200 then
    raise exception 'Train between 1 and 200.';
  end if;
  k := public.cc_lock_kingdom();
  if k.b_barracks < 1 then
    raise exception 'Build a barracks before you train.';
  end if;
  req_m := public.cc_unit(p_unit, 'req_military');
  req_g := public.cc_unit(p_unit, 'req_magic');
  if k.r_military < req_m or k.r_magic < req_g then
    raise exception 'That college is not open yet.';
  end if;
  if exists (select 1 from public.cc_jobs where kingdom_id = k.id and kind = 'train') then
    raise exception 'A company is already in training.';
  end if;
  batches := (p_count + public.cc_unit(p_unit, 'batch') - 1) / public.cc_unit(p_unit, 'batch');
  seconds := (batches * public.cc_unit(p_unit, 'seconds') * public.cc_land(k.land_type, 'train')) / 100;
  need_gold := public.cc_unit(p_unit, 'gold') * p_count;
  need_food := public.cc_unit(p_unit, 'food') * p_count;
  need_peasants := public.cc_unit(p_unit, 'peasants') * p_count;
  need_housing := public.cc_unit(p_unit, 'housing') * p_count;
  if public.cc_housing_used(k.id) + need_housing > (30 + k.b_barracks * 48) then
    raise exception 'The barracks cannot house them.';
  end if;
  if k.gold < need_gold then
    raise exception 'Not enough gold.';
  end if;
  if k.food < need_food then
    raise exception 'Not enough food.';
  end if;
  if k.peasants - need_peasants < 20 then
    raise exception 'Leave at least 20 peasants to work the land.';
  end if;
  update public.cc_kingdoms
  set gold = gold - need_gold, food = food - need_food, peasants = peasants - need_peasants
  where id = k.id;
  insert into public.cc_jobs (kingdom_id, kind, unit_id, count, settlers, started_at, completes_at)
  values (k.id, 'train', p_unit, p_count, 0, now(), now() + make_interval(secs => seconds));
  select * into k from public.cc_kingdoms where id = k.id;
  k := public.cc_note(k, now(), p_count || ' ' || case p_unit
    when 'militia' then 'Militia' when 'footmen' then 'Footmen' when 'pikemen' then 'Pikemen'
    when 'archers' then 'Archers' when 'knights' then 'Knights' when 'siege' then 'Siege Engines'
    when 'warden' then 'Crownwardens' when 'spellbow' then 'Spellbows' when 'wyvern' then 'Wyvern Guard'
    else p_unit end || ' began training.');
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
begin
  if p_track not in ('economy', 'population', 'food', 'military', 'magic') then
    raise exception 'Unknown college.';
  end if;
  k := public.cc_lock_kingdom();
  level := case p_track
    when 'economy' then k.r_economy
    when 'population' then k.r_population
    when 'food' then k.r_food
    when 'military' then k.r_military
    else k.r_magic
  end;
  if level >= 10 then
    raise exception 'That college is fully studied.';
  end if;
  cost := 20 * (level + 1) * (level + 2);
  if k.research_points < cost then
    raise exception 'Not enough research.';
  end if;
  label := case p_track
    when 'economy' then 'Coinwright' when 'population' then 'Hearthcraft' when 'food' then 'Harvest Lore'
    when 'military' then 'War College' else 'Ley Studies'
  end;
  if p_track = 'economy' then k.r_economy := level + 1;
  elsif p_track = 'population' then k.r_population := level + 1;
  elsif p_track = 'food' then k.r_food := level + 1;
  elsif p_track = 'military' then k.r_military := level + 1;
  else k.r_magic := level + 1;
  end if;
  k.research_points := k.research_points - cost;
  k := public.cc_note(k, now(), label || ' reached level ' || (level + 1) || '.');
  perform public.cc_save_kingdom(k);
  select * into row from public.cc_players where id = k.owner_id;
  return public.cc_state_json(row, k.last_tick_at + make_interval(secs => public.cc_tick_seconds()) <= now());
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
      'realm_name', r.name
    ) as item
    from public.cc_kingdoms k
    join public.cc_realms r on r.id = k.realm_id
    where p_realm is null or k.realm_id = p_realm
  ) s;
  return rows;
end;
$$;

create or replace function public.cc_realm()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
  r public.cc_realms;
  n int;
begin
  row := public.cc_load_player();
  select * into k from public.cc_kingdoms where owner_id = row.id;
  if k.id is null then
    raise exception 'Raise a banner before you take a seat.';
  end if;
  perform public.cc_settle(k.id);
  select * into k from public.cc_kingdoms where id = k.id;
  select * into r from public.cc_realms where id = k.realm_id;
  select count(*) into n from public.cc_kingdoms where realm_id = k.realm_id;
  return jsonb_build_object(
    'realm', jsonb_build_object(
      'id', r.id,
      'name', r.name,
      'seat', r.seat,
      'count', n,
      'open', greatest(0, 20 - n)
    ),
    'kingdoms', public.cc_public_rows(k.realm_id, k.id)
  );
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
      'realm_name', r.name
    ) as item
    from public.cc_kingdoms c
    join public.cc_realms r on r.id = c.realm_id
    order by public.cc_networth(c) desc, c.name
    limit 20
  ) s;
  return jsonb_build_object('kingdoms', rows);
end;
$$;

-- ---------- admin ----------
create or replace function public.cc_admin_search(p_query text default '')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  raw text := left(trim(coalesce(p_query, '')), 32);
  q text := replace(replace(replace(raw, '\', '\\'), '%', '\%'), '_', '\_');
  rows jsonb;
begin
  if not public.cc_is_admin() then
    raise exception 'Admins only.';
  end if;
  select coalesce(jsonb_agg(s.item order by s.label), '[]'::jsonb)
  into rows
  from (
    select k.name as label, jsonb_build_object(
      'kingdom_id', k.id,
      'name', k.name,
      'username', p.username,
      'land_type', k.land_type,
      'land', k.land,
      'gold', k.gold,
      'food', k.food,
      'peasants', k.peasants,
      'networth', public.cc_networth(k),
      'is_npc', k.is_npc,
      'banned', coalesce(p.banned, false),
      'ban_reason', p.ban_reason,
      'realm_name', r.name
    ) as item
    from public.cc_kingdoms k
    join public.cc_realms r on r.id = k.realm_id
    left join public.cc_players p on p.id = k.owner_id
    where q = ''
      or k.name ilike '%' || q || '%' escape '\'
      or p.username ilike '%' || q || '%' escape '\'
    order by k.name
    limit 40
  ) s;
  return jsonb_build_object('kingdoms', rows);
end;
$$;

create or replace function public.cc_admin_grant(
  p_name text,
  p_gold int default 0,
  p_food int default 0,
  p_land int default 0,
  p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  k public.cc_kingdoms;
  add_gold int := coalesce(p_gold, 0);
  add_food int := coalesce(p_food, 0);
  add_land int := coalesce(p_land, 0);
begin
  if not public.cc_is_admin() then
    raise exception 'Admins only.';
  end if;
  if add_gold < 0 or add_food < 0 or add_land < 0 then
    raise exception 'Grants must be zero or positive.';
  end if;
  if add_gold = 0 and add_food = 0 and add_land = 0 then
    raise exception 'Grant at least one thing.';
  end if;
  if add_gold > 500000 or add_food > 500000 or add_land > 2000 then
    raise exception 'That grant is too large.';
  end if;
  select * into k from public.cc_kingdoms where lower(name) = lower(trim(p_name)) for update;
  if k.id is null then
    raise exception 'No kingdom by that name.';
  end if;
  if not k.is_npc then
    perform public.cc_settle(k.id);
    select * into k from public.cc_kingdoms where id = k.id for update;
  end if;
  update public.cc_kingdoms
  set gold = least(1000000000, gold + add_gold),
      food = least(1000000000, food + add_food),
      land = least(2000000, land + add_land)
  where id = k.id;
  insert into public.cc_admin_log (admin_id, action, target_player_id, target_kingdom_id, target_label, gold, food, land, note)
  values (uid, 'grant', k.owner_id, k.id, k.name, add_gold, add_food, add_land, nullif(left(trim(coalesce(p_note, '')), 200), ''));
  return jsonb_build_object('ok', true, 'name', k.name);
end;
$$;

create or replace function public.cc_admin_ban(p_username text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  target public.cc_players;
  why text := left(trim(coalesce(p_reason, '')), 200);
begin
  if not public.cc_is_admin() then
    raise exception 'Admins only.';
  end if;
  if why = '' then
    raise exception 'A ban needs a reason.';
  end if;
  select * into target from public.cc_players where lower(username) = lower(trim(p_username)) for update;
  if target.id is null then
    raise exception 'No player by that name.';
  end if;
  if target.id = uid then
    raise exception 'You cannot ban this login.';
  end if;
  update public.cc_players set banned = true, ban_reason = why where id = target.id;
  insert into public.cc_admin_log (admin_id, action, target_player_id, target_label, note)
  values (uid, 'ban', target.id, target.username, why);
  return jsonb_build_object('ok', true, 'username', target.username);
end;
$$;

create or replace function public.cc_admin_unban(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  target public.cc_players;
begin
  if not public.cc_is_admin() then
    raise exception 'Admins only.';
  end if;
  select * into target from public.cc_players where lower(username) = lower(trim(p_username)) for update;
  if target.id is null then
    raise exception 'No player by that name.';
  end if;
  update public.cc_players set banned = false, ban_reason = null where id = target.id;
  insert into public.cc_admin_log (admin_id, action, target_player_id, target_label)
  values (uid, 'unban', target.id, target.username);
  return jsonb_build_object('ok', true, 'username', target.username);
end;
$$;

create or replace function public.cc_admin_log()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  rows jsonb;
begin
  if not public.cc_is_admin() then
    raise exception 'Admins only.';
  end if;
  select coalesce(jsonb_agg(s.item order by s.created_at desc), '[]'::jsonb)
  into rows
  from (
    select l.created_at, jsonb_build_object(
      'action', l.action,
      'label', l.target_label,
      'gold', l.gold,
      'food', l.food,
      'land', l.land,
      'note', l.note,
      'created_at', l.created_at
    ) as item
    from public.cc_admin_log l
    order by l.created_at desc
    limit 20
  ) s;
  return jsonb_build_object('entries', rows);
end;
$$;

-- ---------- privileges ----------
revoke all on function public.cc_tick_seconds() from public, anon, authenticated;
revoke all on function public.cc_land(text, text) from public, anon, authenticated;
revoke all on function public.cc_building_cost(text) from public, anon, authenticated;
revoke all on function public.cc_building_seconds(text) from public, anon, authenticated;
revoke all on function public.cc_unit(text, text) from public, anon, authenticated;
revoke all on function public.cc_is_admin() from public, anon, authenticated;
revoke all on function public.cc_reject_banned(public.cc_players) from public, anon, authenticated;
revoke all on function public.cc_networth(public.cc_kingdoms) from public, anon, authenticated;
revoke all on function public.cc_food_rates(public.cc_kingdoms) from public, anon, authenticated;
revoke all on function public.cc_apply_tick(public.cc_kingdoms) from public, anon, authenticated;
revoke all on function public.cc_note(public.cc_kingdoms, timestamptz, text) from public, anon, authenticated;
revoke all on function public.cc_complete_due(public.cc_kingdoms, timestamptz) from public, anon, authenticated;
revoke all on function public.cc_save_kingdom(public.cc_kingdoms) from public, anon, authenticated;
revoke all on function public.cc_settle(bigint) from public, anon, authenticated;
revoke all on function public.cc_state_json(public.cc_players, boolean) from public, anon, authenticated;
revoke all on function public.cc_load_player() from public, anon, authenticated;
revoke all on function public.cc_insert_npc(bigint, text, text, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int) from public, anon, authenticated;
revoke all on function public.cc_seed_realm(bigint) from public, anon, authenticated;
revoke all on function public.cc_lock_kingdom() from public, anon, authenticated;
revoke all on function public.cc_free_land(bigint) from public, anon, authenticated;
revoke all on function public.cc_housing_used(bigint) from public, anon, authenticated;
revoke all on function public.cc_public_rows(bigint, bigint) from public, anon, authenticated;

revoke all on function public.cc_ensure_player() from public, anon;
revoke all on function public.cc_get_state() from public, anon;
revoke all on function public.cc_create_kingdom(text, text) from public, anon;
revoke all on function public.cc_build(text, int) from public, anon;
revoke all on function public.cc_explore(int) from public, anon;
revoke all on function public.cc_train(text, int) from public, anon;
revoke all on function public.cc_research(text) from public, anon;
revoke all on function public.cc_realm() from public, anon;
revoke all on function public.cc_leaderboard() from public, anon;
revoke all on function public.cc_admin_search(text) from public, anon;
revoke all on function public.cc_admin_grant(text, int, int, int, text) from public, anon;
revoke all on function public.cc_admin_ban(text, text) from public, anon;
revoke all on function public.cc_admin_unban(text) from public, anon;
revoke all on function public.cc_admin_log() from public, anon;

grant execute on function public.cc_ensure_player() to authenticated;
grant execute on function public.cc_get_state() to authenticated;
grant execute on function public.cc_create_kingdom(text, text) to authenticated;
grant execute on function public.cc_build(text, int) to authenticated;
grant execute on function public.cc_explore(int) to authenticated;
grant execute on function public.cc_train(text, int) to authenticated;
grant execute on function public.cc_research(text) to authenticated;
grant execute on function public.cc_realm() to authenticated;
grant execute on function public.cc_leaderboard() to authenticated;
grant execute on function public.cc_admin_search(text) to authenticated;
grant execute on function public.cc_admin_grant(text, int, int, int, text) to authenticated;
grant execute on function public.cc_admin_ban(text, text) to authenticated;
grant execute on function public.cc_admin_unban(text) to authenticated;
grant execute on function public.cc_admin_log() to authenticated;
