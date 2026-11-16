-- Transaction-scoped memo for the listing/library access chain.
--
-- Why: every content table (listings, photos, capture_assets, renders, leads,
-- media_provenance, render_jobs, capture_chapters) carries the RLS policy
-- current_listing_access(listing_id, false). That function resolves the
-- listing's library, then runs library_content_access, library_team_owner,
-- the team/sponsorship binding checks and effective_plan_before_team: a chain
-- of SECURITY DEFINER SQL functions with ~20 subqueries and auth.users joins
-- that Postgres re-plans and re-runs for EVERY ROW. Measured live on
-- 2026-11-06: 15–33 ms per row for a plain owner, up to ~140 ms per call
-- for a sponsored private library. A 61-asset listing cost 2.0 s of policy
-- evaluation; `select count(*) from capture_assets` as the Rendprop owner
-- took 8.5 s; the Studio media page took 22 s and hit the 8 s
-- statement_timeout (PostgREST "canceling statement due to statement
-- timeout" on the capture_assets range query), which the Studio showed as an
-- empty gallery.
--
-- What: keep the existing functions as *_compute (bodies unchanged, md5
-- pinned) and put a memo in front of library_content_access and
-- listing_content_access. The memo lives in transaction-local settings
-- (set_config(..., is_local => true)), so it never outlives the PostgREST
-- request that created it and never crosses sessions. Within a transaction,
-- any write to a table the chain reads bumps rp.access_epoch (statement
-- trigger), and memo entries carry the epoch they were computed at, so a
-- mutation RPC that changes a membership and re-checks access in the same
-- transaction still sees the fresh answer. Functions stay PARALLEL UNSAFE
-- (the default), which is required for set_config.
--
-- Semantics are unchanged: the first call per (actor, org/listing, write)
-- per transaction-epoch runs the original body; later calls return that
-- result. The policies are untouched (they reference current_listing_access
-- by OID, which still calls listing_content_access by name).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $pin$
begin
 if (select md5(prosrc) from pg_proc where oid = 'public.library_content_access(uuid,uuid,boolean)'::regprocedure)
    is distinct from '2c000242919f52a6c8e4b28328488cb7' then
  raise exception 'library_content_access changed since 2026-11-06; review the memo before applying';
 end if;
 if (select md5(prosrc) from pg_proc where oid = 'public.listing_content_access(uuid,uuid,boolean)'::regprocedure)
    is distinct from 'a33c1ea0b72b7cae9919edbb33da4b55' then
  raise exception 'listing_content_access changed since 2026-11-06; review the memo before applying';
 end if;
 if to_regprocedure('public.library_content_access_compute(uuid,uuid,boolean)') is not null
    or to_regprocedure('public.listing_content_access_compute(uuid,uuid,boolean)') is not null then
  raise exception 'access memo already applied';
 end if;
end
$pin$;

-- 1. Epoch bump: one statement trigger on every table the access chain reads
--    (auth.users excluded: anonymity flips are never in the same transaction
--    as a content read).
create or replace function public.access_cache_epoch_bump()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
 perform pg_catalog.set_config('rp.access_epoch',
   pg_catalog.txid_current()::text || ':' || pg_catalog.date_part('epoch', pg_catalog.clock_timestamp())::text, true);
 return null;
end
$$;
revoke all on function public.access_cache_epoch_bump() from public, anon, authenticated;

do $triggers$
declare t text;
begin
 foreach t in array array[
   'apple_serving_schedules', 'apple_subscriptions', 'brokerage_contracts', 'credit_monthly_catalog',
   'deletion_requests', 'listings', 'memberships', 'org_internal_testing_grants', 'org_invites', 'orgs',
   'private_internal_testing_sponsorships', 'profiles', 'serving_funding', 'team_paid_seat_variants',
   'team_private_libraries', 'user_workspace_state'] loop
  if to_regclass('public.' || t) is null then raise exception 'access chain table % is missing', t; end if;
  execute format('drop trigger if exists access_cache_epoch on public.%I', t);
  execute format('create trigger access_cache_epoch after insert or update or delete or truncate on public.%I '
                 'for each statement execute function public.access_cache_epoch_bump()', t);
 end loop;
end
$triggers$;

-- 2. Keep the original bodies under *_compute. ACLs travel with the rename
--    (postgres + service_role only).
alter function public.library_content_access(uuid, uuid, boolean) rename to library_content_access_compute;
alter function public.listing_content_access(uuid, uuid, boolean) rename to listing_content_access_compute;

-- 3. Memo fronts. Keys are per actor + scope + read/write; values carry the
--    epoch they were computed at.
create function public.library_content_access(p_actor uuid, p_org uuid, p_write boolean default false)
returns boolean
language plpgsql
stable
security definer
set search_path to ''
as $$
declare k text; v text; e text; r boolean;
begin
 if p_actor is null or p_org is null then return false; end if;
 e := coalesce(pg_catalog.current_setting('rp.access_epoch', true), '');
 k := 'rp.lca.a' || replace(p_actor::text, '-', '') || '.o' || replace(p_org::text, '-', '') || case when p_write then '.w' else '.r' end;
 v := pg_catalog.current_setting(k, true);
 if v is not null and v <> '' and pg_catalog.split_part(v, '|', 1) = e then
  return pg_catalog.split_part(v, '|', 2) = 't';
 end if;
 r := coalesce(public.library_content_access_compute(p_actor, p_org, p_write), false);
 perform pg_catalog.set_config(k, e || '|' || case when r then 't' else 'f' end, true);
 return r;
end
$$;
revoke all on function public.library_content_access(uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.library_content_access(uuid, uuid, boolean) to service_role;

create function public.listing_content_access(p_actor uuid, p_listing uuid, p_write boolean default false)
returns boolean
language plpgsql
stable
security definer
set search_path to ''
as $$
declare k text; v text; e text; r boolean;
begin
 if p_actor is null or p_listing is null then return false; end if;
 e := coalesce(pg_catalog.current_setting('rp.access_epoch', true), '');
 k := 'rp.lsa.a' || replace(p_actor::text, '-', '') || '.l' || replace(p_listing::text, '-', '') || case when p_write then '.w' else '.r' end;
 v := pg_catalog.current_setting(k, true);
 if v is not null and v <> '' and pg_catalog.split_part(v, '|', 1) = e then
  return pg_catalog.split_part(v, '|', 2) = 't';
 end if;
 r := coalesce(public.listing_content_access_compute(p_actor, p_listing, p_write), false);
 perform pg_catalog.set_config(k, e || '|' || case when r then 't' else 'f' end, true);
 return r;
end
$$;
revoke all on function public.listing_content_access(uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.listing_content_access(uuid, uuid, boolean) to service_role;

do $check$
begin
 if (select proacl::text from pg_proc where oid = 'public.listing_content_access(uuid,uuid,boolean)'::regprocedure)
    is distinct from (select proacl::text from pg_proc where oid = 'public.listing_content_access_compute(uuid,uuid,boolean)'::regprocedure) then
  raise exception 'listing_content_access ACL drifted from its compute function';
 end if;
 if (select proacl::text from pg_proc where oid = 'public.library_content_access(uuid,uuid,boolean)'::regprocedure)
    is distinct from (select proacl::text from pg_proc where oid = 'public.library_content_access_compute(uuid,uuid,boolean)'::regprocedure) then
  raise exception 'library_content_access ACL drifted from its compute function';
 end if;
end
$check$;
commit;
