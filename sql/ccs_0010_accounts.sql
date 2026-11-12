-- Crown & Conquest site accounts.
-- Review this file, then run it yourself. It is not applied from here.
-- Sign-up stores the username in auth user metadata. The existing
-- handle_new_user trigger copies it onto public.profiles, which already
-- has a unique index on lower(username). This function only answers
-- whether a name is free. It never returns an email address.

create or replace function public.ccs_username_available(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  clean text := trim(coalesce(p_name, ''));
begin
  if clean !~ '^[A-Za-z0-9_]{3,20}$' then
    return false;
  end if;
  return not exists (
    select 1
    from public.profiles pr
    where lower(pr.username) = lower(clean)
  );
end;
$fn$;

revoke all on function public.ccs_username_available(text) from public;
grant execute on function public.ccs_username_available(text) to anon, authenticated;
