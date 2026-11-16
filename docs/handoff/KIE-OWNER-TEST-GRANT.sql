-- KIE-OWNER-TEST-GRANT.sql: create ONE owner-only Kie quality-test grant
-- (public.property_video_kie_test_grants) for kie-kling3-4k-steady-v1 while the
-- global production selector stays unchanged (FAL/legacy). OPERATOR STEP,
-- never a migration.
--
-- PREPARED ONLY: running it is NOT authorised. A controlled owner-only quality
-- test first needs the owner's explicit scoped processor/content
-- acknowledgement and Codex's exact bounded grant/request approval; paid tests
-- are paused. approval_ref names that reviewed approval; one approval creates
-- exactly one grant.
--
-- What the grant allows, server-enforced: new property-video admissions by
-- exactly one actor, for exactly one physical listing and its owning library
-- (public.listing_owner_library), on the reviewed Kie identity
-- (public.property_video_quality_identity('kie-kling3-4k-steady-v1'), checked
-- below against the reviewed literal), for 1 to 4 named new operation ids, with
-- exactly the listed sources in manifest order (asset, version, provenance and
-- the prepared-bytes sha256 this script reads through
-- public.property_photo_reference), until it expires (1 to 72 hours) or is
-- revoked, within max_creates createTask calls and max_cents (at most
-- max_creates x 167.5). An admission must name the grant and match all of it
-- (public.property_video_quality_profile_for); before every prospective paid
-- Kie create the runtime asks public.property_video_kie_dispatch_authority,
-- which re-checks the exact scope against the saved job and consumes one create
-- (167.5 cents) atomically. No ordinary customer job can use it. A
-- new-admission hold also stops grant-scoped admissions.
-- Permission: the admitted job still needs the owner's own fresh
-- property-video-jobs-v2 processor permission for the published disclosure
-- revision, given through a client like any user. This script only requires
-- that contract to be published (public.property_video_processor_consent_current()
-- is not NULL); an operator acknowledgement is never user permission.
-- Route window: if the pinned row 7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21 is OFF,
-- this script switches it ON and saves app_config.property_video_kie_test_window
--   {"grant_id":"<new grant id>","route_enabled_before":false,"opened_at":<now()>}
-- The reseller-row invariant accepts the ON row while a grant can still create
-- (not revoked, not expired, creates_used < max_creates) and the selector does
-- not select Kie. Close it with KIE-REVOKE-TEST-GRANT.sql -v route_off=on, or
-- with KIE-ROUTE-OFF.sql once no grant can create.
--
-- Variables (all required; missing, empty or malformed values refuse):
--   actor_id                     the approved owner's auth user id (canonical lowercase uuid)
--   listing_id                   the physical listing id (canonical lowercase uuid)
--   operation_ids                JSON array of 1 to 4 distinct operation ids that this
--                                actor has never used, e.g. '["<uuid>","<uuid>"]'
--   sources                      JSON array of 1 to 10 objects, in manifest order, each exactly
--                                {"photo_asset_id":"<uuid>","photo_version_id":"<1-200 characters>","photo_provenance_id":"<uuid>" or null}
--   max_creates                  1 to 20 createTask calls, at least one per source
--   max_cents                    at least 167.5 per source and at most max_creates x 167.5
--                                (decimal, up to 4 fraction digits)
--   expires_in_hours             1 to 72
--   approval_ref                 the reviewed approval id: 1 to 200 visible ASCII
--                                characters, never used by an earlier grant
--   expected_selector_sha256     digest of the current property_video_quality value, or
--                                absent; it must be absent or a working pre-Kie selector
--                                (never a hold, never Kie: the production default is unchanged)
--   expected_route_enabled       true or false: the pinned row's current enabled
--   expected_test_window_sha256  digest of the current app_config.property_video_kie_test_window
--                                value, or absent
-- A digest is encode(sha256(convert_to(value::text,'UTF8')),'hex') of the stored
-- jsonb value (its canonical text): 64 lowercase hex characters. Read the
-- baselines with docs/handoff/KIE-READONLY-VERIFY.sql. Run exactly as (-X: no
-- psqlrc can change the session), as the role that applies migrations (it owns
-- the tables, sees every row and may SET ROLE service_role for the
-- service-role-only reads):
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -1 -v actor_id='<uuid>' -v listing_id='<uuid>' -v operation_ids='<json-array>' -v sources='<json-array>' -v max_creates='<n>' -v max_cents='<cents>' -v expires_in_hours='<hours>' -v approval_ref='<approval-id>' -v expected_selector_sha256='<sha256-or-absent>' -v expected_route_enabled='<true-or-false>' -v expected_test_window_sha256='<sha256-or-absent>' -f docs/handoff/KIE-OWNER-TEST-GRANT.sql
--
-- Refusals change nothing (and say so): any missing or malformed variable; a
-- deployed Kie identity that is not the reviewed literal; a session that may
-- not see every row; a selector, route or window record that is not exactly its
-- baseline; a selector that is a hold, selects or names Kie, or is not a working
-- pre-Kie selector; a pinned row that differs from the reviewed identity in any
-- field but enabled; a new-admission hold record that is not released or is
-- malformed; an unpublished processor-permission contract; an approval_ref an
-- earlier grant already used (a rerun after a lost reply refuses here); an
-- operation id this actor already used; a listing without an owning library; a
-- source the actor cannot use on this listing or without a prepared-bytes
-- sha256.
-- On success it prints the grant id and the baselines the next operations need,
--   NOTICE:  KIE-OWNER-TEST-GRANT new baselines: grant_id=... expected_grant_sha256=... expected_route_enabled=true expected_test_window_sha256=... expected_selector_sha256=...
-- (expected_grant_sha256 is the digest of to_jsonb(grant row), computed in UTC)
-- and reads the grant back.
--
-- One transaction. All work is one DO block, so it is all-or-nothing even
-- without -1. Lock order (every Kie operator script): the Kie operator-scripts
-- transaction advisory lock, then the selector row, then the pinned route row,
-- then the record rows (hold record, test window record, processor-permission
-- contract), then the new grant row. Admission locks the selector FOR SHARE,
-- then a grant FOR UPDATE, then the route FOR SHARE, so nothing can deadlock.
-- Lock waits are bounded (lock_timeout 15 s); a timeout refuses and changes
-- nothing. It never touches saved jobs, receipts, ledgers, prices, allowances,
-- the selector, the activation or hold record, the FAL route or any other route.
\set ON_ERROR_STOP on

\if :{?actor_id}
\else
\set actor_id ''
\endif
\if :{?listing_id}
\else
\set listing_id ''
\endif
\if :{?operation_ids}
\else
\set operation_ids ''
\endif
\if :{?sources}
\else
\set sources ''
\endif
\if :{?max_creates}
\else
\set max_creates ''
\endif
\if :{?max_cents}
\else
\set max_cents ''
\endif
\if :{?expires_in_hours}
\else
\set expires_in_hours ''
\endif
\if :{?approval_ref}
\else
\set approval_ref ''
\endif
\if :{?expected_selector_sha256}
\else
\set expected_selector_sha256 ''
\endif
\if :{?expected_route_enabled}
\else
\set expected_route_enabled ''
\endif
\if :{?expected_test_window_sha256}
\else
\set expected_test_window_sha256 ''
\endif
-- Stamps and digests (to_jsonb of the grant row) in UTC; bounded lock waits.
set timezone = 'UTC';
set lock_timeout = '15s';
-- Hand the psql values to the DO block (psql does not interpolate inside it).
select set_config('rendprop.kie_grant_actor_id',:'actor_id',false) as actor_id,
       set_config('rendprop.kie_grant_listing_id',:'listing_id',false) as listing_id,
       set_config('rendprop.kie_grant_operation_ids',:'operation_ids',false) as operation_ids,
       set_config('rendprop.kie_grant_sources',:'sources',false) as sources,
       set_config('rendprop.kie_grant_max_creates',:'max_creates',false) as max_creates,
       set_config('rendprop.kie_grant_max_cents',:'max_cents',false) as max_cents,
       set_config('rendprop.kie_grant_expires_in_hours',:'expires_in_hours',false) as expires_in_hours,
       set_config('rendprop.kie_grant_approval_ref',:'approval_ref',false) as approval_ref,
       set_config('rendprop.kie_grant_expected_selector_sha256',:'expected_selector_sha256',false) as expected_selector_sha256,
       set_config('rendprop.kie_grant_expected_route_enabled',:'expected_route_enabled',false) as expected_route_enabled,
       set_config('rendprop.kie_grant_expected_test_window_sha256',:'expected_test_window_sha256',false) as expected_test_window_sha256;

do $kie_owner_test_grant$
declare
 v_kie constant jsonb:=public.property_video_quality_identity('kie-kling3-4k-steady-v1');
 -- The reviewed canonical identity (functions/_shared/property-video-kie-identity.json),
 -- the same literal KIE-ACTIVATION.sql embeds; the disposable-Postgres proof compares them.
 reviewed constant jsonb:='{"profile":"kie-kling3-4k-steady-v1","provider":"kie","model":"kling-3.0/video","route_id":"7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21","task":"video.property_reel_clip_kie","mode":"4K","sound":false,"multi_shots":false,"seconds":5,"unit":"second","unit_cents":33.5,"attempt_cents":167.5,"credits_per_second":67,"usd_per_credit":0.005,"price_source":"https://kie.ai/kling-3-0","price_checked":"2026-10-16","bonus_credits_excluded":true,"max_paid_attempts_per_source":2,"prompt_profile":"steady-property-v1","prompt_template_token":"{scene_noun}","prompt_scene_nouns":["home","event venue","restaurant","store","fitness studio","space"],"prompt_template_sha256":{"fly_through":"5a27f080e3affd92fc1f455f09d29df3b9d82c3bb07de6a4fae644ddba95a785","push_in":"275836a1c183898de223d1f576eba246ca4aa635611a0afd410743a264d472f7","side_glide":"cad745c420ac54cd4339a73fde9ad33322949dbbb6764f596c2d1da24d0848a3","pull_back":"e80e5a784366935080e5ab43d2e8ea395859a6993c6c146bfc96c86b138b8aa9"},"composition_profile":"steady-v2-cfr24","output_fps":24,"output_frames":[120,121],"min_short_side_px":2160,"min_pixels":8000000,"aspect_ratio_wire":"omitted_source_auto","privacy_tier":"trains_by_default","content_license_ack":"kie-terms-2025-08-01-section-3-owner-accepted"}';
 v_uuid_re constant text:='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
 v_actor_txt constant text:=current_setting('rendprop.kie_grant_actor_id',true);
 v_listing_txt constant text:=current_setting('rendprop.kie_grant_listing_id',true);
 v_ops_txt constant text:=current_setting('rendprop.kie_grant_operation_ids',true);
 v_sources_txt constant text:=current_setting('rendprop.kie_grant_sources',true);
 v_max_creates_txt constant text:=current_setting('rendprop.kie_grant_max_creates',true);
 v_max_cents_txt constant text:=current_setting('rendprop.kie_grant_max_cents',true);
 v_hours_txt constant text:=current_setting('rendprop.kie_grant_expires_in_hours',true);
 v_approval constant text:=current_setting('rendprop.kie_grant_approval_ref',true);
 v_expected_selector constant text:=current_setting('rendprop.kie_grant_expected_selector_sha256',true);
 v_expected_route constant text:=current_setting('rendprop.kie_grant_expected_route_enabled',true);
 v_expected_window constant text:=current_setting('rendprop.kie_grant_expected_test_window_sha256',true);
 v_operator_role constant text:=current_setting('role');
 v_actor uuid;
 v_listing uuid;
 v_ops jsonb;
 v_op_ids uuid[];
 v_src jsonb;
 v_n integer;
 v_i integer;
 v_e jsonb;
 v_attempt_cents numeric;
 v_max_creates integer;
 v_max_cents numeric;
 v_hours integer;
 v_selector jsonb;
 v_present boolean;
 v_selector_sha text;
 v_route public.ai_routes;
 v_hold jsonb;
 v_window jsonb;
 v_window_found boolean;
 v_window_sha text;
 v_new_window jsonb;
 v_consent jsonb;
 v_library uuid;
 v_existing uuid;
 v_ref jsonb;
 v_msg text;
 v_grant_sources jsonb:='[]'::jsonb;
 v_grant public.property_video_kie_test_grants;
 v_grant_sha text;
begin
 -- 0. Every input, before any lock.
 if coalesce(v_actor_txt,'') !~ v_uuid_re then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v actor_id=... is required: the approved owner''s auth user id as a canonical lowercase uuid; got "%". Nothing changed.',coalesce(v_actor_txt,'');
 end if;
 v_actor:=v_actor_txt::uuid;
 if coalesce(v_listing_txt,'') !~ v_uuid_re then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v listing_id=... is required: the physical listing id as a canonical lowercase uuid; got "%". Nothing changed.',coalesce(v_listing_txt,'');
 end if;
 v_listing:=v_listing_txt::uuid;
 begin
  v_ops:=v_ops_txt::jsonb;
 exception when others then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v operation_ids=... must be a JSON array of 1 to 4 distinct canonical lowercase uuids (%). Nothing changed.',sqlerrm;
 end;
 if jsonb_typeof(v_ops) is distinct from 'array' then
  raise exception 'KIE-OWNER-TEST-GRANT refused: operation_ids must be a JSON array of 1 to 4 distinct canonical lowercase uuids; got %. Nothing changed.',coalesce(v_ops::text,'nothing');
 end if;
 if jsonb_array_length(v_ops) not between 1 and 4
  or exists(select 1 from jsonb_array_elements(v_ops) x where jsonb_typeof(x) is distinct from 'string' or x#>>'{}' !~ v_uuid_re)
  or (select count(distinct x) from jsonb_array_elements_text(v_ops) x)<>jsonb_array_length(v_ops) then
  raise exception 'KIE-OWNER-TEST-GRANT refused: operation_ids must be a JSON array of 1 to 4 distinct canonical lowercase uuids; got %. Nothing changed.',v_ops::text;
 end if;
 v_op_ids:=array(select x::uuid from jsonb_array_elements_text(v_ops) with ordinality as t(x,n) order by n);
 begin
  v_src:=v_sources_txt::jsonb;
 exception when others then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v sources=... must be a JSON array of 1 to 10 source objects in manifest order (%). Nothing changed.',sqlerrm;
 end;
 if jsonb_typeof(v_src) is distinct from 'array' then
  raise exception 'KIE-OWNER-TEST-GRANT refused: sources must be a JSON array of 1 to 10 source objects in manifest order; got %. Nothing changed.',coalesce(v_src::text,'nothing');
 end if;
 v_n:=jsonb_array_length(v_src);
 if v_n not between 1 and 10 then
  raise exception 'KIE-OWNER-TEST-GRANT refused: sources must hold 1 to 10 source objects; got %. Nothing changed.',v_n;
 end if;
 for v_i in 0..v_n-1 loop
  v_e:=v_src->v_i;
  if jsonb_typeof(v_e) is distinct from 'object' then
   raise exception 'KIE-OWNER-TEST-GRANT refused: sources[%] must be exactly {"photo_asset_id":"<uuid>","photo_version_id":"<1-200 characters>","photo_provenance_id":"<uuid>" or null}; got %. Nothing changed.',v_i,v_e::text;
  end if;
  if not (v_e ?& array['photo_asset_id','photo_version_id','photo_provenance_id'])
   or v_e - array['photo_asset_id','photo_version_id','photo_provenance_id']<>'{}'::jsonb
   or jsonb_typeof(v_e->'photo_asset_id') is distinct from 'string' or v_e->>'photo_asset_id' !~ v_uuid_re
   or jsonb_typeof(v_e->'photo_version_id') is distinct from 'string' or length(v_e->>'photo_version_id') not between 1 and 200
   or not (jsonb_typeof(v_e->'photo_provenance_id')='null'
           or (jsonb_typeof(v_e->'photo_provenance_id')='string' and v_e->>'photo_provenance_id' ~ v_uuid_re)) then
   raise exception 'KIE-OWNER-TEST-GRANT refused: sources[%] must be exactly {"photo_asset_id":"<uuid>","photo_version_id":"<1-200 characters>","photo_provenance_id":"<uuid>" or null}; got %. Nothing changed.',v_i,v_e::text;
  end if;
 end loop;
 -- The deployed identity must be exactly the reviewed one (it fixes the price).
 if v_kie is distinct from reviewed then
  raise exception 'KIE-OWNER-TEST-GRANT refused: the deployed Kie identity (md5 %) is not the reviewed canonical identity in this script. Nothing changed.',coalesce(md5(v_kie::text),'missing');
 end if;
 v_attempt_cents:=(v_kie->>'attempt_cents')::numeric;
 -- Each text is matched before it is cast, so a malformed value only refuses.
 if coalesce(v_max_creates_txt,'') !~ '^[0-9]{1,2}$' then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v max_creates=... must be 1 to 20 createTask calls and at least one per source (%); got "%". Nothing changed.',v_n,coalesce(v_max_creates_txt,'');
 end if;
 v_max_creates:=v_max_creates_txt::integer;
 if v_max_creates not between 1 and 20 or v_max_creates<v_n then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v max_creates=... must be 1 to 20 createTask calls and at least one per source (%); got %. Nothing changed.',v_n,v_max_creates;
 end if;
 if coalesce(v_max_cents_txt,'') !~ '^[0-9]{1,7}([.][0-9]{1,4})?$' then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v max_cents=... must be a decimal number of cents (up to 4 fraction digits); got "%". Nothing changed.',coalesce(v_max_cents_txt,'');
 end if;
 v_max_cents:=v_max_cents_txt::numeric;
 if v_max_cents<v_n*v_attempt_cents or v_max_cents>v_max_creates*v_attempt_cents then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v max_cents=... must be from % (% source(s) x %) to % (max_creates % x %); got %. Nothing changed.',
   v_n*v_attempt_cents,v_n,v_attempt_cents,v_max_creates*v_attempt_cents,v_max_creates,v_attempt_cents,v_max_cents;
 end if;
 if coalesce(v_hours_txt,'') !~ '^[0-9]{1,2}$' then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v expires_in_hours=... must be 1 to 72; got "%". Nothing changed.',coalesce(v_hours_txt,'');
 end if;
 v_hours:=v_hours_txt::integer;
 if v_hours not between 1 and 72 then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v expires_in_hours=... must be 1 to 72; got %. Nothing changed.',v_hours;
 end if;
 if coalesce(v_approval,'') !~ '^[!-~]{1,200}$' then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v approval_ref=... is required: the reviewed approval id, 1 to 200 visible ASCII characters; got % character(s). Nothing changed.',length(coalesce(v_approval,''));
 end if;
 if coalesce(v_expected_selector,'') !~ '^([0-9a-f]{64}|absent)$' then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v expected_selector_sha256=... is required: the sha256 (64 lowercase hex characters) of the current property_video_quality value, or the word absent, as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(v_expected_selector,'');
 end if;
 if coalesce(v_expected_route,'') not in ('true','false') then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v expected_route_enabled=... is required: true or false, the pinned Kie route''s current enabled value as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(v_expected_route,'');
 end if;
 if coalesce(v_expected_window,'') !~ '^([0-9a-f]{64}|absent)$' then
  raise exception 'KIE-OWNER-TEST-GRANT refused: -v expected_test_window_sha256=... is required: the sha256 of the current app_config.property_video_kie_test_window value, or the word absent, as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(v_expected_window,'');
 end if;
 -- A row hidden by row level security would be missed: refuse instead.
 if not coalesce((select bool_and(not c.relrowsecurity or r.rolsuper or r.rolbypassrls or (c.relowner=r.oid and not c.relforcerowsecurity))
                    from pg_class c cross join pg_roles r
                   where r.rolname=current_user
                     and c.oid in ('public.app_config'::regclass,'public.ai_routes'::regclass,'public.property_video_jobs'::regclass,
                                   'public.property_video_refused_operations'::regclass,'public.property_video_kie_test_grants'::regclass)),false) then
  raise exception 'KIE-OWNER-TEST-GRANT refused: role % may not see every row it reads (row level security); run it as the role that applies migrations. Nothing changed.',current_user;
 end if;
 -- Operator scripts never interleave, even while there is no selector row to lock.
 perform pg_advisory_xact_lock(hashtextextended('rendprop:kie-operator-scripts',0));
 -- 1. Selector first (admission's lock order): exactly as read, and the
 -- unchanged production default (absent or a working pre-Kie selector).
 select value into v_selector from public.app_config where key='property_video_quality' for update;
 v_present:=found;
 v_selector_sha:=case when v_present then encode(sha256(convert_to(v_selector::text,'UTF8')),'hex') else 'absent' end;
 if v_selector_sha is distinct from v_expected_selector then
  raise exception 'KIE-OWNER-TEST-GRANT refused: property_video_quality is not the expected baseline (expected %, found % = %): it changed after it was read. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   v_expected_selector,v_selector_sha,case when v_present then v_selector::text else 'absent' end;
 end if;
 if v_present and coalesce(jsonb_typeof(v_selector)='object' and v_selector->>'profile'='hold-new-paid-admissions',false) then
  raise exception 'KIE-OWNER-TEST-GRANT refused: a new-admission hold is active (property_video_quality %): it would refuse the owner test too. Nothing changed.',v_selector::text;
 end if;
 if v_present and not coalesce(jsonb_typeof(v_selector)='object' and v_selector->>'profile' is distinct from 'kie-kling3-4k-steady-v1'
                               and (v_selector->'enabled'='false'::jsonb
                                    or (v_selector->'enabled'='true'::jsonb and v_selector->>'profile' in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2'))),false) then
  raise exception 'KIE-OWNER-TEST-GRANT refused: property_video_quality % is not the unchanged production default an owner test runs beside (absent, "enabled" false, or true with profile fal-kling3-4k-v1 or fal-kling3-4k-steady-v2; never Kie). Nothing changed.',v_selector::text;
 end if;
 -- 2. The pinned row second: exactly the expected enabled value, and still
 -- exactly the reviewed row in every other field.
 select * into v_route from public.ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21' for update;
 if not found then
  raise exception 'KIE-OWNER-TEST-GRANT refused: pinned Kie route differs from the reviewed identity (row missing). Nothing changed.';
 end if;
 if v_route.enabled::text is distinct from v_expected_route then
  raise exception 'KIE-OWNER-TEST-GRANT refused: the pinned Kie route is enabled=% but -v expected_route_enabled=%: it changed after it was read, or this grant already ran and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   v_route.enabled::text,v_expected_route;
 end if;
 if (v_route.task,v_route.position,v_route.provider,v_route.model,v_route.unit,v_route.unit_cents,v_route.capabilities,v_route.max_latency_s,
      v_route.min_plan,v_route.same_model_as,v_route.privacy_tier,v_route.retire_after,v_route.params)
     is distinct from ('video.property_reel_clip_kie'::text,1,'kie'::text,'kling-3.0/video'::text,'second'::text,33.5::numeric,
      array['i2v','1080p','5s','native4k','preserve_photo']::text[],1800,'free'::text,'kling_3_pro'::text,'trains_by_default'::text,
      null::date,'{"kie_mode":"4K","sound":false}'::jsonb)
  or v_route.id::text is distinct from v_kie->>'route_id' or v_route.task is distinct from v_kie->>'task'
  or v_route.provider is distinct from v_kie->>'provider' or v_route.model is distinct from v_kie->>'model'
  or v_route.unit is distinct from v_kie->>'unit' or v_route.unit_cents is distinct from (v_kie->>'unit_cents')::numeric
  or v_route.privacy_tier is distinct from v_kie->>'privacy_tier'
  or v_route.params is distinct from jsonb_build_object('kie_mode',v_kie->'mode','sound',v_kie->'sound')
  or (select count(*) from public.ai_routes where task='video.property_reel_clip_kie')<>1 then
  raise exception 'KIE-OWNER-TEST-GRANT refused: pinned Kie route differs from the reviewed identity (%). Nothing changed.',
   (to_jsonb(v_route)-'created_at'-'updated_at'-'note')::text;
 end if;
 -- 3. Records, in the operator scripts' fixed order. No new-admission hold may
 -- be outstanding, and its record must be readable.
 select value into v_hold from public.app_config where key='property_video_quality_hold' for share;
 if found then
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
   raise exception 'KIE-OWNER-TEST-GRANT refused: the new-admission hold record app_config.property_video_quality_hold is malformed (%). Nothing changed; it needs a reviewed manual correction.',v_hold::text;
  end if;
  if v_hold->'released_at'='null'::jsonb then
   raise exception 'KIE-OWNER-TEST-GRANT refused: new-admission hold % (held %) is not released. Nothing changed.',v_hold->>'hold_id',v_hold->>'held_at';
  end if;
 end if;
 -- The route-window record: exactly the expected baseline.
 select value into v_window from public.app_config where key='property_video_kie_test_window' for update;
 v_window_found:=found;
 v_window_sha:=case when v_window_found then encode(sha256(convert_to(v_window::text,'UTF8')),'hex') else 'absent' end;
 if v_window_sha is distinct from v_expected_window then
  raise exception 'KIE-OWNER-TEST-GRANT refused: the route-window record app_config.property_video_kie_test_window is not the expected baseline (expected %, found %). Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   v_expected_window,v_window_sha;
 end if;
 perform 1 from public.app_config where key='property_video_processor_consent' for share;
 -- One reviewed approval creates exactly one grant: a rerun after a lost reply
 -- stops here and changes nothing.
 select id into v_existing from public.property_video_kie_test_grants where approval_ref=v_approval order by created_at limit 1;
 if found then
  raise exception 'KIE-OWNER-TEST-GRANT refused: approval % already created grant % (one approval, one grant; after a lost reply KIE-READONLY-VERIFY.sql lists it). Nothing changed.',v_approval,v_existing;
 end if;
 -- The named operations must be new for this actor.
 if exists(select 1 from public.property_video_jobs where actor_id=v_actor and operation_id=any(v_op_ids))
  or exists(select 1 from public.property_video_refused_operations where actor_id=v_actor and operation_id=any(v_op_ids)) then
  raise exception 'KIE-OWNER-TEST-GRANT refused: this actor already used one of the operation ids % (a saved or refused video). Name new operation ids. Nothing changed.',v_ops::text;
 end if;
 v_library:=public.listing_owner_library(v_listing);
 if v_library is null then
  raise exception 'KIE-OWNER-TEST-GRANT refused: listing % has no owning library (missing or deleted). Nothing changed.',v_listing;
 end if;
 -- 4. Service-role-only reads: the published permission contract and each
 -- source's prepared-bytes sha256, exactly as admission and dispatch read them.
 perform set_config('role','service_role',true);
 v_consent:=public.property_video_processor_consent_current();
 if v_consent is null then
  raise exception 'KIE-OWNER-TEST-GRANT refused: no processor-permission contract is published (public.property_video_processor_consent_current() is NULL). The owner must give the fresh property-video-jobs-v2 permission for a published disclosure revision through a client like any user; an operator acknowledgement is never user permission. Nothing changed.';
 end if;
 for v_i in 0..v_n-1 loop
  v_e:=v_src->v_i;
  begin
   v_ref:=public.property_photo_reference(v_actor,v_listing,(v_e->>'photo_asset_id')::uuid,(v_e->>'photo_provenance_id')::uuid);
  exception when others then
   get stacked diagnostics v_msg=message_text;
   raise exception 'KIE-OWNER-TEST-GRANT refused: sources[%] (photo_asset_id %) is not usable by this actor on this listing: %. Nothing changed.',v_i,v_e->>'photo_asset_id',v_msg;
  end;
  if coalesce(v_ref->>'sha256','') !~ '^[a-f0-9]{64}$' then
   raise exception 'KIE-OWNER-TEST-GRANT refused: sources[%] (photo_asset_id %) has no prepared-bytes sha256. Nothing changed.',v_i,v_e->>'photo_asset_id';
  end if;
  v_grant_sources:=v_grant_sources||jsonb_build_array(jsonb_build_object('photo_asset_id',v_e->'photo_asset_id','photo_version_id',v_e->'photo_version_id',
   'photo_provenance_id',v_e->'photo_provenance_id','sha256',v_ref->'sha256'));
 end loop;
 perform set_config('role',v_operator_role,true);
 -- 5. The grant (its guard re-checks identity, library, sources and limits).
 insert into public.property_video_kie_test_grants(profile,quality_identity,actor_id,library_org_id,listing_id,operation_ids,sources,
  max_creates,max_cents,approval_ref,expires_at)
 values('kie-kling3-4k-steady-v1',v_kie,v_actor,v_library,v_listing,v_op_ids,v_grant_sources,
  v_max_creates,v_max_cents,v_approval,now()+v_hours*interval '1 hour')
 returning * into v_grant;
 -- 6. The route window: only when the pinned row is OFF.
 if not v_route.enabled then
  update public.ai_routes set enabled=true,updated_at=now() where id=v_route.id;
  v_new_window:=jsonb_build_object('grant_id',v_grant.id,'route_enabled_before',v_route.enabled,'opened_at',now());
  if v_window_found then
   update public.app_config set value=v_new_window,updated_at=now() where key='property_video_kie_test_window';
  else
   insert into public.app_config(key,value,updated_at) values('property_video_kie_test_window',v_new_window,now()) on conflict(key) do nothing;
   if not found then
    raise exception 'KIE-OWNER-TEST-GRANT refused: the route-window record was created concurrently. Nothing changed; rerun.';
   end if;
  end if;
  v_window_sha:=encode(sha256(convert_to(v_new_window::text,'UTF8')),'hex');
 end if;
 v_grant_sha:=encode(sha256(convert_to(to_jsonb(v_grant)::text,'UTF8')),'hex');
 raise notice 'KIE-OWNER-TEST-GRANT done: grant % for actor % on listing % (library %): % operation(s), % source(s), up to % create(s) and % cents, expires %; approval %; pinned Kie route %; consent disclosure revision %',
  v_grant.id,v_actor,v_listing,v_library,cardinality(v_op_ids),v_n,v_max_creates,v_max_cents,v_grant.expires_at,v_approval,
  case when v_route.enabled then 'already ON' else 'switched ON (route window opened)' end,v_consent->>'disclosure_revision';
 raise notice 'KIE-OWNER-TEST-GRANT new baselines: grant_id=% expected_grant_sha256=% expected_route_enabled=true expected_test_window_sha256=% expected_selector_sha256=%',
  v_grant.id,v_grant_sha,v_window_sha,v_selector_sha;
end
$kie_owner_test_grant$;

-- Read the grant back (no PII beyond ids), with the digests the next
-- operations take as their baselines.
select g.id as grant_id,g.actor_id,g.listing_id,g.library_org_id,cardinality(g.operation_ids) as operations,
       jsonb_array_length(g.sources) as sources,g.creates_used||'/'||g.max_creates as creates,g.cents_used||'/'||g.max_cents as cents,
       g.expires_at,encode(sha256(convert_to(to_jsonb(g)::text,'UTF8')),'hex') as grant_sha256,
       r.enabled as kie_route_enabled,
       coalesce(w.value::text,'none') as property_video_kie_test_window,
       coalesce(encode(sha256(convert_to(w.value::text,'UTF8')),'hex'),'absent') as property_video_kie_test_window_sha256,
       coalesce(encode(sha256(convert_to(c.value::text,'UTF8')),'hex'),'absent') as property_video_quality_sha256
  from public.property_video_kie_test_grants g
  left join public.ai_routes r on r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'
  left join public.app_config w on w.key='property_video_kie_test_window'
  left join public.app_config c on c.key='property_video_quality'
 where g.approval_ref=current_setting('rendprop.kie_grant_approval_ref');
