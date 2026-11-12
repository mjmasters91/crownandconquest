-- Crown & Conquest official site: news and forums.
-- Review this file, then run it yourself. It is not applied from here.
-- It does not change the Windows game or the legacy browser game.
-- Tables use the ccs_ prefix. Reads are public. Writes go through
-- SECURITY DEFINER functions with search_path = public.
-- Admins are the existing stewards (cc_is_admin) plus the named
-- accounts mjmasters91 and Sender.
-- A post waits 8 seconds, and a person may post 12 times in 10 minutes.
-- Titles are 3-80 characters (news titles 3-120). Forum posts are
-- 1-4000 characters. News bodies are 1-8000.

create table if not exists public.ccs_posts (
  id bigint generated always as identity primary key,
  title text not null check (char_length(title) between 3 and 120),
  body text not null check (char_length(body) between 1 and 8000),
  author_id uuid,
  author_name text not null check (char_length(author_name) between 1 and 32),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.ccs_categories (
  id bigint generated always as identity primary key,
  slug text not null unique check (slug ~ '^[a-z]{3,24}$'),
  name text not null check (char_length(name) between 3 and 40),
  blurb text not null default '',
  sort int not null default 0
);

create table if not exists public.ccs_threads (
  id bigint generated always as identity primary key,
  category_id bigint not null references public.ccs_categories (id),
  author_id uuid,
  author_name text not null check (char_length(author_name) between 1 and 32),
  title text not null check (char_length(title) between 3 and 80),
  body text not null check (char_length(body) between 1 and 4000),
  pinned boolean not null default false,
  locked boolean not null default false,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.ccs_replies (
  id bigint generated always as identity primary key,
  thread_id bigint not null references public.ccs_threads (id),
  author_id uuid,
  author_name text not null check (char_length(author_name) between 1 and 32),
  body text not null check (char_length(body) between 1 and 4000),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.ccs_actions (
  id bigint generated always as identity primary key,
  player_id uuid not null,
  created_at timestamptz not null default now()
);

create index if not exists ccs_posts_recent on public.ccs_posts (created_at desc) where deleted_at is null;
create index if not exists ccs_threads_category on public.ccs_threads (category_id, created_at desc) where deleted_at is null;
create index if not exists ccs_replies_thread on public.ccs_replies (thread_id, created_at);
create index if not exists ccs_actions_player on public.ccs_actions (player_id, created_at desc);

alter table public.ccs_posts enable row level security;
alter table public.ccs_categories enable row level security;
alter table public.ccs_threads enable row level security;
alter table public.ccs_replies enable row level security;
alter table public.ccs_actions enable row level security;

drop policy if exists ccs_posts_read on public.ccs_posts;
create policy ccs_posts_read on public.ccs_posts
  for select to anon, authenticated using (deleted_at is null);

drop policy if exists ccs_categories_read on public.ccs_categories;
create policy ccs_categories_read on public.ccs_categories
  for select to anon, authenticated using (true);

drop policy if exists ccs_threads_read on public.ccs_threads;
create policy ccs_threads_read on public.ccs_threads
  for select to anon, authenticated using (deleted_at is null);

drop policy if exists ccs_replies_read on public.ccs_replies;
create policy ccs_replies_read on public.ccs_replies
  for select to anon, authenticated using (deleted_at is null);

revoke all on public.ccs_posts from public, anon, authenticated;
revoke all on public.ccs_categories from public, anon, authenticated;
revoke all on public.ccs_threads from public, anon, authenticated;
revoke all on public.ccs_replies from public, anon, authenticated;
revoke all on public.ccs_actions from public, anon, authenticated;

grant select on public.ccs_posts to anon, authenticated;
grant select on public.ccs_categories to anon, authenticated;
grant select on public.ccs_threads to anon, authenticated;
grant select on public.ccs_replies to anon, authenticated;

insert into public.ccs_categories (slug, name, blurb, sort) values
  ('announcements', 'Announcements', 'Releases and notes from the stewards.', 10),
  ('general', 'General', 'The valley, the game, and everything beside strategy.', 20),
  ('strategy', 'Strategy', 'Openings, army counters, and how a valley is won.', 30),
  ('bugs', 'Bug Reports', 'What broke, and how to see it again.', 40),
  ('suggestions', 'Suggestions', 'Ideas for the next build.', 50)
on conflict (slug) do nothing;

insert into public.ccs_posts (title, body, author_name)
select
  'v0.1.0 is ready to download',
  E'Crown & Conquest v0.1.0, the first public Windows build, is on the download page.\n\nIt is a skirmish against the AI. Play as the Vale Wardens or the Rime Clans. Villagers gather food, wood, gold, and stone, a Homestead raises the population cap, and the match starts in the Seed Age. Pikes, archers, and cavalry counter one another. Maps are Small, Medium, and Large. Large is 96 by 96.\n\nThe zip holds CrownAndConquest.exe. Windows SmartScreen may warn because the build is not signed. Choose More info, then Run anyway.\n\nTwo hearths cannot share one valley.',
  'Crown & Conquest'
where not exists (select 1 from public.ccs_posts where title = 'v0.1.0 is ready to download');

create or replace function public.ccs_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select public.cc_is_admin()
    or exists (
      select 1 from public.cc_players p
      where p.id = auth.uid()
        and lower(p.username) in ('mjmasters91', 'sender')
    );
$fn$;

create or replace function public.ccs_actor()
returns table (player_id uuid, username text, is_admin boolean)
language plpgsql
stable
security definer
set search_path = public
as $fn$
#variable_conflict use_column
declare
  uid uuid := auth.uid();
  name text;
  banned boolean := false;
begin
  if uid is null then
    raise exception 'Log in first.';
  end if;
  select p.username, p.banned into name, banned
  from public.cc_players p
  where p.id = uid;
  if banned then
    raise exception 'This account is banned.';
  end if;
  if name is null then
    select pr.username into name
    from public.profiles pr
    where pr.id = uid;
  end if;
  name := left(trim(coalesce(name, 'player-' || left(uid::text, 6))), 32);
  if name = '' then
    name := 'player';
  end if;
  player_id := uid;
  username := name;
  is_admin := public.ccs_is_admin();
  return next;
end;
$fn$;

create or replace function public.ccs_touch_rate()
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  uid uuid := auth.uid();
  recent int;
begin
  if uid is null then
    raise exception 'Log in first.';
  end if;
  if exists (
    select 1 from public.ccs_actions a
    where a.player_id = uid and a.created_at > now() - interval '8 seconds'
  ) then
    raise exception 'Wait a moment before posting again.';
  end if;
  select count(*) into recent
  from public.ccs_actions a
  where a.player_id = uid and a.created_at > now() - interval '10 minutes';
  if recent >= 12 then
    raise exception 'You have posted enough for these ten minutes.';
  end if;
  insert into public.ccs_actions (player_id) values (uid);
  delete from public.ccs_actions a
  where a.player_id = uid and a.created_at < now() - interval '2 days';
end;
$fn$;

create or replace function public.ccs_whoami()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  actor record;
begin
  if auth.uid() is null then
    return jsonb_build_object('signed_in', false, 'username', '', 'admin', false);
  end if;
  select * into actor from public.ccs_actor();
  return jsonb_build_object('signed_in', true, 'username', actor.username, 'admin', actor.is_admin);
end;
$fn$;

create or replace function public.ccs_news_list()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object('posts', coalesce(jsonb_agg(s.item order by s.created_at desc), '[]'::jsonb))
  from (
    select p.created_at, jsonb_build_object(
      'id', p.id,
      'title', p.title,
      'body', p.body,
      'author_name', p.author_name,
      'created_at', p.created_at
    ) as item
    from public.ccs_posts p
    where p.deleted_at is null
    order by p.created_at desc
    limit 40
  ) s;
$fn$;

create or replace function public.ccs_news_publish(p_title text, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor record;
  clean_title text := left(trim(regexp_replace(coalesce(p_title, ''), '\s+', ' ', 'g')), 120);
  clean_body text := trim(coalesce(p_body, ''));
  pid bigint;
begin
  select * into actor from public.ccs_actor();
  if not actor.is_admin then
    raise exception 'Admins only.';
  end if;
  if char_length(coalesce(p_title, '')) > 120 or char_length(clean_title) < 3 then
    raise exception 'Use a title of 3-120 characters.';
  end if;
  if char_length(coalesce(p_body, '')) > 8000 or char_length(clean_body) < 1 then
    raise exception 'Keep a notice to 8000 characters.';
  end if;
  perform public.ccs_touch_rate();
  insert into public.ccs_posts (title, body, author_id, author_name)
  values (clean_title, clean_body, actor.player_id, actor.username)
  returning id into pid;
  return jsonb_build_object('id', pid);
end;
$fn$;

create or replace function public.ccs_news_remove(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor record;
begin
  select * into actor from public.ccs_actor();
  if not actor.is_admin then
    raise exception 'Admins only.';
  end if;
  update public.ccs_posts
  set deleted_at = now()
  where id = p_id and deleted_at is null;
  if not found then
    raise exception 'That notice is already gone.';
  end if;
  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.ccs_forum_board()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object('categories', coalesce(jsonb_agg(s.item order by s.sort, s.name), '[]'::jsonb))
  from (
    select c.sort, c.name, jsonb_build_object(
      'slug', c.slug,
      'name', c.name,
      'blurb', c.blurb,
      'threads', (
        select count(*) from public.ccs_threads t
        where t.category_id = c.id and t.deleted_at is null
      )
    ) as item
    from public.ccs_categories c
  ) s;
$fn$;

create or replace function public.ccs_forum_threads(p_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  cat public.ccs_categories;
  rows jsonb;
begin
  select * into cat from public.ccs_categories where slug = lower(trim(coalesce(p_slug, '')));
  if not found then
    raise exception 'Unknown hall.';
  end if;
  select coalesce(jsonb_agg(s.item order by s.pinned desc, s.created_at desc), '[]'::jsonb)
  into rows
  from (
    select t.pinned, t.created_at, jsonb_build_object(
      'id', t.id,
      'title', t.title,
      'author_name', t.author_name,
      'created_at', t.created_at,
      'pinned', t.pinned,
      'locked', t.locked,
      'replies', (
        select count(*) from public.ccs_replies r
        where r.thread_id = t.id and r.deleted_at is null
      )
    ) as item
    from public.ccs_threads t
    where t.category_id = cat.id and t.deleted_at is null
    order by t.pinned desc, t.created_at desc
    limit 80
  ) s;
  return jsonb_build_object(
    'category', jsonb_build_object('slug', cat.slug, 'name', cat.name, 'blurb', cat.blurb),
    'threads', rows
  );
end;
$fn$;

create or replace function public.ccs_forum_thread(p_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  thread public.ccs_threads;
  cat public.ccs_categories;
  replies jsonb;
begin
  select * into thread from public.ccs_threads where id = p_id and deleted_at is null;
  if not found then
    raise exception 'That thread is gone.';
  end if;
  select * into cat from public.ccs_categories where id = thread.category_id;
  select coalesce(jsonb_agg(s.item order by s.created_at), '[]'::jsonb)
  into replies
  from (
    select r.created_at, jsonb_build_object(
      'id', r.id,
      'author_name', r.author_name,
      'body', r.body,
      'created_at', r.created_at
    ) as item
    from public.ccs_replies r
    where r.thread_id = thread.id and r.deleted_at is null
    order by r.created_at
    limit 200
  ) s;
  return jsonb_build_object(
    'thread', jsonb_build_object(
      'id', thread.id,
      'title', thread.title,
      'body', thread.body,
      'author_name', thread.author_name,
      'created_at', thread.created_at,
      'pinned', thread.pinned,
      'locked', thread.locked,
      'category_slug', cat.slug,
      'category_name', cat.name
    ),
    'replies', replies
  );
end;
$fn$;

create or replace function public.ccs_forum_new_thread(p_slug text, p_title text, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor record;
  cat public.ccs_categories;
  clean_title text := left(trim(regexp_replace(coalesce(p_title, ''), '\s+', ' ', 'g')), 80);
  clean_body text := trim(coalesce(p_body, ''));
  tid bigint;
begin
  select * into actor from public.ccs_actor();
  select * into cat from public.ccs_categories where slug = lower(trim(coalesce(p_slug, '')));
  if not found then
    raise exception 'Unknown hall.';
  end if;
  if cat.slug = 'announcements' and not actor.is_admin then
    raise exception 'Only a steward can post an announcement.';
  end if;
  if char_length(coalesce(p_title, '')) > 80 or char_length(clean_title) < 3 then
    raise exception 'Use a title of 3-80 characters.';
  end if;
  if char_length(coalesce(p_body, '')) > 4000 or char_length(clean_body) < 1 then
    raise exception 'Keep a post to 4000 characters.';
  end if;
  perform public.ccs_touch_rate();
  insert into public.ccs_threads (category_id, author_id, author_name, title, body)
  values (cat.id, actor.player_id, actor.username, clean_title, clean_body)
  returning id into tid;
  return jsonb_build_object('id', tid);
end;
$fn$;

create or replace function public.ccs_forum_reply(p_thread bigint, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor record;
  thread public.ccs_threads;
  clean_body text := trim(coalesce(p_body, ''));
  rid bigint;
begin
  select * into actor from public.ccs_actor();
  select * into thread from public.ccs_threads where id = p_thread and deleted_at is null;
  if not found then
    raise exception 'That thread is gone.';
  end if;
  if thread.locked and not actor.is_admin then
    raise exception 'This thread is locked.';
  end if;
  if char_length(coalesce(p_body, '')) > 4000 or char_length(clean_body) < 1 then
    raise exception 'Keep a post to 4000 characters.';
  end if;
  perform public.ccs_touch_rate();
  insert into public.ccs_replies (thread_id, author_id, author_name, body)
  values (thread.id, actor.player_id, actor.username, clean_body)
  returning id into rid;
  return jsonb_build_object('id', rid);
end;
$fn$;

create or replace function public.ccs_forum_pin(p_thread bigint, p_pinned boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor record;
begin
  select * into actor from public.ccs_actor();
  if not actor.is_admin then
    raise exception 'Admins only.';
  end if;
  update public.ccs_threads
  set pinned = coalesce(p_pinned, false)
  where id = p_thread and deleted_at is null;
  if not found then
    raise exception 'That thread is gone.';
  end if;
  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.ccs_forum_lock(p_thread bigint, p_locked boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor record;
begin
  select * into actor from public.ccs_actor();
  if not actor.is_admin then
    raise exception 'Admins only.';
  end if;
  update public.ccs_threads
  set locked = coalesce(p_locked, false)
  where id = p_thread and deleted_at is null;
  if not found then
    raise exception 'That thread is gone.';
  end if;
  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.ccs_forum_delete_thread(p_thread bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor record;
begin
  select * into actor from public.ccs_actor();
  if not actor.is_admin then
    raise exception 'Admins only.';
  end if;
  update public.ccs_threads
  set deleted_at = now()
  where id = p_thread and deleted_at is null;
  if not found then
    raise exception 'That thread is gone.';
  end if;
  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.ccs_forum_delete_reply(p_reply bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  actor record;
begin
  select * into actor from public.ccs_actor();
  if not actor.is_admin then
    raise exception 'Admins only.';
  end if;
  update public.ccs_replies
  set deleted_at = now()
  where id = p_reply and deleted_at is null;
  if not found then
    raise exception 'That reply is gone.';
  end if;
  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.ccs_is_admin() from public, anon, authenticated;
revoke all on function public.ccs_actor() from public, anon, authenticated;
revoke all on function public.ccs_touch_rate() from public, anon, authenticated;
revoke all on function public.ccs_whoami() from public, anon;
revoke all on function public.ccs_news_list() from public, anon;
revoke all on function public.ccs_news_publish(text, text) from public, anon, authenticated;
revoke all on function public.ccs_news_remove(bigint) from public, anon, authenticated;
revoke all on function public.ccs_forum_board() from public, anon;
revoke all on function public.ccs_forum_threads(text) from public, anon;
revoke all on function public.ccs_forum_thread(bigint) from public, anon;
revoke all on function public.ccs_forum_new_thread(text, text, text) from public, anon, authenticated;
revoke all on function public.ccs_forum_reply(bigint, text) from public, anon, authenticated;
revoke all on function public.ccs_forum_pin(bigint, boolean) from public, anon, authenticated;
revoke all on function public.ccs_forum_lock(bigint, boolean) from public, anon, authenticated;
revoke all on function public.ccs_forum_delete_thread(bigint) from public, anon, authenticated;
revoke all on function public.ccs_forum_delete_reply(bigint) from public, anon, authenticated;

grant execute on function public.ccs_whoami() to anon, authenticated;
grant execute on function public.ccs_news_list() to anon, authenticated;
grant execute on function public.ccs_news_publish(text, text) to authenticated;
grant execute on function public.ccs_news_remove(bigint) to authenticated;
grant execute on function public.ccs_forum_board() to anon, authenticated;
grant execute on function public.ccs_forum_threads(text) to anon, authenticated;
grant execute on function public.ccs_forum_thread(bigint) to anon, authenticated;
grant execute on function public.ccs_forum_new_thread(text, text, text) to authenticated;
grant execute on function public.ccs_forum_reply(bigint, text) to authenticated;
grant execute on function public.ccs_forum_pin(bigint, boolean) to authenticated;
grant execute on function public.ccs_forum_lock(bigint, boolean) to authenticated;
grant execute on function public.ccs_forum_delete_thread(bigint) to authenticated;
grant execute on function public.ccs_forum_delete_reply(bigint) to authenticated;
