-- Crown & Conquest chat. Review this file, then run it yourself. It is not applied here.
-- Requires 0002 (realms, alliances, cc_tag, cc_is_admin). Independent of 0003–0006.
-- 0005's admin-log check lists the same chat actions, so either file can be applied first.
-- No kingdom rows are deleted. Old chat lines are pruned inside cc_chat_send, and only
-- past the 500 kept for that channel.
-- Reads go through RLS. Writes go through cc_chat_send. Realtime uses the same select policy.

create table if not exists public.cc_chat_mutes (
  player_id uuid primary key references public.cc_players (id) on delete cascade,
  muted_until timestamptz not null,
  reason text,
  muted_by uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.cc_chat_messages (
  id bigint generated always as identity primary key,
  channel text not null check (channel in ('global', 'realm', 'alliance')),
  realm_id bigint references public.cc_realms (id) on delete cascade,
  alliance_id bigint references public.cc_alliances (id) on delete cascade,
  kingdom_id bigint references public.cc_kingdoms (id) on delete set null,
  player_id uuid not null references public.cc_players (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now(),
  deleted boolean not null default false,
  constraint cc_chat_channel_shape check (
    (channel = 'global' and realm_id is null and alliance_id is null)
    or (channel = 'realm' and realm_id is not null and alliance_id is null)
    or (channel = 'alliance' and alliance_id is not null and realm_id is null)
  )
);

create index if not exists cc_chat_player_recent on public.cc_chat_messages (player_id, created_at desc);
create index if not exists cc_chat_global_recent on public.cc_chat_messages (id desc) where channel = 'global';
create index if not exists cc_chat_realm_recent on public.cc_chat_messages (realm_id, id desc) where channel = 'realm';
create index if not exists cc_chat_alliance_recent on public.cc_chat_messages (alliance_id, id desc) where channel = 'alliance';

alter table public.cc_chat_messages replica identity full;

alter table public.cc_chat_mutes enable row level security;
alter table public.cc_chat_messages enable row level security;

revoke all on public.cc_chat_mutes from public, anon, authenticated;
revoke all on public.cc_chat_messages from public, anon, authenticated;
grant select on public.cc_chat_messages to authenticated;

create or replace function public.cc_chat_can_read(p_channel text, p_realm bigint, p_alliance bigint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when auth.uid() is null then false
    when p_channel = 'global' then true
    when p_channel = 'realm' then exists (
      select 1 from public.cc_kingdoms k
      where k.owner_id = auth.uid() and k.realm_id = p_realm
    )
    when p_channel = 'alliance' then exists (
      select 1
      from public.cc_kingdoms k
      join public.cc_alliance_members m on m.kingdom_id = k.id
      where k.owner_id = auth.uid() and m.alliance_id = p_alliance
    )
    else false
  end;
$$;

drop policy if exists cc_chat_read on public.cc_chat_messages;
create policy cc_chat_read on public.cc_chat_messages
  for select to authenticated
  using (not deleted and public.cc_chat_can_read(channel, realm_id, alliance_id));

create or replace function public.cc_chat_sender_admin(p_player uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.cc_admins a where a.user_id = p_player)
    or exists (select 1 from public.profiles p where p.id = p_player and p.role = 'admin');
$$;

create or replace function public.cc_chat_history(p_channel text, p_before bigint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
  pact bigint;
  rows jsonb;
  locked text := '';
begin
  if p_channel not in ('global', 'realm', 'alliance') then
    raise exception 'Unknown channel.';
  end if;
  row := public.cc_load_player();
  select * into k from public.cc_kingdoms where owner_id = row.id;
  if p_channel = 'realm' and k.id is null then
    locked := 'Raise a banner to hear your realm.';
  end if;
  if p_channel = 'alliance' then
    select m.alliance_id into pact
    from public.cc_alliance_members m
    where m.kingdom_id = k.id;
    if pact is null then
      locked := 'Join a pact to hear its hall.';
    end if;
  end if;
  if locked <> '' then
    return jsonb_build_object('messages', '[]'::jsonb, 'locked', locked);
  end if;

  select coalesce(jsonb_agg(s.item order by s.id), '[]'::jsonb)
  into rows
  from (
    select m.id, jsonb_build_object(
      'id', m.id,
      'body', m.body,
      'created_at', m.created_at,
      'kingdom', coalesce(k2.name, row_player.username, 'A departed crown'),
      'tag', coalesce(public.cc_tag(k2.id), ''),
      'admin', public.cc_chat_sender_admin(m.player_id),
      'player_id', m.player_id,
      'kingdom_id', m.kingdom_id
    ) as item
    from (
      select *
      from public.cc_chat_messages m
      where m.deleted = false
        and m.channel = p_channel
        and (
          p_channel = 'global'
          or (p_channel = 'realm' and m.realm_id = k.realm_id)
          or (p_channel = 'alliance' and m.alliance_id = pact)
        )
        and (p_before is null or m.id < p_before)
      order by m.id desc
      limit 100
    ) m
    left join public.cc_kingdoms k2 on k2.id = m.kingdom_id
    left join public.cc_players row_player on row_player.id = m.player_id
  ) s;
  return jsonb_build_object('messages', rows, 'locked', '');
end;
$$;

create or replace function public.cc_chat_send(p_channel text, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.cc_players;
  k public.cc_kingdoms;
  pact bigint;
  clean text := left(trim(regexp_replace(coalesce(p_body, ''), '\s+', ' ', 'g')), 300);
  recent int;
  mid bigint;
begin
  if p_channel not in ('global', 'realm', 'alliance') then
    raise exception 'Unknown channel.';
  end if;
  if clean = '' then
    raise exception 'Say something.';
  end if;
  if char_length(btrim(coalesce(p_body, ''))) > 300 then
    raise exception 'Keep it to 300 characters.';
  end if;
  row := public.cc_load_player();
  if exists (
    select 1 from public.cc_chat_mutes mute
    where mute.player_id = row.id and mute.muted_until > now()
  ) then
    raise exception 'You are muted.';
  end if;
  if (
    select count(*) from public.cc_chat_messages m
    where m.player_id = row.id and m.created_at > now() - interval '3 seconds'
  ) > 0 then
    raise exception 'Wait a moment before speaking again.';
  end if;
  select count(*) into recent
  from public.cc_chat_messages m
  where m.player_id = row.id and m.created_at > now() - interval '1 minute';
  if recent >= 20 then
    raise exception 'You have said enough for this minute.';
  end if;

  select * into k from public.cc_kingdoms where owner_id = row.id;
  if p_channel = 'realm' and k.id is null then
    raise exception 'Raise a banner before you speak in a realm.';
  end if;
  if p_channel = 'alliance' then
    if k.id is null then
      raise exception 'Raise a banner before you speak in a pact.';
    end if;
    select m.alliance_id into pact from public.cc_alliance_members m where m.kingdom_id = k.id;
    if pact is null then
      raise exception 'You are not in an alliance.';
    end if;
  end if;

  insert into public.cc_chat_messages (channel, realm_id, alliance_id, kingdom_id, player_id, body)
  values (
    p_channel,
    case when p_channel = 'realm' then k.realm_id else null end,
    case when p_channel = 'alliance' then pact else null end,
    k.id,
    row.id,
    clean
  )
  returning id into mid;

  delete from public.cc_chat_messages m
  where m.channel = p_channel
    and m.realm_id is not distinct from (case when p_channel = 'realm' then k.realm_id else null end)
    and m.alliance_id is not distinct from (case when p_channel = 'alliance' then pact else null end)
    and m.id < coalesce((
      select older.id
      from public.cc_chat_messages older
      where older.channel = p_channel
        and older.realm_id is not distinct from (case when p_channel = 'realm' then k.realm_id else null end)
        and older.alliance_id is not distinct from (case when p_channel = 'alliance' then pact else null end)
      order by older.id desc
      offset 499
      limit 1
    ), 0);

  return public.cc_chat_history(p_channel, null);
end;
$$;

create or replace function public.cc_admin_chat_recent()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  messages jsonb;
  mutes jsonb;
begin
  if not public.cc_is_admin() then
    raise exception 'Admins only.';
  end if;
  select coalesce(jsonb_agg(s.item order by s.id desc), '[]'::jsonb)
  into messages
  from (
    select m.id, jsonb_build_object(
      'id', m.id,
      'channel', m.channel,
      'body', m.body,
      'created_at', m.created_at,
      'kingdom', coalesce(k.name, p.username, 'A departed crown'),
      'username', p.username,
      'tag', coalesce(public.cc_tag(k.id), ''),
      'deleted', m.deleted
    ) as item
    from public.cc_chat_messages m
    left join public.cc_kingdoms k on k.id = m.kingdom_id
    left join public.cc_players p on p.id = m.player_id
    where m.deleted = false
    order by m.id desc
    limit 40
  ) s;
  select coalesce(jsonb_agg(s.item order by s.until desc), '[]'::jsonb)
  into mutes
  from (
    select mute.muted_until as until, jsonb_build_object(
      'username', p.username,
      'until', mute.muted_until,
      'reason', coalesce(mute.reason, '')
    ) as item
    from public.cc_chat_mutes mute
    join public.cc_players p on p.id = mute.player_id
    where mute.muted_until > now()
  ) s;
  return jsonb_build_object('messages', messages, 'mutes', mutes);
end;
$$;

create or replace function public.cc_admin_chat_delete(p_message_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  label text;
begin
  if not public.cc_is_admin() then
    raise exception 'Admins only.';
  end if;
  update public.cc_chat_messages
  set deleted = true
  where id = p_message_id and deleted = false
  returning left(body, 80) into label;
  if label is null then
    raise exception 'That message is already gone.';
  end if;
  insert into public.cc_admin_log (admin_id, action, target_label, note)
  values (uid, 'chat_delete', 'Message ' || p_message_id, label);
  return public.cc_admin_chat_recent();
end;
$$;

create or replace function public.cc_admin_chat_mute(p_player text, p_minutes int, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  target public.cc_players;
  why text := left(trim(coalesce(p_reason, '')), 200);
  mins int := coalesce(p_minutes, 0);
begin
  if not public.cc_is_admin() then
    raise exception 'Admins only.';
  end if;
  if mins < 1 or mins > 10080 then
    raise exception 'Mute between 1 minute and 7 days.';
  end if;
  if why = '' then
    raise exception 'A mute needs a reason.';
  end if;
  select * into target from public.cc_players where lower(username) = lower(trim(coalesce(p_player, '')));
  if target.id is null then
    raise exception 'No player by that name.';
  end if;
  if target.id = uid then
    raise exception 'You cannot mute this login.';
  end if;
  insert into public.cc_chat_mutes (player_id, muted_until, reason, muted_by)
  values (target.id, now() + make_interval(mins => mins), why, uid)
  on conflict (player_id) do update
  set muted_until = excluded.muted_until, reason = excluded.reason, muted_by = excluded.muted_by;
  insert into public.cc_admin_log (admin_id, action, target_player_id, target_label, note)
  values (uid, 'chat_mute', target.id, target.username, mins || ' minutes. ' || why);
  return public.cc_admin_chat_recent();
end;
$$;

create or replace function public.cc_admin_chat_unmute(p_player text)
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
  select * into target from public.cc_players where lower(username) = lower(trim(coalesce(p_player, '')));
  if target.id is null then
    raise exception 'No player by that name.';
  end if;
  delete from public.cc_chat_mutes where player_id = target.id;
  insert into public.cc_admin_log (admin_id, action, target_player_id, target_label, note)
  values (uid, 'chat_unmute', target.id, target.username, 'The mute was lifted.');
  return public.cc_admin_chat_recent();
end;
$$;

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
  alter table public.cc_admin_log
    add constraint cc_admin_log_action_check
    check (action in ('grant', 'ban', 'unban', 'wipe', 'chat_delete', 'chat_mute', 'chat_unmute'));
end $$;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'cc_chat_messages'
     ) then
    alter publication supabase_realtime add table public.cc_chat_messages;
  end if;
end $$;

revoke all on function public.cc_chat_can_read(text, bigint, bigint) from public, anon;
revoke all on function public.cc_chat_sender_admin(uuid) from public, anon, authenticated;
revoke all on function public.cc_chat_history(text, bigint) from public, anon;
revoke all on function public.cc_chat_send(text, text) from public, anon;
revoke all on function public.cc_admin_chat_recent() from public, anon;
revoke all on function public.cc_admin_chat_delete(bigint) from public, anon;
revoke all on function public.cc_admin_chat_mute(text, int, text) from public, anon;
revoke all on function public.cc_admin_chat_unmute(text) from public, anon;

grant execute on function public.cc_chat_can_read(text, bigint, bigint) to authenticated;
grant execute on function public.cc_chat_history(text, bigint) to authenticated;
grant execute on function public.cc_chat_send(text, text) to authenticated;
grant execute on function public.cc_admin_chat_recent() to authenticated;
grant execute on function public.cc_admin_chat_delete(bigint) to authenticated;
grant execute on function public.cc_admin_chat_mute(text, int, text) to authenticated;
grant execute on function public.cc_admin_chat_unmute(text) to authenticated;
