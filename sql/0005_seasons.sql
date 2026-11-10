-- Crown & Conquest seasons.
-- Review this file, then run it yourself. It does not wipe anything when applied.
-- It only adds cc_seasons, opens Season 1 around the kingdoms already there,
-- and creates the wipe RPC. Calling cc_admin_wipe_season is a separate act.
-- Do not fold this into 0003 or 0004. Those files are still unapplied and
-- this one does not depend on them. Apply 0003, 0004, and 0005 in any order.
--
-- Only rows in cc_admins may wipe (seeded as mjmasters91 and Sender).
-- The confirm word is exactly WIPE. Accounts, admins, and the action log stay.
-- Hosted Supabase rejects a bare DELETE, so every delete below has a WHERE.

create table if not exists public.cc_seasons (
  id bigint generated always as identity primary key,
  number int not null,
  name text not null,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  standings jsonb not null default '{}'::jsonb,
  constraint cc_seasons_number_positive check (number > 0)
);

create unique index if not exists cc_seasons_number on public.cc_seasons (number);
create unique index if not exists cc_seasons_one_open on public.cc_seasons ((1)) where ended_at is null;

alter table public.cc_seasons enable row level security;
revoke all on public.cc_seasons from public, anon, authenticated;

do $$
declare
  con text;
begin
  select c.conname into con
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public'
    and t.relname = 'cc_admin_log'
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%grant%';
  if con is not null then
    execute format('alter table public.cc_admin_log drop constraint %I', con);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'cc_admin_log_action_check'
  ) then
    alter table public.cc_admin_log
      add constraint cc_admin_log_action_check
      check (action in ('grant', 'ban', 'unban', 'wipe', 'chat_delete', 'chat_mute', 'chat_unmute'));
  end if;
end $$;

insert into public.cc_seasons (number, name, started_at)
select 1, 'Season 1', coalesce((select min(created_at) from public.cc_kingdoms), now())
where not exists (select 1 from public.cc_seasons);

create or replace function public.cc_season_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  by_networth jsonb;
  by_land jsonb;
  alliances jsonb;
begin
  select coalesce(jsonb_agg(s.item order by s.networth desc, s.name), '[]'::jsonb)
  into by_networth
  from (
    select c.name, public.cc_networth(c) as networth, jsonb_build_object(
      'name', c.name,
      'land', c.land,
      'networth', public.cc_networth(c),
      'is_npc', c.is_npc,
      'realm', r.name,
      'tag', public.cc_tag(c.id)
    ) as item
    from public.cc_kingdoms c
    join public.cc_realms r on r.id = c.realm_id
    order by public.cc_networth(c) desc, c.name
    limit 10
  ) s;

  select coalesce(jsonb_agg(s.item order by s.land desc, s.networth desc, s.name), '[]'::jsonb)
  into by_land
  from (
    select c.name, c.land, public.cc_networth(c) as networth, jsonb_build_object(
      'name', c.name,
      'land', c.land,
      'networth', public.cc_networth(c),
      'is_npc', c.is_npc,
      'realm', r.name,
      'tag', public.cc_tag(c.id)
    ) as item
    from public.cc_kingdoms c
    join public.cc_realms r on r.id = c.realm_id
    order by c.land desc, public.cc_networth(c) desc, c.name
    limit 10
  ) s;

  select coalesce(jsonb_agg(s.item order by s.networth desc, s.name), '[]'::jsonb)
  into alliances
  from (
    select a.name, coalesce(sum(public.cc_networth(c)), 0) as networth, jsonb_build_object(
      'name', a.name,
      'tag', a.tag,
      'members', count(m.kingdom_id),
      'networth', coalesce(sum(public.cc_networth(c)), 0)
    ) as item
    from public.cc_alliances a
    left join public.cc_alliance_members m on m.alliance_id = a.id
    left join public.cc_kingdoms c on c.id = m.kingdom_id
    group by a.id
    order by coalesce(sum(public.cc_networth(c)), 0) desc, a.name
    limit 10
  ) s;

  return jsonb_build_object(
    'by_networth', by_networth,
    'by_land', by_land,
    'alliances', alliances
  );
end;
$$;

create or replace function public.cc_seasons_json()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  current_row jsonb;
  past jsonb;
begin
  select jsonb_build_object(
    'number', s.number,
    'name', s.name,
    'started_at', s.started_at
  )
  into current_row
  from public.cc_seasons s
  where s.ended_at is null
  order by s.number desc
  limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'number', s.number,
    'name', s.name,
    'started_at', s.started_at,
    'ended_at', s.ended_at,
    'standings', s.standings
  ) order by s.number desc), '[]'::jsonb)
  into past
  from public.cc_seasons s
  where s.ended_at is not null;

  return jsonb_build_object('current', current_row, 'past', past);
end;
$$;

create or replace function public.cc_seasons_view()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.cc_load_player();
  return public.cc_seasons_json();
end;
$$;

create or replace function public.cc_admin_wipe_season(p_confirm text, p_season_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cur public.cc_seasons;
  snap jsonb;
  next_number int;
  next_name text;
  rid bigint;
  realm record;
begin
  if auth.uid() is null then
    raise exception 'Log in first.';
  end if;
  if not exists (select 1 from public.cc_admins where user_id = auth.uid()) then
    raise exception 'Only the crowned stewards may wipe a season.';
  end if;
  if p_confirm is distinct from 'WIPE' then
    raise exception 'Type WIPE to confirm.';
  end if;

  lock table public.cc_battle_reports, public.cc_marches, public.cc_alliance_requests,
    public.cc_alliance_members, public.cc_alliances, public.cc_jobs, public.cc_kingdoms,
    public.cc_realms, public.cc_seasons
  in access exclusive mode;

  select * into cur from public.cc_seasons where ended_at is null order by number desc limit 1 for update;
  if cur.id is null then
    insert into public.cc_seasons (number, name, started_at)
    values (coalesce((select max(number) from public.cc_seasons), 0) + 1, 'Season 1', now())
    returning * into cur;
  end if;

  snap := public.cc_season_snapshot();
  update public.cc_seasons
  set ended_at = now(), standings = snap
  where id = cur.id;

  delete from public.cc_battle_reports where id is not null;
  delete from public.cc_marches where id is not null;
  delete from public.cc_alliance_requests where id is not null;
  delete from public.cc_alliance_members where kingdom_id is not null;
  delete from public.cc_alliances where id is not null;
  delete from public.cc_jobs where id is not null;
  delete from public.cc_kingdoms where id is not null;

  for realm in select r.id from public.cc_realms r order by r.id loop
    perform public.cc_seed_realm(realm.id);
  end loop;
  if not exists (select 1 from public.cc_realms where id is not null) then
    insert into public.cc_realms (name, seat) values ('The Amber March', 'Western vales') returning id into rid;
    perform public.cc_seed_realm(rid);
  end if;

  next_number := cur.number + 1;
  next_name := nullif(left(trim(coalesce(p_season_name, '')), 40), '');
  if next_name is null then
    next_name := 'Season ' || next_number;
  end if;
  insert into public.cc_seasons (number, name, started_at)
  values (next_number, next_name, now());

  insert into public.cc_admin_log (admin_id, action, target_label, note)
  values (
    auth.uid(),
    'wipe',
    'Season ' || cur.number,
    'Ended ' || cur.name || '. Started ' || next_name || '.'
  );

  return public.cc_seasons_json() || jsonb_build_object(
    'ended', jsonb_build_object('number', cur.number, 'name', cur.name)
  );
end;
$$;

revoke all on function public.cc_season_snapshot() from public, anon, authenticated;
revoke all on function public.cc_seasons_json() from public, anon, authenticated;
revoke all on function public.cc_seasons_view() from public, anon;
revoke all on function public.cc_admin_wipe_season(text, text) from public, anon;

grant execute on function public.cc_seasons_view() to authenticated;
grant execute on function public.cc_admin_wipe_season(text, text) to authenticated;
