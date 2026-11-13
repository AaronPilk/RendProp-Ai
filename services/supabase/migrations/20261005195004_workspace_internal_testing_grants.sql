begin;

-- Explicit internal-testing authority, never a retail Team allowance change.
-- No account, organization, email or grant is seeded by this migration.
create table if not exists public.org_internal_testing_grants (
  org_id uuid not null references public.orgs(id) on delete cascade,
  owner_user_id uuid not null references public.profiles(id) on delete cascade,
  unmetered_business_allowances boolean not null,
  starts_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  note text check (note is null or length(note) <= 500),
  primary key (org_id, owner_user_id),
  check (expires_at is null or expires_at > starts_at)
);
alter table public.org_internal_testing_grants enable row level security;
revoke all on public.org_internal_testing_grants from public, anon, authenticated;
grant select, insert, update, delete on public.org_internal_testing_grants to service_role;
comment on table public.org_internal_testing_grants is
  'Service-only opt-in internal testing. Active only for a named product-admin owner of a live manual Team workspace without an active brokerage contract. No client policies or client DML.';

-- Grant changes join the same org-row serialization used by seat admission.
-- Identity is immutable; revoke/delete the old grant before granting another.
create or replace function public.lock_internal_testing_grant_org()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and (new.org_id is distinct from old.org_id
    or new.owner_user_id is distinct from old.owner_user_id) then
    raise exception 'RP400: Testing grant identity is immutable';
  end if;
  perform 1 from public.orgs
    where id = case when tg_op = 'DELETE' then old.org_id else new.org_id end
    for update;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public.lock_internal_testing_grant_org() from public, anon, authenticated, service_role;
drop trigger if exists internal_testing_grant_org_lock on public.org_internal_testing_grants;
create trigger internal_testing_grant_org_lock
  before insert or update or delete on public.org_internal_testing_grants
  for each row execute function public.lock_internal_testing_grant_org();

-- The invoker entitlement RPC cannot directly read the private grant or Auth.
-- This narrowly bounded helper exposes only a boolean to a current member or
-- service caller. A SQL admin fixture must have no caller JWT and no SET ROLE;
-- session_user alone must never authorize a foreign authenticated caller.
create or replace function public.org_has_internal_testing_grant(p_org uuid)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  if not (
    current_setting('role', true) = 'service_role'
    or (session_user = current_user and current_setting('role', true) = 'none' and auth.uid() is null)
    or exists (select 1 from public.memberships where org_id = p_org and user_id = auth.uid())
  ) then return false; end if;

  return exists (
    select 1 from public.org_internal_testing_grants g
    join public.orgs o on o.id = g.org_id
    join public.profiles p on p.id = g.owner_user_id and p.is_admin is true
    join auth.users u on u.id = g.owner_user_id and u.is_anonymous is false
    join public.memberships m on m.org_id = g.org_id and m.user_id = g.owner_user_id and m.role = 'owner'
    where g.org_id = p_org and g.unmetered_business_allowances is true
      and g.starts_at <= now() and (g.expires_at is null or g.expires_at > now())
      and g.revoked_at is null and o.deleted_at is null
      and o.plan = 'team' and o.plan_source = 'manual'
      -- Do not call the legacy invoker effective_plan() inside this definer:
      -- its public search_path can consult caller-owned temporary tables.
      -- This is its exact 0050 active-contract precedence, fully qualified.
      and not exists (select 1 from public.brokerage_contracts c
        where c.org_id = p_org and c.status = 'active'
          and c.starts_at <= now() and (c.ends_at is null or c.ends_at > now()))
      and not exists (select 1 from public.deletion_requests d
        where d.user_id = g.owner_user_id and d.status in ('pending', 'processing'))
  );
end $$;
revoke all on function public.org_has_internal_testing_grant(uuid) from public, anon, authenticated;
grant execute on function public.org_has_internal_testing_grant(uuid) to authenticated, service_role;
comment on function public.org_has_internal_testing_grant(uuid) is
  'Current internal-testing authority; false for nonmembers. Rechecks named product-admin ownership, live manual Team, contract precedence, deletion, revocation and expiry. No JWT user_metadata authorization.';

-- Guarded insertions into the exact deployed 0050 definitions. CREATE OR
-- REPLACE preserves owner, ACL, invoker mode, volatility and search_path.
-- 2147483647 is a compatibility projection for existing signed Int32 clients;
-- it is NOT the grant authority, a new retail allowance, or mathematical
-- infinity. Zero/negative remain unavailable. Current technical/per-job caps,
-- spatial $25 budget, disabled-provider/privacy/consent gates remain intact.
do $patch$
declare
  definition text;
  body text;
  anchor text;
  insertion text;
begin
  select pg_get_functiondef(oid), prosrc into definition, body
    from pg_proc where oid = 'public.org_entitlement(uuid)'::regprocedure;
  anchor := E'  v_base := plan_entitlement(effective_plan(p_org));\n';
  insertion := E'  if public.org_has_internal_testing_grant(p_org) then\n    v_base.seats := 2147483647;\n    v_base.renders_per_month := 2147483647;\n    v_base.photo_edits_per_month := 2147483647;\n    v_base.reels_per_month := 2147483647;\n    v_base.aerials_per_month := 2147483647;\n    v_base.topaz_per_month := 2147483647;\n    v_base.cogs_ceiling_cents := 2147483647;\n    return v_base;\n  end if;\n';
  if md5(replace(body, insertion, '')) <> '555f204626eb76a2e594394d23553c19'
    or (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 then
    raise exception 'org_entitlement definition changed; review before installing testing grant';
  end if;
  if position(insertion in body) = 0 then
    execute replace(definition, anchor, anchor || insertion);
  elsif (length(body) - length(replace(body, anchor || insertion, ''))) / length(anchor || insertion) <> 1 then
    raise exception 'org_entitlement testing insertion changed';
  end if;

  select pg_get_functiondef(oid), prosrc into definition, body
    from pg_proc where oid = 'public.org_seats_allowed(uuid)'::regprocedure;
  anchor := E'  select coalesce(\n';
  insertion := E'    (select 2147483647 where public.org_has_internal_testing_grant(p_org)),\n';
  if md5(replace(body, insertion, '')) <> '627538faa6d77f97a228a1bca7299fa3'
    or (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 then
    raise exception 'org_seats_allowed definition changed; review before installing testing grant';
  end if;
  if position(insertion in body) = 0 then
    execute replace(definition, anchor, anchor || insertion);
  elsif (length(body) - length(replace(body, anchor || insertion, ''))) / length(anchor || insertion) <> 1 then
    raise exception 'org_seats_allowed testing insertion changed';
  end if;
end $patch$;
commit;
