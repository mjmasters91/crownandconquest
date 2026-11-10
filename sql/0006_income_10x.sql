-- Crown & Conquest: 10× hourly production.
-- Review this file, then run it yourself. It replaces rate functions only.
-- It does not delete or rewrite kingdom rows. Ticks stay 60 seconds.
-- Does not depend on 0003, 0004, or 0005.
--
-- Production constants are 10× the originals in 0001:
--   farms 140 food, granaries 60, markets 100 gold, mines 120 gold,
--   peasant tax 30 per 100 people, shrines 40 mana, scholars 20 research.
-- The mana well is 10× as deep (2500 + 900 per shrine) so it does not fill at once.
-- Peasant upkeep and soldier upkeep are 10× as well, so a starting kit's
-- net food stays about 10× the old surplus (Highlands 2124 grown, 649 eaten, net 1475).
-- A fresh Highlands tick from gold 6500 / food 4200 / mana 80 / research 70
-- ends at food 4224 (bank 2100), gold 6512 (bank 600), mana bank 2160,
-- research 74 (bank 2400). Pop progress is unchanged.
-- Build, explore, and train prices are unchanged.

create or replace function public.cc_unit(p_id text, p_key text)
returns int
language sql
immutable
as $$
  select case p_id
    when 'militia' then case p_key
      when 'attack' then 1 when 'defense' then 2 when 'gold' then 12 when 'food' then 8
      when 'peasants' then 1 when 'housing' then 1 when 'upkeep' then 60 when 'seconds' then 40
      when 'batch' then 10 when 'networth' then 2 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'footmen' then case p_key
      when 'attack' then 4 when 'defense' then 5 when 'gold' then 40 when 'food' then 16
      when 'peasants' then 1 when 'housing' then 1 when 'upkeep' then 120 when 'seconds' then 60
      when 'batch' then 8 when 'networth' then 5 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'pikemen' then case p_key
      when 'attack' then 3 when 'defense' then 8 when 'gold' then 48 when 'food' then 18
      when 'peasants' then 1 when 'housing' then 1 when 'upkeep' then 120 when 'seconds' then 60
      when 'batch' then 8 when 'networth' then 6 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'archers' then case p_key
      when 'attack' then 7 when 'defense' then 3 when 'gold' then 52 when 'food' then 14
      when 'peasants' then 1 when 'housing' then 1 when 'upkeep' then 100 when 'seconds' then 60
      when 'batch' then 8 when 'networth' then 7 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'knights' then case p_key
      when 'attack' then 12 when 'defense' then 10 when 'gold' then 160 when 'food' then 48
      when 'peasants' then 1 when 'housing' then 2 when 'upkeep' then 280 when 'seconds' then 100
      when 'batch' then 4 when 'networth' then 18 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'siege' then case p_key
      when 'attack' then 16 when 'defense' then 4 when 'gold' then 240 when 'food' then 36
      when 'peasants' then 2 when 'housing' then 4 when 'upkeep' then 220 when 'seconds' then 120
      when 'batch' then 2 when 'networth' then 22 when 'req_military' then 0 when 'req_magic' then 0
    end
    when 'warden' then case p_key
      when 'attack' then 9 when 'defense' then 12 when 'gold' then 130 when 'food' then 32
      when 'peasants' then 1 when 'housing' then 2 when 'upkeep' then 200 when 'seconds' then 100
      when 'batch' then 4 when 'networth' then 14 when 'req_military' then 4 when 'req_magic' then 0
    end
    when 'spellbow' then case p_key
      when 'attack' then 14 when 'defense' then 5 when 'gold' then 150 when 'food' then 28
      when 'peasants' then 1 when 'housing' then 1 when 'upkeep' then 160 when 'seconds' then 100
      when 'batch' then 4 when 'networth' then 16 when 'req_military' then 0 when 'req_magic' then 4
    end
    when 'wyvern' then case p_key
      when 'attack' then 22 when 'defense' then 16 when 'gold' then 380 when 'food' then 70
      when 'peasants' then 2 when 'housing' then 3 when 'upkeep' then 400 when 'seconds' then 160
      when 'batch' then 2 when 'networth' then 40 when 'req_military' then 7 when 'req_magic' then 5
    end
  end;
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
  produced := ((k.b_farm * 140 + k.b_granary * 60) * food_pct) / 100;
  upkeep := k.peasants * 200
    + k.u_militia * 60 + k.u_footmen * 120 + k.u_pikemen * 120 + k.u_archers * 100
    + k.u_knights * 280 + k.u_siege * 220 + k.u_warden * 200 + k.u_spellbow * 160 + k.u_wyvern * 400;
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
  gold_base := k.b_market * 100 + k.b_mine * 120 + (k.peasants * 30) / 100;
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
  mana_hour := (k.b_shrine * 40 * mana_pct) / 100;
  mana_cap := 2500 + k.b_shrine * 900;
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
  study_hour := (scholars * 20 * study_pct) / 100;
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
