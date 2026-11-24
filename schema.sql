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

-- ===== Backup before every run (2026-11-24) =====
-- Each time this file is run, it first copies what is there now (every table: farms, loads, trucks, tools,
-- people and portals, and the sign-in list of emails, never passwords) into backup_rows, as one backup_runs row.
-- The last 5 runs are kept; running the file again within 10 minutes takes no second copy. To see them:
--   select id, at, note, (select count(*) from backup_rows b where b.run_id = r.id) as rows from backup_runs r order by at desc;
-- Saved mill report PDFs are left out (they stay in their own table and are never changed by an update).
create table if not exists public.backup_runs (
  id   bigserial primary key,
  at   timestamptz not null default now(),
  note text
);
create table if not exists public.backup_rows (
  run_id bigint not null references public.backup_runs (id) on delete cascade,
  tbl    text not null,
  row    jsonb not null
);
create index if not exists backup_rows_run_idx on public.backup_rows (run_id, tbl);
alter table public.backup_runs enable row level security;
alter table public.backup_rows enable row level security;
revoke all on public.backup_runs, public.backup_rows from anon, authenticated;
do $$
declare r bigint; t text;
begin
  if to_regclass('public.docs') is null then return; end if;          -- a new project: nothing to keep yet
  if exists (select 1 from backup_runs where at > now() - interval '10 minutes') then return; end if;
  insert into backup_runs (note) values ('before running schema.sql') returning id into r;
  for t in select table_name from information_schema.tables
            where table_schema = 'public' and table_type = 'BASE TABLE'
              and table_name not in ('backup_runs', 'backup_rows', 'mill_report_files', 'docs_history') loop
    execute format('insert into backup_rows (run_id, tbl, row) select %s, %L, to_jsonb(x) from public.%I x', r, t, t);
  end loop;
  if to_regclass('auth.users') is not null then
    insert into backup_rows (run_id, tbl, row)
      select r, 'auth.users', jsonb_build_object('id', u.id, 'email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at) from auth.users u;
  end if;
  delete from backup_runs where id not in (select id from backup_runs order by at desc limit 5);
end $$;

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
  is_active := (s[1] = 'farms' and n = 4 and s[3] in ('active', 'harvest'));   -- the shared active track and field, each harvester's open field, and its field sessions
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
         or (array_length(s, 1) = 3 and s[1] = 'farms' and s[3] in ('active', 'quota', 'harvest')))
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
  -- 2026-11-24: a load the mill has certified keeps its mill numbers when it is saved whole
  if existed and n = 6 and s[1] = 'farms' and s[3] = 'days' and s[5] = 'loads' then
    p_data := coalesce(p_data, '{}'::jsonb) || coalesce((select jsonb_object_agg(k.key, k.value) from docs d, jsonb_each(d.data) k
                where d.path = p_path and d.data->>'millReport' is not null and k.key = any(array['tons','trs','trsFinal','crs','brix','pol','purity','fiber','sed','ticket','weighedAt','millReport','millSample','trsFrom','certified','finalAt','tonsEst','trsEst'])), '{}'::jsonb);
  end if;
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
    -- crew may change the track, field, variety and harvester lists; managers also the mills, their colors, their start dates and the harvest start date
    if exists (select 1 from jsonb_object_keys(coalesce(p_patch, '{}'::jsonb)) k
               where k not in ('tracks', 'fields', 'varieties', 'harvesters') and not (w.o_role = 'manager' and k in ('mills', 'millColors', 'millStart', 'harvestStart', 'harvestEnd'))) then
      raise exception 'denied' using errcode = '42501';
    end if;
  end if;
  if w.o_role <> 'admin' and s[1] = 'trucks' then
    if not exists (select 1 from docs where path = p_path and data->>'farm' = w.o_farm)
       or (p_patch->'farm' is not null and p_patch->>'farm' is distinct from w.o_farm) then
      raise exception 'denied' using errcode = '42501';
    end if;
  end if;
  -- 2026-11-24: the mill report is the certified tons and TRS: once a load has it, edits keep the mill's numbers
  if n = 6 and s[1] = 'farms' and s[3] = 'days' and s[5] = 'loads'
     and exists (select 1 from docs where path = p_path and data->>'millReport' is not null) then
    p_patch := coalesce(p_patch, '{}'::jsonb) - array['tons','trs','trsFinal','crs','brix','pol','purity','fiber','sed','ticket','weighedAt','millReport','millSample','trsFrom','certified','finalAt','tonsEst','trsEst'];
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

-- ---------- Edge 101 field recorder: harvester keys and recorder reports ----------
-- A harvester with an Edge 101 gets a secret key (Tools > Harvest by field, administrators and the farm's manager).
-- The recorder sends its events over Wi-Fi to edge_report with that key, no sign-in:
--   open  (a record started: its fields, variety, stubble, burnt), field (the field the GPS says it is cutting),
--   close (the record closed, with each field's tons), wagon (a wagon cleared), undo (that wagon undone).
-- Every event has its own id; an id already received is skipped, so the recorder can always send again.
-- A harvester without an Edge 101 keeps working by hand, as before.
create table if not exists public.harv_keys (
  key_hash   text primary key,
  farm_id    text not null,
  harvester  text not null,
  created_at timestamptz not null default now(),
  last_at    timestamptz,
  unique (farm_id, harvester)
);
create table if not exists public.edge_seen (
  key_hash text not null,
  eid      text not null,
  at       timestamptz not null default now(),
  primary key (key_hash, eid)
);
alter table public.harv_keys enable row level security;
alter table public.edge_seen enable row level security;
revoke all on public.harv_keys, public.edge_seen from anon, authenticated;

-- same as the page's hvKey(): 'h_' + the name in lower case, other characters as '-'
create or replace function public._hkey(p_name text) returns text
language sql immutable as $$
  select 'h_' || left(trim(both '-' from regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '-', 'g')), 40)
$$;
-- stubble text from the recorder ("Plant", "1st", "2", "3rd stubble") as the page's number (0 = plant cane)
create or replace function public._stub(p text) returns int
language sql immutable as $$
  select case when coalesce(p, '') ~* '(plant|^\s*p\s*$)' then 0
              when substring(coalesce(p, '') from '[0-9]+') is not null then least(substring(p from '[0-9]+')::int, 6)
              else null end
$$;
create or replace function public._doc_put(p_path text, p_data jsonb) returns void
language sql security definer set search_path = public as $$
  insert into docs (path, parent, id, data)
    values (p_path, regexp_replace(p_path, '/[^/]+$', ''), regexp_replace(p_path, '^.*/', ''), p_data)
    on conflict (path) do update set data = excluded.data, updated_at = now();
$$;
create or replace function public._edge_sid(p_hash text, p_rec text, p_label text) returns text
language sql immutable as $$
  select 'e_' || substr(p_hash, 1, 8) || '_' || regexp_replace(coalesce(p_rec, ''), '[^A-Za-z0-9]+', '', 'g')
         || '_' || trim(both '-' from regexp_replace(lower(coalesce(p_label, '')), '[^a-z0-9]+', '-', 'g'))
$$;
-- add a name to one of the farm's lists (fields, tracks, varieties) if it is not there yet
create or replace function public._farm_list_add(p_farm text, p_key text, p_val text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(p_val), '') = '' then return; end if;
  update docs set data = jsonb_set(data, array[p_key], coalesce(data->p_key, '[]'::jsonb) || to_jsonb(trim(p_val))), updated_at = now()
   where path = 'farms/' || p_farm
     and not exists (select 1 from jsonb_array_elements_text(coalesce(data->p_key, '[]'::jsonb)) x where lower(trim(x)) = lower(trim(p_val)));
end $$;
-- the harvester's open field: the page's own document, keeping its letter and any waiting wagons
create or replace function public._edge_set_active(p_farm text, p_harv text, p_sid text) returns void
language plpgsql security definer set search_path = public as $$
declare s jsonb; old jsonb; nowms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  select data into s from docs where path = 'farms/' || p_farm || '/harvest/' || p_sid;
  if s is null then return; end if;
  select data into old from docs where path = 'farms/' || p_farm || '/active/' || _hkey(p_harv);
  perform _doc_put('farms/' || p_farm || '/active/' || _hkey(p_harv), jsonb_strip_nulls(jsonb_build_object(
    'harvester', p_harv, 'session', p_sid, 'track', coalesce(s->>'track', ''), 'field', coalesce(s->>'field', ''),
    'variety', coalesce(s->>'variety', ''), 'stubble', s->'stubble', 'openedAt', coalesce((s->>'openedAt')::bigint, nowms),
    'by', p_harv || ' (Edge 101)', 'at', nowms, 'edge', true, 'code', old->'code', 'queue', old->'queue', 'ew', old->'ew')));
end $$;
-- a truck's 3 wagons are full: log it as loaded, like a tap on its number (the mill must be known)
create or replace function public._edge_log_truck(p_farm text, p_truck text, p_d jsonb, p_harv text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t jsonb; f jsonb; mills jsonb; v_mill text; day text := to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD');
  lid text := 'le' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 14); best jsonb; nmix int; rec jsonb; pd record;
  lpath text; nowms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  select data into t from docs where path = 'trucks/' || p_truck;
  select data into f from docs where path = 'farms/' || p_farm;
  if t is null or f is null then return jsonb_build_object('logged', false, 'why', 'truck or farm missing'); end if;
  -- the truck's own mill(s) that are still on the farm (as the Board reads them), else all the farm's mills
  mills := coalesce((select jsonb_agg(distinct x) from jsonb_array_elements_text(case when jsonb_typeof(t->'mills') = 'array' then t->'mills' else '[]'::jsonb end) x
                      where x in (select y from jsonb_array_elements_text(coalesce(f->'mills', '[]'::jsonb)) y)), '[]'::jsonb);
  if jsonb_array_length(mills) = 0 then
    mills := coalesce((select jsonb_agg(distinct x) from jsonb_array_elements_text(coalesce(f->'mills', '[]'::jsonb)) x), '[]'::jsonb);
  end if;
  if jsonb_array_length(mills) = 1 then v_mill := mills->>0;
  elsif jsonb_array_length(mills) = 0 then v_mill := '';
  else
    update docs set data = data || jsonb_build_object('needTap', true), updated_at = now() where path = 'farms/' || p_farm || '/active/w_' || p_truck;
    return jsonb_build_object('logged', false, 'why', 'pick the mill: tap the truck number');
  end if;
  -- the load follows the field most of its wagons came from (first wagon on a tie)
  select x.v into best from (
    select e.v, e.i, count(*) over (partition by e.v->>'s') c
      from jsonb_array_elements(p_d) with ordinality e(v, i) where jsonb_typeof(e.v) = 'object') x
    order by x.c desc, x.i limit 1;
  select count(distinct e->>'s') into nmix from jsonb_array_elements(p_d) e where jsonb_typeof(e) = 'object';
  rec := jsonb_build_object('truck', p_truck, 'no', t->>'no', 'farm', p_farm, 'hauler', coalesce(t->>'hauler', ''),
    'track', coalesce(best->>'track', ''), 'field', coalesce(best->>'field', ''), 'variety', coalesce(best->>'variety', ''),
    'stubble', coalesce(best->'stubble', '""'::jsonb), 'mill', v_mill, 'loadedAt', nowms, 'loadedBy', p_harv || ' (Edge 101)',
    'day', day, 'dumps', p_d, 'mixed', nmix > 1, 'edge', true);
  lpath := 'farms/' || p_farm || '/days/' || day || '/loads/' || lid;
  perform _doc_put(lpath, rec);
  -- a weight that came in before the truck was logged goes onto the new load (as in db_set)
  select * into pd from scale_pending
    where (farm_id = p_farm or (farm_id is null and (org is null or org = f->>'org') and lower(mill) = lower(coalesce(rec->>'mill', ''))))
      and (hauler is null or hauler = f->>'haulerCode'
           or hauler in (select e.value from jsonb_each_text(coalesce(f->'haulerMillCodes', '{}'::jsonb)) e))
      and upper(truck_no) = upper(coalesce(t->>'no', '')) and at > now() - interval '12 hours'
    order by at limit 1;
  if found then
    update docs set data = data || jsonb_strip_nulls(jsonb_build_object(
        'tons', pd.tons, 'trs', pd.trs, 'brix', pd.brix, 'ticket', pd.ticket, 'weighedAt', (extract(epoch from pd.at) * 1000)::bigint))
      where path = lpath;
    delete from scale_pending where id = pd.id;
  end if;
  update docs set data = data || jsonb_build_object('lastUsed', day), updated_at = now() where path = 'trucks/' || p_truck;
  delete from docs where path = 'farms/' || p_farm || '/active/w_' || p_truck;
  return jsonb_build_object('logged', true, 'load', lid, 'mill', v_mill);
end $$;

-- Administrators, and the farm's manager: make, list and turn off harvester keys. The key is shown once.
create or replace function public.harv_key_new(p_farm text, p_harvester text) returns text
language plpgsql security definer set search_path = public as $$
declare w record; k text := 'hk_' || replace(gen_random_uuid()::text, '-', ''); h text := left(trim(coalesce(p_harvester, '')), 40);
begin
  select * into w from _who();
  if not (w.o_role = 'admin' or (w.o_role = 'manager' and w.o_farm = p_farm)) or not _farm_in(w.o_org, p_farm) or h = '' then
    raise exception 'denied' using errcode = '42501';
  end if;
  delete from harv_keys where farm_id = p_farm and harvester = h;
  insert into harv_keys (key_hash, farm_id, harvester) values (encode(sha256(convert_to(k, 'utf8')), 'hex'), p_farm, h);
  return k;
end $$;
create or replace function public.harv_key_list(p_farm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if not (w.o_role = 'admin' or (w.o_role = 'manager' and w.o_farm = p_farm)) or not _farm_in(w.o_org, p_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('harvester', harvester, 'created_at', created_at, 'last_at', last_at) order by harvester), '[]'::jsonb)
            from harv_keys where farm_id = p_farm);
end $$;
create or replace function public.harv_key_off(p_farm text, p_harvester text) returns void
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if not (w.o_role = 'admin' or (w.o_role = 'manager' and w.o_farm = p_farm)) or not _farm_in(w.o_org, p_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  delete from harv_keys where farm_id = p_farm and harvester = p_harvester;
end $$;

-- One wagon box on one truck, set safely (signed-in crew on their own farm). p_from_queue takes the oldest
-- wagon an Edge 101 reported that is waiting for a truck. Returns the truck's 3 boxes.
drop function if exists public.wag_set(text, text, int, jsonb, boolean);
create or replace function public.wag_set(p_farm text, p_truck text, p_i int, p_slot jsonb default null, p_from_queue boolean default false, p_harvester text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; wpath text := 'farms/' || p_farm || '/active/w_' || p_truck; cur jsonb; d jsonb; q record; used jsonb;
  nowms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  select * into w from _who();
  if w.o_role = 'mill' or not (w.o_role = 'admin' or w.o_farm = p_farm) or not _farm_in(w.o_org, p_farm) or p_i not between 0 and 2 then
    raise exception 'denied' using errcode = '42501';
  end if;
  perform 1 from docs where path = 'farms/' || p_farm for update;   -- one change to the farm's boxes at a time
  select data into cur from docs where path = wpath;
  d := case when cur is not null and jsonb_typeof(cur->'d') = 'array' and coalesce((cur->>'at')::bigint, 0) > nowms - 16 * 3600000
            then cur->'d' else '[null,null,null]'::jsonb end;
  while jsonb_array_length(d) < 3 loop d := d || 'null'::jsonb; end loop;
  if p_from_queue and jsonb_typeof(d->p_i) is distinct from 'object' then
    select a.path, a.data into q from docs a
      where a.parent = 'farms/' || p_farm || '/active' and a.id like 'h\_%' and jsonb_typeof(a.data->'queue') = 'array' and jsonb_array_length(a.data->'queue') > 0
      order by (p_harvester is not null and a.id = _hkey(p_harvester)) desc, (a.data->'queue'->0->>'at')::bigint nulls last limit 1;
    if found then
      used := q.data->'queue'->0;
      update docs set data = jsonb_set(data, '{queue}', (data->'queue') - 0), updated_at = now() where path = q.path;
      d := jsonb_set(d, array[p_i::text], used - 'at');
    end if;
  end if;
  if used is null then d := jsonb_set(d, array[p_i::text], coalesce(p_slot, 'null'::jsonb)); end if;
  perform _doc_put(wpath, jsonb_build_object('d', d, 'at', nowms, 'by', (select name from profiles where user_id = auth.uid())));
  return jsonb_build_object('d', d, 'fromQueue', used is not null);
end $$;

-- A full wagon waiting for a truck (the evening round): saved with the field it was cut in, placed in the
-- morning with a tap on a box. p_slot is the wagon (harvester, field session, track, field, variety, stubble).
create or replace function public.wag_queue_add(p_farm text, p_harvester text, p_slot jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare w record; hp text := 'farms/' || p_farm || '/active/' || _hkey(p_harvester); old jsonb; q jsonb;
begin
  select * into w from _who();
  if w.o_role = 'mill' or not (w.o_role = 'admin' or w.o_farm = p_farm) or not _farm_in(w.o_org, p_farm) or jsonb_typeof(p_slot) <> 'object' then
    raise exception 'denied' using errcode = '42501';
  end if;
  perform 1 from docs where path = 'farms/' || p_farm for update;
  select data into old from docs where path = hp;
  q := coalesce(old->'queue', '[]'::jsonb) || ((p_slot - 'at') || jsonb_build_object('h', p_harvester, 'at', (extract(epoch from now()) * 1000)::bigint, 'by', (select name from profiles where user_id = auth.uid())));
  while jsonb_array_length(q) > 12 loop q := q - 0; end loop;
  perform _doc_put(hp, coalesce(old, jsonb_build_object('harvester', p_harvester, 'closed', true)) || jsonb_build_object('queue', q));
  return jsonb_array_length(q);
end $$;
create or replace function public.wag_queue_drop(p_farm text, p_harvester text) returns int
language plpgsql security definer set search_path = public as $$
declare w record; hp text := 'farms/' || p_farm || '/active/' || _hkey(p_harvester); q jsonb;
begin
  select * into w from _who();
  if w.o_role = 'mill' or not (w.o_role = 'admin' or w.o_farm = p_farm) or not _farm_in(w.o_org, p_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  perform 1 from docs where path = 'farms/' || p_farm for update;
  select data->'queue' into q from docs where path = hp;
  if jsonb_typeof(q) <> 'array' or jsonb_array_length(q) = 0 then return 0; end if;
  q := q - (jsonb_array_length(q) - 1);   -- the last one added
  update docs set data = jsonb_set(data, '{queue}', q), updated_at = now() where path = hp;
  return jsonb_array_length(q);
end $$;

-- The recorder's report. No sign-in: the harvester key is checked here.
create or replace function public.edge_report(p_key text, p_events jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k record; e jsonb; f jsonb; x jsonb; eid text; rc int; done int := 0; skipped int := 0; sid text; s jsonb; slot jsonb;
  tr record; d jsonb; i int; q jsonb; old jsonb; nowms bigint := (extract(epoch from now()) * 1000)::bigint; res jsonb; wid text;
  day text := to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD'); notes jsonb := '[]'::jsonb;
begin
  select * into k from harv_keys where key_hash = encode(sha256(convert_to(coalesce(p_key, ''), 'utf8')), 'hex');
  if not found then perform pg_sleep(0.6); raise exception 'bad key' using errcode = '42501'; end if;
  if not exists (select 1 from docs where path = 'farms/' || k.farm_id) then raise exception 'farm missing' using errcode = '42501'; end if;
  if jsonb_typeof(p_events) is distinct from 'array' or jsonb_array_length(p_events) > 50 then raise exception 'bad events' using errcode = '22023'; end if;
  perform 1 from docs where path = 'farms/' || k.farm_id for update;   -- one change to the farm's boxes at a time
  for e in select * from jsonb_array_elements(p_events) loop
    eid := left(e->>'id', 80);
    if eid is null or eid = '' then continue; end if;
    insert into edge_seen (key_hash, eid) values (k.key_hash, eid) on conflict do nothing;
    get diagnostics rc = row_count;
    if rc = 0 then skipped := skipped + 1; continue; end if;
    done := done + 1;
    if e->>'e' = 'open' then
      -- a record with its fields: one field session per field, the harvester's open field = the first (or the one named)
      for f in select * from jsonb_array_elements(coalesce(e->'fields', '[]'::jsonb)) loop
        sid := _edge_sid(k.key_hash, e->>'rec', f->>'l');
        select data into old from docs where path = 'farms/' || k.farm_id || '/harvest/' || sid;
        perform _doc_put('farms/' || k.farm_id || '/harvest/' || sid, (coalesce(old, jsonb_build_object('checks', '[]'::jsonb, 'openedAt', coalesce((e->>'utc')::bigint, nowms), 'openedBy', k.harvester || ' (Edge 101)', 'day', day)) - 'closedAt')
          || jsonb_strip_nulls(jsonb_build_object('harvester', k.harvester, 'track', coalesce(f->>'tr', ''), 'field', coalesce(nullif(f->>'f', ''), f->>'l'),
               'variety', coalesce(f->>'v', ''), 'stubble', to_jsonb(_stub(f->>'s')), 'burned', case when f ? 'b' then (f->>'b') = '1' end,
               -- the field's full size goes in fieldAcres; acres actually cut come with the tons (tot 'ac' -> cutAcres)
               'fieldAcres', case when coalesce((f->>'a')::numeric, 0) > 0 then (f->>'a')::numeric end,
               'edge', true, 'rec', e->>'rec', 'label', f->>'l')));
        perform _farm_list_add(k.farm_id, 'fields', coalesce(nullif(f->>'f', ''), f->>'l'));
        perform _farm_list_add(k.farm_id, 'tracks', f->>'tr');
        perform _farm_list_add(k.farm_id, 'varieties', f->>'v');
      end loop;
      sid := _edge_sid(k.key_hash, e->>'rec', coalesce(e->>'l', e->'fields'->0->>'l'));
      perform _edge_set_active(k.farm_id, k.harvester, sid);
    elsif e->>'e' = 'field' then
      perform _edge_set_active(k.farm_id, k.harvester, _edge_sid(k.key_hash, e->>'rec', e->>'l'));
    elsif e->>'e' in ('close', 'wagon', 'tot') then
      -- the recorder's own field totals: set, never added, so a field reopened is not counted twice.
      -- 'ac' = acres cut in that field so far (the recorder's per-field acres), kept as cutAcres next to its tons.
      for x in select * from jsonb_array_elements(coalesce(e->'tot', '[]'::jsonb)) loop
        update docs set data = data || jsonb_build_object('monitorTons', round((x->>'t')::numeric, 3))
                                    || case when x ? 'ac' and (x->>'ac') ~ '^[0-9.]+$' then jsonb_build_object('cutAcres', round((x->>'ac')::numeric, 3)) else '{}'::jsonb end, updated_at = now()
         where path = 'farms/' || k.farm_id || '/harvest/' || _edge_sid(k.key_hash, e->>'rec', x->>'l');
      end loop;
      if e->>'e' = 'close' then
        update docs set data = data || jsonb_build_object('closedAt', coalesce((e->>'utc')::bigint, nowms), 'closedBy', k.harvester || ' (Edge 101)'), updated_at = now()
         where parent = 'farms/' || k.farm_id || '/harvest' and data->>'rec' = e->>'rec' and data->>'harvester' = k.harvester;
        select data into old from docs where path = 'farms/' || k.farm_id || '/active/' || _hkey(k.harvester);
        if old is not null and (old->>'session') in (select id from docs where parent = 'farms/' || k.farm_id || '/harvest' and data->>'rec' = e->>'rec') then
          perform _doc_put('farms/' || k.farm_id || '/active/' || _hkey(k.harvester), jsonb_strip_nulls(jsonb_build_object(
            'harvester', k.harvester, 'closed', true, 'lastField', old->>'field', 'lastTrack', old->>'track', 'at', nowms,
            'by', k.harvester || ' (Edge 101)', 'edge', true, 'code', old->'code', 'queue', old->'queue', 'ew', old->'ew')));
        end if;
      end if;
      if e->>'e' = 'wagon' then   -- 2026-11-22: each Edge wagon's tons per field, kept for the truck it goes into
        perform _edge_wagon_keep(k.farm_id, k.harvester, k.key_hash, e, nowms);
      end if;
      if e->>'e' = 'wagon' and false then   -- wagon boxes: off for now (the wagon's field totals above still count)
        -- the wagon belongs to the field most of its tons came from
        select r, l into tr from (
          select sp1->>'r' r, sp1->>'l' l, sum((sp1->>'t')::numeric) t from jsonb_array_elements(coalesce(e->'sp', '[]'::jsonb)) sp1 group by 1, 2) z
          order by t desc limit 1;
        sid := case when tr.l is not null then _edge_sid(k.key_hash, coalesce(tr.r, e->>'rec'), tr.l) end;
        select data into s from docs where path = 'farms/' || k.farm_id || '/harvest/' || sid;
        if s is null then  -- not a field it reported: the harvester's open field
          select a.data->>'session' into sid from docs a where a.path = 'farms/' || k.farm_id || '/active/' || _hkey(k.harvester);
          select data into s from docs where path = 'farms/' || k.farm_id || '/harvest/' || sid;
        end if;
        if s is null then
          notes := notes || to_jsonb('wagon ' || coalesce(e->>'n', '?') || ': no field known for it');
        else
          wid := coalesce(e->>'rec', '') || ':' || coalesce(e->>'n', '');
          slot := jsonb_strip_nulls(jsonb_build_object('h', k.harvester, 's', sid, 'track', coalesce(s->>'track', ''), 'field', coalesce(s->>'field', ''),
            'variety', coalesce(s->>'variety', ''), 'stubble', coalesce(s->'stubble', '""'::jsonb), 'wid', wid,
            't', round((e->>'t')::numeric, 3), 'sc', round((e->>'sc')::numeric, 3), 'edge', true));
          -- the truck this harvester is already filling (one of its wagons in it, not full, last 3 hours)
          select a.path, a.id, a.data into tr from docs a
            where a.parent = 'farms/' || k.farm_id || '/active' and a.id like 'w\_%' and jsonb_typeof(a.data->'d') = 'array'
              and coalesce((a.data->>'at')::bigint, 0) > nowms - 3 * 3600000
              and exists (select 1 from jsonb_array_elements(a.data->'d') y where jsonb_typeof(y) = 'object' and y->>'h' = k.harvester)
              and exists (select 1 from generate_series(0, 2) g where jsonb_typeof(a.data->'d'->g) is distinct from 'object')
            order by (a.data->>'at')::bigint desc limit 1;
          if found then
            d := tr.data->'d'; while jsonb_array_length(d) < 3 loop d := d || 'null'::jsonb; end loop;
            select min(g) into i from generate_series(0, 2) g where jsonb_typeof(d->g) is distinct from 'object';
            d := jsonb_set(d, array[i::text], slot);
            perform _doc_put(tr.path, (tr.data - 'needTap') || jsonb_build_object('d', d, 'at', nowms));
            if (select count(*) from generate_series(0, 2) g where jsonb_typeof(d->g) = 'object') = 3 then
              res := _edge_log_truck(k.farm_id, substr(tr.id, 3), d, k.harvester);
              notes := notes || to_jsonb('truck ' || coalesce((select data->>'no' from docs where path = 'trucks/' || substr(tr.id, 3)), '?') || ': ' ||
                         case when (res->>'logged')::boolean then 'loaded' else res->>'why' end);
            end if;
          else
            -- no truck yet: the wagon waits on the Board until the logger taps a box of the truck it went into
            select data into old from docs where path = 'farms/' || k.farm_id || '/active/' || _hkey(k.harvester);
            q := coalesce(old->'queue', '[]'::jsonb) || (slot || jsonb_build_object('at', nowms));
            while jsonb_array_length(q) > 12 loop q := q - 0; end loop;
            if old is null then old := jsonb_build_object('harvester', k.harvester, 'closed', true); end if;
            perform _doc_put('farms/' || k.farm_id || '/active/' || _hkey(k.harvester), old || jsonb_build_object('queue', q));
          end if;
        end if;
      end if;
    elsif e->>'e' = 'undo' then
      wid := coalesce(e->>'rec', '') || ':' || coalesce(e->>'n', '');
      perform _edge_wagon_drop(k.farm_id, k.harvester, wid);   -- 2026-11-22
      for tr in select a.path, a.id, a.data from docs a where a.parent = 'farms/' || k.farm_id || '/active' and a.id like 'w\_%' and jsonb_typeof(a.data->'d') = 'array' loop
        if exists (select 1 from jsonb_array_elements(tr.data->'d') y where y->>'wid' = wid) then
          update docs set data = jsonb_set(data, '{d}', (select jsonb_agg(case when y->>'wid' = wid then 'null'::jsonb else y end order by o) from jsonb_array_elements(tr.data->'d') with ordinality z(y, o))), updated_at = now()
           where path = tr.path;
        end if;
      end loop;
      update docs set data = jsonb_set(data, '{queue}', coalesce((select jsonb_agg(y) from jsonb_array_elements(data->'queue') y where y->>'wid' is distinct from wid), '[]'::jsonb)), updated_at = now()
       where path = 'farms/' || k.farm_id || '/active/' || _hkey(k.harvester) and jsonb_typeof(data->'queue') = 'array';
    end if;
  end loop;
  update harv_keys set last_at = now() where key_hash = k.key_hash;
  delete from edge_seen where at < now() - interval '60 days';
  return jsonb_build_object('ok', true, 'done', done, 'skipped', skipped, 'harvester', k.harvester, 'notes', notes);
end $$;

revoke execute on function public._hkey(text), public._stub(text), public._doc_put(text, jsonb), public._edge_sid(text, text, text),
  public._farm_list_add(text, text, text), public._edge_set_active(text, text, text), public._edge_log_truck(text, text, jsonb, text)
  from public, anon, authenticated;
revoke execute on function public.harv_key_new(text, text), public.harv_key_list(text), public.harv_key_off(text, text),
  public.wag_set(text, text, int, jsonb, boolean, text), public.wag_queue_add(text, text, jsonb), public.wag_queue_drop(text, text), public.edge_report(text, jsonb) from public, anon;
grant execute on function public.harv_key_new(text, text), public.harv_key_list(text), public.harv_key_off(text, text),
  public.wag_set(text, text, int, jsonb, boolean, text), public.wag_queue_add(text, text, jsonb), public.wag_queue_drop(text, text) to authenticated;
-- the recorder has no sign-in: it uses its harvester key, checked inside edge_report
grant execute on function public.edge_report(text, jsonb) to anon, authenticated;

-- ===== 2026-11-22: truck loads split by field / track / variety from the Edge 101's wagons =====
-- Each Edge wagon arrives (edge_report 'wagon') with its tons per field. The harvester's active doc keeps the
-- last 15 (6 hours) in 'ew'. When a truck is logged, edge_wagons_take hands the Board the newest ones, one per
-- wagon from that harvester in the truck, and clears the list; the load's 'split' is made from them.
create or replace function public._edge_wagon_keep(p_farm text, p_harv text, p_kh text, e jsonb, nowms bigint) returns void
language plpgsql security definer set search_path = public as $$
declare hp text := 'farms/' || p_farm || '/active/' || _hkey(p_harv); old jsonb; ew jsonb; sp jsonb := '[]'::jsonb; x jsonb; s jsonb; sid text;
  wid text := coalesce(e->>'rec', '') || ':' || coalesce(e->>'n', '');
begin
  if coalesce(nullif(e->>'t', '')::numeric, 0) <= 0 then return; end if;
  for x in select * from jsonb_array_elements(case when jsonb_typeof(e->'sp') = 'array' then e->'sp' else '[]'::jsonb end) loop
    if coalesce(nullif(x->>'t', '')::numeric, 0) <= 0 then continue; end if;
    sid := _edge_sid(p_kh, coalesce(nullif(x->>'r', ''), e->>'rec'), x->>'l');
    select data into s from docs where path = 'farms/' || p_farm || '/harvest/' || sid;
    sp := sp || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('s', sid, 'track', coalesce(s->>'track', ''), 'field', coalesce(s->>'field', x->>'l', ''),
            'variety', coalesce(s->>'variety', ''), 'stubble', coalesce(s->'stubble', '""'::jsonb), 't', round((x->>'t')::numeric, 3))));
  end loop;
  if jsonb_array_length(sp) = 0 then return; end if;
  select data into old from docs where path = hp;
  ew := coalesce((select jsonb_agg(y) from jsonb_array_elements(case when jsonb_typeof(old->'ew') = 'array' then old->'ew' else '[]'::jsonb end) y
                   where y->>'wid' is distinct from wid and coalesce((y->>'at')::bigint, 0) > nowms - 6 * 3600000), '[]'::jsonb);
  ew := ew || jsonb_build_array(jsonb_build_object('wid', wid, 'at', coalesce(nullif(e->>'utc', '')::bigint, nowms), 't', round((e->>'t')::numeric, 3), 'sp', sp));
  while jsonb_array_length(ew) > 15 loop ew := ew - 0; end loop;
  perform _doc_put(hp, coalesce(old, jsonb_build_object('harvester', p_harv, 'closed', true)) || jsonb_build_object('ew', ew));
end $$;
create or replace function public._edge_wagon_drop(p_farm text, p_harv text, p_wid text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update docs set data = jsonb_set(data, '{ew}', coalesce((select jsonb_agg(y) from jsonb_array_elements(data->'ew') y where y->>'wid' is distinct from p_wid), '[]'::jsonb)), updated_at = now()
   where path = 'farms/' || p_farm || '/active/' || _hkey(p_harv) and jsonb_typeof(data->'ew') = 'array';
end $$;
-- the Board, when a truck is logged: the p_n newest Edge wagons of a harvester (removed, so each wagon goes in one truck)
create or replace function public.edge_wagons_take(p_farm text, p_harvester text, p_n int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; hp text := 'farms/' || p_farm || '/active/' || _hkey(p_harvester); ew jsonb; took jsonb; nowms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  select * into w from _who();
  if w.o_role = 'mill' or not (w.o_role = 'admin' or w.o_farm = p_farm) or not _farm_in(w.o_org, p_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  if coalesce(p_n, 0) <= 0 then return '[]'::jsonb; end if;
  perform 1 from docs where path = 'farms/' || p_farm for update;
  select data->'ew' into ew from docs where path = hp;
  if jsonb_typeof(ew) <> 'array' then return '[]'::jsonb; end if;
  -- the newest p_n wagons are the ones in this truck (the truck is logged once its last wagon is in); anything older
  -- missed a truck (one not logged) and is cleared, so a missed truck never shifts the next ones
  select coalesce(jsonb_agg(y order by (y->>'at')::bigint), '[]'::jsonb) into took from (
    select y from jsonb_array_elements(ew) y where coalesce((y->>'at')::bigint, 0) > nowms - 6 * 3600000 order by (y->>'at')::bigint desc limit p_n) z;
  update docs set data = jsonb_set(data, '{ew}', '[]'::jsonb), updated_at = now() where path = hp;
  return took;
end $$;
revoke execute on function public.edge_wagons_take(text, text, int) from public, anon;
revoke execute on function public._edge_wagon_keep(text, text, text, jsonb, bigint), public._edge_wagon_drop(text, text, text) from public, anon, authenticated;
grant execute on function public.edge_wagons_take(text, text, int) to authenticated;

create table if not exists public.docs_history (
  id          bigserial primary key,
  path        text not null,
  data        jsonb not null,
  replaced_at timestamptz not null default now(),
  op          text not null
);
create index if not exists docs_history_path_idx on public.docs_history (path, replaced_at desc);
alter table public.docs_history enable row level security;   -- no policies: only the SQL editor / owner can read it

create or replace function public._docs_keep_history() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.path like 'tools/sugarlog%' then
    insert into docs_history (path, data, op) values (old.path, old.data, tg_op);
    -- keep the newest 300 versions of each document
    delete from docs_history h
     where h.path = old.path
       and h.id < (select min(id) from (select id from docs_history where path = old.path order by id desc limit 300) k);
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public._docs_keep_history() from public, anon, authenticated;

drop trigger if exists docs_keep_history on public.docs;
create trigger docs_keep_history before update or delete on public.docs
  for each row execute function public._docs_keep_history();


-- ===== 2026-11-23: the mill's daily cane receipt (PDF), matched to the trucks logged the day before =====
-- The mill emails a Daily Cane Receipt each morning for the day before. /api/mill-report reads the PDF and sends
-- each tract on it here (one report = one grower/tract for one day): every load's receipt number, truck (54-398),
-- scale time, net tons and, for the loads the mill cored, brix, pol, purity, fiber, TRS and CRS.
-- Each weigh-in goes on the truck's latest load logged 10 minutes to 4 hours before it (a truck has to be weighed
-- before it can be loaded again). If that load was already taken by an earlier weigh-in, a log entry is missing and the
-- weigh-in is left for a person to place. The load keeps its track, field, variety, stubble, harvester and split, so
-- the tons and sugar trace back to where the cane was cut; each report also saves a by-field summary.
-- Sending the same report again changes nothing: a receipt already on a load stays on that load.
create table if not exists public.mill_report_keys (
  org        text primary key,
  key_hash   text not null,
  created_at timestamptz not null default now()
);
-- reports that matched no logged loads (wrong day, trucks not logged yet): kept so they can be tried again
create table if not exists public.mill_report_unplaced (
  id      uuid primary key default gen_random_uuid(),
  org     text not null,
  rkey    text not null,
  report  jsonb not null,
  source  text,
  at      timestamptz not null default now(),
  unique (org, rkey)
);
alter table public.mill_report_keys enable row level security;
alter table public.mill_report_unplaced enable row level security;
revoke all on public.mill_report_keys, public.mill_report_unplaced from anon, authenticated;

create or replace function public._mr_ms(p_day date, p_time text) returns bigint
language sql immutable as $$
  select (extract(epoch from ((p_day::text || ' ' || p_time)::timestamp at time zone 'America/Chicago')) * 1000)::bigint
$$;
create or replace function public._mr_num(v jsonb) returns numeric
language sql immutable as $$
  select case when jsonb_typeof(v) = 'number' then (v #>> '{}')::numeric
              when jsonb_typeof(v) = 'string' and (v #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then (v #>> '{}')::numeric end
$$;
create or replace function public._mr_rkey(p_rep jsonb) returns text
language sql immutable as $$
  select regexp_replace(coalesce(p_rep->>'day', '') || '_' || coalesce(p_rep->>'operator', '') || '-' || coalesce(p_rep->>'account', ''), '[^A-Za-z0-9_-]', '', 'g')
$$;

-- A logged load's truck number against the mill's (54-398, 9095-416, 395-127): the board keeps 398, or the whole id.
create or replace function public._mr_truck_ok(p_no text, p_truck text) returns boolean
language sql immutable as $$
  select upper(coalesce(p_no, '')) <> '' and upper(p_no) in (upper(case when p_truck like '%-%' then split_part(p_truck, '-', 2) else p_truck end),
         upper(replace(p_truck, '-', '')), upper(p_truck))
$$;

-- Which logged loads the weigh-ins go on, for one farm and mill. Writes nothing.
-- With scale times: each weigh-in goes on its truck's latest load logged 10 minutes to 4 hours before it.
-- With no times (Raceland's Daily Transaction Report): a truck's tickets, in the mill's order, go on its loads of that
-- day in the order they were logged, but only when the counts agree; otherwise that truck's tickets are left to place.
create or replace function public._mr_pairs(p_farm text, p_mill text, p_day date, p_loads jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e jsonb; i bigint; sms bigint; b record; bp text; used text[] := '{}'; done bigint[] := '{}'; pairs jsonb := '[]'::jsonb; n int := 0;
  t text; ri bigint[]; lp text[]; k int;
  parents text[] := array['farms/' || p_farm || '/days/' || p_day::text || '/loads', 'farms/' || p_farm || '/days/' || (p_day - 1)::text || '/loads'];
  timed boolean := not exists (select 1 from jsonb_array_elements(p_loads) x where coalesce(x->>'time', '') = '');
begin
  -- receipts already on a load (this report sent again) stay where they are
  for e, i in select x.v, x.o from jsonb_array_elements(p_loads) with ordinality x(v, o) loop
    bp := null;
    select d.path into bp from docs d where d.parent = any(parents) and d.data->>'ticket' = e->>'rcpt' and d.data->>'millReport' is not null limit 1;
    if bp is not null and not (bp = any(used)) then
      used := used || bp; done := done || i; pairs := pairs || jsonb_build_array(jsonb_build_object('i', i, 'path', bp)); n := n + 1;
    end if;
  end loop;

  if timed then
    for e, i in select x.v, x.o from jsonb_array_elements(p_loads) with ordinality x(v, o) order by x.v->>'time', x.o loop
      if i = any(done) then continue; end if;
      sms := _mr_ms(p_day, e->>'time');
      select d.path, d.data->>'millReport' as mr into b from docs d
        where d.parent = any(parents) and lower(coalesce(d.data->>'mill', '')) = lower(p_mill)
          and _mr_truck_ok(d.data->>'no', e->>'truck')
          and (d.data->>'loadedAt') ~ '^[0-9]+$'
          and (d.data->>'loadedAt')::bigint between sms - 4 * 3600000 and sms - 10 * 60000
        order by (d.data->>'loadedAt')::bigint desc limit 1;
      if found and b.mr is null and not (b.path = any(used)) then
        used := used || b.path; pairs := pairs || jsonb_build_array(jsonb_build_object('i', i, 'path', b.path)); n := n + 1;
      end if;
    end loop;
  else
    for t in select distinct x->>'truck' from jsonb_array_elements(p_loads) x loop
      select array_agg(x.o order by coalesce(_mr_num(x.v->'seq'), 0), x.o) into ri
        from jsonb_array_elements(p_loads) with ordinality x(v, o) where x.v->>'truck' = t and not (x.o = any(done));
      select array_agg(d.path order by (d.data->>'loadedAt')::bigint) into lp
        from docs d where d.parent = 'farms/' || p_farm || '/days/' || p_day::text || '/loads'
          and lower(coalesce(d.data->>'mill', '')) = lower(p_mill) and _mr_truck_ok(d.data->>'no', t)
          and d.data->>'millReport' is null and (d.data->>'loadedAt') ~ '^[0-9]+$' and not (d.path = any(used));
      if coalesce(array_length(ri, 1), 0) > 0 and array_length(ri, 1) = coalesce(array_length(lp, 1), 0) then
        for k in 1 .. array_length(ri, 1) loop
          used := used || lp[k]; pairs := pairs || jsonb_build_array(jsonb_build_object('i', ri[k], 'path', lp[k])); n := n + 1;
        end loop;
      end if;
    end loop;
  end if;
  return jsonb_build_object('n', n, 'pairs', pairs);
end $$;

-- Places one report: finds the farm and mill whose logged loads it fits best, writes the mill numbers on those loads,
-- and saves the report with its matches, the weigh-ins left over and a by-field summary at farms/<farm>/millreports/<day>_<grower>-<tract>.
create or replace function public._mr_apply(p_org text, p_only text, p_rep jsonb, p_source text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare dday date; loads jsonb; hc text; fm record; ml text; g text; fh text; r jsonb; sc int; bn int := -1; best jsonb; bf text; bm text;
  rk text := _mr_rkey(p_rep); pr jsonb; e jsonb; ld jsonb; patch jsonb; trs numeric; tons numeric; usedI int[] := '{}'; un jsonb := '[]'::jsonb;
  tcrs numeric; mt numeric := 0; rtons numeric := 0; avgTrs numeric; bfld jsonb; nolog jsonb; trk text; dpath text;
begin
  begin dday := (p_rep->>'day')::date; exception when others then return jsonb_build_object('status', 'bad', 'why', 'no date'); end;
  loads := p_rep->'loads';
  if jsonb_typeof(loads) <> 'array' or jsonb_array_length(loads) = 0 or jsonb_array_length(loads) > 400 then
    return jsonb_build_object('status', 'bad', 'why', 'no loads');
  end if;
  if exists (select 1 from jsonb_array_elements(loads) x where (coalesce(x->>'time', '') !~ '^[0-9]{2}:[0-9]{2}(:[0-9]{2})?$' and _mr_num(x->'seq') is null)
             or coalesce(_mr_num(x->'tons'), 0) <= 0 or _mr_num(x->'tons') > 200 or coalesce(x->>'rcpt', '') = '' or coalesce(x->>'truck', '') = '') then
    return jsonb_build_object('status', 'bad', 'why', 'a load is missing its receipt, truck, time or tons');
  end if;
  -- one report has scale times on every load or on none
  if exists (select 1 from jsonb_array_elements(loads) x where coalesce(x->>'time', '') = '')
     and exists (select 1 from jsonb_array_elements(loads) x where coalesce(x->>'time', '') <> '') then
    return jsonb_build_object('status', 'bad', 'why', 'some loads have scale times and some do not');
  end if;
  hc := case when loads->0->>'truck' like '%-%' then split_part(loads->0->>'truck', '-', 1) end;

  for fm in select id, data from docs where parent = 'farms' and data->>'org' = p_org and (p_only is null or id = p_only) order by id loop
    for ml in select distinct d2.data->>'mill' from docs d2
               where d2.parent in ('farms/' || fm.id || '/days/' || dday::text || '/loads', 'farms/' || fm.id || '/days/' || (dday - 1)::text || '/loads')
                 and coalesce(d2.data->>'mill', '') <> '' loop
      g := null; fh := null;
      -- the grower number at this mill (Setup), when it is set, must be the report's
      select x.value into g from jsonb_each_text(coalesce(fm.data->'millGrowers', '{}'::jsonb)) x where lower(x.key) = lower(ml) limit 1;
      if coalesce(g, '') <> '' and g <> coalesce(p_rep->>'operator', '') then continue; end if;
      -- the hauler number, for a mill whose trucks the board numbers hauler-truck (Setup)
      if exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(fm.data->'haulerMills') = 'array' then fm.data->'haulerMills' else '[]'::jsonb end) y where lower(y) = lower(ml)) then
        select nullif(x.value, '') into fh from jsonb_each_text(coalesce(fm.data->'haulerMillCodes', '{}'::jsonb)) x where lower(x.key) = lower(ml) limit 1;
        fh := coalesce(fh, nullif(fm.data->>'haulerCode', ''));
      end if;
      if hc is not null and fh is not null and ltrim(fh, '0') <> ltrim(hc, '0') then continue; end if;
      r := _mr_pairs(fm.id, ml, dday, loads);
      sc := (r->>'n')::int * 4 + case when coalesce(g, '') <> '' then 2 else 0 end
            + case when coalesce(p_rep->>'mill', '') <> '' and position(lower(split_part(ml, ' ', 1)) in lower(p_rep->>'mill')) > 0 then 1 else 0 end;
      if (r->>'n')::int > 0 and sc > bn then bn := sc; best := r; bf := fm.id; bm := ml; end if;
    end loop;
  end loop;

  if best is null then
    insert into mill_report_unplaced (org, rkey, report, source) values (p_org, rk, p_rep, p_source)
      on conflict (org, rkey) do update set report = excluded.report, source = excluded.source, at = now();
    return jsonb_build_object('status', 'unplaced', 'day', dday, 'account', p_rep->>'accountName', 'loads', jsonb_array_length(loads));
  end if;
  delete from mill_report_unplaced where org = p_org and rkey = rk;

  dpath := 'farms/' || bf || '/millreports/' || rk;
  -- the tract's TRS and CRS: the mill's own figures, or else its cored loads weighted by tons
  select case when sum(_mr_num(x->'tons')) > 0 then sum(_mr_num(x->'tons') * _mr_num(x->'trs')) / sum(_mr_num(x->'tons')) end,
         case when sum(_mr_num(x->'tons')) filter (where _mr_num(x->'crs') is not null) > 0
              then sum(_mr_num(x->'tons') * _mr_num(x->'crs')) filter (where _mr_num(x->'crs') is not null) / sum(_mr_num(x->'tons')) filter (where _mr_num(x->'crs') is not null) end
    into avgTrs, tcrs from jsonb_array_elements(loads) x where _mr_num(x->'trs') is not null;
  avgTrs := round(coalesce(_mr_num(p_rep->'totals'->'trs'), avgTrs), 2);
  tcrs := round(coalesce(_mr_num(p_rep->'totals'->'crs'), tcrs), 2);
  for pr in select * from jsonb_array_elements(best->'pairs') loop
    e := loads->((pr->>'i')::int - 1);
    usedI := usedI || (pr->>'i')::int;
    select data into ld from docs where path = pr->>'path';
    tons := _mr_num(e->'tons'); trs := _mr_num(e->'trs');
    patch := jsonb_strip_nulls(jsonb_build_object('tons', tons, 'ticket', e->>'rcpt',
               'weighedAt', case when coalesce(e->>'time', '') <> '' then _mr_ms(dday, e->>'time') end,
               'millReport', rk, 'millSample', nullif(e->>'sample', ''), 'crs', _mr_num(e->'crs'), 'brix', _mr_num(e->'brix'),
               'pol', _mr_num(e->'pol'), 'purity', _mr_num(e->'purity'), 'fiber', _mr_num(e->'fiber'), 'sed', _mr_num(e->'sed')));
    if ld->>'tons' is not null and ld->>'millReport' is null and _mr_num(ld->'tons') is distinct from tons then
      patch := patch || jsonb_build_object('tonsEst', _mr_num(ld->'tons'));
    end if;
    -- certified by the mill: its tons, and its TRS (a cored load's own, or the tract's for a load it did not core)
    patch := patch || jsonb_build_object('certified', true, 'trsFrom', case when trs is not null then 'core' else 'tract' end);
    if trs is null and avgTrs is not null then
      patch := patch || jsonb_strip_nulls(jsonb_build_object('trs', avgTrs, 'crs', tcrs, 'trsFinal', true, 'finalAt', (extract(epoch from now()) * 1000)::bigint));
      if ld->>'trs' is not null and coalesce((ld->>'trsFinal')::boolean, false) = false then patch := patch || jsonb_build_object('trsEst', _mr_num(ld->'trs')); end if;
    end if;
    if trs is not null then
      patch := patch || jsonb_build_object('trs', trs, 'trsFinal', true, 'finalAt', (extract(epoch from now()) * 1000)::bigint);
      if ld->>'trs' is not null and coalesce((ld->>'trsFinal')::boolean, false) = false then patch := patch || jsonb_build_object('trsEst', _mr_num(ld->'trs')); end if;
    end if;
    update docs set data = data || patch, updated_at = now() where path = pr->>'path';
    mt := mt + tons;
  end loop;

  -- weigh-ins that found no logged load
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('rcpt', x.v->>'rcpt', 'truck', x.v->>'truck', 'time', x.v->>'time',
           'tons', _mr_num(x.v->'tons'), 'trs', _mr_num(x.v->'trs'))) order by x.v->>'time', _mr_num(x.v->'seq'), x.o), '[]'::jsonb),
         coalesce(sum(_mr_num(x.v->'tons')), 0)
    into un, rtons from jsonb_array_elements(loads) with ordinality x(v, o) where not (x.o::int = any(usedI));
  rtons := rtons + mt;
  -- the report's TRS: the mill's own tract figure, or else every load the mill cored, matched or not, weighted by tons
  select case when sum(_mr_num(x->'tons')) > 0 then sum(_mr_num(x->'tons') * _mr_num(x->'trs')) / sum(_mr_num(x->'tons')) end into avgTrs
    from jsonb_array_elements(loads) x where _mr_num(x->'trs') is not null;
  avgTrs := coalesce(_mr_num(p_rep->'totals'->'trs'), avgTrs);

  -- logged loads on that day, for this mill (and this tract's track when the track names match), still with no mill weight
  trk := case when exists (select 1 from docs d where d.parent = 'farms/' || bf || '/days/' || dday::text || '/loads'
                            and lower(coalesce(d.data->>'track', '')) = lower(coalesce(p_rep->>'accountName', '-'))) then lower(p_rep->>'accountName') end;
  select coalesce(jsonb_agg(jsonb_build_object('no', d.data->>'no', 'loadedAt', (d.data->>'loadedAt')::bigint, 'field', coalesce(d.data->>'field', ''))
           order by (d.data->>'loadedAt')::bigint), '[]'::jsonb) into nolog
    from docs d where d.parent = 'farms/' || bf || '/days/' || dday::text || '/loads'
      and lower(coalesce(d.data->>'mill', '')) = lower(bm) and d.data->>'millReport' is null
      and (trk is null or lower(coalesce(d.data->>'track', '')) = trk) and (d.data->>'loadedAt') ~ '^[0-9]+$';

  -- by field: each load's tons split by its parts (one part, or the Edge 101 split), TRS from the loads the mill cored
  select coalesce(jsonb_agg(jsonb_build_object('track', q.track, 'field', q.field, 'variety', q.variety, 'stubble', q.stubble,
           'loads', round(q.loads, 2), 'tons', round(q.tons, 2), 'coredTons', round(q.ck, 2),
           'trs', case when q.ct > 0 then round(q.tt / q.ct, 2) end,
           'lbsTrs', round(q.tons * coalesce(case when q.ct > 0 then q.tt / q.ct end, avgTrs, 0))) order by q.tons desc), '[]'::jsonb)
    into bfld from (
      select coalesce(p.v->>'track', '') as track, coalesce(p.v->>'field', '') as field, coalesce(p.v->>'variety', '') as variety,
             coalesce(p.v->>'stubble', '') as stubble, sum(p.sh) as loads, sum(p.sh * _mr_num(d.data->'tons')) as tons,
             sum(case when d.data->>'trs' is not null then p.sh * _mr_num(d.data->'tons') else 0 end) as ct,
             sum(case when d.data->>'trs' is not null then p.sh * _mr_num(d.data->'tons') * _mr_num(d.data->'trs') else 0 end) as tt,
             sum(case when d.data->>'trsFrom' = 'core' then p.sh * _mr_num(d.data->'tons') else 0 end) as ck
        from docs d
        cross join lateral (
          select y.v, coalesce(_mr_num(y.v->'share'), 0) as sh from jsonb_array_elements(d.data->'split') y(v)
            where jsonb_typeof(d.data->'split') = 'array' and jsonb_array_length(d.data->'split') > 0
          union all
          select jsonb_build_object('track', d.data->>'track', 'field', d.data->>'field', 'variety', d.data->>'variety', 'stubble', d.data->'stubble' #>> '{}'), 1
            where jsonb_typeof(d.data->'split') is distinct from 'array' or jsonb_array_length(d.data->'split') = 0
        ) p
       where d.parent in ('farms/' || bf || '/days/' || dday::text || '/loads', 'farms/' || bf || '/days/' || (dday - 1)::text || '/loads')
         and d.data->>'millReport' = rk
       group by 1, 2, 3, 4) q;

  perform _doc_put(dpath, jsonb_strip_nulls(jsonb_build_object(
    'day', dday::text, 'mill', bm, 'millName', nullif(p_rep->>'mill', ''), 'pdfId', nullif(p_rep->>'pdfId', ''), 'operator', p_rep->>'operator', 'operatorName', p_rep->>'operatorName',
    'account', p_rep->>'account', 'accountName', p_rep->>'accountName', 'cropDay', p_rep->'cropDay', 'file', p_rep->>'file',
    'loads', jsonb_array_length(loads), 'tons', round(rtons, 2), 'matched', (best->>'n')::int, 'matchedTons', round(mt, 2),
    'cored', (select count(*) from jsonb_array_elements(loads) x where _mr_num(x->'trs') is not null),
    'trs', round(avgTrs, 2), 'totals', p_rep->'totals', 'unmatched', un, 'noWeight', nolog, 'byField', bfld,
    'source', p_source, 'at', (extract(epoch from now()) * 1000)::bigint, 'report', p_rep)));
  return jsonb_build_object('status', 'ok', 'farm', bf, 'mill', bm, 'day', dday, 'account', p_rep->>'accountName', 'id', rk,
    'loads', jsonb_array_length(loads), 'matched', (best->>'n')::int, 'unmatched', jsonb_array_length(un), 'noWeight', jsonb_array_length(nolog),
    'tons', round(rtons, 2), 'trs', round(avgTrs, 2));
end $$;

-- The original PDFs, so a report opens from the Mill tab instead of the email. Kept once per file (same file sent twice: one copy).
create table if not exists public.mill_report_files (
  id    uuid primary key default gen_random_uuid(),
  org   text not null,
  sha   text not null,
  name  text,
  pdf   text not null,         -- base64
  bytes int,
  at    timestamptz not null default now(),
  unique (org, sha)
);
alter table public.mill_report_files enable row level security;
revoke all on public.mill_report_files from anon, authenticated;

create or replace function public._mr_file(p_org text, p_pdf text, p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare b bytea; i uuid;
begin
  if coalesce(p_pdf, '') = '' then return null; end if;
  if length(p_pdf) > 12000000 then return null; end if;
  begin b := decode(p_pdf, 'base64'); exception when others then return null; end;
  if substring(b from 1 for 5) <> convert_to('%PDF-', 'utf8') then return null; end if;
  insert into mill_report_files (org, sha, name, pdf, bytes) values (p_org, encode(sha256(b), 'hex'), left(p_name, 160), p_pdf, length(b))
    on conflict (org, sha) do update set name = coalesce(excluded.name, mill_report_files.name)
    returning id into i;
  return i;
end $$;

drop function if exists public.mill_report(text, jsonb);
drop function if exists public.mill_report_upload(jsonb);

-- The email path: no sign-in, the portal's mill report key (Setup > Mill reports) says which portal.
create or replace function public.mill_report(p_key text, p_reports jsonb, p_pdf text default null, p_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o text; r jsonb; out jsonb := '[]'::jsonb; f uuid;
begin
  select org into o from mill_report_keys where key_hash = encode(sha256(convert_to(coalesce(p_key, ''), 'utf8')), 'hex');
  if o is null then perform pg_sleep(0.6); raise exception 'bad key' using errcode = '42501'; end if;
  if jsonb_typeof(p_reports) <> 'array' or jsonb_array_length(p_reports) > 50 then raise exception 'bad request' using errcode = '22023'; end if;
  f := _mr_file(o, p_pdf, p_name);
  for r in select * from jsonb_array_elements(p_reports) loop
    if f is not null then r := r || jsonb_build_object('pdfId', f); end if;
    out := out || jsonb_build_array(_mr_apply(o, null, r, 'email'));
  end loop;
  return out;
end $$;

-- The upload button: an administrator (any farm in the portal) or a crew manager (their own farm only).
create or replace function public.mill_report_upload(p_reports jsonb, p_pdf text default null, p_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; r jsonb; out jsonb := '[]'::jsonb; f uuid;
begin
  select * into w from _who();
  if w.o_role not in ('admin', 'manager') then raise exception 'denied' using errcode = '42501'; end if;
  if jsonb_typeof(p_reports) <> 'array' or jsonb_array_length(p_reports) > 50 then raise exception 'bad request' using errcode = '22023'; end if;
  f := _mr_file(w.o_org, p_pdf, p_name);
  for r in select * from jsonb_array_elements(p_reports) loop
    if f is not null then r := r || jsonb_build_object('pdfId', f); end if;
    out := out || jsonb_build_array(_mr_apply(w.o_org, case when w.o_role = 'admin' then null else w.o_farm end, r, 'upload'));
  end loop;
  return out;
end $$;

-- The saved reports of a farm, newest day first (administrators: any farm; crew managers: their own farm),
-- and, for administrators, the ones not placed yet.
create or replace function public.mill_report_list(p_farm text, p_limit int default 15) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; f text;
begin
  select * into w from _who();
  f := case when w.o_role = 'admin' then p_farm else w.o_farm end;
  if w.o_role not in ('admin', 'manager') or not _farm_in(w.o_org, f) then raise exception 'denied' using errcode = '42501'; end if;
  return jsonb_build_object(
    'reports', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'data', q.data - 'report') order by q.data->>'day' desc, q.id), '[]'::jsonb)
                  from (select id, data from docs where parent = 'farms/' || f || '/millreports' order by data->>'day' desc, id limit least(coalesce(p_limit, 15), 60)) q),
    'unplaced', case when w.o_role = 'admin' then (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'day', report->>'day', 'account', report->>'accountName',
                  'operator', report->>'operatorName', 'loads', jsonb_array_length(report->'loads'), 'at', (extract(epoch from at) * 1000)::bigint) order by at desc), '[]'::jsonb)
                  from mill_report_unplaced where org = w.o_org) else '[]'::jsonb end);
end $$;

-- Try a saved report again (after a missing truck was logged or a time fixed). p_farm null: one not placed yet, by its id.
create or replace function public.mill_report_again(p_farm text, p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; rep jsonb;
begin
  select * into w from _who();
  if w.o_role not in ('admin', 'manager') then raise exception 'denied' using errcode = '42501'; end if;
  if p_farm is null then
    if w.o_role <> 'admin' then raise exception 'denied' using errcode = '42501'; end if;
    select report into rep from mill_report_unplaced where org = w.o_org and id::text = p_id;
  else
    if not _farm_in(w.o_org, p_farm) or (w.o_role <> 'admin' and p_farm <> w.o_farm) then raise exception 'denied' using errcode = '42501'; end if;
    select data->'report' into rep from docs where path = 'farms/' || p_farm || '/millreports/' || p_id;
  end if;
  if rep is null then return jsonb_build_object('status', 'notfound'); end if;
  return _mr_apply(w.o_org, case when w.o_role = 'admin' then null else w.o_farm end, rep, 'again');
end $$;

-- The day's weather, saved on a mill report (the page looks it up from Open-Meteo for the farm's weather spot).
create or replace function public.mill_report_weather(p_farm text, p_id text, p_wx jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if w.o_role not in ('admin', 'manager') or not _farm_in(w.o_org, p_farm) or (w.o_role <> 'admin' and p_farm <> w.o_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  if jsonb_typeof(p_wx) <> 'object' or length(p_wx::text) > 2000 then raise exception 'bad request' using errcode = '22023'; end if;
  update docs set data = data || jsonb_build_object('wx', p_wx), updated_at = now()
   where path = 'farms/' || p_farm || '/millreports/' || p_id;
end $$;

create or replace function public.mill_report_drop(p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if w.o_role <> 'admin' then raise exception 'denied' using errcode = '42501'; end if;
  delete from mill_report_unplaced where org = w.o_org and id::text = p_id;
end $$;

-- The portal's mill report key (administrators). The key is shown once; the email address has it at the end.
create or replace function public.mill_report_key_get() returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; k record;
begin
  select * into w from _who();
  if w.o_role <> 'admin' then raise exception 'denied' using errcode = '42501'; end if;
  select * into k from mill_report_keys where org = w.o_org;
  return jsonb_build_object('exists', found, 'created_at', k.created_at);
end $$;
create or replace function public.mill_report_key_new() returns text
language plpgsql security definer set search_path = public as $$
declare w record; k text := 'mrk_' || replace(gen_random_uuid()::text, '-', '');
begin
  select * into w from _who();
  if w.o_role <> 'admin' then raise exception 'denied' using errcode = '42501'; end if;
  insert into mill_report_keys (org, key_hash) values (w.o_org, encode(sha256(convert_to(k, 'utf8')), 'hex'))
    on conflict (org) do update set key_hash = excluded.key_hash, created_at = now();
  return k;
end $$;
create or replace function public.mill_report_key_off() returns void
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if w.o_role <> 'admin' then raise exception 'denied' using errcode = '42501'; end if;
  delete from mill_report_keys where org = w.o_org;
end $$;

revoke execute on function public._mr_ms(date, text), public._mr_num(jsonb), public._mr_rkey(jsonb), public._mr_pairs(text, text, date, jsonb), public._mr_truck_ok(text, text),
  public._mr_apply(text, text, jsonb, text) from public, anon, authenticated;
revoke execute on function public.mill_report(text, jsonb, text, text), public.mill_report_upload(jsonb, text, text), public.mill_report_list(text, int), public.mill_report_again(text, text),
  public.mill_report_drop(text), public.mill_report_weather(text, text, jsonb), public.mill_report_key_get(), public.mill_report_key_new(), public.mill_report_key_off() from public, anon;
grant execute on function public.mill_report_upload(jsonb, text, text), public.mill_report_list(text, int), public.mill_report_again(text, text),
  public.mill_report_drop(text), public.mill_report_weather(text, text, jsonb), public.mill_report_key_get(), public.mill_report_key_new(), public.mill_report_key_off() to authenticated;
-- the email path has no sign-in: it uses the portal's mill report key, checked inside mill_report
grant execute on function public.mill_report(text, jsonb, text, text) to anon, authenticated;

-- ===== 2026-11-24: saved mill PDFs, the Farm tab's field maps, and a backup download =====

-- A saved mill report PDF (base64), for an administrator, or a crew manager when it is on a report of their farm.
create or replace function public.mill_report_pdf(p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; f record;
begin
  select * into w from _who();
  if w.o_role not in ('admin', 'manager') then raise exception 'denied' using errcode = '42501'; end if;
  select * into f from mill_report_files where id::text = p_id and org = w.o_org;
  if not found then return null; end if;
  if w.o_role <> 'admin' and not exists (select 1 from docs where parent = 'farms/' || w.o_farm || '/millreports' and data->>'pdfId' = p_id) then
    raise exception 'denied' using errcode = '42501';
  end if;
  return jsonb_build_object('name', f.name, 'pdf', f.pdf, 'bytes', f.bytes);
end $$;

-- Each farm's field map (from a Yote Farmview shapefile or GeoJSON, read by /api/field-map): every field's track,
-- ID, variety, stubble, acres, center and outline. nextSeason: the file's stubble is already next year's.
create table if not exists public.field_maps (
  farm       text primary key,
  org        text not null,
  data       jsonb not null,
  by_name    text,
  updated_at timestamptz not null default now()
);
alter table public.field_maps enable row level security;
revoke all on public.field_maps from anon, authenticated;

create or replace function public.field_map_get(p_farm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; m record;
begin
  select * into w from _who();
  if w.o_role in ('mill', 'pending') or w.o_org is null or not _farm_in(w.o_org, p_farm)
     or (w.o_role <> 'admin' and p_farm is distinct from w.o_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  select * into m from field_maps where farm = p_farm and org = w.o_org;
  if not found then return null; end if;
  return m.data || jsonb_build_object('by', m.by_name, 'updatedAt', (extract(epoch from m.updated_at) * 1000)::bigint);
end $$;

create or replace function public.field_map_put(p_farm text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w record; nm text;
begin
  select * into w from _who();
  if w.o_role not in ('admin', 'manager') or not _farm_in(w.o_org, p_farm) or (w.o_role <> 'admin' and p_farm <> w.o_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  if jsonb_typeof(p_data) <> 'object' or jsonb_typeof(p_data->'fields') <> 'array' or jsonb_array_length(p_data->'fields') = 0
     or jsonb_array_length(p_data->'fields') > 3000 or octet_length(p_data::text) > 4000000 then
    raise exception 'bad request' using errcode = '22023';
  end if;
  select name into nm from profiles where user_id = auth.uid();
  insert into field_maps (farm, org, data, by_name) values (p_farm, w.o_org, p_data, nm)
    on conflict (farm) do update set data = excluded.data, org = excluded.org, by_name = excluded.by_name, updated_at = now();
end $$;

-- Settings on a farm's map that do not need the whole file again (nextSeason).
create or replace function public.field_map_set(p_farm text, p_patch jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if w.o_role not in ('admin', 'manager') or not _farm_in(w.o_org, p_farm) or (w.o_role <> 'admin' and p_farm <> w.o_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  if jsonb_typeof(p_patch) <> 'object' or exists (select 1 from jsonb_object_keys(p_patch) k where k not in ('nextSeason')) then
    raise exception 'bad request' using errcode = '22023';
  end if;
  update field_maps set data = data || p_patch, updated_at = now() where farm = p_farm and org = w.o_org;
end $$;

-- An administrator's download of their portal: farms with everything under them (loads, harvest sessions,
-- mill reports), trucks, tools, field maps and people (name, role, farm, email). No passwords and no keys.
create or replace function public.backup_export() returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; farms text[];
begin
  select * into w from _who();
  if w.o_role <> 'admin' then raise exception 'denied' using errcode = '42501'; end if;
  select coalesce(array_agg(id), '{}') into farms from docs where parent = 'farms' and data->>'org' = w.o_org;
  return jsonb_build_object(
    'portal', (select name from orgs where id = w.o_org), 'org', w.o_org, 'takenAt', now(),
    'docs', (select coalesce(jsonb_agg(jsonb_build_object('path', d.path, 'data', d.data) order by d.path), '[]'::jsonb) from docs d
              where (d.parent = 'farms' and d.id = any(farms)) or split_part(d.path, '/', 1) = 'farms' and split_part(d.path, '/', 2) = any(farms) and d.parent <> 'farms'
                 or (d.parent = 'trucks' and d.data->>'farm' = any(farms)) or (d.parent = 'tools' and d.id like w.o_org || '.%')),
    'fieldMaps', (select coalesce(jsonb_object_agg(farm, data), '{}'::jsonb) from field_maps where org = w.o_org),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'role', p.role, 'farm', p.farm, 'mill', p.mill,
                 'email', (select u.email from auth.users u where u.id = p.user_id)) order by p.name), '[]'::jsonb)
               from profiles p where p.org = w.o_org));
end $$;

revoke execute on function public._mr_file(text, text, text) from public, anon, authenticated;
revoke execute on function public.mill_report_pdf(text), public.field_map_get(text), public.field_map_put(text, jsonb),
  public.field_map_set(text, jsonb), public.backup_export() from public, anon;
grant execute on function public.mill_report_pdf(text), public.field_map_get(text), public.field_map_put(text, jsonb),
  public.field_map_set(text, jsonb), public.backup_export() to authenticated;

-- ===== 2026-11-24: field records (sprays, fertilizer, planting, scouting, notes) on the Farm tab =====
-- One row per field per job; a job put on several fields at once shares a batch id. data: type, date, time,
-- products [{name, rate, unit, epa}], applicator, license, equipment, acres, gpa, target, notes, weather.
create table if not exists public.field_records (
  id       uuid primary key default gen_random_uuid(),
  org      text not null,
  farm     text not null,
  fkey     text not null,          -- lower(track) | field number before any "-"
  track    text,
  field    text,
  batch    uuid not null,
  data     jsonb not null,
  by_user  uuid,
  by_name  text,
  at       timestamptz not null default now()
);
create index if not exists field_records_farm_idx on public.field_records (farm, fkey);
alter table public.field_records enable row level security;
revoke all on public.field_records from anon, authenticated;

create or replace function public._fr_ok(p_farm text, out o_org text, out o_role text) returns record
language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from _who();
  if w.o_role not in ('admin', 'manager', 'crew') or not _farm_in(w.o_org, p_farm) or (w.o_role <> 'admin' and p_farm is distinct from w.o_farm) then
    raise exception 'denied' using errcode = '42501';
  end if;
  o_org := w.o_org; o_role := w.o_role;
end $$;

-- Add one job to one or more fields of a farm (administrators: any farm; managers and crew: their own).
create or replace function public.field_record_add(p_farm text, p_fields jsonb, p_data jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare a record; b uuid := gen_random_uuid(); f jsonb; n int := 0; nm text; tr text; fd text;
begin
  select * into a from _fr_ok(p_farm);
  if jsonb_typeof(p_fields) <> 'array' or jsonb_array_length(p_fields) = 0 or jsonb_array_length(p_fields) > 300
     or jsonb_typeof(p_data) <> 'object' or octet_length(p_data::text) > 30000 or coalesce(p_data->>'date', '') !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'bad request' using errcode = '22023';
  end if;
  select name into nm from profiles where user_id = auth.uid();
  for f in select * from jsonb_array_elements(p_fields) loop
    tr := left(coalesce(f->>'track', ''), 60); fd := left(coalesce(f->>'field', ''), 60);
    if fd = '' then continue; end if;
    insert into field_records (org, farm, fkey, track, field, batch, data, by_user, by_name)
      values (a.o_org, p_farm, lower(trim(tr)) || '|' || lower(trim(split_part(fd, '-', 1))), tr, fd, b, p_data, auth.uid(), nm);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Every record on a farm, newest first.
create or replace function public.field_record_list(p_farm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select * into a from _fr_ok(p_farm);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'fkey', fkey, 'track', track, 'field', field, 'batch', batch, 'data', data,
            'by', by_name, 'mine', by_user = auth.uid(), 'at', (extract(epoch from at) * 1000)::bigint) order by data->>'date' desc, data->>'time' desc, at desc), '[]'::jsonb)
          from (select * from field_records where farm = p_farm and org = a.o_org order by at desc limit 5000) q);
end $$;

-- Delete a record (p_all: every field of that job). Administrators and managers, or whoever added it.
create or replace function public.field_record_del(p_id text, p_all boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare r record; a record; n int;
begin
  select * into r from field_records where id::text = p_id;
  if not found then return 0; end if;
  select * into a from _fr_ok(r.farm);
  if a.o_role = 'crew' and r.by_user is distinct from auth.uid() then raise exception 'denied' using errcode = '42501'; end if;
  if p_all then delete from field_records where batch = r.batch and farm = r.farm; else delete from field_records where id = r.id; end if;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public._fr_ok(text) from public, anon, authenticated;
revoke execute on function public.field_record_add(text, jsonb, jsonb), public.field_record_list(text), public.field_record_del(text, boolean) from public, anon;
grant execute on function public.field_record_add(text, jsonb, jsonb), public.field_record_list(text), public.field_record_del(text, boolean) to authenticated;
