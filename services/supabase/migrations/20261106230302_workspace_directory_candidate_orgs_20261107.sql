-- workspace_directory: evaluate access only for the orgs the actor could
-- possibly reach, not for every org in the system.
--
-- The switcher was built with
--   from public.orgs o where o.deleted_at is null and library_content_access(p_user,o.id,false)
-- i.e. one access evaluation per org that exists, on nearly every request
-- (~30k calls/day). 47 orgs today; it would be 100k evaluations per request
-- at 100k users. library_content_access(actor, org) can only be true when
-- actor is a member of org, or library_team_owner(org) = actor, and
-- library_team_owner returns team_private_libraries.team_owner_user_id or
-- private_internal_testing_sponsorships.sponsor_owner_user_id for that org
-- (revoked rows are excluded by the chain). So the candidate set
--   memberships(user) ∪ team libraries owned by user ∪ sponsorships owned by user
-- is complete, and filtering orgs to it changes nothing in the result.
-- Verified on production in a rolled-back dry run (byte-identical directories
-- for every user that has a membership, before vs after).
--
-- Also adds the four indexes the access chain lacks at scale: memberships by
-- org, deletion_requests by user (pending/processing), and the two owner
-- lookups used by the candidate set.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $repair$
declare d text; needle text; replacement text; before_meta jsonb; target regprocedure;
begin
 target := 'public.workspace_directory(uuid,uuid)'::regprocedure;
 if (select md5(prosrc) from pg_proc where oid = target) is distinct from '746cc680332190d8338147f67308ce22' then
  raise exception 'workspace_directory changed since 2026-11-06; review the candidate-org rewrite before applying';
 end if;
 select to_jsonb(p) - 'prosrc' - 'prosqlbody', pg_get_functiondef(p.oid) into before_meta, d from pg_proc p where p.oid = target;
 needle := 'from public.orgs o where o.deleted_at is null and public.library_content_access(p_user,o.id,false);';
 replacement := 'from public.orgs o where o.deleted_at is null and o.id in ('
   || 'select m.org_id from public.memberships m where m.user_id=p_user '
   || 'union select b.private_org_id from public.team_private_libraries b where b.team_owner_user_id=p_user and b.revoked_at is null '
   || 'union select s.private_org_id from public.private_internal_testing_sponsorships s where s.sponsor_owner_user_id=p_user and s.revoked_at is null'
   || ') and public.library_content_access(p_user,o.id,false);';
 if length(d) - length(replace(d, needle, '')) <> length(needle) then
  raise exception 'workspace_directory switcher seam not found exactly once';
 end if;
 execute replace(d, needle, replacement);
 if (select to_jsonb(p) - 'prosrc' - 'prosqlbody' from pg_proc p where p.oid = target) is distinct from before_meta then
  raise exception 'workspace_directory metadata changed';
 end if;
end
$repair$;

create index if not exists memberships_org_role_idx on public.memberships using btree (org_id, role);
create index if not exists deletion_requests_user_open_idx on public.deletion_requests using btree (user_id) where status in ('pending', 'processing');
create index if not exists team_private_library_live_owner_user on public.team_private_libraries using btree (team_owner_user_id) where revoked_at is null;
create index if not exists private_internal_testing_live_sponsor_owner on public.private_internal_testing_sponsorships using btree (sponsor_owner_user_id) where revoked_at is null;
commit;
