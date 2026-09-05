-- 0017: server-enforced owner/admin role for the spend console (2026-09-04).
--
-- The owner needs to see, from inside the app, every AI/API call the product
-- makes and what it costs. That is a cross-org read, which every existing RLS
-- policy correctly forbids. This migration adds the ONE thing that can grant
-- it safely: a role that lives in the database, is set by the server, and can
-- never be asserted by a client.
--
-- Design rules this file obeys:
--
--   1. NO CREDENTIAL, ANYWHERE. Admin is not a password, a shared secret, a
--      magic header or a hardcoded id in the app. It is a boolean on the user's
--      own row, seeded from an allowlist of e-mail addresses at SIGN-UP time.
--      The owner signs in with Apple/e-mail exactly like everyone else and comes
--      out an admin; nobody ever types a secret and none ships in the binary.
--
--   2. A CLIENT CAN NEVER SET IT. `profiles` is tenant-writable through the
--      "own profile" RLS policy (0001) and, until now, the table-level UPDATE
--      grant covered every column — so simply adding `is_admin` would have
--      handed every signed-in user a one-line PostgREST self-promotion
--      (`PATCH /profiles?id=eq.<me> {"is_admin":true}`). §2 closes that by
--      column-scoping the grant, exactly as 0005/0008 did for orgs.plan and
--      listings.org_id, and by revoking INSERT/DELETE so the delete-then-insert
--      variant of the same trick is closed too.
--
--   3. NON-ADMIN REACH IS UNCHANGED. Not one existing policy is dropped,
--      rewritten or widened. The admin grants are NEW, additional, permissive
--      SELECT policies whose entire predicate is `public.is_admin()`. For a
--      non-admin they evaluate to false, so the visible row set is bit-for-bit
--      what it was before this file ran (asserted in tests/invariants.sql).
--
-- Idempotent: `add column if not exists` / `create table if not exists` /
-- `drop policy if exists` before `create policy` / guarded constraint / upsert
-- seed / `create or replace function`, and both back-fills are predicated on
-- `is_admin is not true` so a replay is a no-op.

-- ── 1. The flag itself ───────────────────────────────────────────────────────
-- It lives on `profiles`, which is where user rows live in this schema:
-- `profiles.id` references `auth.users(id)` and every row is created by the
-- `handle_new_user()` signup trigger (0001 §identity, latest body in 0011 §11).
-- There is no `users` table in `public`, and `org_members` does not exist —
-- org membership is `public.memberships`, which is a JOIN row (user × org ×
-- role) and therefore the wrong place for a global, org-independent flag.

alter table public.profiles
  add column if not exists is_admin boolean not null default false;

comment on column public.profiles.is_admin is
  'Product-owner/admin. Grants CROSS-ORG read of cost_ledger, render_jobs, orgs '
  'and the rate_limits usage counters, and is the only thing the admin edge '
  'function accepts. Set ONLY by handle_new_user() from public.admin_allowlist '
  'or by the service role — never by a client (the UPDATE grant below omits it).';

create index if not exists idx_profiles_admin on public.profiles (is_admin) where is_admin;

-- ── 2. A client cannot write it (privilege escalation, closed) ───────────────
-- Column privileges are enforced INDEPENDENTLY of RLS, so this holds even
-- though the "own profile" policy lets a user update their own row.
--
-- The re-grant lists exactly the display columns a tenant legitimately edits.
-- Deliberately omitted: `is_admin` (this file), `apple_refresh_token` (0006 —
-- a token the client has no business rewriting), `id` and `created_at`.
-- INSERT/DELETE go too: with "own profile" being FOR ALL, a user could
-- otherwise delete their profile row and re-insert it with is_admin = true.
-- Every server path that writes `profiles` (handle_new_user, POST /me/apple-code,
-- DELETE /me) runs as the definer or the service role, so nothing legitimate
-- loses a capability here.

revoke update, insert, delete on public.profiles from authenticated, anon;
grant  update (email, phone, name, avatar_url) on public.profiles to authenticated;

-- ── 3. The allowlist ─────────────────────────────────────────────────────────
-- E-mail addresses that BECOME admins on first sign-up. Stored lower-cased and
-- trimmed, primary key = unique by construction; a check constraint makes the
-- normalisation an invariant rather than a convention, so a stray
-- 'Aaron@Pilk.AI' row can never sit there silently matching nothing.
--
-- Service-role only: RLS on with NO policies, and every tenant grant revoked.
-- A tenant cannot read the list (it would name the owner) and cannot add to it
-- (that would be self-promotion by another route).

create table if not exists public.admin_allowlist (
  email      text primary key,
  note       text,
  created_at timestamptz not null default now()
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.admin_allowlist'::regclass
       and conname  = 'admin_allowlist_email_normalised'
  ) then
    alter table public.admin_allowlist
      add constraint admin_allowlist_email_normalised
      check (email = lower(btrim(email)) and email like '%@%' and length(email) between 3 and 320);
  end if;
end $$;

alter table public.admin_allowlist enable row level security;  -- no policies: service-role only
revoke all on public.admin_allowlist from authenticated, anon;

comment on table public.admin_allowlist is
  'E-mails that are promoted to profiles.is_admin on signup by handle_new_user(). '
  'Service-role only (RLS on, no policies, no tenant grants). Normalised lower-case.';

-- Exactly one seed row: the product owner.
insert into public.admin_allowlist (email, note)
values ('aaron@pilk.ai', 'Rendprop product owner — bootstrap admin (migration 0017)')
on conflict (email) do nothing;

-- ── 4. is_admin() — the policy helper ────────────────────────────────────────
-- SECURITY DEFINER with a pinned search_path, matching the convention every
-- other definer in this repo uses (`set search_path = public`: org_role 0006,
-- effective_plan/log_job_cost 0010, create_render_job/publish_render 0011).
--
-- GRANTS — deliberate, and the reasoning is the same one 0005b wrote down for
-- is_org_member: RLS policy expressions are evaluated with the privileges of
-- the QUERYING role, so a helper used inside a policy must stay executable by
-- every role that can reach the table. `anon` still holds SELECT on cost_ledger
-- (only INSERT/UPDATE/DELETE were revoked in 0007), so revoking the implicit
-- PUBLIC EXECUTE here would turn an anonymous read from "zero rows" into
-- "permission denied for function is_admin" — a behaviour change, not a
-- hardening. Leaving PUBLIC in place leaks nothing: without a JWT `auth.uid()`
-- is null, so the function returns false.

create or replace function public.is_admin() returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select p.is_admin from profiles p where p.id = auth.uid()), false);
$$;

grant execute on function public.is_admin() to authenticated, service_role;

comment on function public.is_admin() is
  'True when the CURRENT caller (auth.uid()) is a product admin. Reads only the '
  'caller''s own profiles row; returns false with no JWT. Used by the admin-only '
  'RLS policies below and by the admin edge function.';

-- ── 5. Signup promotes an allowlisted e-mail ─────────────────────────────────
-- Reproduced from 0011 §11 (the LATEST definition of this function). The org
-- naming, the 7-day trial, the membership insert, the security context and the
-- grants are UNCHANGED; the only additions are the allowlist lookup and the
-- is_admin write.
--
-- Deliberate detail: this body must NOT contain the literal `coalesce(new.email`
-- — 0010 §5 re-installs its own (pre-0011) version of this trigger unless the
-- installed source both mentions 'My business' AND lacks that substring. The
-- e-mail is normalised as `lower(btrim(new.email))` inside a coalesce for
-- exactly that reason, so a replay of 0010 after this file still no-ops instead
-- of silently reverting both the org-name fix and the admin bit.

create or replace function public.handle_new_user() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  new_org uuid;
  v_email text := coalesce(lower(btrim(new.email)), '');
  v_admin boolean := false;
  v_name text := left(trim(coalesce(
    nullif(trim(new.raw_user_meta_data->>'name'), ''),
    nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
    ''
  )), 120);
begin
  -- Allowlisted e-mail → admin on first sign-up. No password, no shared secret,
  -- nothing hardcoded in the app.
  if v_email <> '' then
    select exists (select 1 from public.admin_allowlist a where a.email = v_email)
      into v_admin;
  end if;

  insert into public.profiles (id, email, name, is_admin)
  values (new.id, new.email, v_name, v_admin)
  on conflict (id) do nothing;

  -- Covers the on-conflict path (a profile row that somehow already existed):
  -- the insert above would have been skipped, so promote explicitly.
  if v_admin then
    update public.profiles set is_admin = true where id = new.id and is_admin is not true;
  end if;

  insert into public.orgs (name, plan, trial_ends_at)
  values (
    case when v_name <> '' and v_name not like '%@%' then v_name else 'My business' end,
    'trial',
    now() + interval '7 days'
  )
  returning id into new_org;
  insert into public.memberships (user_id, org_id, role) values (new.id, new_org, 'owner');
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- The trigger itself is unchanged from 0001; re-assert it so a database that
-- lost it (or never had it) ends up in the same state.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── 6. Promote accounts that ALREADY exist ───────────────────────────────────
-- The owner's account predates this migration, so the trigger will never fire
-- for it. Both statements are guarded on `is_admin is not true`, so re-running
-- this file updates zero rows.
--
-- auth.users is the authoritative e-mail (profiles.email is a mirror written at
-- signup and can be null for rows created before the trigger existed), so it is
-- matched first; the profiles.email pass is the belt-and-braces second.

update public.profiles p
   set is_admin = true
  from auth.users u
  join public.admin_allowlist a on a.email = coalesce(lower(btrim(u.email)), '')
 where u.id = p.id
   and p.is_admin is not true;

update public.profiles p
   set is_admin = true
  from public.admin_allowlist a
 where a.email = coalesce(lower(btrim(p.email)), '')
   and p.is_admin is not true;

-- ── 7. Admin-only RLS: cross-org READ, nothing else ──────────────────────────
-- Every policy below is NEW, permissive, SELECT-only, and its whole predicate
-- is is_admin(). Nothing existing is dropped or rewritten, so a non-admin's
-- visible rows are identical to what they were before this file:
--
--   cost_ledger  "org ledger"      select using (is_org_member(org_id))     -- untouched
--   render_jobs  "org jobs read"   select using (<member of listing's org>) -- untouched
--   orgs         "member orgs read" select using (is_org_member(id))        -- untouched
--   orgs         "org admin write"  update ...                              -- untouched
--
-- (`drop policy if exists` targets only the admin policies this file creates,
-- so the file is replay-safe without ever touching a tenant policy.)

drop policy if exists "admin ledger read" on public.cost_ledger;
create policy "admin ledger read" on public.cost_ledger
  for select using (public.is_admin());

drop policy if exists "admin jobs read" on public.render_jobs;
create policy "admin jobs read" on public.render_jobs
  for select using (public.is_admin());

drop policy if exists "admin orgs read" on public.orgs;
create policy "admin orgs read" on public.orgs
  for select using (public.is_admin());

-- plan_entitlements is ALREADY world-readable by policy ("entitlements readable"
-- … using (true), 0010 §2) with SELECT granted to authenticated and anon, because
-- the app shows allowances. An admin therefore already reads every row and no
-- new policy is needed; adding one would be dead code. Writes stay service-role
-- only. Asserted in tests/invariants.sql so this stays true.

-- The usage counters: `rate_limits` (0004/0006) is the table the AI routes charge
-- the monthly meters against (aiphotomo: / reelmo: / aerialmo: / dronemo: + org
-- id). RLS is enabled on it with NO policies, and 0007 revoked every tenant
-- privilege — so today a tenant SELECT is a hard permission error.
--
-- Admins need it across all orgs, and an RLS policy only takes effect for a role
-- that also holds the table grant, so SELECT is granted to `authenticated` and
-- the single policy restricts it to admins. Net effect for a non-admin: zero
-- rows instead of an error — no row was readable before and none is now
-- (asserted in tests/invariants.sql, executed AS the authenticated role).
-- INSERT/UPDATE/DELETE stay revoked; bump_rate() remains service-role only.

grant select on public.rate_limits to authenticated;
revoke insert, update, delete on public.rate_limits from authenticated, anon;

drop policy if exists "admin rate limits read" on public.rate_limits;
create policy "admin rate limits read" on public.rate_limits
  for select using (public.is_admin());
