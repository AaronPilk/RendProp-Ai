-- Library listing reads: look only at the listings a library could own.
--
-- list_library_listings (the phone's and Studio's library sync) and
-- library_listing_ids (behind the leads inbox, the usage summary and the
-- compliance export) both select with
--   from public.listings l where public.listing_owner_library(l.id)=p_org and ...
-- so every call runs listing_owner_library() - a plpgsql function with its own
-- lookups - once for EVERY listing in the system, and list_library_listings
-- does it twice (count, then page). Postgres cannot use an index for a
-- predicate on a function result. Since the statistics reset on 2026-08-20
-- these two reads account for list_library_listings 611 ms and
-- library_usage_summary 384 ms mean, with 27 listings in the table. With one
-- 500-agent firm (and everybody else's listings) each call is tens of
-- thousands of function calls and passes the 8 s statement timeout.
--
-- listing_owner_library(l) can only equal p_org when
--   l.org_id = p_org                                  (its ELSE branch), or
--   agent_private_library(l.agent_id) = p_org         (its invited-agent branch)
-- and agent_private_library(a) returns, in order,
--   a team_private_libraries.private_org_id in which a is an 'owner' member,
--   a live private_internal_testing_sponsorships.private_org_id whose
--     beneficiary is a, or
--   resolve_actor_owned_library(a,false): an org in which a is an 'owner' member.
-- So a listing can belong to library p_org only if
--   l.org_id = p_org, or l.agent_id is an 'owner' member of p_org, or
--   l.agent_id is the beneficiary of a live sponsorship on p_org.
-- That candidate filter is added IN FRONT of the existing predicates, which
-- stay exactly as they are: it can remove only rows they would reject, so the
-- result of both functions is unchanged. It lets Postgres reach the rows by
-- index (listings by org_id / agent_id) instead of scanning the table.
--
-- The argument depends on the three function bodies above, so each is
-- md5-pinned here, and the migration re-proves it on the live rows before it
-- commits: no live listing may have a library outside its candidate set.
-- Checked read-only on production on 2026-11-12: 1,350 (org, listing) pairs,
-- 24 matches before and after, 0 differences. Production has no listing on
-- the invited-agent branch yet; services/supabase/tests/team_private_libraries.sql
-- exercises that branch in CI.
--
-- Same shape as 20261106230302 (workspace_directory candidate orgs): the
-- definitions are edited mechanically at one exact seam, never retyped.
--
-- Also here:
--   * the indexes the candidate filter and the access chain need at scale;
--   * the two RLS policies the performance advisor flags for re-evaluating
--     auth.uid() per row ("own profile", "own memberships"): wrapped as
--     (select auth.uid()), which Postgres evaluates once per statement. Same
--     predicate, same rows.
--
-- APPLYING. One transaction; safe to apply once (a second run is a no-op with
-- a notice). The CREATE INDEX statements take a brief write lock on tables
-- that hold under 1,000 rows today (single-digit ms). If any of listings,
-- org_invites, team_private_libraries or apple_subscriptions has grown past
-- ~1M rows by the time this ships, create the indexes first, by hand, one
-- statement at a time OUTSIDE a transaction (CREATE INDEX CONCURRENTLY cannot
-- run inside one, and this file is one), then apply this file - its
-- IF NOT EXISTS clauses then do nothing:
--   create index concurrently if not exists listings_agent_live_idx on public.listings using btree (agent_id) where deleted_at is null;
--   create index concurrently if not exists org_invites_accepted_member_idx on public.org_invites using btree (org_id, accepted_by) where accepted_at is not null;
--   create index concurrently if not exists team_private_libraries_agent_idx on public.team_private_libraries using btree (agent_user_id);
--   create index concurrently if not exists apple_subscriptions_user_idx on public.apple_subscriptions using btree (user_id);
--
-- ROLLBACK (nothing here changes data):
--   1. In list_library_listings and library_listing_ids, delete the text of
--      v_candidates (below) plus the ' and ' that follows it - i.e. run the
--      same replace() with needle and replacement swapped.
--   2. alter policy "own profile" on public.profiles using (id = auth.uid()) with check (id = auth.uid());
--      alter policy "own memberships" on public.memberships using (user_id = auth.uid());
--   3. drop index if exists public.listings_agent_live_idx, public.org_invites_accepted_member_idx,
--        public.team_private_libraries_agent_idx, public.apple_subscriptions_user_idx;
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $repair$
declare
 v_candidates constant text :=
   '(l.org_id=p_org or l.agent_id=any(array('
   || 'select m.user_id from public.memberships m where m.org_id=p_org and m.role=''owner'' '
   || 'union select s.beneficiary_user_id from public.private_internal_testing_sponsorships s where s.private_org_id=p_org and s.revoked_at is null)))';
 v_stray bigint;
 target record;
 d text; before_meta jsonb; hits integer; applied integer := 0;
begin
 -- The proof above reads these three bodies. If one changed, re-derive the
 -- candidate set before applying.
 for target in select * from (values
   ('public.listing_owner_library(uuid)', '14b71d616f49eb0a34c164265703faf8'),
   ('public.agent_private_library(uuid)', '1b9a6370cf3db205f1b30961f066cd26'),
   ('public.resolve_actor_owned_library(uuid,boolean)', '6a167cb9808ec858d158946e6825bf71')) as t(sig, md5) loop
  if (select md5(prosrc) from pg_proc where oid = target.sig::regprocedure) is distinct from target.md5 then
   raise exception '% changed since 2026-11-12; re-derive the listing candidate set before applying', target.sig;
  end if;
 end loop;

 -- Re-prove it on the rows that exist now: one pass over the live listings.
 select count(*) into v_stray
 from (select l.org_id, l.agent_id, public.listing_owner_library(l.id) as library
       from public.listings l where l.deleted_at is null) x
 where x.library is not null
   and not (x.org_id = x.library or x.agent_id = any(array(
     select m.user_id from public.memberships m where m.org_id = x.library and m.role = 'owner'
     union select s.beneficiary_user_id from public.private_internal_testing_sponsorships s
       where s.private_org_id = x.library and s.revoked_at is null)));
 if v_stray <> 0 then
  raise exception '% live listing(s) belong to a library outside the candidate set; not applying', v_stray;
 end if;

 for target in select * from (values
   ('public.list_library_listings(uuid,uuid,integer,integer)', '08a8cc38d3c4d9dca50c767ba2f1060e',
    'from public.listings l where l.deleted_at is null and public.listing_owner_library(l.id)=p_org and ', 2),
   ('public.library_listing_ids(uuid,uuid)', 'd73a4e8eac5a8019cc85358b5593bcc2',
    'from public.listings l where public.listing_owner_library(l.id)=p_org and ', 1)) as t(sig, md5, needle, expected) loop
  select to_jsonb(p) - 'prosrc' - 'prosqlbody', pg_get_functiondef(p.oid) into before_meta, d
    from pg_proc p where p.oid = target.sig::regprocedure;
  if position(v_candidates in d) > 0 then
   raise notice '% already filters by candidate listings; left as is', target.sig;
   continue;
  end if;
  if (select md5(prosrc) from pg_proc where oid = target.sig::regprocedure) is distinct from target.md5 then
   raise exception '% changed since 2026-11-12; review the candidate filter before applying', target.sig;
  end if;
  hits := (length(d) - length(replace(d, target.needle, ''))) / length(target.needle);
  if hits <> target.expected then
   raise exception '% listing seam found % time(s), expected %', target.sig, hits, target.expected;
  end if;
  -- "... where [l.deleted_at is null and ]<candidates> and listing_owner_library(l.id)=p_org and ..."
  execute replace(d, target.needle,
    replace(target.needle, 'public.listing_owner_library(l.id)=p_org and ',
      v_candidates || ' and public.listing_owner_library(l.id)=p_org and '));
  if (select to_jsonb(p) - 'prosrc' - 'prosqlbody' from pg_proc p where p.oid = target.sig::regprocedure) is distinct from before_meta then
   raise exception '% metadata changed', target.sig;
  end if;
  applied := applied + 1;
 end loop;
 raise notice 'candidate listing filter applied to % function(s)', applied;
end
$repair$;

-- Reach a library's listings by index.
create index if not exists listings_agent_live_idx on public.listings using btree (agent_id) where deleted_at is null;
-- listing_owner_library(): "was this agent invited into the listing's org".
create index if not exists org_invites_accepted_member_idx on public.org_invites using btree (org_id, accepted_by) where accepted_at is not null;
-- agent_private_library(): reads an agent's bindings in any revocation state,
-- which the existing live-only partial index cannot serve.
create index if not exists team_private_libraries_agent_idx on public.team_private_libraries using btree (agent_user_id);
-- GET /me "no active Apple chain" asks by org, account token or user; user_id
-- had no index (also the advisor's unindexed foreign key).
create index if not exists apple_subscriptions_user_idx on public.apple_subscriptions using btree (user_id);

-- auth.uid() once per statement instead of once per row. Only the two
-- policies still written the old way are touched, and only if they still read
-- exactly as they did on 2026-11-12.
do $policies$
declare q text; c text;
begin
 select qual, with_check into q, c from pg_policies
  where schemaname = 'public' and tablename = 'profiles' and policyname = 'own profile';
 if q = '(id = auth.uid())' and c = '(id = auth.uid())' then
  alter policy "own profile" on public.profiles using (id = (select auth.uid())) with check (id = (select auth.uid()));
 else
  raise notice 'policy "own profile" is not in its 2026-11-12 form (using %, check %); left as is', q, c;
 end if;
 select qual, with_check into q, c from pg_policies
  where schemaname = 'public' and tablename = 'memberships' and policyname = 'own memberships';
 if q = '(user_id = auth.uid())' and c is null then
  alter policy "own memberships" on public.memberships using (user_id = (select auth.uid()));
 else
  raise notice 'policy "own memberships" is not in its 2026-11-12 form (using %, check %); left as is', q, c;
 end if;
end
$policies$;
commit;
