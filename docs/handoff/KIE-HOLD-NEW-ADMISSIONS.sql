-- KIE-HOLD-NEW-ADMISSIONS.sql: stop every NEW paid property-video admission
-- (legacy, FAL, Kie and owner-test-grant-scoped alike) without switching to
-- FAL. OPERATOR STEP, never a migration.
--
-- What it does, in one transaction: it replaces app_config.property_video_quality
-- with exactly
--   {"enabled":true,"profile":"hold-new-paid-admissions","hold_id":"<new uuid>"}
-- and saves the hold record app_config.property_video_quality_hold
--   {"hold_id":"<same uuid>",
--    "previous_selector":{"present":true,"value":<exact previous value>} or {"present":false},
--    "reason":"<hold_reason>","held_at":<now()>,"released_at":null}
-- public.property_video_quality_profile() refuses that selector (RP503), and
-- public.property_video_quality_profile_for() calls it first, so every new
-- admission and every new property-video recipe quote refuses with no job and
-- no fallback, grant-scoped ones included. docs/handoff/KIE-RELEASE-HOLD.sql
-- restores previous_selector exactly.
--
-- What it does not do:
--   * admitted jobs (Kie and FAL) keep dispatching and polling, and owner
--     resumes of admitted jobs continue: none of them re-reads the selector;
--   * the pinned Kie route row is unchanged, so already admitted Kie jobs
--     (including jobs admitted under an owner-test grant that can still create)
--     can still send their unsent Kie clips; no new job is admitted under any
--     grant while held. To also stop new Kie createTask calls run
--     docs/handoff/KIE-ROUTE-OFF.sql (allowed while held);
--   * other paid AI features that never read this selector (direct reel clips,
--     animate-photo, photo edits) are not held;
--   * like any selector change it removes the selector-based FAL paid-quality
--     allowance floor (pre-existing paid_quality_processing_budget behaviour):
--     admitted FAL quality jobs fall back to the base ceiling, while admitted
--     Kie jobs keep theirs through the drain floor of migration 20261016110000.
-- Over an activated Kie selector the activation record stays current:
-- KIE-ROLLBACK.sql refuses while held, and KIE-RELEASE-HOLD.sql restores the
-- Kie selector exactly. To leave Kie for its recorded FAL/legacy selector
-- without admitting on Kie in between: KIE-ROUTE-OFF.sql, then
-- KIE-RELEASE-HOLD.sql (Kie admissions then refuse RP409 because the row is
-- OFF), then KIE-ROLLBACK.sql. The database invariant keeps the pinned row ON
-- only while Kie is activated, an admitted Kie job drains or an owner-test grant
-- can still create; during a hold run KIE-ROUTE-OFF.sql once none of that holds
-- (the NOTICE says so when it is already the case).
--
-- Baselines, read with docs/handoff/KIE-READONLY-VERIFY.sql (state rows
-- property_video_quality_sha256 and property_video_quality_hold_sha256):
--   expected_selector_sha256     digest of the current property_video_quality
--                                value, or absent when the key does not exist
--   expected_hold_record_sha256  digest of the current
--                                app_config.property_video_quality_hold value,
--                                or absent (a released earlier hold is replaced)
--   hold_reason                  1 to 200 printable ASCII characters (0x20-0x7E:
--                                letters, digits, spaces, punctuation), saved in
--                                the record
-- A digest is encode(sha256(convert_to(value::text,'UTF8')),'hex') of the stored
-- jsonb value (its canonical text): 64 lowercase hex characters.
-- Run exactly as (-X: no psqlrc can change the session), as the role that
-- applies migrations:
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -1 -v expected_selector_sha256='<sha256-or-absent>' -v expected_hold_record_sha256='<sha256-or-absent>' -v hold_reason='<reason>' -f docs/handoff/KIE-HOLD-NEW-ADMISSIONS.sql
--
-- Refusals change nothing (and say so): a missing or malformed variable; a
-- selector or hold record that is not exactly its baseline (it changed after it
-- was read, or this hold already ran and its reply was lost: KIE-READONLY-VERIFY.sql
-- then shows the true state); a hold that is already active (the selector is a
-- hold value, or the hold record is not released); a malformed hold record.
-- On success it prints the baselines KIE-RELEASE-HOLD.sql needs,
--   NOTICE:  KIE-HOLD new baselines: expected_selector_sha256=... expected_hold_record_sha256=... (hold_id ...)
-- and reads them back.
--
-- One transaction. All work is one DO block, so it is all-or-nothing even
-- without -1. Lock order (every Kie operator script): the Kie operator-scripts
-- transaction advisory lock, then the selector row, then the pinned route row
-- (locked, never changed here), then the hold record. Admission locks the
-- selector FOR SHARE first, so it either finishes on the old selector before
-- the hold or refuses after it. Lock waits are bounded (lock_timeout 15 s); a
-- timeout refuses and changes nothing. It never touches jobs, receipts,
-- ledgers, prices, allowances, grants, any route or any other config key.
\set ON_ERROR_STOP on

\if :{?expected_selector_sha256}
\else
\set expected_selector_sha256 ''
\endif
\if :{?expected_hold_record_sha256}
\else
\set expected_hold_record_sha256 ''
\endif
\if :{?hold_reason}
\else
\set hold_reason ''
\endif
-- Stamps and digests in UTC; bounded lock waits.
set timezone = 'UTC';
set lock_timeout = '15s';
-- Hand the psql values to the DO block (psql does not interpolate inside it).
select set_config('rendprop.kie_hold_expected_selector_sha256',:'expected_selector_sha256',false) as expected_selector_sha256,
       set_config('rendprop.kie_hold_expected_hold_record_sha256',:'expected_hold_record_sha256',false) as expected_hold_record_sha256,
       set_config('rendprop.kie_hold_reason',:'hold_reason',false) as hold_reason;

do $kie_hold$
declare
 v_expected_selector constant text:=current_setting('rendprop.kie_hold_expected_selector_sha256',true);
 v_expected_hold constant text:=current_setting('rendprop.kie_hold_expected_hold_record_sha256',true);
 v_reason constant text:=current_setting('rendprop.kie_hold_reason',true);
 v_previous jsonb;
 v_present boolean;
 v_selector_sha text;
 v_previous_selects_kie boolean;
 v_route_on boolean;
 v_old jsonb;
 v_old_found boolean;
 v_old_sha text;
 v_hold_id constant uuid:=gen_random_uuid();
 v_hold_value jsonb;
 v_record jsonb;
 v_draining bigint;
 v_live_grants bigint;
begin
 -- 0. Every input, before any lock.
 if coalesce(v_expected_selector,'') !~ '^([0-9a-f]{64}|absent)$' then
  raise exception 'KIE-HOLD refused: -v expected_selector_sha256=... is required: the sha256 (64 lowercase hex characters) of the current property_video_quality value, or the word absent, as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(v_expected_selector,'');
 end if;
 if coalesce(v_expected_hold,'') !~ '^([0-9a-f]{64}|absent)$' then
  raise exception 'KIE-HOLD refused: -v expected_hold_record_sha256=... is required: the sha256 of the current app_config.property_video_quality_hold value, or the word absent, as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(v_expected_hold,'');
 end if;
 if coalesce(v_reason,'') !~ '^[ -~]{1,200}$' then
  raise exception 'KIE-HOLD refused: -v hold_reason=... is required: 1 to 200 printable ASCII characters (letters, digits, spaces and punctuation; no tabs, line breaks, control or non-ASCII characters); got % character(s). Nothing changed.',length(coalesce(v_reason,''));
 end if;
 -- A row hidden by row level security would read as absent: refuse instead.
 if not coalesce((select bool_and(not c.relrowsecurity or r.rolsuper or r.rolbypassrls or (c.relowner=r.oid and not c.relforcerowsecurity))
                    from pg_class c cross join pg_roles r
                   where r.rolname=current_user
                     and c.oid in ('public.app_config'::regclass,'public.ai_routes'::regclass,'public.property_video_jobs'::regclass,
                                   'public.property_video_kie_test_grants'::regclass)),false) then
  raise exception 'KIE-HOLD refused: role % may not see every row it reads (row level security); run it as the role that applies migrations. Nothing changed.',current_user;
 end if;
 -- Operator scripts never interleave, even while there is no selector row to lock.
 perform pg_advisory_xact_lock(hashtextextended('rendprop:kie-operator-scripts',0));
 -- 1. Selector first (admission's lock order): exactly the expected baseline,
 -- and not already a hold.
 select value into v_previous from public.app_config where key='property_video_quality' for update;
 v_present:=found;
 v_selector_sha:=case when v_present then encode(sha256(convert_to(v_previous::text,'UTF8')),'hex') else 'absent' end;
 if v_selector_sha is distinct from v_expected_selector then
  raise exception 'KIE-HOLD refused: property_video_quality is not the expected baseline (expected %, found % = %): it changed after it was read, or this hold already ran and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   v_expected_selector,v_selector_sha,case when v_present then v_previous::text else 'absent' end;
 end if;
 if v_present and coalesce(jsonb_typeof(v_previous)='object' and v_previous->>'profile'='hold-new-paid-admissions',false) then
  raise exception 'KIE-HOLD refused: a new-admission hold is already active (property_video_quality %). Nothing changed.',v_previous::text;
 end if;
 v_previous_selects_kie:=v_present and coalesce(jsonb_typeof(v_previous)='object' and v_previous->'enabled'='true'::jsonb
  and v_previous->>'profile'='kie-kling3-4k-steady-v1'
  and v_previous->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack',false);
 -- 2. The pinned route row second (the common lock order); never changed here.
 select enabled into v_route_on from public.ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21' for update;
 -- 3. The hold record last: exactly the expected baseline, and released if present.
 select value into v_old from public.app_config where key='property_video_quality_hold' for update;
 v_old_found:=found;
 v_old_sha:=case when v_old_found then encode(sha256(convert_to(v_old::text,'UTF8')),'hex') else 'absent' end;
 if v_old_sha is distinct from v_expected_hold then
  raise exception 'KIE-HOLD refused: the hold record app_config.property_video_quality_hold is not the expected baseline (expected %, found %): it changed after it was read, or this hold already ran and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   v_expected_hold,v_old_sha;
 end if;
 if v_old_found then
  if not coalesce(case when jsonb_typeof(v_old)='object' then
                   v_old ?& array['hold_id','previous_selector','reason','held_at','released_at']
                   and v_old - array['hold_id','previous_selector','reason','held_at','released_at']='{}'::jsonb
                   and jsonb_typeof(v_old->'hold_id')='string'
                   and v_old->>'hold_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   and case when jsonb_typeof(v_old->'previous_selector')='object' then
                         v_old->'previous_selector'='{"present":false}'::jsonb
                         or ((v_old->'previous_selector') ?& array['present','value']
                             and (v_old->'previous_selector') - array['present','value']='{}'::jsonb
                             and v_old#>'{previous_selector,present}'='true'::jsonb
                             and coalesce(v_old#>>'{previous_selector,value,profile}','')<>'hold-new-paid-admissions')
                       else false end
                   and jsonb_typeof(v_old->'reason')='string' and v_old->>'reason' ~ '^[ -~]{1,200}$'
                   and jsonb_typeof(v_old->'held_at')='string'
                   and jsonb_typeof(v_old->'released_at') in ('null','string')
                  else false end,false) then
   raise exception 'KIE-HOLD refused: the hold record app_config.property_video_quality_hold is malformed (%), so whether an earlier hold is still active is unknown. Nothing changed; it needs a reviewed manual correction (KIE-READONLY-VERIFY.sql shows it).',v_old::text;
  end if;
  if v_old->'released_at'='null'::jsonb then
   raise exception 'KIE-HOLD refused: hold % (held %) is recorded as active and was never released, although the selector is not its hold value (%). Nothing changed; review the hold record and the selector by hand (KIE-READONLY-VERIFY.sql).',
    v_old->>'hold_id',v_old->>'held_at',case when v_present then v_previous::text else 'absent' end;
  end if;
 end if;
 -- 4. The hold selector, then its record with the exact previous selector.
 v_hold_value:=jsonb_build_object('enabled',true,'profile','hold-new-paid-admissions','hold_id',v_hold_id);
 if v_present then
  update public.app_config set value=v_hold_value,updated_at=now() where key='property_video_quality';
 else
  insert into public.app_config(key,value,updated_at) values('property_video_quality',v_hold_value,now()) on conflict(key) do nothing;
  if not found then
   raise exception 'KIE-HOLD refused: property_video_quality was created concurrently. Nothing changed; rerun.';
  end if;
 end if;
 v_record:=jsonb_build_object('hold_id',v_hold_id,
  'previous_selector',case when v_present then jsonb_build_object('present',true,'value',v_previous) else jsonb_build_object('present',false) end,
  'reason',v_reason,'held_at',now(),'released_at',null);
 if v_old_found then
  update public.app_config set value=v_record,updated_at=now() where key='property_video_quality_hold';
 else
  insert into public.app_config(key,value,updated_at) values('property_video_quality_hold',v_record,now()) on conflict(key) do nothing;
  if not found then
   raise exception 'KIE-HOLD refused: the hold record was created concurrently. Nothing changed; rerun.';
  end if;
 end if;
 -- 5. What keeps running while new admissions are held.
 select count(*) into v_draining from public.property_video_jobs
  where quality_profile='kie-kling3-4k-steady-v1' and state in('queued','generating','quality_review','composing','failed')
    and cancelled_at is null and deadline>now();
 select count(*) into v_live_grants from public.property_video_kie_test_grants
  where revoked_at is null and expires_at>now() and creates_used<max_creates;
 raise notice 'KIE-HOLD done: new paid property-video admissions are held (hold %); previous property_video_quality %; pinned Kie route % (unchanged); % admitted Kie job(s) can still be granted work or resumed; % owner-test grant(s) can still create',
  v_hold_id,case when v_present then v_previous::text else 'absent' end,
  case when v_route_on is null then 'row missing' when v_route_on then 'ON' else 'OFF' end,v_draining,v_live_grants;
 if v_previous_selects_kie then
  raise notice 'KIE-HOLD: the held selector is the activated Kie selector: its activation record stays current, KIE-ROLLBACK.sql refuses while held, and KIE-RELEASE-HOLD.sql restores Kie exactly (to leave Kie without admitting on it again: KIE-ROUTE-OFF.sql, KIE-RELEASE-HOLD.sql, then KIE-ROLLBACK.sql)';
 end if;
 if v_route_on and v_draining=0 and v_live_grants=0 then
  raise notice 'KIE-HOLD: the pinned Kie route is ON but no admitted Kie job drains and no owner-test grant can still create: run KIE-ROUTE-OFF.sql now (the reseller-row invariant is red until the row is OFF)';
 end if;
 raise notice 'KIE-HOLD new baselines: expected_selector_sha256=% expected_hold_record_sha256=% (hold_id %)',
  encode(sha256(convert_to(v_hold_value::text,'UTF8')),'hex'),encode(sha256(convert_to(v_record::text,'UTF8')),'hex'),v_hold_id;
end
$kie_hold$;

-- Read back the hold as new admissions will see it once this transaction
-- commits, with the digests KIE-RELEASE-HOLD.sql takes as its baselines.
select coalesce(c.value::text,'absent') as property_video_quality,
       coalesce(encode(sha256(convert_to(c.value::text,'UTF8')),'hex'),'absent') as property_video_quality_sha256,
       coalesce(h.value::text,'none') as property_video_quality_hold,
       coalesce(encode(sha256(convert_to(h.value::text,'UTF8')),'hex'),'absent') as property_video_quality_hold_sha256,
       r.enabled as kie_route_enabled
  from (select 1) one
  left join public.app_config c on c.key='property_video_quality'
  left join public.app_config h on h.key='property_video_quality_hold'
  left join public.ai_routes r on r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';
