-- KIE-REVOKE-TEST-GRANT.sql: revoke one owner-only Kie quality-test grant
-- (public.property_video_kie_test_grants), and optionally switch the pinned Kie
-- route row OFF in the same transaction. OPERATOR STEP, never a migration.
--
-- Effect: the grant is stamped revoked_at/revoked_reason (one-way; the grant's
-- guard keeps scope immutable and usage append-only). From this commit on,
-- public.property_video_kie_dispatch_authority refuses every attempt that has
-- not already consumed its create ("The owner quality-test permission has
-- ended. No new clip was sent.") and grant-scoped admissions refuse. An attempt
-- that consumed its create before this commit keeps it (the authority replays
-- it idempotently; it was counted). Accepted Kie tasks stay pollable and
-- retained: polling and every read path never consult the grant.
--
-- Optional -v route_off=on also switches the pinned row
-- 7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21 OFF, but only when all of these hold
-- (otherwise the whole run refuses with the exact reason and changes nothing;
-- rerun without route_off to revoke only):
--   * the selector does not select Kie (the activated profile needs the row);
--   * no other grant can still create (not revoked, not expired,
--     creates_used < max_creates);
--   * no admitted Kie job is draining (not cancelled, before its deadline, in
--     queued/generating/quality_review/composing/failed). To stop a drain's
--     unsent clips too, revoke first and then run KIE-ROUTE-OFF.sql.
-- The route-window record app_config.property_video_kie_test_window is kept as
-- written (an audit record no gate reads).
--
-- Variables:
--   grant_id               the grant id (canonical lowercase uuid), required
--   expected_grant_sha256  digest of to_jsonb(grant row), computed in UTC, as
--                          KIE-READONLY-VERIFY.sql (kie_test_grants[].sha256) or
--                          KIE-OWNER-TEST-GRANT.sql printed it, required
--   revoke_reason          1 to 200 printable ASCII characters (0x20-0x7E),
--                          required, saved as revoked_reason
--   route_off              on or off (default off)
--   expected_route_enabled required with route_off=on and then exactly true;
--                          optional otherwise (true or false, compared when given)
-- A digest is encode(sha256(convert_to(value::text,'UTF8')),'hex'): 64 lowercase
-- hex characters.
-- Run exactly as (-X: no psqlrc can change the session), as the role that
-- applies migrations:
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -1 -v grant_id='<uuid>' -v expected_grant_sha256='<sha256>' -v revoke_reason='<reason>' -f docs/handoff/KIE-REVOKE-TEST-GRANT.sql
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -1 -v grant_id='<uuid>' -v expected_grant_sha256='<sha256>' -v revoke_reason='<reason>' -v route_off=on -v expected_route_enabled=true -f docs/handoff/KIE-REVOKE-TEST-GRANT.sql
--
-- Refusals change nothing (and say so): a missing or malformed variable; a
-- missing grant; a grant row that is not exactly its baseline (it changed after
-- it was read, e.g. a create was consumed, or this revocation already ran and
-- its reply was lost: KIE-READONLY-VERIFY.sql then shows the true state); an
-- already revoked grant; with route_off=on, a route that is not ON as expected
-- or any of the conditions above.
-- On success it prints the new baselines,
--   NOTICE:  KIE-REVOKE-TEST-GRANT new baselines: grant_id=... expected_grant_sha256=... expected_route_enabled=...
-- and reads the grant and the row back.
--
-- One transaction. All work is one DO block, so it is all-or-nothing even
-- without -1. Lock order (every Kie operator script): the Kie operator-scripts
-- transaction advisory lock, then the selector row, then the pinned route row,
-- then the grant row. A dispatch authority call holds the grant row FOR UPDATE
-- and never waits for the selector or the route, and admission locks the
-- selector FOR SHARE first, so nothing can deadlock. Other grants are only
-- read: one that cannot create can never create again, and new grants come
-- only from KIE-OWNER-TEST-GRANT.sql, which waits for the same advisory lock.
-- Lock waits are bounded (lock_timeout 15 s); a timeout refuses and changes
-- nothing. It never touches the selector, any record, job, receipt, ledger or
-- other route.
\set ON_ERROR_STOP on

\if :{?grant_id}
\else
\set grant_id ''
\endif
\if :{?expected_grant_sha256}
\else
\set expected_grant_sha256 ''
\endif
\if :{?revoke_reason}
\else
\set revoke_reason ''
\endif
\if :{?route_off}
\else
\set route_off off
\endif
\if :{?expected_route_enabled}
\else
\set expected_route_enabled ''
\endif
-- Stamps and digests (to_jsonb of the grant row) in UTC; bounded lock waits.
set timezone = 'UTC';
set lock_timeout = '15s';
-- Hand the psql values to the DO block (psql does not interpolate inside it).
select set_config('rendprop.kie_revoke_grant_id',:'grant_id',false) as grant_id,
       set_config('rendprop.kie_revoke_expected_grant_sha256',:'expected_grant_sha256',false) as expected_grant_sha256,
       set_config('rendprop.kie_revoke_reason',:'revoke_reason',false) as revoke_reason,
       set_config('rendprop.kie_revoke_route_off',:'route_off',false) as route_off,
       set_config('rendprop.kie_revoke_expected_route_enabled',:'expected_route_enabled',false) as expected_route_enabled;

do $kie_revoke_test_grant$
declare
 v_grant_txt constant text:=current_setting('rendprop.kie_revoke_grant_id',true);
 v_expected_grant constant text:=current_setting('rendprop.kie_revoke_expected_grant_sha256',true);
 v_reason constant text:=current_setting('rendprop.kie_revoke_reason',true);
 v_route_off constant text:=current_setting('rendprop.kie_revoke_route_off',true);
 v_expected_route constant text:=current_setting('rendprop.kie_revoke_expected_route_enabled',true);
 v_grant_id uuid;
 v_selector jsonb;
 v_route_on boolean;
 v_route_found boolean;
 v_grant public.property_video_kie_test_grants;
 v_grant_sha text;
 v_other_live text;
 v_draining bigint;
 v_drain_ends timestamptz;
 v_grant_draining bigint;
 v_unsent_jobs bigint;
 v_unsent_clips bigint;
 v_pollable bigint;
begin
 -- 0. Every input, before any lock.
 if coalesce(v_grant_txt,'') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
  raise exception 'KIE-REVOKE-TEST-GRANT refused: -v grant_id=... is required: the grant id as a canonical lowercase uuid; got "%". Nothing changed.',coalesce(v_grant_txt,'');
 end if;
 v_grant_id:=v_grant_txt::uuid;
 if coalesce(v_expected_grant,'') !~ '^[0-9a-f]{64}$' then
  raise exception 'KIE-REVOKE-TEST-GRANT refused: -v expected_grant_sha256=... is required: the sha256 (64 lowercase hex characters) of to_jsonb(grant row) as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(v_expected_grant,'');
 end if;
 if coalesce(v_reason,'') !~ '^[ -~]{1,200}$' then
  raise exception 'KIE-REVOKE-TEST-GRANT refused: -v revoke_reason=... is required: 1 to 200 printable ASCII characters (letters, digits, spaces and punctuation; no tabs, line breaks, control or non-ASCII characters); got % character(s). Nothing changed.',length(coalesce(v_reason,''));
 end if;
 if v_route_off is distinct from 'on' and v_route_off is distinct from 'off' then
  raise exception 'KIE-REVOKE-TEST-GRANT refused: route_off must be on or off, not "%". Nothing changed.',v_route_off;
 end if;
 if v_route_off='on' and coalesce(v_expected_route,'') is distinct from 'true' then
  raise exception 'KIE-REVOKE-TEST-GRANT refused: -v route_off=on needs -v expected_route_enabled=true (it only switches an ON pinned row OFF); got "%". Nothing changed.',coalesce(v_expected_route,'');
 end if;
 if coalesce(v_expected_route,'') not in ('','true','false') then
  raise exception 'KIE-REVOKE-TEST-GRANT refused: expected_route_enabled must be true or false when given; got "%". Nothing changed.',v_expected_route;
 end if;
 -- A row hidden by row level security would be missed: refuse instead.
 if not coalesce((select bool_and(not c.relrowsecurity or r.rolsuper or r.rolbypassrls or (c.relowner=r.oid and not c.relforcerowsecurity))
                    from pg_class c cross join pg_roles r
                   where r.rolname=current_user
                     and c.oid in ('public.app_config'::regclass,'public.ai_routes'::regclass,'public.property_video_jobs'::regclass,
                                   'public.property_video_job_sources'::regclass,'public.property_video_kie_test_grants'::regclass)),false) then
  raise exception 'KIE-REVOKE-TEST-GRANT refused: role % may not see every row it reads (row level security); run it as the role that applies migrations. Nothing changed.',current_user;
 end if;
 -- Operator scripts never interleave.
 perform pg_advisory_xact_lock(hashtextextended('rendprop:kie-operator-scripts',0));
 -- 1. Selector, then 2. the pinned route row, in the common lock order (both
 -- only read unless route_off=on switches the row OFF).
 select value into v_selector from public.app_config where key='property_video_quality' for update;
 select enabled into v_route_on from public.ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21' for update;
 v_route_found:=found;
 if coalesce(v_expected_route,'')<>'' and (not v_route_found or v_route_on::text is distinct from v_expected_route) then
  raise exception 'KIE-REVOKE-TEST-GRANT refused: the pinned Kie route is % but -v expected_route_enabled=%: it changed after it was read, or this run already happened and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   case when v_route_found then 'enabled='||v_route_on::text else 'missing' end,v_expected_route;
 end if;
 -- 3. The grant row last: exactly the expected baseline, not yet revoked.
 select * into v_grant from public.property_video_kie_test_grants where id=v_grant_id for update;
 if not found then
  raise exception 'KIE-REVOKE-TEST-GRANT refused: owner-test grant % does not exist. Nothing changed.',v_grant_id;
 end if;
 v_grant_sha:=encode(sha256(convert_to(to_jsonb(v_grant)::text,'UTF8')),'hex');
 if v_grant_sha is distinct from v_expected_grant then
  raise exception 'KIE-REVOKE-TEST-GRANT refused: grant % is not the expected baseline (expected %, found %; creates %/%, revoked %): it changed after it was read (a create was consumed, or this revocation already ran and its reply was lost). Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   v_grant_id,v_expected_grant,v_grant_sha,v_grant.creates_used,v_grant.max_creates,coalesce(v_grant.revoked_at::text,'no');
 end if;
 if v_grant.revoked_at is not null then
  raise exception 'KIE-REVOKE-TEST-GRANT refused: grant % was already revoked at %. Nothing changed.',v_grant_id,v_grant.revoked_at;
 end if;
 select count(*),max(deadline) into v_draining,v_drain_ends from public.property_video_jobs
  where quality_profile='kie-kling3-4k-steady-v1' and state in('queued','generating','quality_review','composing','failed')
    and cancelled_at is null and deadline>now();
 -- route_off=on: only when nothing still needs the pinned row.
 if v_route_off='on' then
  if coalesce(jsonb_typeof(v_selector)='object' and v_selector->'enabled'='true'::jsonb and v_selector->>'profile'='kie-kling3-4k-steady-v1'
     and v_selector->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack',false) then
   raise exception 'KIE-REVOKE-TEST-GRANT refused: route_off=on, but property_video_quality selects Kie (%), so the activated profile needs the pinned row (KIE-ROLLBACK.sql -v emergency_stop=on stops it). Rerun without route_off to revoke only. Nothing changed.',v_selector::text;
  end if;
  select string_agg(id::text,', ' order by id) into v_other_live from public.property_video_kie_test_grants
   where id<>v_grant_id and revoked_at is null and expires_at>now() and creates_used<max_creates;
  if v_other_live is not null then
   raise exception 'KIE-REVOKE-TEST-GRANT refused: route_off=on, but other owner-test grant(s) % can still create. Revoke them too, or rerun without route_off to revoke only. Nothing changed.',v_other_live;
  end if;
  if v_draining>0 then
   raise exception 'KIE-REVOKE-TEST-GRANT refused: route_off=on, but % admitted Kie job(s) are still draining (until %). Rerun without route_off to revoke only; then KIE-ROUTE-OFF.sql switches the row OFF (their unsent clips then refuse) or wait for the drain. Nothing changed.',v_draining,v_drain_ends;
  end if;
 end if;
 -- 4. Revoke (one-way), then, with route_off=on, switch only the pinned row OFF.
 update public.property_video_kie_test_grants set revoked_at=now(),revoked_reason=v_reason where id=v_grant_id returning * into v_grant;
 if v_route_off='on' then
  update public.ai_routes set enabled=false,updated_at=now() where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';
 end if;
 select count(*) into v_grant_draining from public.property_video_jobs
  where kie_test_grant_id=v_grant_id and quality_profile='kie-kling3-4k-steady-v1'
    and state in('queued','generating','quality_review','composing','failed') and cancelled_at is null and deadline>now();
 select count(distinct s.job_id),count(*) into v_unsent_jobs,v_unsent_clips
   from public.property_video_job_sources s join public.property_video_jobs j on j.id=s.job_id
  where j.kie_test_grant_id=v_grant_id and j.state in('queued','generating','quality_review','composing','failed')
    and j.cancelled_at is null and j.deadline>now()
    and s.receipt is null and s.state in('pending','dispatching','failed');
 select count(*) into v_pollable
   from public.property_video_job_sources s join public.property_video_jobs j on j.id=s.job_id
  where j.kie_test_grant_id=v_grant_id and s.receipt is not null and s.state='processing' and s.clip is null;
 raise notice 'KIE-REVOKE-TEST-GRANT done: grant % revoked (creates %/%, cents %/%); % admitted job(s) under it can still be granted work or resumed, % of them with % saved clip(s) without a supplier receipt that now refuse before any create; % accepted Kie task(s) under it stay pollable; pinned Kie route %',
  v_grant_id,v_grant.creates_used,v_grant.max_creates,v_grant.cents_used,v_grant.max_cents,v_grant_draining,v_unsent_jobs,v_unsent_clips,v_pollable,
  case when v_route_off='on' then 'switched OFF' when not v_route_found then 'missing' when v_route_on then 'left ON' else 'left OFF' end;
 raise notice 'KIE-REVOKE-TEST-GRANT new baselines: grant_id=% expected_grant_sha256=% expected_route_enabled=%',
  v_grant_id,encode(sha256(convert_to(to_jsonb(v_grant)::text,'UTF8')),'hex'),
  case when v_route_off='on' then 'false' when not v_route_found then 'missing' else v_route_on::text end;
end
$kie_revoke_test_grant$;

-- Read the grant and the pinned row back as dispatch will see them once this
-- transaction commits, with the digests the next operation takes as baselines.
select g.id as grant_id,g.revoked_at,g.creates_used||'/'||g.max_creates as creates,g.cents_used||'/'||g.max_cents as cents,g.expires_at,
       encode(sha256(convert_to(to_jsonb(g)::text,'UTF8')),'hex') as grant_sha256,
       r.enabled as kie_route_enabled
  from public.property_video_kie_test_grants g
  left join public.ai_routes r on r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'
 where g.id::text=current_setting('rendprop.kie_revoke_grant_id');
