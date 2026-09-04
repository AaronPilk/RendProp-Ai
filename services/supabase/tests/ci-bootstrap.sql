-- ci-bootstrap.sql — the SLICE of a Supabase project that the migrations depend
-- on, recreated on a plain Postgres so `migrations/*.sql` + `tests/invariants.sql`
-- can run in CI (and locally) without the Supabase CLI or Docker-in-Docker.
--
-- NEVER run this against a real Supabase project: every object here already
-- exists there (created by the platform), and the roles/privileges below mirror
-- what Supabase provisions so grant/revoke assertions in invariants.sql mean the
-- same thing in CI as in production.
--
-- What is mirrored:
--   • roles anon / authenticated / service_role (+ supabase_auth_admin for the
--     signup trigger's effective role)
--   • schema auth, a minimal auth.users (the columns handle_new_user() reads),
--     auth.uid() / auth.role() / auth.jwt() as Supabase defines them
--   • the default privileges Supabase gives the API roles on `public` (ALL on
--     tables/sequences/functions created by the migrating role) — this is why
--     the migrations carry explicit REVOKEs; without the same defaults the
--     revoke tests would pass vacuously.

\set ON_ERROR_STOP on

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    create role supabase_auth_admin nologin noinherit;
  end if;
end $$;

grant anon, authenticated, service_role to current_user;

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role, supabase_auth_admin;

-- Minimal auth.users: only what public.handle_new_user() touches (id, email,
-- raw_user_meta_data) plus the columns invariants.sql's fixture sets.
create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  instance_id        uuid,
  aud                text,
  role               text,
  email              text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  raw_app_meta_data  jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
grant all on auth.users to supabase_auth_admin;

-- Verbatim semantics of Supabase's auth helpers (request.jwt.claims is a GUC
-- PostgREST sets per request; tests set it with set_config(..., true)).
create or replace function auth.uid() returns uuid
language sql stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    ),
    ''
  )::uuid
$$;

create or replace function auth.role() returns text
language sql stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claim.role', true),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
    ),
    ''
  )::text
$$;

create or replace function auth.jwt() returns jsonb
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb
$$;

grant execute on function auth.uid(), auth.role(), auth.jwt() to anon, authenticated, service_role;

-- Supabase's `public` schema defaults: the API roles get ALL on every new
-- table/sequence/function the migrating role creates. Mirroring this is what
-- makes the lockdown migrations' REVOKEs load-bearing in CI.
grant usage, create on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
