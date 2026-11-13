-- KIE-READONLY-VERIFY.sql: read-only checks for the Kie Kling 3.0 native-4K
-- property-video profile kie-kling3-4k-steady-v1 and every Kie operator state,
-- with the exact baselines every Kie operator script takes.
-- OPERATOR STEP. It changes nothing: every query runs in one READ ONLY
-- transaction (any write would fail) on one snapshot, then rolls back.
--
-- Run WITHOUT -1 (the file opens and rolls back its own transaction), as the
-- role that applies migrations (property_video_quality_identity is not
-- executable by anon or authenticated, and check 23 needs a session that sees
-- every row):
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -f docs/handoff/KIE-READONLY-VERIFY.sql
-- Run against the complete current migration history. Both Kie migrations
-- (20261016100000 and 20261016110000) must be applied; it refuses with that
-- message otherwise. This file pins later deliberate Photo Motion and prompt
-- registry additions too, while Kie identity, activation and route stay exact.
--
-- When, and the phase to expect in the "state: phase" row (check 18):
--   * after the migrations and the edge deploy: "not activated";
--   * after docs/handoff/KIE-OWNER-TEST-GRANT.sql, while its grant can still
--     create and the selector is unchanged: "owner-test window";
--   * after docs/handoff/KIE-ACTIVATION.sql: "activated";
--   * after a default docs/handoff/KIE-ROLLBACK.sql, after an owner-test grant
--     was revoked, expired or used up, or under a hold over an activated Kie
--     selector: "draining" while admitted Kie jobs can still be granted work or
--     resumed (not cancelled, before the 24 h deadline,
--     queued/generating/quality_review/composing or a failed pause; ready,
--     cancelled and needs_reconciliation are final), "drain over" (false: run
--     docs/handoff/KIE-ROUTE-OFF.sql now) once none can;
--   * after docs/handoff/KIE-ROUTE-OFF.sql or an EMERGENCY rollback: "Kie off"
--     ("not activated" when there never was an activation record).
--   A new-admission hold (docs/handoff/KIE-HOLD-NEW-ADMISSIONS.sql) is named in
--   the phase text.
--
-- Output 1, the checks: n | check_name | ok | detail. ok is always a boolean;
-- the last row (28), "all checks", is true only when every row above it is
-- true. 1-15 pin the migrated objects, 16-18 the selector, the activation
-- record and the phase, 19-22 the objects of migration 20261016110000, 23 this
-- session's row visibility, 24-27 the hold record, the route-window record, the
-- grants and the published processor-permission contract. The md5 pins (6-11)
-- are the bodies after the complete current migration history. The Kie
-- migration-boundary bodies remain pinned separately by
-- services/supabase/tests/property_video_kie_profile_pg.py. A later migration
-- that replaces one of these functions on purpose must update its pin here.
-- Output 2, the state: item | value, as stored, including the digests every
-- operator script takes as its exact baselines:
--   property_video_quality_sha256          -> expected_selector_sha256
--   kie_route_enabled                      -> expected_route_enabled
--   kie_activation_record_sha256           -> expected_record_sha256
--   property_video_quality_hold_sha256     -> expected_hold_record_sha256
--   property_video_kie_test_window_sha256  -> expected_test_window_sha256
--   kie_test_grants[].sha256               -> expected_grant_sha256
-- A digest is encode(sha256(convert_to(value::text,'UTF8')),'hex') of the stored
-- jsonb value (for a grant: of to_jsonb(row), computed in UTC, which this file
-- sets), or absent when there is none. Grants are listed by id only (actor,
-- listing and library ids, the approval reference and counters; no names, no
-- source photos).
\set ON_ERROR_STOP on
\pset pager off
begin transaction isolation level repeatable read read only;
set local lock_timeout = '5s';
set local statement_timeout = '60s';
-- to_jsonb(grant row) prints timestamps in the session time zone: every Kie
-- operator script computes grant digests in UTC.
set local timezone = 'UTC';
-- Both Kie migrations must be applied (a clear refusal, not a missing relation).
do $kie_verify_objects$
begin
 if to_regprocedure('public.property_video_quality_identity(text)') is null
  or to_regclass('public.property_video_kie_test_grants') is null
  or to_regclass('public.property_video_kie_test_grant_uses') is null then
  raise exception 'KIE-READONLY-VERIFY: migrations 20261016100000 and 20261016110000 must both be applied (the Kie identity function or the owner-test grant tables are missing).';
 end if;
end
$kie_verify_objects$;

with
expected as (select
 '{"profile":"kie-kling3-4k-steady-v1","provider":"kie","model":"kling-3.0/video","route_id":"7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21","task":"video.property_reel_clip_kie","mode":"4K","sound":false,"multi_shots":false,"seconds":5,"unit":"second","unit_cents":33.5,"attempt_cents":167.5,"credits_per_second":67,"usd_per_credit":0.005,"price_source":"https://kie.ai/kling-3-0","price_checked":"2026-10-16","bonus_credits_excluded":true,"max_paid_attempts_per_source":2,"prompt_profile":"steady-property-v1","prompt_template_token":"{scene_noun}","prompt_scene_nouns":["home","event venue","restaurant","store","fitness studio","space"],"prompt_template_sha256":{"fly_through":"5a27f080e3affd92fc1f455f09d29df3b9d82c3bb07de6a4fae644ddba95a785","push_in":"275836a1c183898de223d1f576eba246ca4aa635611a0afd410743a264d472f7","side_glide":"cad745c420ac54cd4339a73fde9ad33322949dbbb6764f596c2d1da24d0848a3","pull_back":"e80e5a784366935080e5ab43d2e8ea395859a6993c6c146bfc96c86b138b8aa9"},"composition_profile":"steady-v2-cfr24","output_fps":24,"output_frames":[120,121],"min_short_side_px":2160,"min_pixels":8000000,"aspect_ratio_wire":"omitted_source_auto","privacy_tier":"trains_by_default","content_license_ack":"kie-terms-2025-08-01-section-3-owner-accepted"}'::jsonb as identity,
 '{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}'::jsonb as kie_selector),
pins(n, signature, after_md5, expected_volatility, expected_result) as (values
 (1, 'public.property_video_quality_profile()', '9671b48a46a1e777bc4b968c1a669d44', 'v', 'text'),
 (2, 'public.property_video_quality_freeze()', 'd3739899b2177091178aa93b886d8873', 'v', 'trigger'),
 (3, 'public.property_video_job_admit(uuid,jsonb,numeric,text)', '2929b69b330f4ab7a5aca6257e86398b', 'v', 'jsonb'),
 (4, 'public.paid_quality_processing_budget(uuid)', 'bb8399f07e08f42447915f1513dbd0c7', 's', 'integer'),
 (5, 'public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)', '2af2e6a298ecfae7c58d6845b94ab509', 'v', 'property_video_jobs'),
 (6, 'public.background_video_delivery(uuid,uuid,uuid,text,bigint)', '0d5766730ab7c061abc8ee4f2bd10a7e', 'v', 'jsonb')),
-- Migration 20261016110000's functions: the RPCs execute only as service_role,
-- the guard trigger functions by no client role.
new_functions(signature, rpc) as (values
 ('public.property_video_processor_consent_current()', true),
 ('public.property_video_processor_consent_record(text,jsonb)', true),
 ('public.property_video_kie_test_grant_scope(uuid,uuid,jsonb)', true),
 ('public.property_video_quality_profile_for(uuid,jsonb,uuid)', true),
 ('public.property_video_job_admit_v2(uuid,jsonb,numeric,text,jsonb,uuid)', true),
 ('public.property_video_kie_dispatch_authority(uuid,uuid,uuid)', true),
 ('public.property_video_kie_test_grant_guard()', false),
 ('public.property_video_kie_test_grant_use_guard()', false)),
function_checks as (select nf.signature,
 coalesce(p.oid is not null and p.prosecdef and p.proconfig = array['search_path=""']::text[]
          and not has_function_privilege('anon', p.oid, 'EXECUTE')
          and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
          and not has_function_privilege('public', p.oid, 'EXECUTE')
          and (not nf.rpc or has_function_privilege('service_role', p.oid, 'EXECUTE')), false) as ok
 from new_functions nf left join pg_proc p on p.oid = to_regprocedure(nf.signature)),
-- Every table these checks read: rows hidden by row level security would make
-- them lie, so this session must see them all.
read_tables(name) as (values ('public.app_config'), ('public.ai_routes'), ('public.property_video_jobs'),
 ('public.property_video_job_sources'), ('public.property_video_kie_test_grants'), ('public.property_video_kie_test_grant_uses')),
visibility as (select t.name,
 coalesce(not c.relrowsecurity or r.rolsuper or r.rolbypassrls or (c.relowner = r.oid and not c.relforcerowsecurity), false) as visible
 from read_tables t
 left join pg_class c on c.oid = to_regclass(t.name)
 left join pg_roles r on r.rolname = current_user),
stored as (select
 (select value from public.app_config where key = 'property_video_quality') as selector,
 exists (select 1 from public.app_config where key = 'property_video_quality') as selector_present,
 (select enabled from public.ai_routes where id = '7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21') as route_on,
 (select value from public.app_config where key = 'property_video_quality_kie_activation') as record,
 (select value from public.app_config where key = 'property_video_quality_hold') as hold,
 (select value from public.app_config where key = 'property_video_kie_test_window') as test_window,
 (select value from public.app_config where key = 'property_video_processor_consent') as consent,
 (select count(*) from public.property_video_jobs
   where quality_profile = 'kie-kling3-4k-steady-v1'
     and state in ('queued','generating','quality_review','composing','failed')
     and cancelled_at is null and deadline > now()) as draining,
 (select max(deadline) from public.property_video_jobs
   where quality_profile = 'kie-kling3-4k-steady-v1'
     and state in ('queued','generating','quality_review','composing','failed')
     and cancelled_at is null and deadline > now()) as drain_ends_by,
 -- Owner-test grants that can still create (the reseller-row invariant's test).
 (select count(*) from public.property_video_kie_test_grants
   where revoked_at is null and expires_at > now() and creates_used < max_creates) as live_grants,
 (select max(expires_at) from public.property_video_kie_test_grants
   where revoked_at is null and expires_at > now() and creates_used < max_creates) as live_grants_until),
facts as (select s.*,
 coalesce(s.selector = e.kie_selector, false) as selects_kie,
 -- The rule property_video_quality_profile() applies (extra keys allowed).
 coalesce(s.selector->'enabled' = 'true'::jsonb and s.selector->>'profile' = 'kie-kling3-4k-steady-v1'
          and s.selector->'vendor_content_license' = e.kie_selector->'vendor_content_license', false) as kie_rule,
 coalesce(jsonb_typeof(s.selector) = 'object' and s.selector->>'profile' = 'hold-new-paid-admissions', false) as hold_like,
 -- What KIE-ROLLBACK.sql restores and KIE-ACTIVATION.sql accepts as previous.
 not s.selector_present
  or coalesce(case when jsonb_typeof(s.selector) = 'object' then
                coalesce(s.selector->>'profile', '') not in ('kie-kling3-4k-steady-v1', 'hold-new-paid-admissions')
                and (s.selector->'enabled' = 'false'::jsonb
                     or (s.selector->'enabled' = 'true'::jsonb and s.selector->>'profile' in ('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')))
              else false end, false) as pre_kie,
 -- The activation record: exactly the fields KIE-ACTIVATION.sql writes (the
 -- same test KIE-ROLLBACK.sql applies before it restores anything).
 case when s.record is null then 'none'
      when coalesce(case when jsonb_typeof(s.record) = 'object' then
             s.record ?& array['profile','route_id','previous_selector','route_enabled_before','processor_disclosure','consent_disclosure_revision',
                               'vendor_content_license','activated_at','rolled_back_at','rollback_mode','route_disabled_at']
             and s.record - array['profile','route_id','previous_selector','route_enabled_before','processor_disclosure','consent_disclosure_revision',
                                  'vendor_content_license','activated_at','rolled_back_at','rollback_mode','route_disabled_at'] = '{}'::jsonb
             and s.record->'profile' = '"kie-kling3-4k-steady-v1"'::jsonb
             and s.record->'route_id' = '"7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21"'::jsonb
             and s.record->'vendor_content_license' = e.kie_selector->'vendor_content_license'
             and jsonb_typeof(s.record->'processor_disclosure') = 'string'
             and s.record->>'processor_disclosure' ~ '^[!-~]{1,200}$'
             and jsonb_typeof(s.record->'consent_disclosure_revision') = 'string'
             and s.record->>'consent_disclosure_revision' ~ '^[!-~]{1,200}$'
             and jsonb_typeof(s.record->'route_enabled_before') = 'boolean'
             and jsonb_typeof(s.record->'activated_at') = 'string'
             and jsonb_typeof(s.record->'rolled_back_at') in ('null','string')
             and (s.record->'rolled_back_at' = 'null'::jsonb) = (s.record->'rollback_mode' = 'null'::jsonb)
             and (s.record->'rollback_mode' = 'null'::jsonb or s.record->'rollback_mode' in ('"default"'::jsonb, '"emergency"'::jsonb))
             and jsonb_typeof(s.record->'route_disabled_at') in ('null','string')
             and case when jsonb_typeof(s.record->'previous_selector') = 'object' then
                   s.record->'previous_selector' = '{"present":false}'::jsonb
                   or ((s.record->'previous_selector') ?& array['present','value']
                       and (s.record->'previous_selector') - array['present','value'] = '{}'::jsonb
                       and s.record#>'{previous_selector,present}' = 'true'::jsonb
                       and case when jsonb_typeof(s.record#>'{previous_selector,value}') = 'object' then
                             coalesce(s.record#>>'{previous_selector,value,profile}', '') not in ('kie-kling3-4k-steady-v1', 'hold-new-paid-admissions')
                             and (s.record#>'{previous_selector,value,enabled}' = 'false'::jsonb
                                  or (s.record#>'{previous_selector,value,enabled}' = 'true'::jsonb
                                      and s.record#>>'{previous_selector,value,profile}' in ('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')))
                           else false end)
                 else false end
           else false end, false)
      then case when s.record->'rolled_back_at' = 'null'::jsonb then 'active' else 'rolled back' end
      else 'malformed' end as record_state,
 -- The hold record: exactly the fields KIE-HOLD-NEW-ADMISSIONS.sql writes.
 case when s.hold is null then 'none'
      when coalesce(case when jsonb_typeof(s.hold) = 'object' then
             s.hold ?& array['hold_id','previous_selector','reason','held_at','released_at']
             and s.hold - array['hold_id','previous_selector','reason','held_at','released_at'] = '{}'::jsonb
             and jsonb_typeof(s.hold->'hold_id') = 'string'
             and s.hold->>'hold_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
             and case when jsonb_typeof(s.hold->'previous_selector') = 'object' then
                   s.hold->'previous_selector' = '{"present":false}'::jsonb
                   or ((s.hold->'previous_selector') ?& array['present','value']
                       and (s.hold->'previous_selector') - array['present','value'] = '{}'::jsonb
                       and s.hold#>'{previous_selector,present}' = 'true'::jsonb
                       and coalesce(s.hold#>>'{previous_selector,value,profile}', '') <> 'hold-new-paid-admissions')
                 else false end
             and jsonb_typeof(s.hold->'reason') = 'string' and s.hold->>'reason' ~ '^[ -~]{1,200}$'
             and jsonb_typeof(s.hold->'held_at') = 'string'
             and jsonb_typeof(s.hold->'released_at') in ('null','string')
           else false end, false)
      then case when s.hold->'released_at' = 'null'::jsonb then 'active' else 'released' end
      else 'malformed' end as hold_state,
 -- The route-window record: exactly the fields KIE-OWNER-TEST-GRANT.sql
 -- writes, naming an existing grant.
 case when s.test_window is null then 'none'
      when coalesce(case when jsonb_typeof(s.test_window) = 'object' then
             s.test_window ?& array['grant_id','route_enabled_before','opened_at']
             and s.test_window - array['grant_id','route_enabled_before','opened_at'] = '{}'::jsonb
             and jsonb_typeof(s.test_window->'grant_id') = 'string'
             and jsonb_typeof(s.test_window->'route_enabled_before') = 'boolean'
             and jsonb_typeof(s.test_window->'opened_at') = 'string'
             and exists (select 1 from public.property_video_kie_test_grants g where g.id::text = s.test_window->>'grant_id')
           else false end, false)
      then 'recorded' else 'malformed' end as window_state,
 -- The rule public.property_video_processor_consent_current() applies.
 coalesce(case when jsonb_typeof(s.consent) = 'object' then
            s.consent->>'token' = 'property-video-jobs-v2'
            and jsonb_typeof(s.consent->'disclosure_revision') = 'string' and s.consent->>'disclosure_revision' ~ '^[!-~]{1,200}$'
            and jsonb_typeof(s.consent->'processors') = 'array' and (s.consent->'processors') ? 'kie'
            and jsonb_typeof(s.consent->'profiles') = 'array' and (s.consent->'profiles') ? 'kie-kling3-4k-steady-v1'
            and s.consent - array['token','disclosure_revision','processors','profiles'] = '{}'::jsonb
          else false end, false) as consent_published
 from stored s, expected e),
state as (select f.*,
 f.hold_state = 'active'
  and coalesce(f.selector = jsonb_build_object('enabled', true, 'profile', 'hold-new-paid-admissions', 'hold_id', f.hold->>'hold_id'), false) as held
 from facts f),
notes as (select st.*,
 case when st.held then 'new paid admissions held (hold ' || (st.hold->>'hold_id') || ' since ' || (st.hold->>'held_at') || ')'
      else 'selector pre-Kie' end as selector_note,
 case when st.held then '; new paid admissions held (hold ' || (st.hold->>'hold_id') || ' since ' || (st.hold->>'held_at') || ')'
      else '' end as hold_note
 from state st),
checks(n, check_name, ok, detail) as (
 select 1, 'migration: property_video_quality_identity(kie-kling3-4k-steady-v1) equals the canonical identity JSON',
        coalesce(public.property_video_quality_identity('kie-kling3-4k-steady-v1') = e.identity
                 and public.property_video_quality_identity('kie-kling3-4k-steady-v1')::text = e.identity::text, false),
        coalesce('md5 of the deployed identity text ' || md5(public.property_video_quality_identity('kie-kling3-4k-steady-v1')::text), 'identity is NULL')
   from expected e
 union all
 select 2, 'migration: the identity is NULL for legacy and FAL profiles',
        public.property_video_quality_identity('legacy') is null and public.property_video_quality_identity('fal-kling3-4k-v1') is null
        and public.property_video_quality_identity('fal-kling3-4k-steady-v2') is null, ''
 union all
 select 3, 'migration: property_video_jobs.quality_identity is nullable jsonb without default',
        coalesce((select format_type(atttypid, atttypmod) = 'jsonb' and not attnotnull and not atthasdef from pg_attribute
                   where attrelid = 'public.property_video_jobs'::regclass and attname = 'quality_identity' and not attisdropped), false),
        coalesce((select format_type(atttypid, atttypmod) || ' notnull=' || attnotnull || ' default=' || atthasdef from pg_attribute
                   where attrelid = 'public.property_video_jobs'::regclass and attname = 'quality_identity' and not attisdropped), 'column missing')
 union all
 select 4, 'migration: trigger property_video_quality_freeze runs BEFORE INSERT OR UPDATE FOR EACH ROW and is enabled',
        coalesce((select tgtype = 23 and tgenabled = 'O' and tgfoid = 'public.property_video_quality_freeze()'::regprocedure and cardinality(tgattr::int2[]) = 0
                    from pg_trigger where tgrelid = 'public.property_video_jobs'::regclass and tgname = 'property_video_quality_freeze' and not tgisinternal), false),
        coalesce((select pg_get_triggerdef(oid) || ' enabled=' || tgenabled::text from pg_trigger
                   where tgrelid = 'public.property_video_jobs'::regclass and tgname = 'property_video_quality_freeze' and not tgisinternal), 'trigger missing')
 union all
 select 5, 'migration: saved profile constraint admits exactly legacy, two FAL, Kie and three Photo Motion profiles',
        coalesce((select pg_get_constraintdef(oid) = $c$CHECK ((quality_profile = ANY (ARRAY['legacy'::text, 'fal-kling3-4k-v1'::text, 'fal-kling3-4k-steady-v2'::text, 'kie-kling3-4k-steady-v1'::text, 'photo-motion-v1-cfr24'::text, 'photo-motion-v2-cfr24'::text, 'photo-motion-v2-opening-cfr24'::text])))$c$
                    from pg_constraint where conrelid = 'public.property_video_jobs'::regclass and conname = 'property_video_quality_profile_check' and contype = 'c' and convalidated), false),
        coalesce((select pg_get_constraintdef(oid) from pg_constraint
                   where conrelid = 'public.property_video_jobs'::regclass and conname = 'property_video_quality_profile_check'), 'constraint missing')
 union all
 select 5 + p.n, 'migration: body and execution authority of ' || p.signature || ' match the final pin',
        coalesce(md5(f.prosrc) = p.after_md5
                 and pg_get_userbyid(f.proowner) = 'postgres'
                 and f.prosecdef and f.proconfig = array['search_path=""']::text[]
                 and f.provolatile = p.expected_volatility and l.lanname = 'plpgsql'
                 and pg_get_function_result(f.oid) = p.expected_result
                 and f.proacl::text = '{postgres=X/postgres,service_role=X/postgres}'
                 and not has_function_privilege('anon', f.oid, 'EXECUTE')
                 and not has_function_privilege('authenticated', f.oid, 'EXECUTE'), false),
        coalesce('actual ' || md5(f.prosrc) || ', owner ' || pg_get_userbyid(f.proowner)
                 || ', acl ' || f.proacl::text || ', definer ' || f.prosecdef::text
                 || ', config ' || f.proconfig::text || ', volatility ' || f.provolatile::text
                 || ', language ' || l.lanname || ', result ' || pg_get_function_result(f.oid), 'function missing')
                 || '; pin ' || p.after_md5
   from pins p left join pg_proc f on f.oid = to_regprocedure(p.signature)
               left join pg_language l on l.oid = f.prolang
 union all
 select 12, 'migration: pinned Kie row 7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21 equals the identity in every field but enabled',
        exists (select 1 from public.ai_routes r, expected e
                 where r.id = '7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21' and r.task = 'video.property_reel_clip_kie' and r.position = 1
                   and r.provider = 'kie' and r.model = 'kling-3.0/video' and r.unit = 'second' and r.unit_cents = 33.5
                   and r.capabilities = array['i2v','1080p','5s','native4k','preserve_photo'] and r.max_latency_s = 1800 and r.min_plan = 'free'
                   and r.same_model_as = 'kling_3_pro' and r.privacy_tier = 'trains_by_default' and r.retire_after is null
                   and r.params = '{"kie_mode":"4K","sound":false}'::jsonb
                   and r.id::text = e.identity->>'route_id' and r.task = e.identity->>'task' and r.provider = e.identity->>'provider'
                   and r.model = e.identity->>'model' and r.unit = e.identity->>'unit' and r.unit_cents = (e.identity->>'unit_cents')::numeric
                   and r.privacy_tier = e.identity->>'privacy_tier' and r.params = jsonb_build_object('kie_mode', e.identity->'mode', 'sound', e.identity->'sound')),
        coalesce((select (to_jsonb(r) - 'created_at' - 'updated_at' - 'note')::text from public.ai_routes r where r.id = '7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'), 'row missing')
 union all
 select 13, 'migration: task video.property_reel_clip_kie has exactly one row',
        (select count(*) = 1 from public.ai_routes where task = 'video.property_reel_clip_kie'),
        (select count(*) || ' row(s)' from public.ai_routes where task = 'video.property_reel_clip_kie')
 union all
 select 14, 'migration: FAL property row b04b57c1-12c8-44f9-9c64-e06561358f01 unchanged (every field but note and timestamps)',
        exists (select 1 from public.ai_routes
                 where id = 'b04b57c1-12c8-44f9-9c64-e06561358f01' and task = 'video.property_reel_clip' and position = 1
                   and provider = 'fal' and model = 'fal-ai/kling-video/v3/4k/image-to-video' and unit = 'second' and unit_cents = 42
                   and capabilities = array['i2v','1080p','5s','native4k','preserve_photo'] and max_latency_s = 900 and min_plan = 'free'
                   and same_model_as = 'kling_3_pro' and privacy_tier = 'retained_30d' and enabled and retire_after is null and params is null),
        coalesce((select (to_jsonb(r) - 'created_at' - 'updated_at' - 'note')::text from public.ai_routes r where r.id = 'b04b57c1-12c8-44f9-9c64-e06561358f01'), 'row missing')
 union all
 select 15, 'migration: task video.property_reel_clip has exactly one row (the FAL row)',
        (select count(*) = 1 and bool_and(id = 'b04b57c1-12c8-44f9-9c64-e06561358f01') from public.ai_routes where task = 'video.property_reel_clip'),
        (select count(*) || ' row(s)' from public.ai_routes where task = 'video.property_reel_clip')
 union all
 select 16, 'state: property_video_quality is absent, a working pre-Kie selector, exactly the Kie activation value or exactly the active new-admission hold value',
        f.pre_kie or f.selects_kie or f.held,
        coalesce(f.selector::text, 'absent')
        || case when f.held then ' (new-admission hold ' || (f.hold->>'hold_id') || ')'
                when f.hold_like then ' (a hold value without its active hold record)' else '' end
   from notes f
 union all
 select 17, 'state: the Kie activation record is absent or well-formed',
        f.record_state <> 'malformed', f.record_state || coalesce(': ' || f.record::text, '')
   from notes f
 union all
 select 18, 'state: phase',
        f.route_on is not null and (f.pre_kie or f.selects_kie or f.held)
        and ((f.route_on and f.selects_kie and f.record_state = 'active')
             or (f.route_on and not f.kie_rule and (f.draining > 0 or f.live_grants > 0))
             or (not f.route_on and not f.kie_rule)),
        case when f.route_on is null then 'pinned Kie route row is missing'
             when not (f.pre_kie or f.selects_kie or f.held)
               then 'property_video_quality is not a value the operator scripts leave: admissions may refuse (RP503)'
             when f.route_on and f.selects_kie and f.record_state = 'active'
               then 'activated: pinned row ON, exact Kie selector, activation recorded ' || (f.record->>'activated_at')
                    || ' with processor disclosure ' || (f.record->>'processor_disclosure')
                    || ' and consent revision ' || (f.record->>'consent_disclosure_revision')
             when f.route_on and f.selects_kie
               then 'NOT ACTIVATED BY KIE-ACTIVATION.sql: pinned row ON and Kie selector, but the activation record is ' || f.record_state
             when f.route_on and f.live_grants > 0
               then 'owner-test window: ' || f.live_grants || ' owner quality-test grant(s) can still create until ' || f.live_grants_until
                    || ', selector unchanged' || f.hold_note
                    || case when f.draining > 0 then '; ' || f.draining || ' admitted Kie job(s) draining until ' || f.drain_ends_by else '' end
             when f.route_on and f.draining > 0
               then 'draining: ' || f.draining || ' admitted Kie job(s) can still be granted work until ' || f.drain_ends_by
                    || ' (active, or paused and resumable by the owner); then run KIE-ROUTE-OFF.sql' || f.hold_note
             when f.route_on
               then 'drain over: run KIE-ROUTE-OFF.sql now (no admitted Kie job or owner-test grant needs the pinned row ON)' || f.hold_note
             when f.selects_kie
               then 'pinned row OFF under the Kie selector: every Kie admission refuses (RP409); run KIE-ROLLBACK.sql to restore the saved selector'
             when f.record_state = 'none' then 'not activated: pinned row OFF, ' || f.selector_note || ', no activation record'
             else 'Kie off: pinned row OFF, ' || f.selector_note || ', activation record ' || f.record_state end
   from notes f
 union all
 select 19, 'migration 20261016110000: the owner-test grant tables have row level security on and no client privileges (service_role may only SELECT)',
        coalesce(count(*) = 2 and bool_and(c.relrowsecurity
          and not has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
          and not has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
          and not has_table_privilege('public', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
          and not has_any_column_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES')
          and not has_any_column_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES')
          and has_table_privilege('service_role', c.oid, 'SELECT')
          and not has_table_privilege('service_role', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')), false),
        coalesce(string_agg(c.relname || ' rls=' || c.relrowsecurity::text || ' acl=' || coalesce(c.relacl::text, 'default'), '; ' order by c.relname), 'tables missing')
   from pg_class c
  where c.oid in (to_regclass('public.property_video_kie_test_grants'), to_regclass('public.property_video_kie_test_grant_uses'))
 union all
 select 20, 'migration 20261016110000: the grant guard triggers are enabled (scope immutable, usage append-only, create receipts immutable)',
        (select count(*) = 2 from pg_trigger t
          where not t.tgisinternal and t.tgenabled = 'O' and cardinality(t.tgattr::int2[]) = 0
            and ((t.tgrelid = to_regclass('public.property_video_kie_test_grants') and t.tgname = 'property_video_kie_test_grant_guard'
                  and t.tgtype = 23 and t.tgfoid = to_regprocedure('public.property_video_kie_test_grant_guard()'))
              or (t.tgrelid = to_regclass('public.property_video_kie_test_grant_uses') and t.tgname = 'property_video_kie_test_grant_use_guard'
                  and t.tgtype = 19 and t.tgfoid = to_regprocedure('public.property_video_kie_test_grant_use_guard()')))),
        coalesce((select string_agg(pg_get_triggerdef(t.oid) || ' enabled=' || t.tgenabled::text, '; ' order by t.tgname) from pg_trigger t
                   where not t.tgisinternal
                     and t.tgrelid in (to_regclass('public.property_video_kie_test_grants'), to_regclass('public.property_video_kie_test_grant_uses'))),
                 'triggers missing')
 union all
 select 21, 'migration 20261016110000: property_video_jobs.processor_consent (jsonb) and kie_test_grant_id (uuid, references the grants) are nullable without default; the saved permission constraints and the Kie drain index exist',
        coalesce((select format_type(atttypid, atttypmod) = 'jsonb' and not attnotnull and not atthasdef from pg_attribute
                   where attrelid = 'public.property_video_jobs'::regclass and attname = 'processor_consent' and not attisdropped), false)
        and coalesce((select format_type(atttypid, atttypmod) = 'uuid' and not attnotnull and not atthasdef from pg_attribute
                       where attrelid = 'public.property_video_jobs'::regclass and attname = 'kie_test_grant_id' and not attisdropped), false)
        and exists (select 1 from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attname = 'kie_test_grant_id' and not a.attisdropped
                     where k.conrelid = 'public.property_video_jobs'::regclass and k.contype = 'f'
                       and k.confrelid = to_regclass('public.property_video_kie_test_grants') and k.conkey = array[a.attnum])
        and coalesce((select pg_get_constraintdef(oid) = $c$CHECK ((consent_revision = ANY (ARRAY['property-video-jobs-v1'::text, 'property-video-jobs-v2'::text, 'photo-motion-v1'::text])))$c$
                       from pg_constraint where conrelid = 'public.property_video_jobs'::regclass
                        and conname = 'property_video_jobs_consent_revision_check' and contype = 'c' and convalidated), false)
        and coalesce((select pg_get_constraintdef(oid) = $c$CHECK ((((consent_revision = 'property-video-jobs-v1'::text) AND (processor_consent IS NULL)) OR ((consent_revision = 'property-video-jobs-v2'::text) AND (jsonb_typeof(processor_consent) = 'object'::text)) OR ((consent_revision = 'photo-motion-v1'::text) AND (processor_consent IS NULL) AND (quality_profile = ANY (ARRAY['photo-motion-v1-cfr24'::text, 'photo-motion-v2-cfr24'::text, 'photo-motion-v2-opening-cfr24'::text])))))$c$
                       from pg_constraint where conrelid = 'public.property_video_jobs'::regclass
                        and conname = 'property_video_jobs_processor_consent_check' and contype = 'c' and convalidated), false)
        and (select count(*) = 3 from pg_constraint where conrelid = 'public.property_video_jobs'::regclass and contype = 'c' and convalidated
              and conname in ('property_video_jobs_processor_consent_check', 'property_video_jobs_kie_consent_check', 'property_video_jobs_kie_test_grant_check'))
        and coalesce((select i.indisvalid and i.indisready and not i.indisunique and not i.indisprimary
                            and pg_get_indexdef(i.indexrelid) = $idx$CREATE INDEX property_video_jobs_kie_drain ON public.property_video_jobs USING btree (deadline) WHERE ((quality_profile = 'kie-kling3-4k-steady-v1'::text) AND (cancelled_at IS NULL))$idx$
                        from pg_index i where i.indexrelid = to_regclass('public.property_video_jobs_kie_drain')
                          and i.indrelid = 'public.property_video_jobs'::regclass), false),
        coalesce((select string_agg(conname || ': ' || pg_get_constraintdef(oid), '; ' order by conname) from pg_constraint
                   where conrelid = 'public.property_video_jobs'::regclass
                     and conname in ('property_video_jobs_consent_revision_check', 'property_video_jobs_processor_consent_check',
                                     'property_video_jobs_kie_consent_check', 'property_video_jobs_kie_test_grant_check')), 'constraints missing')
        || '; drain index ' || coalesce((select pg_get_indexdef(i.indexrelid) || ' valid=' || i.indisvalid::text || ' ready=' || i.indisready::text
                                         from pg_index i where i.indexrelid = to_regclass('public.property_video_jobs_kie_drain')), 'missing')
 union all
 select 22, 'migration 20261016110000: its functions are SECURITY DEFINER with an empty search_path; the RPCs execute only as service_role, the guard trigger functions by no client role',
        coalesce(count(*) = 8 and bool_and(ok), false),
        coalesce('not exact: ' || string_agg(signature, ', ') filter (where not ok), 'all ' || count(*) || ' exact')
   from function_checks
 union all
 select 23, 'state: this session sees every row these checks read (row level security off, table owner without FORCE, superuser or BYPASSRLS)',
        coalesce(count(*) = 6 and bool_and(visible), false),
        current_user || ': ' || coalesce('rows may be hidden in ' || string_agg(name, ', ') filter (where not visible), 'every row visible')
   from visibility
 union all
 select 24, 'state: the new-admission hold record is absent or well-formed, and active exactly when the selector is its hold value',
        f.hold_state <> 'malformed' and (f.hold_state = 'active') = f.held and (not f.hold_like or f.held),
        f.hold_state || coalesce(': ' || f.hold::text, '')
   from notes f
 union all
 select 25, 'state: the owner-test route-window record is absent or well-formed and names an existing grant',
        f.window_state <> 'malformed', f.window_state || coalesce(': ' || f.test_window::text, '')
   from notes f
 union all
 select 26, 'state: every owner-test grant pins the reviewed identity and its usage equals its create receipts',
        coalesce(bool_and(g.profile = 'kie-kling3-4k-steady-v1' and g.quality_identity = e.identity
                          and g.creates_used = coalesce(u.creates, 0) and g.cents_used = coalesce(u.cents, 0)), true),
        count(g.id) || ' grant(s); inconsistent: '
        || coalesce(string_agg(g.id::text, ', ') filter (where not coalesce(g.profile = 'kie-kling3-4k-steady-v1' and g.quality_identity = e.identity
                                                                and g.creates_used = coalesce(u.creates, 0) and g.cents_used = coalesce(u.cents, 0), false)), 'none')
   from public.property_video_kie_test_grants g
   cross join expected e
   left join (select grant_id, count(*) as creates, sum(cents) as cents
                from public.property_video_kie_test_grant_uses group by grant_id) u on u.grant_id = g.id
 union all
 select 27, 'state: the processor-permission contract is published whenever Kie can be admitted (a Kie selector, or a grant that can still create)',
        f.consent_published or not (f.kie_rule or f.live_grants > 0),
        case when f.consent_published then 'published: disclosure_revision ' || (f.consent->>'disclosure_revision') else 'not published' end
        || case when f.kie_rule then '; the selector selects Kie'
                when f.live_grants > 0 then '; ' || f.live_grants || ' owner-test grant(s) can still create'
                else '; Kie cannot be admitted now' end
   from notes f)
select n, check_name, coalesce(ok, false) as ok, detail from checks
union all
select 28, 'all checks', bool_and(coalesce(ok, false)), count(*) filter (where ok is not true) || ' of ' || count(*) || ' check(s) false' from checks
order by n;

select item, value from (values
 (1, 'property_video_quality', coalesce((select value::text from public.app_config where key = 'property_video_quality'), 'absent')),
 (2, 'kie_route_enabled', coalesce((select enabled::text from public.ai_routes where id = '7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'), 'row missing')),
 (3, 'kie_activation_record', coalesce((select value::text from public.app_config where key = 'property_video_quality_kie_activation'), 'none')),
 (4, 'kie_jobs_admitted', (select count(*)::text from public.property_video_jobs where quality_profile = 'kie-kling3-4k-steady-v1')),
 (5, 'kie_jobs_draining', (select count(*)::text from public.property_video_jobs
                            where quality_profile = 'kie-kling3-4k-steady-v1'
                              and state in ('queued','generating','quality_review','composing','failed')
                              and cancelled_at is null and deadline > now())),
 (6, 'kie_drain_ends_by', coalesce((select max(deadline)::text from public.property_video_jobs
                                     where quality_profile = 'kie-kling3-4k-steady-v1'
                                       and state in ('queued','generating','quality_review','composing','failed')
                                       and cancelled_at is null and deadline > now()), 'none')),
 -- The exact baselines the operator scripts take (see the header).
 (7, 'property_video_quality_sha256', coalesce((select encode(sha256(convert_to(value::text, 'UTF8')), 'hex')
                                                from public.app_config where key = 'property_video_quality'), 'absent')),
 (8, 'kie_activation_record_sha256', coalesce((select encode(sha256(convert_to(value::text, 'UTF8')), 'hex')
                                               from public.app_config where key = 'property_video_quality_kie_activation'), 'absent')),
 (9, 'property_video_quality_hold', coalesce((select value::text from public.app_config where key = 'property_video_quality_hold'), 'none')),
 (10, 'property_video_quality_hold_sha256', coalesce((select encode(sha256(convert_to(value::text, 'UTF8')), 'hex')
                                                      from public.app_config where key = 'property_video_quality_hold'), 'absent')),
 (11, 'property_video_kie_test_window', coalesce((select value::text from public.app_config where key = 'property_video_kie_test_window'), 'none')),
 (12, 'property_video_kie_test_window_sha256', coalesce((select encode(sha256(convert_to(value::text, 'UTF8')), 'hex')
                                                         from public.app_config where key = 'property_video_kie_test_window'), 'absent')),
 -- The published processor-permission contract (the rule of
 -- public.property_video_processor_consent_current()).
 (13, 'processor_consent_contract', coalesce((select case when coalesce(case when jsonb_typeof(value) = 'object' then
                                                                    value->>'token' = 'property-video-jobs-v2'
                                                                    and jsonb_typeof(value->'disclosure_revision') = 'string'
                                                                    and value->>'disclosure_revision' ~ '^[!-~]{1,200}$'
                                                                    and jsonb_typeof(value->'processors') = 'array' and (value->'processors') ? 'kie'
                                                                    and jsonb_typeof(value->'profiles') = 'array' and (value->'profiles') ? 'kie-kling3-4k-steady-v1'
                                                                    and value - array['token','disclosure_revision','processors','profiles'] = '{}'::jsonb
                                                                  else false end, false)
                                                         then 'published: disclosure_revision ' || (value->>'disclosure_revision')
                                                         else 'not published (invalid value): ' || value::text end
                                               from public.app_config where key = 'property_video_processor_consent'), 'not published')),
 -- Every owner-test grant, by id only, with the digest KIE-REVOKE-TEST-GRANT.sql
 -- takes as expected_grant_sha256 (to_jsonb(row) in UTC).
 (14, 'kie_test_grants', (select coalesce(jsonb_agg(jsonb_build_object(
          'grant_id', g.id, 'actor_id', g.actor_id, 'listing_id', g.listing_id, 'library_org_id', g.library_org_id,
          'approval_ref', g.approval_ref, 'operations', cardinality(g.operation_ids), 'sources', jsonb_array_length(g.sources),
          'creates_used', g.creates_used, 'max_creates', g.max_creates, 'cents_used', g.cents_used, 'max_cents', g.max_cents,
          'created_at', g.created_at, 'expires_at', g.expires_at, 'expired', g.expires_at <= now(),
          'revoked', g.revoked_at is not null, 'revoked_at', g.revoked_at,
          'can_still_create', g.revoked_at is null and g.expires_at > now() and g.creates_used < g.max_creates,
          'jobs', (select count(*) from public.property_video_jobs j where j.kie_test_grant_id = g.id),
          'jobs_draining', (select count(*) from public.property_video_jobs j
                             where j.kie_test_grant_id = g.id and j.state in ('queued','generating','quality_review','composing','failed')
                               and j.cancelled_at is null and j.deadline > now()),
          'sha256', encode(sha256(convert_to(to_jsonb(g)::text, 'UTF8')), 'hex')) order by g.created_at, g.id), '[]'::jsonb)::text
        from public.property_video_kie_test_grants g)),
 (15, 'kie_test_grants_can_still_create', (select count(*)::text from public.property_video_kie_test_grants
                                            where revoked_at is null and expires_at > now() and creates_used < max_creates)),
 -- Admitted Kie jobs by the authority each dispatch asks for: a global
 -- activation (no grant) or an owner quality-test grant.
 (16, 'kie_jobs_admitted_by_authority', (select jsonb_build_object('activated_profile', count(*) filter (where kie_test_grant_id is null),
                                                                   'owner_quality_test', count(*) filter (where kie_test_grant_id is not null))::text
                                          from public.property_video_jobs where quality_profile = 'kie-kling3-4k-steady-v1')),
 (17, 'kie_jobs_draining_by_authority', (select jsonb_build_object('activated_profile', count(*) filter (where kie_test_grant_id is null),
                                                                   'owner_quality_test', count(*) filter (where kie_test_grant_id is not null))::text
                                          from public.property_video_jobs
                                         where quality_profile = 'kie-kling3-4k-steady-v1'
                                           and state in ('queued','generating','quality_review','composing','failed')
                                           and cancelled_at is null and deadline > now())),
 -- What KIE-ROUTE-OFF.sql would stop: saved clips of draining Kie jobs without a
 -- supplier receipt (pending, dispatching, or failed and resumable), and the
 -- accepted Kie tasks that stay pollable either way (receipt saved, no clip yet).
 (18, 'kie_unsent_clips', (select jsonb_build_object('jobs', count(distinct s.job_id), 'clips', count(*))::text
                             from public.property_video_job_sources s join public.property_video_jobs j on j.id = s.job_id
                            where j.quality_profile = 'kie-kling3-4k-steady-v1'
                              and j.state in ('queued','generating','quality_review','composing','failed')
                              and j.cancelled_at is null and j.deadline > now()
                              and s.receipt is null and s.state in ('pending','dispatching','failed'))),
 (19, 'kie_accepted_tasks_pollable', (select count(*)::text
                                        from public.property_video_job_sources s join public.property_video_jobs j on j.id = s.job_id
                                       where j.quality_profile = 'kie-kling3-4k-steady-v1'
                                         and s.receipt is not null and s.state = 'processing' and s.clip is null))) v(n, item, value)
order by n;

rollback;
