-- KIE-ROLLBACK.sql: undo docs/handoff/KIE-ACTIVATION.sql for NEW property-video
-- admissions by restoring exactly the selector value saved in the current
-- activation record. OPERATOR STEP, never a migration.
--
-- What it is, and is not: a rollback to the recorded pre-Kie selector (FAL,
-- legacy, or the key deleted again when it was absent). New admissions continue
-- at once on that restored profile, so it is NOT a stop of new paid videos. To
-- stop every new paid property-video admission without switching to FAL use
-- docs/handoff/KIE-HOLD-NEW-ADMISSIONS.sql; to stop new Kie createTask calls
-- once the selector no longer selects Kie use docs/handoff/KIE-ROUTE-OFF.sql.
--
-- Restore target: ONLY app_config.property_video_quality_kie_activation as
-- KIE-ACTIVATION.sql saved it. Its previous_selector is the exact
-- property_video_quality value before activation, or {"present":false} when the
-- key did not exist (the key is then deleted again). The record must be current
-- (not rolled back) and well-formed (every field KIE-ACTIVATION.sql writes,
-- nothing else). A missing or unusable record is a refusal with instructions,
-- never permission to guess: no default and no operator-supplied value is ever
-- restored. The old -v previous override is gone; supplying it refuses.
--
-- Baselines (all three required), read with docs/handoff/KIE-READONLY-VERIFY.sql
-- or taken from the NOTICE "KIE-ACTIVATION new baselines" the activation printed:
--   expected_selector_sha256  digest of the current property_video_quality value
--                             (it must name the Kie profile)
--   expected_route_enabled    true or false: the pinned row's current enabled
--   expected_record_sha256    digest of the current activation record
-- A digest is encode(sha256(convert_to(value::text,'UTF8')),'hex') of the stored
-- jsonb value (its canonical text): 64 lowercase hex characters.
--
-- DEFAULT: restore the saved selector only. Nothing new is admitted on Kie;
-- work already admitted on Kie can finish.
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -1 -v expected_selector_sha256='<sha256>' -v expected_route_enabled='<true-or-false>' -v expected_record_sha256='<sha256>' -f docs/handoff/KIE-ROLLBACK.sql
-- New admissions use the restored profile at once and a stale Kie quote
-- refuses (RP409) with no job. Pinned ai_routes row
-- 7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21 stays as it is (ON after activation):
-- jobs already admitted on kie-kling3-4k-steady-v1 keep their immutable frozen
-- quality_profile/quality_identity and their bounded paid-quality allowance
-- floor (migration 20261016110000), and can still send their unsent clips (the
-- runtime sends a Kie clip only while that row is ON and exact).
-- The readback prints kie_jobs_draining: saved Kie jobs that may still need
-- the pinned row: not cancelled, before the 24 h deadline set at admission
-- (never extended), and in a state from which Kie work can still be granted
-- (queued, generating, quality_review, composing: the worker scope test
-- property_video_job_scope(p_active=>true) applies before every dispatch) or
-- resumed by the owner (failed: a capacity, quality or CPU pause, resumable
-- only before the deadline; the resume quote reads the pinned row). ready,
-- cancelled and needs_reconciliation are final: no function moves a job out
-- of them. kie_drain_ends_by is their latest deadline. The database invariant
-- 'every kie / higgsfield row is disabled and assumes trains_by_default'
-- accepts the ON row after a rollback only while that count is above zero (or
-- an owner-test grant can still create); it reaches zero 24 h after the last
-- Kie admission at the latest. Then switch the row OFF with
-- docs/handoff/KIE-ROUTE-OFF.sql. The same count at any time, read-only (or
-- docs/handoff/KIE-READONLY-VERIFY.sql):
--   select count(*) as kie_jobs_draining, max(deadline) as kie_drain_ends_by
--     from public.property_video_jobs
--    where quality_profile='kie-kling3-4k-steady-v1'
--      and state in('queued','generating','quality_review','composing','failed')
--      and cancelled_at is null and deadline>now();
-- A failed (paused) Kie job is counted until its deadline: switching the row
-- OFF earlier would leave it unresumable (its resume quote and its unsent
-- clips refuse before any provider request while the row is OFF).
--
-- EMERGENCY: restore the saved selector AND switch the pinned row OFF, now.
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -1 -v expected_selector_sha256='<sha256>' -v expected_route_enabled='<true-or-false>' -v expected_record_sha256='<sha256>' -v emergency_stop=on -f docs/handoff/KIE-ROLLBACK.sql
-- Pending unsent Kie clips then refuse before any provider request (never a
-- FAL substitute); accepted Kie tasks stay pollable (polling never reads the
-- pinned row). A Kie create whose runtime route read happened before this
-- commit can still be sent; every later read sees the row OFF.
--
-- Refusals change nothing (and say so): -v previous supplied; emergency_stop
-- not on/off; a missing or malformed baseline; a selector, route or record that
-- is not exactly its baseline (it changed after it was read, or this rollback
-- already ran and its reply was lost: KIE-READONLY-VERIFY.sql then shows the
-- true state); a selector that does not name the Kie profile (nothing to roll
-- back: KIE-ROUTE-OFF.sql switches the row OFF; while a new-admission hold
-- replaces an activated Kie selector, run KIE-ROUTE-OFF.sql, then
-- KIE-RELEASE-HOLD.sql, then this script, so Kie never admits in between); a
-- missing, malformed or already rolled back activation record (see the
-- refusal for what to do: hold new admissions, then switch the row OFF).
--
-- Audit: the record is kept and stamped: rolled_back_at and rollback_mode
-- (default or emergency), and route_disabled_at when this run switches the row
-- OFF. A later KIE-ACTIVATION.sql replaces the whole record. On success it
-- prints the baselines the next operation needs,
--   NOTICE:  KIE-ROLLBACK new baselines: expected_selector_sha256=... expected_route_enabled=... expected_record_sha256=...
-- and reads them back.
--
-- One transaction. All work is one DO block, so it is all-or-nothing even
-- without -1. Lock order (every Kie operator script): one transaction advisory
-- lock shared only by the Kie operator scripts (a rollback started during an
-- activation waits for it, even while the selector key is absent), then the
-- selector row, then the pinned route row, then the activation record, which no
-- admission locks. Admission locks the selector FOR SHARE, then an owner-test
-- grant FOR UPDATE, then the route FOR SHARE, so a rollback waits for an
-- in-flight admission and cannot deadlock with it. Lock waits are bounded
-- (lock_timeout 15 s); a timeout refuses and changes nothing. Like any value of
-- this selector, the restored one also decides the selector-based part of
-- paid_quality_processing_budget. It never touches saved jobs, receipts, holds,
-- ledgers, prices, allowances, grants, the FAL route, any other route or any
-- config key other than property_video_quality and its activation record.
\set ON_ERROR_STOP on

\if :{?emergency_stop}
\else
\set emergency_stop off
\endif
\if :{?previous}
\set previous_supplied on
\else
\set previous_supplied off
\endif
\if :{?expected_selector_sha256}
\else
\set expected_selector_sha256 ''
\endif
\if :{?expected_route_enabled}
\else
\set expected_route_enabled ''
\endif
\if :{?expected_record_sha256}
\else
\set expected_record_sha256 ''
\endif
-- Stamps and digests in UTC; bounded lock waits.
set timezone = 'UTC';
set lock_timeout = '15s';
-- Hand the psql values to the DO block (psql does not interpolate inside it).
select set_config('rendprop.kie_rollback_previous_supplied',:'previous_supplied',false) as previous_supplied,
       set_config('rendprop.kie_rollback_emergency_stop',:'emergency_stop',false) as emergency_stop,
       set_config('rendprop.kie_rollback_expected_selector_sha256',:'expected_selector_sha256',false) as expected_selector_sha256,
       set_config('rendprop.kie_rollback_expected_route_enabled',:'expected_route_enabled',false) as expected_route_enabled,
       set_config('rendprop.kie_rollback_expected_record_sha256',:'expected_record_sha256',false) as expected_record_sha256;

do $kie_rollback$
declare
 kie_profile constant text:='kie-kling3-4k-steady-v1';
 pinned constant uuid:='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';
 previous_supplied constant boolean:=current_setting('rendprop.kie_rollback_previous_supplied')='on';
 emergency constant text:=current_setting('rendprop.kie_rollback_emergency_stop');
 expected_selector constant text:=current_setting('rendprop.kie_rollback_expected_selector_sha256',true);
 expected_route constant text:=current_setting('rendprop.kie_rollback_expected_route_enabled',true);
 expected_record constant text:=current_setting('rendprop.kie_rollback_expected_record_sha256',true);
 selector jsonb;   -- property_video_quality now
 present boolean;  -- the key exists
 selector_sha text;
 route_on boolean;
 activation jsonb; -- the activation record, null when the key is absent
 record_sha text;
 usable boolean;   -- the record is a current, well-formed KIE-ACTIVATION.sql record
 target jsonb;     -- its previous_selector: {"present":true,"value":...} or {"present":false}
 stamped jsonb;
 draining bigint;
begin
 -- 0. Every input, before any lock.
 if previous_supplied then
  raise exception 'KIE-ROLLBACK refused: -v previous was removed. The rollback restores only the value saved in the current activation record, never a supplied or default value. Nothing changed.';
 end if;
 if emergency is distinct from 'on' and emergency is distinct from 'off' then
  raise exception 'KIE-ROLLBACK refused: emergency_stop must be on or off, not "%". Nothing changed.',emergency;
 end if;
 if coalesce(expected_selector,'') !~ '^[0-9a-f]{64}$' then
  raise exception 'KIE-ROLLBACK refused: -v expected_selector_sha256=... is required: the sha256 (64 lowercase hex characters) of the current property_video_quality value, which must name the Kie profile, as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(expected_selector,'');
 end if;
 if coalesce(expected_route,'') not in ('true','false') then
  raise exception 'KIE-ROLLBACK refused: -v expected_route_enabled=... is required: true or false, the pinned Kie route''s current enabled value as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(expected_route,'');
 end if;
 if coalesce(expected_record,'') !~ '^[0-9a-f]{64}$' then
  raise exception 'KIE-ROLLBACK refused: -v expected_record_sha256=... is required: the sha256 (64 lowercase hex characters) of the current activation record app_config.property_video_quality_kie_activation as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(expected_record,'');
 end if;
 -- A row hidden by row level security would read as absent: refuse instead.
 if not coalesce((select bool_and(not c.relrowsecurity or r.rolsuper or r.rolbypassrls or (c.relowner=r.oid and not c.relforcerowsecurity))
                    from pg_class c cross join pg_roles r
                   where r.rolname=current_user
                     and c.oid in ('public.app_config'::regclass,'public.ai_routes'::regclass,'public.property_video_jobs'::regclass)),false) then
  raise exception 'KIE-ROLLBACK refused: role % may not see every app_config/ai_routes/property_video_jobs row (row level security); run it as the role that applies migrations. Nothing changed.',current_user;
 end if;
 -- Operator scripts never interleave, even while there is no selector row to lock.
 perform pg_advisory_xact_lock(hashtextextended('rendprop:kie-operator-scripts',0));
 -- 1. Selector first (admission's lock order): exactly the expected baseline,
 -- and it must name the Kie profile.
 select value into selector from public.app_config where key='property_video_quality' for update;
 present:=found;
 selector_sha:=case when present then encode(sha256(convert_to(selector::text,'UTF8')),'hex') else 'absent' end;
 raise notice 'KIE-ROLLBACK current property_video_quality: %',case when present then selector::text else 'absent' end;
 if selector_sha is distinct from expected_selector then
  raise exception 'KIE-ROLLBACK refused: property_video_quality is not the expected baseline (expected %, found % = %): it changed after it was read, or this rollback already ran and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   expected_selector,selector_sha,case when present then selector::text else 'absent' end;
 end if;
 if present and coalesce(jsonb_typeof(selector)='object' and selector->>'profile'='hold-new-paid-admissions',false) then
  raise exception 'KIE-ROLLBACK refused: nothing to roll back while a new-admission hold is active (property_video_quality %): nothing new is admitted. If the hold replaced an activated Kie selector and Kie must be rolled back without admitting on it again, run KIE-ROUTE-OFF.sql, then KIE-RELEASE-HOLD.sql, then this script. Nothing changed.',selector::text;
 end if;
 if not present or selector->>'profile' is distinct from kie_profile then
  raise exception 'KIE-ROLLBACK refused: nothing to roll back: property_video_quality (%) does not name the Kie profile. Nothing changed. To switch the pinned Kie route OFF use docs/handoff/KIE-ROUTE-OFF.sql.',
   case when present then selector::text else 'absent' end;
 end if;
 -- 2. The pinned route row second (admission's order), exactly as expected.
 select enabled into route_on from public.ai_routes where id=pinned for update;
 if not found then
  raise exception 'KIE-ROLLBACK refused: the pinned Kie route row % is missing. Nothing changed.',pinned;
 end if;
 if route_on::text is distinct from expected_route then
  raise exception 'KIE-ROLLBACK refused: the pinned Kie route is enabled=% but -v expected_route_enabled=%: it changed after it was read, or this rollback already ran and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   route_on::text,expected_route;
 end if;
 -- 3. The activation record last: exactly the expected baseline, current and
 -- well-formed (exactly the fields KIE-ACTIVATION.sql writes).
 select value into activation from public.app_config where key='property_video_quality_kie_activation' for update;
 record_sha:=case when found then encode(sha256(convert_to(activation::text,'UTF8')),'hex') else 'absent' end;
 if record_sha is distinct from expected_record then
  raise exception 'KIE-ROLLBACK refused: the activation record app_config.property_video_quality_kie_activation is not the expected baseline (expected %, found %): it changed after it was read, or this rollback already ran and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   expected_record,record_sha;
 end if;
 usable:=coalesce(case when jsonb_typeof(activation)='object' then
   activation ?& array['profile','route_id','previous_selector','route_enabled_before','processor_disclosure','consent_disclosure_revision',
                       'vendor_content_license','activated_at','rolled_back_at','rollback_mode','route_disabled_at']
   and activation - array['profile','route_id','previous_selector','route_enabled_before','processor_disclosure','consent_disclosure_revision',
                          'vendor_content_license','activated_at','rolled_back_at','rollback_mode','route_disabled_at']='{}'::jsonb
   and activation->'profile'=to_jsonb(kie_profile) and activation->'route_id'=to_jsonb(pinned::text)
   and activation->'vendor_content_license'='"kie-terms-2025-08-01-section-3-owner-accepted"'::jsonb
   and jsonb_typeof(activation->'processor_disclosure')='string' and activation->>'processor_disclosure' ~ '^[!-~]{1,200}$'
   and jsonb_typeof(activation->'consent_disclosure_revision')='string' and activation->>'consent_disclosure_revision' ~ '^[!-~]{1,200}$'
   and jsonb_typeof(activation->'route_enabled_before')='boolean'
   and jsonb_typeof(activation->'activated_at')='string'
   and activation->'rolled_back_at'='null'::jsonb and activation->'rollback_mode'='null'::jsonb
   and jsonb_typeof(activation->'route_disabled_at') in ('null','string')
   and case when jsonb_typeof(activation->'previous_selector')='object' then
         activation->'previous_selector'='{"present":false}'::jsonb
         or ((activation->'previous_selector') ?& array['present','value']
             and (activation->'previous_selector') - array['present','value']='{}'::jsonb
             and activation#>'{previous_selector,present}'='true'::jsonb
             and case when jsonb_typeof(activation#>'{previous_selector,value}')='object' then
                   coalesce(activation#>>'{previous_selector,value,profile}','') not in (kie_profile,'hold-new-paid-admissions')
                   and (activation#>'{previous_selector,value,enabled}'='false'::jsonb
                        or (activation#>'{previous_selector,value,enabled}'='true'::jsonb
                            and activation#>>'{previous_selector,value,profile}' in ('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')))
                 else false end)
       else false end
  else false end,false);
 if not usable then
  raise exception 'KIE-ROLLBACK refused: property_video_quality names the Kie profile, but the activation record (%) is not a current, well-formed KIE-ACTIVATION.sql record (missing, malformed, or already rolled back), so nothing says exactly what to restore. Nothing changed; no value is ever guessed or supplied. To stop new paid admissions now run KIE-HOLD-NEW-ADMISSIONS.sql (its record keeps this exact selector), then KIE-ROUTE-OFF.sql to stop new Kie creates; restoring a FAL/legacy selector then needs a reviewed manual decision.',
   coalesce(activation::text,'missing');
 end if;
 target:=activation->'previous_selector';
 raise notice 'KIE-ROLLBACK restoring the value saved by KIE-ACTIVATION.sql (activated %): %',activation->>'activated_at',coalesce((target->'value')::text,'absent');
 -- Restore exactly the recorded value, or delete the key it did not have.
 if target->'present'='true'::jsonb then
  update public.app_config set value=target->'value',updated_at=now() where key='property_video_quality';
 else
  delete from public.app_config where key='property_video_quality';
 end if;
 -- EMERGENCY only: switch only the pinned Kie row OFF (after the selector row).
 if emergency='on' then
  update public.ai_routes set enabled=false,updated_at=now() where id=pinned;
 end if;
 -- The audit stamps; the record is kept.
 stamped:=activation||jsonb_build_object('rolled_back_at',now(),'rollback_mode',case when emergency='on' then 'emergency' else 'default' end)
                    ||case when emergency='on' and route_on then jsonb_build_object('route_disabled_at',now()) else '{}'::jsonb end;
 update public.app_config set value=stamped,updated_at=now() where key='property_video_quality_kie_activation';
 select count(*) into draining from public.property_video_jobs
  where quality_profile='kie-kling3-4k-steady-v1' and state in('queued','generating','quality_review','composing','failed')
    and cancelled_at is null and deadline>now();
 raise notice 'KIE-ROLLBACK done (%): property_video_quality = %; pinned Kie route %; % admitted Kie job(s) can still be granted work or resumed',
  case when emergency='on' then 'emergency stop' else 'default' end,
  coalesce((target->'value')::text,'absent'),
  case when emergency='on' and route_on then 'switched OFF' when emergency='on' then 'already OFF' else 'left as it was ('||case when route_on then 'ON' else 'OFF' end||')' end,
  draining;
 raise notice 'KIE-ROLLBACK new baselines: expected_selector_sha256=% expected_route_enabled=% expected_record_sha256=%',
  case when target->'present'='true'::jsonb then encode(sha256(convert_to((target->'value')::text,'UTF8')),'hex') else 'absent' end,
  case when emergency='on' then 'false' else route_on::text end,
  encode(sha256(convert_to(stamped::text,'UTF8')),'hex');
end
$kie_rollback$;

-- Read back what new admissions will see once this transaction commits, the
-- digests the next operation takes as its baselines, and whether admitted Kie
-- work is still draining (same test as the invariant).
select coalesce(c.value::text,'absent') as property_video_quality,
       coalesce(encode(sha256(convert_to(c.value::text,'UTF8')),'hex'),'absent') as property_video_quality_sha256,
       r.enabled as kie_route_enabled,
       d.kie_jobs_draining,
       d.kie_drain_ends_by,
       case when r.enabled is not true then 'done: the pinned Kie route is OFF'
            when d.kie_jobs_draining>0 then 'draining: once kie_jobs_draining is 0 (24 h after the last Kie admission at the latest) run KIE-ROUTE-OFF.sql'
            else 'drain over: run KIE-ROUTE-OFF.sql now to switch the pinned Kie route OFF (revoke any owner-test grant that can still create first)' end as next_step,
       coalesce(a.value::text,'none') as kie_activation_record,
       coalesce(encode(sha256(convert_to(a.value::text,'UTF8')),'hex'),'absent') as kie_activation_record_sha256
  from (select count(*) as kie_jobs_draining,max(deadline) as kie_drain_ends_by
          from public.property_video_jobs
         where quality_profile='kie-kling3-4k-steady-v1'
           and state in('queued','generating','quality_review','composing','failed')
           and cancelled_at is null and deadline>now()) d
  left join public.app_config c on c.key='property_video_quality'
  left join public.ai_routes r on r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'
  left join public.app_config a on a.key='property_video_quality_kie_activation';
