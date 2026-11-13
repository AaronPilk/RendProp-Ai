-- KIE-ROUTE-OFF.sql: stop new Kie createTask calls by switching ONLY the pinned
-- Kie route row 7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21 OFF. OPERATOR STEP, never a
-- migration.
--
-- When: after a default KIE-ROLLBACK.sql once the drain is over (or earlier, to
-- stop the drain's unsent clips), during a new-admission hold, or after an
-- owner-test grant was revoked, expired or used up. It never changes the
-- selector, any record, job, receipt or grant.
-- Effect: the runtime sends a Kie clip only while that row is ON and exact, so
-- every later Kie create refuses before any provider request (never a FAL
-- substitute): an admitted Kie job's unsent clips and its owner resume quote
-- refuse while the row is OFF. A create whose runtime route read happened
-- before this commit can still be sent; every later read sees the row OFF.
-- Accepted Kie tasks (a supplier receipt is saved) stay pollable and retained:
-- polling never reads the pinned row.
--
-- Refusals change nothing (and say so):
--   * expected_route_enabled is not exactly true, or the row is not ON (this
--     script only switches an ON row OFF; a rerun after a lost reply refuses
--     here);
--   * expected_selector_sha256 missing, malformed or not exactly the current
--     selector;
--   * the selector selects Kie (the rule property_video_quality_profile()
--     applies, extra keys included): the activated profile needs the row; use
--     KIE-ROLLBACK.sql -v emergency_stop=on, which restores the recorded
--     selector and switches the row OFF together;
--   * an owner-test grant can still create (not revoked, not expired,
--     creates_used < max_creates): revoke it first with
--     KIE-REVOKE-TEST-GRANT.sql;
--   * the pinned row is missing.
-- Admitted Kie jobs that are still draining do NOT refuse it: it prints how
-- many could still be granted work or resumed, how many of their saved clips
-- have no supplier receipt yet (pending, dispatching or failed without a
-- receipt: each refuses before any provider request while the row is OFF), and
-- how many accepted Kie tasks remain pollable (receipt saved, state processing,
-- no clip yet).
--
-- Baselines (both required), read with docs/handoff/KIE-READONLY-VERIFY.sql:
--   expected_route_enabled    must be true (state row kie_route_enabled)
--   expected_selector_sha256  digest of the current property_video_quality value,
--                             or absent (state row property_video_quality_sha256);
--                             any selector that does not select Kie is accepted,
--                             but only exactly as read
-- A digest is encode(sha256(convert_to(value::text,'UTF8')),'hex') of the stored
-- jsonb value (its canonical text): 64 lowercase hex characters.
-- Run exactly as (-X: no psqlrc can change the session), as the role that
-- applies migrations:
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -1 -v expected_route_enabled=true -v expected_selector_sha256='<sha256-or-absent>' -f docs/handoff/KIE-ROUTE-OFF.sql
-- On success it prints
--   NOTICE:  KIE-ROUTE-OFF new baselines: expected_route_enabled=false expected_selector_sha256=...
-- and reads the row back.
--
-- One transaction. All work is one DO block, so it is all-or-nothing even
-- without -1. Lock order (every Kie operator script): the Kie operator-scripts
-- transaction advisory lock, then the selector row, then the pinned route row.
-- Grant rows are only read: a grant that cannot create can never create again
-- (revocation, expiry and usage are one-way), and new grants come only from
-- KIE-OWNER-TEST-GRANT.sql, which waits for the same advisory lock. Admission
-- locks the selector FOR SHARE first, so it finishes before this script or
-- after it. Lock waits are bounded (lock_timeout 15 s); a timeout refuses and
-- changes nothing.
\set ON_ERROR_STOP on

\if :{?expected_route_enabled}
\else
\set expected_route_enabled ''
\endif
\if :{?expected_selector_sha256}
\else
\set expected_selector_sha256 ''
\endif
-- Digests in UTC; bounded lock waits.
set timezone = 'UTC';
set lock_timeout = '15s';
-- Hand the psql values to the DO block (psql does not interpolate inside it).
select set_config('rendprop.kie_route_off_expected_route_enabled',:'expected_route_enabled',false) as expected_route_enabled,
       set_config('rendprop.kie_route_off_expected_selector_sha256',:'expected_selector_sha256',false) as expected_selector_sha256;

do $kie_route_off$
declare
 v_expected_route constant text:=current_setting('rendprop.kie_route_off_expected_route_enabled',true);
 v_expected_selector constant text:=current_setting('rendprop.kie_route_off_expected_selector_sha256',true);
 v_selector jsonb;
 v_present boolean;
 v_selector_sha text;
 v_route_on boolean;
 v_live_grants text;
 v_draining bigint;
 v_unsent_jobs bigint;
 v_unsent_clips bigint;
 v_pollable bigint;
begin
 -- 0. Every input, before any lock.
 if coalesce(v_expected_route,'') is distinct from 'true' then
  raise exception 'KIE-ROUTE-OFF refused: -v expected_route_enabled=true is required (this script only switches an ON pinned row OFF; KIE-READONLY-VERIFY.sql prints kie_route_enabled); got "%". Nothing changed.',coalesce(v_expected_route,'');
 end if;
 if coalesce(v_expected_selector,'') !~ '^([0-9a-f]{64}|absent)$' then
  raise exception 'KIE-ROUTE-OFF refused: -v expected_selector_sha256=... is required: the sha256 (64 lowercase hex characters) of the current property_video_quality value, or the word absent, as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(v_expected_selector,'');
 end if;
 -- A row hidden by row level security would be missed: refuse instead.
 if not coalesce((select bool_and(not c.relrowsecurity or r.rolsuper or r.rolbypassrls or (c.relowner=r.oid and not c.relforcerowsecurity))
                    from pg_class c cross join pg_roles r
                   where r.rolname=current_user
                     and c.oid in ('public.app_config'::regclass,'public.ai_routes'::regclass,'public.property_video_jobs'::regclass,
                                   'public.property_video_job_sources'::regclass,'public.property_video_kie_test_grants'::regclass)),false) then
  raise exception 'KIE-ROUTE-OFF refused: role % may not see every row it reads (row level security); run it as the role that applies migrations. Nothing changed.',current_user;
 end if;
 -- Operator scripts never interleave.
 perform pg_advisory_xact_lock(hashtextextended('rendprop:kie-operator-scripts',0));
 -- 1. Selector first (admission's lock order): exactly as read, and not Kie.
 select value into v_selector from public.app_config where key='property_video_quality' for update;
 v_present:=found;
 v_selector_sha:=case when v_present then encode(sha256(convert_to(v_selector::text,'UTF8')),'hex') else 'absent' end;
 if v_selector_sha is distinct from v_expected_selector then
  raise exception 'KIE-ROUTE-OFF refused: property_video_quality is not the expected baseline (expected %, found % = %): it changed after it was read. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   v_expected_selector,v_selector_sha,case when v_present then v_selector::text else 'absent' end;
 end if;
 if v_present and coalesce(jsonb_typeof(v_selector)='object' and v_selector->'enabled'='true'::jsonb
   and v_selector->>'profile'='kie-kling3-4k-steady-v1'
   and v_selector->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack',false) then
  raise exception 'KIE-ROUTE-OFF refused: property_video_quality selects Kie (%), so the activated profile needs the pinned row. Use KIE-ROLLBACK.sql -v emergency_stop=on: it restores the recorded selector and switches the row OFF together. Nothing changed.',v_selector::text;
 end if;
 -- 2. The pinned route row: ON, exactly as expected.
 select enabled into v_route_on from public.ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21' for update;
 if not found then
  raise exception 'KIE-ROUTE-OFF refused: the pinned Kie route row 7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21 is missing. Nothing changed.';
 end if;
 if not v_route_on then
  raise exception 'KIE-ROUTE-OFF refused: the pinned Kie route is already OFF (expected ON): nothing to switch, or this run already happened and its reply was lost. Nothing changed; KIE-READONLY-VERIFY.sql shows the true state.';
 end if;
 -- 3. No owner-test grant may still be able to create.
 select string_agg(id::text,', ' order by id) into v_live_grants from public.property_video_kie_test_grants
  where revoked_at is null and expires_at>now() and creates_used<max_creates;
 if v_live_grants is not null then
  raise exception 'KIE-ROUTE-OFF refused: owner-test grant(s) % can still create; revoke them first with KIE-REVOKE-TEST-GRANT.sql (its -v route_off=on can also switch the row OFF). Nothing changed.',v_live_grants;
 end if;
 -- 4. Switch only the pinned row OFF.
 update public.ai_routes set enabled=false,updated_at=now() where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';
 select count(*) into v_draining from public.property_video_jobs
  where quality_profile='kie-kling3-4k-steady-v1' and state in('queued','generating','quality_review','composing','failed')
    and cancelled_at is null and deadline>now();
 select count(distinct s.job_id),count(*) into v_unsent_jobs,v_unsent_clips
   from public.property_video_job_sources s join public.property_video_jobs j on j.id=s.job_id
  where j.quality_profile='kie-kling3-4k-steady-v1' and j.state in('queued','generating','quality_review','composing','failed')
    and j.cancelled_at is null and j.deadline>now()
    and s.receipt is null and s.state in('pending','dispatching','failed');
 select count(*) into v_pollable
   from public.property_video_job_sources s join public.property_video_jobs j on j.id=s.job_id
  where j.quality_profile='kie-kling3-4k-steady-v1' and s.receipt is not null and s.state='processing' and s.clip is null;
 raise notice 'KIE-ROUTE-OFF done: pinned Kie route switched OFF; property_video_quality unchanged (%); % admitted Kie job(s) could still be granted work or resumed; % of them have % saved clip(s) without a supplier receipt, which now refuse before any provider request; % accepted Kie task(s) stay pollable',
  case when v_present then v_selector::text else 'absent' end,v_draining,v_unsent_jobs,v_unsent_clips,v_pollable;
 raise notice 'KIE-ROUTE-OFF new baselines: expected_route_enabled=false expected_selector_sha256=%',v_selector_sha;
end
$kie_route_off$;

-- Read the row back as the runtime will see it once this transaction commits.
select r.id as kie_route_id,r.enabled as kie_route_enabled,
       coalesce(c.value::text,'absent') as property_video_quality,
       coalesce(encode(sha256(convert_to(c.value::text,'UTF8')),'hex'),'absent') as property_video_quality_sha256
  from public.ai_routes r
  left join public.app_config c on c.key='property_video_quality'
 where r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';
