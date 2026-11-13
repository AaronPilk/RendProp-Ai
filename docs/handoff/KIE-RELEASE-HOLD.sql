-- KIE-RELEASE-HOLD.sql: release the new-admission hold that
-- docs/handoff/KIE-HOLD-NEW-ADMISSIONS.sql placed, by restoring exactly the
-- selector value its hold record saved. OPERATOR STEP, never a migration.
--
-- Restore target: ONLY app_config.property_video_quality_hold as
-- KIE-HOLD-NEW-ADMISSIONS.sql saved it: previous_selector is the exact
-- property_video_quality value before the hold, or {"present":false} when the
-- key did not exist (the key is then deleted again). The selector must still be
-- exactly that record's hold value
--   {"enabled":true,"profile":"hold-new-paid-admissions","hold_id":"<the record's hold_id>"}
-- and the record must be well-formed and not yet released. Nothing is ever
-- guessed: a missing, malformed or released record refuses.
-- New admissions use the restored selector at once. When it is the activated
-- Kie selector, Kie admissions resume only while the pinned row is ON (after
-- KIE-ROUTE-OFF.sql they refuse RP409 with no job, and KIE-ROLLBACK.sql then
-- restores the activation's recorded FAL/legacy selector); the NOTICE says which.
--
-- Baselines (both required), read with docs/handoff/KIE-READONLY-VERIFY.sql or
-- taken from the NOTICE "KIE-HOLD new baselines" the hold printed:
--   expected_selector_sha256     digest of the current property_video_quality
--                                value (the hold value)
--   expected_hold_record_sha256  digest of the current
--                                app_config.property_video_quality_hold value
-- A digest is encode(sha256(convert_to(value::text,'UTF8')),'hex') of the stored
-- jsonb value (its canonical text): 64 lowercase hex characters.
-- Run exactly as (-X: no psqlrc can change the session), as the role that
-- applies migrations:
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -1 -v expected_selector_sha256='<sha256>' -v expected_hold_record_sha256='<sha256>' -f docs/handoff/KIE-RELEASE-HOLD.sql
--
-- Refusals change nothing (and say so): a missing or malformed baseline; a
-- selector or hold record that is not exactly its baseline (it changed after it
-- was read, or this release already ran and its reply was lost:
-- KIE-READONLY-VERIFY.sql then shows the true state); a selector that is not the
-- record's exact hold value; a missing, malformed or already released record.
-- Audit: the record is kept and stamped released_at. On success it prints the
-- new baselines,
--   NOTICE:  KIE-RELEASE-HOLD new baselines: expected_selector_sha256=... expected_hold_record_sha256=...
-- and reads them back.
--
-- One transaction. All work is one DO block, so it is all-or-nothing even
-- without -1. Lock order (every Kie operator script): the Kie operator-scripts
-- transaction advisory lock, then the selector row, then the pinned route row
-- (locked, never changed here), then the hold record. Lock waits are bounded
-- (lock_timeout 15 s); a timeout refuses and changes nothing. It never touches
-- jobs, receipts, ledgers, prices, allowances, grants, any route or any other
-- config key.
\set ON_ERROR_STOP on

\if :{?expected_selector_sha256}
\else
\set expected_selector_sha256 ''
\endif
\if :{?expected_hold_record_sha256}
\else
\set expected_hold_record_sha256 ''
\endif
-- Stamps and digests in UTC; bounded lock waits.
set timezone = 'UTC';
set lock_timeout = '15s';
-- Hand the psql values to the DO block (psql does not interpolate inside it).
select set_config('rendprop.kie_release_expected_selector_sha256',:'expected_selector_sha256',false) as expected_selector_sha256,
       set_config('rendprop.kie_release_expected_hold_record_sha256',:'expected_hold_record_sha256',false) as expected_hold_record_sha256;

do $kie_release_hold$
declare
 v_expected_selector constant text:=current_setting('rendprop.kie_release_expected_selector_sha256',true);
 v_expected_hold constant text:=current_setting('rendprop.kie_release_expected_hold_record_sha256',true);
 v_selector jsonb;
 v_present boolean;
 v_selector_sha text;
 v_route_on boolean;
 v_hold jsonb;
 v_hold_found boolean;
 v_hold_sha text;
 v_target jsonb;   -- previous_selector: {"present":true,"value":...} or {"present":false}
 v_released jsonb;
 v_restores_kie boolean;
 v_activation_current boolean;
begin
 -- 0. Every input, before any lock.
 if coalesce(v_expected_selector,'') !~ '^[0-9a-f]{64}$' then
  raise exception 'KIE-RELEASE-HOLD refused: -v expected_selector_sha256=... is required: the sha256 (64 lowercase hex characters) of the current property_video_quality value (the hold value) as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(v_expected_selector,'');
 end if;
 if coalesce(v_expected_hold,'') !~ '^[0-9a-f]{64}$' then
  raise exception 'KIE-RELEASE-HOLD refused: -v expected_hold_record_sha256=... is required: the sha256 (64 lowercase hex characters) of the current app_config.property_video_quality_hold value as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(v_expected_hold,'');
 end if;
 -- A row hidden by row level security would read as absent: refuse instead.
 if not coalesce((select bool_and(not c.relrowsecurity or r.rolsuper or r.rolbypassrls or (c.relowner=r.oid and not c.relforcerowsecurity))
                    from pg_class c cross join pg_roles r
                   where r.rolname=current_user and c.oid in ('public.app_config'::regclass,'public.ai_routes'::regclass)),false) then
  raise exception 'KIE-RELEASE-HOLD refused: role % may not see every app_config/ai_routes row (row level security); run it as the role that applies migrations. Nothing changed.',current_user;
 end if;
 -- Operator scripts never interleave.
 perform pg_advisory_xact_lock(hashtextextended('rendprop:kie-operator-scripts',0));
 -- 1. Selector first (admission's lock order): exactly the expected baseline.
 select value into v_selector from public.app_config where key='property_video_quality' for update;
 v_present:=found;
 v_selector_sha:=case when v_present then encode(sha256(convert_to(v_selector::text,'UTF8')),'hex') else 'absent' end;
 if v_selector_sha is distinct from v_expected_selector then
  raise exception 'KIE-RELEASE-HOLD refused: property_video_quality is not the expected baseline (expected %, found % = %): it changed after it was read, or this release already ran and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   v_expected_selector,v_selector_sha,case when v_present then v_selector::text else 'absent' end;
 end if;
 -- 2. The pinned route row second (the common lock order); never changed here.
 select enabled into v_route_on from public.ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21' for update;
 -- 3. The hold record last: exactly the expected baseline, well-formed, not
 -- released, and the selector is exactly its hold value.
 select value into v_hold from public.app_config where key='property_video_quality_hold' for update;
 v_hold_found:=found;
 v_hold_sha:=case when v_hold_found then encode(sha256(convert_to(v_hold::text,'UTF8')),'hex') else 'absent' end;
 if v_hold_sha is distinct from v_expected_hold then
  raise exception 'KIE-RELEASE-HOLD refused: the hold record app_config.property_video_quality_hold is not the expected baseline (expected %, found %): it changed after it was read, or this release already ran and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   v_expected_hold,v_hold_sha;
 end if;
 if not coalesce(case when jsonb_typeof(v_hold)='object' then
                  v_hold ?& array['hold_id','previous_selector','reason','held_at','released_at']
                  and v_hold - array['hold_id','previous_selector','reason','held_at','released_at']='{}'::jsonb
                  and jsonb_typeof(v_hold->'hold_id')='string'
                  and v_hold->>'hold_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  and case when jsonb_typeof(v_hold->'previous_selector')='object' then
                        v_hold->'previous_selector'='{"present":false}'::jsonb
                        or ((v_hold->'previous_selector') ?& array['present','value']
                            and (v_hold->'previous_selector') - array['present','value']='{}'::jsonb
                            and v_hold#>'{previous_selector,present}'='true'::jsonb
                            and coalesce(v_hold#>>'{previous_selector,value,profile}','')<>'hold-new-paid-admissions')
                      else false end
                  and jsonb_typeof(v_hold->'reason')='string' and v_hold->>'reason' ~ '^[ -~]{1,200}$'
                  and jsonb_typeof(v_hold->'held_at')='string'
                  and jsonb_typeof(v_hold->'released_at') in ('null','string')
                 else false end,false) then
  raise exception 'KIE-RELEASE-HOLD refused: the hold record app_config.property_video_quality_hold is malformed (%), so nothing says exactly what to restore. Nothing changed; no value is ever guessed. It needs a reviewed manual correction.',v_hold::text;
 end if;
 if v_hold->'released_at' is distinct from 'null'::jsonb then
  raise exception 'KIE-RELEASE-HOLD refused: hold % was already released at %. Nothing changed.',v_hold->>'hold_id',v_hold->>'released_at';
 end if;
 if not v_present or v_selector is distinct from jsonb_build_object('enabled',true,'profile','hold-new-paid-admissions','hold_id',v_hold->>'hold_id') then
  raise exception 'KIE-RELEASE-HOLD refused: property_video_quality (%) is not the exact value of hold %, so releasing it would overwrite a selector the hold did not set. Nothing changed; review both by hand (KIE-READONLY-VERIFY.sql).',
   case when v_present then v_selector::text else 'absent' end,v_hold->>'hold_id';
 end if;
 v_target:=v_hold->'previous_selector';
 -- 4. Restore exactly the recorded value, or delete the key it did not have,
 -- then stamp the record (it is kept).
 if v_target->'present'='true'::jsonb then
  update public.app_config set value=v_target->'value',updated_at=now() where key='property_video_quality';
 else
  delete from public.app_config where key='property_video_quality';
 end if;
 v_released:=v_hold||jsonb_build_object('released_at',now());
 update public.app_config set value=v_released,updated_at=now() where key='property_video_quality_hold';
 v_restores_kie:=coalesce(v_target->'present'='true'::jsonb and jsonb_typeof(v_target->'value')='object'
  and v_target#>'{value,enabled}'='true'::jsonb and v_target#>>'{value,profile}'='kie-kling3-4k-steady-v1'
  and v_target#>'{value,vendor_content_license}'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack',false);
 raise notice 'KIE-RELEASE-HOLD done: hold % released; property_video_quality = %; pinned Kie route % (unchanged)',
  v_hold->>'hold_id',coalesce((v_target->'value')::text,'absent'),case when v_route_on is null then 'row missing' when v_route_on then 'ON' else 'OFF' end;
 if v_restores_kie then
  select coalesce(value->'rolled_back_at'='null'::jsonb,false) into v_activation_current
    from public.app_config where key='property_video_quality_kie_activation';
  raise notice 'KIE-RELEASE-HOLD: the restored selector selects Kie; % ; activation record %',
   case when v_route_on then 'Kie admissions resume now' else 'every Kie admission refuses (RP409) while the pinned row is OFF: run KIE-ROLLBACK.sql to restore the activation''s recorded selector' end,
   case when v_activation_current then 'current' else 'NOT current: KIE-ROLLBACK.sql will refuse; review by hand' end;
 end if;
 raise notice 'KIE-RELEASE-HOLD new baselines: expected_selector_sha256=% expected_hold_record_sha256=%',
  case when v_target->'present'='true'::jsonb then encode(sha256(convert_to((v_target->'value')::text,'UTF8')),'hex') else 'absent' end,
  encode(sha256(convert_to(v_released::text,'UTF8')),'hex');
end
$kie_release_hold$;

-- Read back what new admissions will see once this transaction commits, with
-- the digests the next operation takes as its baselines.
select coalesce(c.value::text,'absent') as property_video_quality,
       coalesce(encode(sha256(convert_to(c.value::text,'UTF8')),'hex'),'absent') as property_video_quality_sha256,
       coalesce(h.value::text,'none') as property_video_quality_hold,
       coalesce(encode(sha256(convert_to(h.value::text,'UTF8')),'hex'),'absent') as property_video_quality_hold_sha256,
       r.enabled as kie_route_enabled
  from (select 1) one
  left join public.app_config c on c.key='property_video_quality'
  left join public.app_config h on h.key='property_video_quality_hold'
  left join public.ai_routes r on r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';
