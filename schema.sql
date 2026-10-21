-- Cane Truck Log: Supabase schema.
-- Run this whole file in Supabase: SQL Editor > New query > paste > Run.
-- It is safe to run again on a project that already has an older copy: it only adds and updates.
--
-- How access works: people create their own account on the site (Supabase Auth).
--   * Each grower has their own portal. Someone who starts a portal becomes its main administrator
--     and only ever sees their own portal's farms, people and tools. Portals cannot see each other.
--   * Each farm has an invite link. Someone who signs up through it asks to join that farm and waits until an administrator approves them.
--   * Someone who signs up with no link and no portal waits until they paste an invite code or start a portal.
--   * A farm manager can run their own farm: mills, tracks, fields, trucks, invites and their crew.
-- The tables are locked (row level security on, no policies), so the public key can only call the
-- functions at the bottom, and every function checks who is signed in first.

create table if not exists public.docs (
  path        text primary key,
  parent      text not null,
  id          text not null,
  data        jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);
create index if not exists docs_parent_idx on public.docs (parent);

create table if not exists public.profiles (
  user_id     uuid primary key,
  name        text not null default '',
  email       text not null default '',
  role        text not null default 'pending',
  farm        text,
  created_at  timestamptz not null default now()
);
-- when the person's page last checked in (used for "logged on now")
alter table public.profiles add column if not exists last_seen timestamptz;
-- a mill field manager sees only loads for this mill (read only), across every farm that delivers to it
alter table public.profiles add column if not exists mill text;
-- older copies only allowed pending / crew / admin
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('pending', 'crew', 'manager', 'admin', 'mill'));

-- one row per grower's portal
create table if not exists public.orgs (
  id          text primary key,
  name        text not null default '',
  created_at  timestamptz not null default now()
);
alter table public.profiles add column if not exists org text;

create table if not exists public.farm_invites (
  farm_id     text primary key,
  code        text not null unique,
  created_at  timestamptz not null default now()
);

-- Scale connection: one secret key per farm (only a hash is kept), and weights that arrived before the load was tapped.
create table if not exists public.farm_keys (
  farm_id    text primary key,
  key_hash   text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.scale_pending (
  id       uuid primary key default gen_random_uuid(),
  farm_id  text not null,
  truck_no text not null,
  tons     numeric not null,
  trs      numeric,
  ticket   text,
  at       timestamptz not null default now()
);
create index if not exists scale_pending_farm on public.scale_pending (farm_id, truck_no);
-- One key per mill for every grower on the site, in every portal. Only the site owner (the first administrator) makes them.
drop table if exists public.mill_keys;
create table if not exists public.mill_keys_all (
  mill_lc    text primary key,
  mill       text not null,
  key_hash   text not null,
  created_at timestamptz not null default now()
);
alter table public.scale_pending alter column farm_id drop not null;
alter table public.scale_pending add column if not exists org text;
alter table public.scale_pending add column if not exists mill text;
alter table public.scale_pending add column if not exists hauler text;
alter table public.scale_pending add column if not exists brix numeric;

alter table public.orgs         enable row level security;
alter table public.docs         enable row level security;
alter table public.profiles     enable row level security;
alter table public.farm_invites enable row level security;
alter table public.farm_keys    enable row level security;
alter table public.scale_pending enable row level security;
alter table public.mill_keys_all enable row level security;
revoke all on public.orgs, public.docs, public.profiles, public.farm_invites, public.farm_keys, public.scale_pending, public.mill_keys_all from anon, authenticated;

-- An older copy of this site had one shared portal. The first time this file runs on it, everything that
-- exists now becomes the first portal ('main'), so nothing changes for the people already using it.
do $mig$
begin
  if not exists (select 1 from public.orgs) and exists (select 1 from public.profiles) then
    insert into public.orgs (id, name) values ('main', 'My portal');
    update public.profiles set org = 'main' where org is null;
    update public.docs set data = data || jsonb_build_object('org', 'main') where parent = 'farms' and data->>'org' is null;
    update public.docs set path = 'tools/main.' || id, id = 'main.' || id where parent = 'tools' and id not like '%.%';
  end if;
end $mig$;

-- ---------- helpers (not callable from the browser) ----------

create or replace function public._new_code() returns text
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  loop
    c := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    exit when not exists (select 1 from farm_invites where code = c);
  end loop;
  return c;
end $$;

-- Who is calling? Raises 'unregistered' or 'pending' unless they have been placed in a portal.
drop function if exists public._who();
create or replace function public._who(out o_role text, out o_farm text, out o_org text)
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if auth.uid() is null then raise exception 'denied' using errcode = '42501'; end if;
  select * into p from profiles where user_id = auth.uid();
  if not found then raise exception 'unregistered' using errcode = '42501'; end if;
  if p.role = 'pending' or p.org is null or (p.role in ('crew', 'manager') and p.farm is null) or (p.role = 'mill' and coalesce(p.mill, '') = '') then
    raise exception 'pending' using errcode = '42501';
  end if;
  o_role := p.role; o_farm := p.farm; o_org := p.org;
end $$;

-- Does this farm belong to this portal?
create or replace function public._farm_in(p_org text, p_farm text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from docs where path = 'farms/' || coalesce(p_farm, '') and data->>'org' = p_org and p_org is not null)
$$;

-- Stops a signed-in person from touching another portal's farms or trucks.
create or replace function public._guard(p_org text, p_path text, p_new jsonb, p_full boolean) returns void
language plpgsql security definer set search_path = public as $$
declare s text[] := string_to_array(p_path, '/'); n int := array_length(string_to_array(p_path, '/'), 1); f text;
begin
  if s[1] = 'farms' then
    if n = 2 then
      if exists (select 1 from docs where path = p_path) and not _farm_in(p_org, s[2]) then raise exception 'denied' using errcode = '42501'; end if;
    elsif not _farm_in(p_org, s[2]) then
      raise exception 'denied' using errcode = '42501';
    end if;
  elsif s[1] = 'trucks' then
    select data->>'farm' into f from docs where path = p_path;
    if found and not _farm_in(p_org, f) then raise exception 'denied' using errcode = '42501'; end if;
    if p_full and not _farm_in(p_org, p_new->>'farm') then raise exception 'denied' using errcode = '42501'; end if;
    if not p_full and p_new ? 'farm' and not _farm_in(p_org, p_new->>'farm') then raise exception 'denied' using errcode = '42501'; end if;
  end if;
end $$;

-- The main administrator of a portal is its account holder: the earliest administrator in that portal.
create or replace function public._is_owner(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select a.user_id = p_user from profiles a
                    where a.role = 'admin' and a.org = (select org from profiles where user_id = p_user)
                    order by a.created_at, a.user_id limit 1), false)
$$;

-- The site owner: the very first administrator on the site. Only this person makes mill keys.
create or replace function public._is_platform_owner(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select a.user_id = p_user from profiles a where a.role = 'admin' order by a.created_at, a.user_id limit 1), false)
$$;

create or replace function public._can_write(p_role text, p_farm text, p_path text) returns boolean
language plpgsql immutable as $$
declare
  s text[] := string_to_array(p_path, '/');
  n int := array_length(string_to_array(p_path, '/'), 1);
  is_load boolean;
  is_active boolean;
begin
  is_load   := (s[1] = 'farms' and n = 6 and s[3] = 'days' and s[5] = 'loads');
  is_active := (s[1] = 'farms' and n = 4 and s[3] = 'active');      -- the shared active track and field
  if p_role = 'mill' then return false; end if;
  if p_role = 'admin' then
    return is_load or is_active or (s[1] in ('farms', 'trucks', 'tools') and n = 2);
  end if;
  -- a manager also keeps the Burn log and Sugar per acre of their own farm (one document per tool per farm),
  -- and shares the portal's Tank mix recipes
  if p_role = 'manager' and s[1] = 'tools' and n = 2 and p_farm is not null
     and s[2] in ('burnlog-' || p_farm, 'sugarlog-' || p_farm, 'yield-' || p_farm, 'tankmix') then return true; end if;
  -- crew and managers: loads and the active track/field on their own farm, trucks, and their own farm's
  -- document (trucks and the farm document are narrowed further in db_set / db_update / db_delete)
  return ((is_load or is_active) and s[2] = p_farm) or (s[1] = 'trucks' and n = 2) or (s[1] = 'farms' and n = 2 and s[2] = p_farm);
end $$;

-- ---------- functions the website calls ----------

-- Safe to call at any time: reports where the signed-in person stands.
create or replace function public.whoami() returns jsonb
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if auth.uid() is null then raise exception 'denied' using errcode = '42501'; end if;
  select * into p from profiles where user_id = auth.uid();
  if not found then return jsonb_build_object('status', 'unregistered'); end if;
  if p.last_seen is null or p.last_seen < now() - interval '30 seconds' then
    update profiles set last_seen = now() where user_id = p.user_id;
  end if;
  return jsonb_build_object(
    'status', case when p.role = 'pending' or p.org is null or (p.role in ('crew', 'manager') and p.farm is null) or (p.role = 'mill' and coalesce(p.mill, '') = '') then 'pending' else 'ok' end,
    'role', p.role, 'farm', p.farm, 'mill', p.mill, 'name', p.name,
    'farm_name', (select d.data->>'name' from docs d where d.path = 'farms/' || p.farm),
    'portal', (select name from orgs where id = p.org),
    'owner', (p.role = 'admin' and _is_owner(p.user_id)),
    'platform', (p.role = 'admin' and _is_platform_owner(p.user_id)));
end $$;

drop function if exists public.register(text);
drop function if exists public.register(text, text);

-- Creates the caller's profile.
--   * A valid invite code puts the person on that farm (in that farm's portal) as crew.
--   * A portal name starts a brand new portal with the person as its main administrator.
--   * Neither: the person waits until they paste an invite code or start a portal.
create or replace function public.register(p_name text, p_join text default null, p_portal text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare em text; inv_farm text; inv_org text; ok boolean := null; oid text; pn text := left(trim(coalesce(p_portal, '')), 60);
begin
  if auth.uid() is null then raise exception 'denied' using errcode = '42501'; end if;
  select email into em from auth.users where id = auth.uid();
  if coalesce(trim(p_join), '') <> '' then
    select i.farm_id, d.data->>'org' into inv_farm, inv_org
      from farm_invites i join docs d on d.path = 'farms/' || i.farm_id where i.code = upper(trim(p_join));
    ok := found and inv_org is not null;
    if not ok then perform pg_sleep(0.6); end if;
  end if;
  if exists (select 1 from profiles where user_id = auth.uid()) then
    return public.whoami() || jsonb_build_object('invite_ok', ok);
  end if;
  if ok then
    -- an invite link only asks to join: the person waits as 'pending' (with the farm they asked for) until an administrator approves
    insert into profiles (user_id, name, email, role, farm, org)
      values (auth.uid(), left(trim(coalesce(p_name, '')), 40), coalesce(em, ''), 'pending', inv_farm, inv_org) on conflict (user_id) do nothing;
  elsif pn <> '' then
    oid := 'o' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
    insert into orgs (id, name) values (oid, pn);
    insert into profiles (user_id, name, email, role, farm, org)
      values (auth.uid(), left(trim(coalesce(p_name, '')), 40), coalesce(em, ''), 'admin', null, oid) on conflict (user_id) do nothing;
  else
    insert into profiles (user_id, name, email, role, farm, org)
      values (auth.uid(), left(trim(coalesce(p_name, '')), 40), coalesce(em, ''), 'pending', null, null) on conflict (user_id) do nothing;
  end if;
  return public.whoami() || jsonb_build_object('invite_ok', ok);
end $$;

-- A person who is waiting can use an invite code to join a farm (and that farm's portal).
create or replace function public.join_farm(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv_farm text; inv_org text; p record;
begin
  if auth.uid() is null then raise exception 'denied' using errcode = '42501'; end if;
  select * into p from profiles where user_id = auth.uid();
  if not found then raise exception 'unregistered' using errcode = '42501'; end if;
  select i.farm_id, d.data->>'org' into inv_farm, inv_org
    from farm_invites i join docs d on d.path = 'farms/' || i.farm_id where i.code = upper(trim(coalesce(p_code, '')));
  if not found or inv_org is null then perform pg_sleep(0.6); raise exception 'bad invite' using errcode = '42501'; end if;
  if p.role = 'pending' then
    update profiles set role = 'pending', farm = inv_farm, org = inv_org where user_id = auth.uid();    -- asks to join; an administrator approves
  end if;
  return public.whoami();
end $$;

-- A person who is waiting can start their own portal and become its main administrator.
create or replace function public.portal_create(p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p record; oid text; pn text := left(trim(coalesce(p_name, '')), 60);
begin
  if auth.uid() is null then raise exception 'denied' using errcode = '42501'; end if;
  select * into p from profiles where user_id = auth.uid();
  if not found then raise exception 'unregistered' using errcode = '42501'; end if;
  if pn = '' then raise exception 'name needed'; end if;
  if p.role = 'pending' then
    oid := 'o' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
    insert into orgs (id, name) values (oid, pn);
    update profiles set role = 'admin', farm = null, org = oid where user_id = auth.uid();
  end if;
  return public.whoami();
end $$;

-- The main administrator can rename their portal.
create or replace function public.portal_rename(p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare w record; pn text := left(trim(coalesce(p_name, '')), 60);
begin
  select * into w from _who();
  if w.o_role <> 'admin' or not _is_owner(auth.uid()) or pn = '' then raise exception 'denied' using errcode = '42501'; end if;
  update orgs set name = pn where id = w.o_org;
end $$;

create or replace function public.db_list(p_parent text, p_limit int default 1000) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; s text[] := string_to_array(p_parent, '/'); res jsonb; m text;
begin
  select * into w from _who();
  if p_limit is null or p_limit > 2000 then p_limit := 2000; end if;
  if w.o_role = 'mill' then
    -- read only: the farms (in their portal) that use their mill, and only the loads for their mill; nothing else
    select mill into m from profiles where user_id = auth.uid();
    if p_parent = 'farms' then
      select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'data', d.data) order by d.path), '[]'::jsonb) into res
        from (select * from docs where parent = 'farms' and data->>'org' = w.o_org and data->'mills' ? m limit p_limit) d;
    elsif array_length(s, 1) = 5 and s[1] = 'farms' and s[3] = 'days' and s[5] = 'loads'
          and exists (select 1 from docs where path = 'farms/' || s[2] and data->>'org' = w.o_org and data->'mills' ? m) then
      select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'data', d.data) order by d.path), '[]'::jsonb) into res
        from (select * from docs where parent = p_parent and data->>'mill' = m limit p_limit) d;
    else
      res := '[]'::jsonb;
    end if;
    return res;
  end if;
  if p_parent = 'farms' then
    select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'data', d.data) order by d.path), '[]'::jsonb) into res
      from (select * from docs where parent = 'farms' and data->>'org' = w.o_org and (w.o_role = 'admin' or id = w.o_farm) limit p_limit) d;
  elsif p_parent = 'tools' and w.o_role = 'admin' then          -- the Tools page: administrators only, and only their own portal's
    select coalesce(jsonb_agg(jsonb_build_object('id', substr(d.id, length(w.o_org) + 2), 'data', d.data) order by d.path), '[]'::jsonb) into res
      from (select * from docs where parent = 'tools' and id like w.o_org || '.%' limit p_limit) d;
  elsif p_parent = 'tools' and w.o_role = 'manager' and w.o_farm is not null then   -- a manager sees their own farm's Burn log and Sugar per acre, and the shared Tank mix
    select coalesce(jsonb_agg(jsonb_build_object('id', substr(d.id, length(w.o_org) + 2), 'data', d.data) order by d.path), '[]'::jsonb) into res
      from (select * from docs where parent = 'tools' and id in (w.o_org || '.burnlog-' || w.o_farm, w.o_org || '.sugarlog-' || w.o_farm, w.o_org || '.yield-' || w.o_farm, w.o_org || '.tankmix') limit p_limit) d;
  elsif p_parent = 'trucks' then
    select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'data', d.data) order by d.path), '[]'::jsonb) into res
      from (select * from docs where parent = 'trucks' and _farm_in(w.o_org, data->>'farm') and (w.o_role = 'admin' or data->>'farm' = w.o_farm) limit p_limit) d;
  elsif ((array_length(s, 1) = 5 and s[1] = 'farms' and s[3] = 'days' and s[5] = 'loads')
         or (array_length(s, 1) = 3 and s[1] = 'farms' and s[3] in ('active', 'quota')))
        and (w.o_role = 'admin' or s[2] = w.o_farm) and _farm_in(w.o_org, s[2]) then
    select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'data', d.data) order by d.path), '[]'::jsonb) into res
      from (select * from docs where parent = p_parent limit p_limit) d;
  else
    raise exception 'denied' using errcode = '42501';
  end if;
  return res;
end $$;

create or replace function public.db_set(p_path text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w record; s text[] := string_to_array(p_path, '/'); n int := array_length(string_to_array(p_path, '/'), 1);
  existed boolean; pd record;
begin
  select * into w from _who();
  if not _can_write(w.o_role, w.o_farm, p_path) then raise exception 'denied' using errcode = '42501'; end if;
  perform _guard(w.o_org, p_path, p_data, true);
  if s[1] = 'tools' then s[2] := w.o_org || '.' || s[2]; p_path := array_to_string(s, '/'); end if;     -- each portal has its own tools data
  if s[1] = 'farms' and n = 2 then p_data := coalesce(p_data, '{}'::jsonb) || jsonb_build_object('org', w.o_org); end if;
  if w.o_role <> 'admin' and s[1] = 'farms' and n = 2 then       -- only an administrator creates or replaces a farm
    raise exception 'denied' using errcode = '42501';
  end if;
  if w.o_role <> 'admin' and s[1] = 'trucks' then                -- crew and managers: trucks on their own farm only
    if p_data->>'farm' is distinct from w.o_farm then raise exception 'denied' using errcode = '42501'; end if;
    if exists (select 1 from docs where path = p_path and data->>'farm' is distinct from w.o_farm) then
      raise exception 'denied' using errcode = '42501';
    end if;
  end if;
  existed := exists (select 1 from docs where path = p_path);
  insert into docs (path, parent, id, data)
    values (p_path, array_to_string(s[1:n-1], '/'), s[n], coalesce(p_data, '{}'::jsonb))
    on conflict (path) do update set data = excluded.data, updated_at = now();
  -- a weight that came in before the truck was tapped goes onto the new load
  if not existed and n = 6 and s[1] = 'farms' and s[3] = 'days' and s[5] = 'loads' and (p_data->>'tons') is null then
    select * into pd from scale_pending
      where (farm_id = s[2] or (farm_id is null and (org is null or org = (select data->>'org' from docs where path = 'farms/' || s[2]))
                                and lower(mill) = lower(coalesce(p_data->>'mill', ''))))
        and (hauler is null or hauler = (select data->>'haulerCode' from docs where path = 'farms/' || s[2])
             or hauler in (select e.value from jsonb_each_text(coalesce((select data->'haulerMillCodes' from docs where path = 'farms/' || s[2]), '{}'::jsonb)) e))
        and upper(truck_no) = upper(coalesce(p_data->>'no', '')) and at > now() - interval '12 hours'
      order by at limit 1;
    if found then
      update docs set data = data || jsonb_strip_nulls(jsonb_build_object(
          'tons', pd.tons, 'trs', pd.trs, 'brix', pd.brix, 'ticket', pd.ticket, 'weighedAt', (extract(epoch from pd.at) * 1000)::bigint))
        where path = p_path;
      delete from scale_pending where id = pd.id;
    end if;
  end if;
  if s[1] = 'farms' and n = 2 then
    insert into farm_invites (farm_id, code) values (s[2], _new_code()) on conflict (farm_id) do nothing;
  end if;
end $$;

create or replace function public.db_update(p_path text, p_patch jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w record; s text[] := string_to_array(p_path, '/'); n int := array_length(string_to_array(p_path, '/'), 1);
begin
  select * into w from _who();
  if not _can_write(w.o_role, w.o_farm, p_path) then raise exception 'denied' using errcode = '42501'; end if;
  perform _guard(w.o_org, p_path, p_patch, false);
  if s[1] = 'tools' then s[2] := w.o_org || '.' || s[2]; p_path := array_to_string(s, '/'); end if;
  p_patch := coalesce(p_patch, '{}'::jsonb) - 'org';
  if w.o_role <> 'admin' and s[1] = 'farms' and n = 2 then
    -- crew may change the track, field and variety lists; managers also the mills, their colors, their start dates and the harvest start date
    if exists (select 1 from jsonb_object_keys(coalesce(p_patch, '{}'::jsonb)) k
               where k not in ('tracks', 'fields', 'varieties') and not (w.o_role = 'manager' and k in ('mills', 'millColors', 'millStart', 'harvestStart'))) then
      raise exception 'denied' using errcode = '42501';
    end if;
  end if;
  if w.o_role <> 'admin' and s[1] = 'trucks' then
    if not exists (select 1 from docs where path = p_path and data->>'farm' = w.o_farm)
       or (p_patch->'farm' is not null and p_patch->>'farm' is distinct from w.o_farm) then
      raise exception 'denied' using errcode = '42501';
    end if;
  end if;
  update docs set data = data || coalesce(p_patch, '{}'::jsonb), updated_at = now() where path = p_path;
  if not found then raise exception 'missing'; end if;
end $$;

create or replace function public.db_delete(p_path text) returns void
language plpgsql security definer set search_path = public as $$
declare w record; s text[] := string_to_array(p_path, '/'); n int := array_length(string_to_array(p_path, '/'), 1);
begin
  select * into w from _who();
  if not _can_write(w.o_role, w.o_farm, p_path) then raise exception 'denied' using errcode = '42501'; end if;
  perform _guard(w.o_org, p_path, null, false);
  if s[1] = 'tools' then s[2] := w.o_org || '.' || s[2]; p_path := array_to_string(s, '/'); end if;
  if w.o_role <> 'admin' and s[1] = 'farms' and n = 2 then       -- only an administrator removes a farm
    raise exception 'denied' using errcode = '42501';
  end if;
  if w.o_role = 'crew' and s[1] = 'trucks' then                  -- crew cannot remove trucks; managers can
    raise exception 'denied' using errcode = '42501';
  end if;
  if w.o_role = 'manager' and s[1] = 'trucks'
     and not exists (select 1 from docs where path = p_path and data->>'farm' = w.o_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  delete from docs where path = p_path or path like p_path || '/%';
  if s[1] = 'farms' and n = 2 then
    update profiles set farm = null where farm = s[2];            -- people on a removed farm go back to waiting
    delete from farm_invites where farm_id = s[2];
    delete from farm_keys where farm_id = s[2];
    delete from scale_pending where farm_id = s[2];
  end if;
end $$;

-- ---------- invites (administrators, and managers for their own farm) ----------

create or replace function public.invite_get(p_farm text) returns text
language plpgsql security definer set search_path = public as $$
declare w record; c text;
begin
  select * into w from _who();
  if not (w.o_role = 'admin' or (w.o_role = 'manager' and w.o_farm = p_farm)) or not _farm_in(w.o_org, p_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  if not exists (select 1 from docs where path = 'farms/' || p_farm) then raise exception 'missing'; end if;
  insert into farm_invites (farm_id, code) values (p_farm, _new_code()) on conflict (farm_id) do nothing;
  select code into c from farm_invites where farm_id = p_farm;
  return c;
end $$;

create or replace function public.invite_new(p_farm text) returns text
language plpgsql security definer set search_path = public as $$
declare w record; c text := _new_code();
begin
  select * into w from _who();
  if not (w.o_role = 'admin' or (w.o_role = 'manager' and w.o_farm = p_farm)) or not _farm_in(w.o_org, p_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  if not exists (select 1 from docs where path = 'farms/' || p_farm) then raise exception 'missing'; end if;
  insert into farm_invites (farm_id, code) values (p_farm, c)
    on conflict (farm_id) do update set code = excluded.code, created_at = now();
  return c;
end $$;

-- ---------- people ----------

-- Main administrator (account holder): everyone, with who is logged on right now.
-- Other administrators: the crew on every farm. A manager sees the people on their own farm.
create or replace function public.people_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; owner boolean;
begin
  select * into w from _who();
  if w.o_role not in ('admin', 'manager') then raise exception 'denied' using errcode = '42501'; end if;
  owner := w.o_role = 'admin' and _is_owner(auth.uid());
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'user_id', user_id, 'name', name, 'email', email, 'role', role, 'farm', farm, 'mill', mill,
            'online', coalesce(last_seen > now() - interval '2 minutes', false),
            'owner', (role = 'admin' and _is_owner(user_id)))
            order by (role = 'pending') desc, name), '[]'::jsonb)
          from profiles
          where case
                  when owner then org = w.o_org
                  when w.o_role = 'admin' then org = w.o_org
                  else org = w.o_org and farm = w.o_farm and role <> 'pending'
                end);
end $$;

-- Administrators can set anyone to anything. A manager can set people already on their farm to crew or manager.
drop function if exists public.person_set(uuid, text, text);
create or replace function public.person_set(p_user uuid, p_role text, p_farm text, p_mill text default null) returns void
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if p_role not in ('pending', 'crew', 'manager', 'admin', 'mill') then raise exception 'bad role'; end if;
  if w.o_role = 'admin' then
    if not exists (select 1 from profiles where user_id = p_user and org = w.o_org) then raise exception 'denied' using errcode = '42501'; end if;
    if nullif(p_farm, '') is not null and not _farm_in(w.o_org, p_farm) then raise exception 'denied' using errcode = '42501'; end if;
    if p_user = auth.uid() and p_role <> 'admin' then raise exception 'you cannot remove your own admin access'; end if;
    if _is_owner(p_user) and p_user <> auth.uid() then raise exception 'denied' using errcode = '42501'; end if;
    update profiles set role = p_role, farm = case when p_role in ('crew', 'manager') then nullif(p_farm, '') else null end,
        mill = case when p_role = 'mill' then nullif(trim(p_mill), '') else null end
      where user_id = p_user;
  elsif w.o_role = 'manager' then
    if p_role not in ('crew', 'manager') or p_user = auth.uid()
       or not exists (select 1 from profiles where user_id = p_user and farm = w.o_farm and role in ('crew', 'manager')) then
      raise exception 'denied' using errcode = '42501';
    end if;
    update profiles set role = p_role where user_id = p_user;
  else
    raise exception 'denied' using errcode = '42501';
  end if;
end $$;

create or replace function public.person_remove(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if p_user = auth.uid() then raise exception 'you cannot remove yourself'; end if;
  if w.o_role = 'admin' then
    if _is_owner(p_user) or not exists (select 1 from profiles where user_id = p_user and org = w.o_org) then raise exception 'denied' using errcode = '42501'; end if;
    delete from profiles where user_id = p_user;
  elsif w.o_role = 'manager' then
    delete from profiles where user_id = p_user and farm = w.o_farm and role in ('crew', 'manager');
  else
    raise exception 'denied' using errcode = '42501';
  end if;
end $$;


-- ---------- scale connection ----------
-- The scale app calls scale_weight / scale_quota with the farm's secret key (no sign-in). A key only works for its own farm.

create or replace function public._key_farm(p_key text) returns text
language plpgsql security definer set search_path = public as $$
declare f text;
begin
  select farm_id into f from farm_keys where key_hash = encode(sha256(convert_to(coalesce(p_key, ''), 'utf8')), 'hex');
  if f is null then perform pg_sleep(0.6); raise exception 'bad key' using errcode = '42501'; end if;
  return f;
end $$;

-- Is there a key for this farm? (administrator, or the farm's manager)
create or replace function public.scale_key_get(p_farm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; k record;
begin
  select * into w from _who();
  if not (w.o_role = 'admin' or (w.o_role = 'manager' and w.o_farm = p_farm)) or not _farm_in(w.o_org, p_farm) then raise exception 'denied' using errcode = '42501'; end if;
  select * into k from farm_keys where farm_id = p_farm;
  if not found then return jsonb_build_object('exists', false); end if;
  return jsonb_build_object('exists', true, 'created_at', k.created_at);
end $$;

-- Makes a new key (replacing any old one). The key is shown once and never stored in readable form.
create or replace function public.scale_key_new(p_farm text) returns text
language plpgsql security definer set search_path = public as $$
declare w record; k text := 'ctl_' || replace(gen_random_uuid()::text, '-', '');
begin
  select * into w from _who();
  if not (w.o_role = 'admin' or (w.o_role = 'manager' and w.o_farm = p_farm)) or not _farm_in(w.o_org, p_farm) then raise exception 'denied' using errcode = '42501'; end if;
  if not exists (select 1 from docs where path = 'farms/' || p_farm) then raise exception 'missing'; end if;
  insert into farm_keys (farm_id, key_hash) values (p_farm, encode(sha256(convert_to(k, 'utf8')), 'hex'))
    on conflict (farm_id) do update set key_hash = excluded.key_hash, created_at = now();
  return k;
end $$;

create or replace function public.scale_key_off(p_farm text) returns void
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if not (w.o_role = 'admin' or (w.o_role = 'manager' and w.o_farm = p_farm)) or not _farm_in(w.o_org, p_farm) then raise exception 'denied' using errcode = '42501'; end if;
  delete from farm_keys where farm_id = p_farm;
end $$;

-- Which farm or mill does this key belong to? A farm key (older) names one farm. A mill key names a mill across the whole portal.
create or replace function public._key_ctx(p_key text, out k_farm text, out k_org text, out k_mill text)
language plpgsql security definer set search_path = public as $$
declare h text := encode(sha256(convert_to(coalesce(p_key, ''), 'utf8')), 'hex'); mk record;
begin
  select farm_id into k_farm from farm_keys where key_hash = h;
  if k_farm is not null then
    select data->>'org' into k_org from docs where path = 'farms/' || k_farm;
    return;
  end if;
  select * into mk from mill_keys_all where key_hash = h;
  if found then k_org := null; k_mill := mk.mill_lc; return; end if;
  perform pg_sleep(0.6); raise exception 'bad key' using errcode = '42501';
end $$;

-- Mill keys: one per mill, for every grower on the site. Only the site owner makes, replaces or turns them off.
create or replace function public.mill_key_list() returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if w.o_role <> 'admin' or not _is_platform_owner(auth.uid()) then raise exception 'denied' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('mill', mill, 'created_at', created_at) order by mill), '[]'::jsonb) from mill_keys_all);
end $$;

-- Every mill name any grower on the site has set up (site owner only), so each can get its key.
create or replace function public.mill_names() returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if w.o_role <> 'admin' or not _is_platform_owner(auth.uid()) then raise exception 'denied' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(m order by m), '[]'::jsonb) from (
            select distinct on (lower(x)) x as m from docs, jsonb_array_elements_text(coalesce(data->'mills', '[]'::jsonb)) x
            where parent = 'farms' order by lower(x), x) q);
end $$;

create or replace function public.mill_key_new(p_mill text) returns text
language plpgsql security definer set search_path = public as $$
declare w record; m text := left(trim(coalesce(p_mill, '')), 60); k text := 'ctl_' || replace(gen_random_uuid()::text, '-', '');
begin
  select * into w from _who();
  if w.o_role <> 'admin' or not _is_platform_owner(auth.uid()) or m = '' then raise exception 'denied' using errcode = '42501'; end if;
  if not exists (select 1 from docs where parent = 'farms'
                 and exists (select 1 from jsonb_array_elements_text(coalesce(data->'mills', '[]'::jsonb)) x where lower(x) = lower(m))) then
    raise exception 'missing';
  end if;
  insert into mill_keys_all (mill_lc, mill, key_hash) values (lower(m), m, encode(sha256(convert_to(k, 'utf8')), 'hex'))
    on conflict (mill_lc) do update set key_hash = excluded.key_hash, mill = excluded.mill, created_at = now();
  return k;
end $$;

create or replace function public.mill_key_off(p_mill text) returns void
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if w.o_role <> 'admin' or not _is_platform_owner(auth.uid()) then raise exception 'denied' using errcode = '42501'; end if;
  delete from mill_keys_all where mill_lc = lower(trim(coalesce(p_mill, '')));
end $$;

-- A weight from the scale. Goes on that truck's oldest load (last 12 hours) that has no weight yet.
-- A mill key looks across every farm in the portal that hauls to that mill (p_farm narrows it if two farms use the same truck number).
-- If the truck has not been tapped yet, the weight waits and lands on the load when it is tapped.
drop function if exists public.scale_weight(text, text, numeric, numeric, text);
drop function if exists public.scale_weight(text, text, numeric, numeric, text, text);
create or replace function public.scale_weight(
  p_key text, p_truck text, p_tons numeric, p_trs numeric default null, p_ticket text default null, p_farm text default null, p_brix numeric default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare kc record; f text; tno text := trim(coalesce(p_truck, '')); tk text := nullif(left(trim(coalesce(p_ticket, '')), 40), '');
        l record; cutoff bigint; patch jsonb; pf text := nullif(trim(coalesce(p_farm, '')), ''); hc text;
begin
  select * into kc from _key_ctx(p_key);
  f := coalesce(kc.k_farm, pf);
  -- the mill's own truck ID, like 54-154: the part before the dash is the hauler number, the rest is the truck number
  if tno ~ '^[A-Za-z0-9]+-[A-Za-z0-9]+$' then hc := split_part(tno, '-', 1); tno := split_part(tno, '-', 2); end if;
  if tno = '' or p_tons is null or p_tons <= 0 or p_tons > 200 then raise exception 'bad weight' using errcode = '22023'; end if;
  if p_trs is not null and (p_trs < 0 or p_trs > 500) then raise exception 'bad trs' using errcode = '22023'; end if;
  if p_brix is not null and (p_brix < 0 or p_brix > 40) then raise exception 'bad brix' using errcode = '22023'; end if;
  if kc.k_farm is null and pf is not null and not exists (select 1 from docs where path = 'farms/' || pf) then raise exception 'bad farm' using errcode = '22023'; end if;
  if tk is not null and (
       exists (select 1 from docs d join docs fm on fm.path = 'farms/' || split_part(d.parent, '/', 2)
               where d.parent ~ '^farms/[^/]+/days/[^/]+/loads$' and (kc.k_org is null or fm.data->>'org' = kc.k_org) and d.data->>'ticket' = tk
                 and (f is null or split_part(d.parent, '/', 2) = f))
       or exists (select 1 from scale_pending where ticket = tk and (farm_id = f or (f is null and org is not distinct from kc.k_org)))) then
    return jsonb_build_object('status', 'duplicate');
  end if;
  cutoff := (extract(epoch from now()) * 1000)::bigint - 12 * 3600 * 1000;
  select d.* into l from docs d join docs fm on fm.path = 'farms/' || split_part(d.parent, '/', 2)
    where d.parent ~ '^farms/[^/]+/days/[^/]+/loads$' and (kc.k_org is null or fm.data->>'org' = kc.k_org)
      and (f is null or split_part(d.parent, '/', 2) = f)
      and (kc.k_mill is null or lower(coalesce(d.data->>'mill', '')) = kc.k_mill)
      and (hc is null or fm.data->>'haulerCode' = hc
           or exists (select 1 from jsonb_each_text(coalesce(fm.data->'haulerMillCodes', '{}'::jsonb)) e where lower(e.key) = lower(coalesce(d.data->>'mill', '')) and e.value = hc))
      and upper(d.data->>'no') = upper(tno) and d.data->>'tons' is null
      and (d.data->>'loadedAt') ~ '^[0-9]+$' and (d.data->>'loadedAt')::bigint > cutoff
    order by (d.data->>'loadedAt')::bigint limit 1;
  if found then
    patch := jsonb_strip_nulls(jsonb_build_object('tons', p_tons, 'trs', p_trs, 'brix', p_brix, 'ticket', tk,
                                                   'weighedAt', (extract(epoch from now()) * 1000)::bigint));
    update docs set data = data || patch, updated_at = now() where path = l.path;
    return jsonb_build_object('status', 'matched', 'load', l.id, 'farm', split_part(l.parent, '/', 2));
  end if;
  delete from scale_pending where at < now() - interval '3 days';
  insert into scale_pending (farm_id, org, mill, hauler, truck_no, tons, trs, brix, ticket) values (f, kc.k_org, kc.k_mill, hc, tno, p_tons, p_trs, p_brix, tk);
  return jsonb_build_object('status', 'waiting');
end $$;

-- The mill's brix and, later, the final TRS for a load, found by its ticket number. The final TRS replaces the first TRS on the load
-- (the first one is kept as trsEst), and the load is marked final. Everything in the site then uses the final number.
create or replace function public.scale_final(
  p_key text, p_ticket text, p_trs numeric default null, p_brix numeric default null, p_farm text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare kc record; tk text := nullif(left(trim(coalesce(p_ticket, '')), 40), ''); pf text := nullif(trim(coalesce(p_farm, '')), ''); l record; patch jsonb;
begin
  select * into kc from _key_ctx(p_key);
  if tk is null or (p_trs is null and p_brix is null) then raise exception 'bad request' using errcode = '22023'; end if;
  if p_trs is not null and (p_trs < 0 or p_trs > 500) then raise exception 'bad trs' using errcode = '22023'; end if;
  if p_brix is not null and (p_brix < 0 or p_brix > 40) then raise exception 'bad brix' using errcode = '22023'; end if;
  select d.* into l from docs d join docs fm on fm.path = 'farms/' || split_part(d.parent, '/', 2)
    where d.parent ~ '^farms/[^/]+/days/[^/]+/loads$' and d.data->>'ticket' = tk
      and (kc.k_org is null or fm.data->>'org' = kc.k_org)
      and (kc.k_farm is null or split_part(d.parent, '/', 2) = kc.k_farm)
      and (pf is null or split_part(d.parent, '/', 2) = pf)
      and (kc.k_mill is null or lower(coalesce(d.data->>'mill', '')) = kc.k_mill)
    limit 1;
  if not found then return jsonb_build_object('status', 'notfound'); end if;
  patch := jsonb_strip_nulls(jsonb_build_object('brix', p_brix));
  if p_trs is not null then
    patch := patch || jsonb_build_object('trs', p_trs, 'trsFinal', true, 'finalAt', (extract(epoch from now()) * 1000)::bigint);
    if coalesce((l.data->>'trsFinal')::boolean, false) = false and l.data->>'trs' is not null then
      patch := patch || jsonb_build_object('trsEst', (l.data->>'trs')::numeric);
    end if;
  end if;
  update docs set data = data || patch, updated_at = now() where path = l.path;
  return jsonb_build_object('status', 'matched', 'load', l.id, 'farm', split_part(l.parent, '/', 2));
end $$;

-- The quota for a day: tons and/or loads, for the whole farm or for one mill. Sending neither clears it.
-- Day defaults to today (Louisiana time). The mill name must match the mill name in the truck log.
-- A mill key must say which farm (p_farm); the mill is the key's own mill.
drop function if exists public.scale_quota(text, numeric, text, date, int);
create or replace function public.scale_quota(
  p_key text, p_tons numeric default null, p_mill text default null, p_day date default null, p_loads int default null, p_farm text default null)
  returns jsonb
language plpgsql security definer set search_path = public as $$
declare kc record; f text; d text; cur jsonb; k text;
begin
  select * into kc from _key_ctx(p_key);
  if kc.k_farm is not null then f := kc.k_farm;
  else
    f := nullif(trim(coalesce(p_farm, '')), '');
    if f is null or not exists (select 1 from docs where path = 'farms/' || f) then raise exception 'farm needed' using errcode = '22023'; end if;
  end if;
  if (p_tons is not null and (p_tons < 0 or p_tons > 100000)) or (p_loads is not null and (p_loads < 0 or p_loads > 10000)) then
    raise exception 'bad quota' using errcode = '22023';
  end if;
  k := coalesce(nullif(left(trim(coalesce(
         case when kc.k_mill is not null then (select x from jsonb_array_elements_text((select data->'mills' from docs where path = 'farms/' || f)) x where lower(x) = kc.k_mill limit 1) else p_mill end, '')), 40), ''), '_farm');
  d := coalesce(p_day, (now() at time zone 'America/Chicago')::date)::text;
  select data into cur from docs where path = 'farms/' || f || '/quota/now';
  if cur is null or cur->>'day' is distinct from d then cur := jsonb_build_object('day', d, 'items', '{}'::jsonb); end if;
  -- a null does not erase an earlier value; send 0 for both to clear
  if p_tons is null and p_loads is null then
    cur := jsonb_set(cur, '{items}', coalesce(cur->'items', '{}'::jsonb) - k);
  else
    cur := jsonb_set(cur, '{items}', coalesce(cur->'items', '{}'::jsonb) || jsonb_build_object(k,
             coalesce(cur->'items'->k, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('tons', p_tons, 'loads', p_loads))));
  end if;
  cur := cur || jsonb_build_object('at', (extract(epoch from now()) * 1000)::bigint);
  insert into docs (path, parent, id, data) values ('farms/' || f || '/quota/now', 'farms/' || f || '/quota', 'now', cur)
    on conflict (path) do update set data = excluded.data, updated_at = now();
  return jsonb_build_object('status', 'ok', 'day', d);
end $$;

-- Weights that are waiting for their truck to be tapped (including mill-key weights not yet tied to a farm).
create or replace function public.scale_pending_list(p_farm text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; f text;
begin
  select * into w from _who();
  f := case when w.o_role = 'admin' then p_farm else w.o_farm end;
  if not _farm_in(w.o_org, f) then raise exception 'denied' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'truck', truck_no, 'tons', tons, 'trs', trs, 'ticket', ticket,
                  'at', (extract(epoch from at) * 1000)::bigint) order by at), '[]'::jsonb)
          from scale_pending where at > now() - interval '3 days'
            and (farm_id = f or (farm_id is null and (org is null or org = w.o_org) and lower(coalesce(mill, '')) in
                 (select lower(x) from jsonb_array_elements_text((select coalesce(data->'mills', '[]'::jsonb) from docs where path = 'farms/' || f)) x))));
end $$;

create or replace function public.scale_pending_drop(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  delete from scale_pending where id = p_id and (
    (farm_id is not null and _farm_in(w.o_org, farm_id) and (w.o_role = 'admin' or farm_id = w.o_farm))
    or (farm_id is null and w.o_role = 'admin' and (org is null or org = w.o_org)));
end $$;

-- ---------- lock down who can call what ----------

revoke execute on function public._new_code(), public._who(), public._is_owner(uuid), public._can_write(text, text, text), public._key_farm(text), public._key_ctx(text), public._is_platform_owner(uuid),
  public._farm_in(text, text), public._guard(text, text, jsonb, boolean)
  from public, anon, authenticated;

revoke execute on function
  public.whoami(), public.register(text, text, text), public.join_farm(text), public.portal_create(text), public.portal_rename(text),
  public.db_list(text, int), public.db_set(text, jsonb), public.db_update(text, jsonb), public.db_delete(text),
  public.invite_get(text), public.invite_new(text),
  public.people_list(), public.person_set(uuid, text, text, text), public.person_remove(uuid),
  public.scale_key_get(text), public.scale_key_new(text), public.scale_key_off(text),
  public.scale_weight(text, text, numeric, numeric, text, text, numeric), public.scale_final(text, text, numeric, numeric, text), public.scale_quota(text, numeric, text, date, int, text),
  public.mill_key_list(), public.mill_names(), public.mill_key_new(text), public.mill_key_off(text),
  public.scale_pending_list(text), public.scale_pending_drop(uuid)
  from public, anon;

-- Only signed-in people can call these (anon, the signed-out key, cannot).
grant execute on function
  public.whoami(), public.register(text, text, text), public.join_farm(text), public.portal_create(text), public.portal_rename(text),
  public.db_list(text, int), public.db_set(text, jsonb), public.db_update(text, jsonb), public.db_delete(text),
  public.invite_get(text), public.invite_new(text),
  public.people_list(), public.person_set(uuid, text, text, text), public.person_remove(uuid),
  public.scale_key_get(text), public.scale_key_new(text), public.scale_key_off(text),
  public.mill_key_list(), public.mill_names(), public.mill_key_new(text), public.mill_key_off(text),
  public.scale_pending_list(text), public.scale_pending_drop(uuid)
  to authenticated;

-- The scale app has no sign-in: it uses the farm's secret key, checked inside these two functions.
grant execute on function
  public.scale_weight(text, text, numeric, numeric, text, text, numeric), public.scale_final(text, text, numeric, numeric, text), public.scale_quota(text, numeric, text, date, int, text)
  to anon, authenticated;
