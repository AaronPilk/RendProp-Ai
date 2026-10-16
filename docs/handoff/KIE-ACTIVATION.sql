-- KIE-ACTIVATION.sql: owner-approved GLOBAL activation of the Kie Kling 3.0
-- native-4K property-video profile kie-kling3-4k-steady-v1 for every new paid
-- property-video admission. OPERATOR STEP, never a migration.
--
-- PREPARED ONLY: running it is NOT authorised. Broad customer activation needs
-- the owner's and Codex's explicit approval after the public disclosures,
-- notices and client consent rollout have shipped. A restricted owner-only
-- quality test never uses this script: docs/handoff/KIE-OWNER-TEST-GRANT.sql
-- leaves the global selector unchanged.
--
-- Preconditions (all required):
--   * migrations 20261016100000_property_video_kie_kling3_4k_profile.sql (it
--     seeds the pinned route row OFF, AI-router contract section 3) and
--     20261016110000_property_video_kie_scope_consent_drain.sql are applied, and
--     docs/handoff/KIE-READONLY-VERIFY.sql shows every migration check true;
--   * the edge functions that understand the Kie profile, the v2 processor
--     permission and the Kie dispatch authority are deployed;
--   * the owner has accepted Kie Terms section 3 (customer content is licensed
--     to Kie "for the purpose of operating and improving our services"). The
--     acknowledgement string written below is the record of that decision;
--   * the published privacy/consent disclosure names Kie as a processor. Its
--     identifier (a document version or URL) is REQUIRED as
--     -v processor_disclosure=... and is saved with the activation;
--   * the processor-permission contract customers accept is published:
--     public.property_video_processor_consent_current() is not NULL
--     (app_config.property_video_processor_consent). Its disclosure_revision is
--     saved as consent_disclosure_revision. Every new Kie job still needs its
--     own customer's fresh property-video-jobs-v2 permission for the
--     then-current revision: neither the owner acknowledgement nor the
--     disclosure identifier is user permission.
--
-- Read the three baselines with docs/handoff/KIE-READONLY-VERIFY.sql (state rows
-- property_video_quality_sha256, kie_route_enabled and
-- kie_activation_record_sha256), then run exactly as (-X: no psqlrc can change
-- the session), as the role that applies migrations (it owns the tables, sees
-- every row and may SET ROLE service_role for the one service-role-only read):
--   psql "<db-url>" -X -v ON_ERROR_STOP=1 -1 -v processor_disclosure='<identifier>' -v expected_selector_sha256='<sha256-or-absent>' -v expected_route_enabled='<true-or-false>' -v expected_record_sha256='<sha256-or-absent>' -f docs/handoff/KIE-ACTIVATION.sql
-- Variables (all required; missing, empty or malformed values refuse):
--   processor_disclosure      1 to 200 visible ASCII characters (0x21-0x7E): no
--                             spaces, tabs, line breaks, control or non-ASCII
--                             characters (percent-encode a URL), e.g.
--                             privacy-policy-2026-10-16 or
--                             https://example.com/privacy?v=2026-10-16#processors
--                             (keep the single quotes: ?, & and # mean
--                             something to the shell);
--   expected_selector_sha256  digest of the current property_video_quality
--                             value, or the word absent when the key does not
--                             exist;
--   expected_route_enabled    true or false: the pinned row's current enabled;
--   expected_record_sha256    digest of the current
--                             app_config.property_video_quality_kie_activation
--                             value, or absent.
-- A digest is encode(sha256(convert_to(value::text,'UTF8')),'hex') of the
-- stored jsonb value (its canonical text): 64 lowercase hex characters.
--
-- One transaction. All work is one DO block, so it is all-or-nothing even
-- without -1, and any refusal changes nothing (and says so):
--   0. checks every variable, that this session sees every app_config and
--      ai_routes row, and that the deployed
--      property_video_quality_identity('kie-kling3-4k-steady-v1') is exactly
--      the reviewed canonical identity embedded below, before any lock;
--   1. locks app_config.property_video_quality and compares it with
--      expected_selector_sha256. It refuses any other value, a new-admission
--      hold (release it first: docs/handoff/KIE-RELEASE-HOLD.sql), a value that
--      already names the Kie profile, or one that is not a working pre-Kie
--      selector ("enabled" false, or true with profile fal-kling3-4k-v1 or
--      fal-kling3-4k-steady-v2): the saved value must be one that
--      KIE-ROLLBACK.sql can restore as it was. Then it PRINTS the value as
--        NOTICE:  KIE-ACTIVATION previous property_video_quality: {...}
--      or "absent" when the key does not exist;
--   2. locks pinned ai_routes row 7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21, compares
--      its enabled with expected_route_enabled and verifies that it still equals
--      the reviewed frozen identity in every field except enabled;
--   3. locks the activation record and compares it with expected_record_sha256,
--      then refuses a new-admission hold record
--      (app_config.property_video_quality_hold) that is not released or is
--      malformed, and an unpublished processor-permission contract;
--   4. enables only that row;
--   5. sets property_video_quality (inserting the key when it was absent) to exactly
--        {"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}
--   6. saves the activation record app_config.property_video_quality_kie_activation,
--      replacing exactly the record its baseline named:
--        {"profile":"kie-kling3-4k-steady-v1","route_id":"7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21",
--         "previous_selector":{"present":true,"value":<exact previous value>} or {"present":false},
--         "route_enabled_before":<boolean>,"processor_disclosure":"<identifier>",
--         "consent_disclosure_revision":"<published disclosure_revision>",
--         "vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted",
--         "activated_at":<now()>,"rolled_back_at":null,"rollback_mode":null,"route_disabled_at":null}
--      KIE-ROLLBACK.sql restores previous_selector from it (never a default or
--      a supplied value) and stamps rolled_back_at/rollback_mode/route_disabled_at;
--      the database invariant accepts the ON row under the Kie selector only
--      with this record;
--   7. prints the baselines the next operation (KIE-ROLLBACK.sql) needs,
--        NOTICE:  KIE-ACTIVATION new baselines: expected_selector_sha256=... expected_route_enabled=true expected_record_sha256=...
--      and reads the result back with the same digests.
-- Lost reply: rerunning with the same baselines refuses (the selector and the
-- record no longer match them) and overwrites nothing; KIE-READONLY-VERIFY.sql
-- shows the true state.
-- It never touches saved jobs, receipts, holds, ledgers, prices, allowances,
-- grants, the FAL route, any other route or any config key other than
-- property_video_quality and its activation record. Lock order (every Kie
-- operator script): one transaction advisory lock shared only by the Kie
-- operator scripts (two runs never interleave, even while the selector key is
-- absent), then the selector row, then the pinned route row, then the record
-- rows (activation record, hold record, processor-permission contract), which
-- no admission locks. Admission locks the selector FOR SHARE, then an
-- owner-test grant FOR UPDATE, then the route FOR SHARE, so an in-flight
-- admission finishes on the old state first and nothing can deadlock. Lock
-- waits are bounded (lock_timeout 15 s); a timeout refuses and changes nothing.
\set ON_ERROR_STOP on

\if :{?processor_disclosure}
\else
\set processor_disclosure ''
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
select set_config('rendprop.kie_activation_processor_disclosure',:'processor_disclosure',false) as processor_disclosure,
       set_config('rendprop.kie_activation_expected_selector_sha256',:'expected_selector_sha256',false) as expected_selector_sha256,
       set_config('rendprop.kie_activation_expected_route_enabled',:'expected_route_enabled',false) as expected_route_enabled,
       set_config('rendprop.kie_activation_expected_record_sha256',:'expected_record_sha256',false) as expected_record_sha256;

do $kie_activation$
declare
 kie constant jsonb:=public.property_video_quality_identity('kie-kling3-4k-steady-v1');
 -- The reviewed canonical identity (functions/_shared/property-video-kie-identity.json,
 -- which the runtime compiles in); the disposable-Postgres proof compares them.
 reviewed constant jsonb:='{"profile":"kie-kling3-4k-steady-v1","provider":"kie","model":"kling-3.0/video","route_id":"7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21","task":"video.property_reel_clip_kie","mode":"4K","sound":false,"multi_shots":false,"seconds":5,"unit":"second","unit_cents":33.5,"attempt_cents":167.5,"credits_per_second":67,"usd_per_credit":0.005,"price_source":"https://kie.ai/kling-3-0","price_checked":"2026-10-16","bonus_credits_excluded":true,"max_paid_attempts_per_source":2,"prompt_profile":"steady-property-v1","prompt_template_token":"{scene_noun}","prompt_scene_nouns":["home","event venue","restaurant","store","fitness studio","space"],"prompt_template_sha256":{"fly_through":"5a27f080e3affd92fc1f455f09d29df3b9d82c3bb07de6a4fae644ddba95a785","push_in":"275836a1c183898de223d1f576eba246ca4aa635611a0afd410743a264d472f7","side_glide":"cad745c420ac54cd4339a73fde9ad33322949dbbb6764f596c2d1da24d0848a3","pull_back":"e80e5a784366935080e5ab43d2e8ea395859a6993c6c146bfc96c86b138b8aa9"},"composition_profile":"steady-v2-cfr24","output_fps":24,"output_frames":[120,121],"min_short_side_px":2160,"min_pixels":8000000,"aspect_ratio_wire":"omitted_source_auto","privacy_tier":"trains_by_default","content_license_ack":"kie-terms-2025-08-01-section-3-owner-accepted"}';
 target constant jsonb:='{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}';
 disclosure constant text:=current_setting('rendprop.kie_activation_processor_disclosure',true);
 expected_selector constant text:=current_setting('rendprop.kie_activation_expected_selector_sha256',true);
 expected_route constant text:=current_setting('rendprop.kie_activation_expected_route_enabled',true);
 expected_record constant text:=current_setting('rendprop.kie_activation_expected_record_sha256',true);
 operator_role constant text:=current_setting('role');
 previous jsonb;
 present boolean;
 selector_sha text;
 route public.ai_routes;
 old_record jsonb;
 old_record_sha text;
 hold_rec jsonb;
 consent jsonb;
 activation jsonb;
begin
 -- 0. Every input, before any lock. The published privacy/consent disclosure
 -- that names Kie, as a bounded identifier.
 if coalesce(disclosure,'')='' then
  raise exception 'KIE-ACTIVATION refused: -v processor_disclosure=... is required: the identifier (document version or URL) of the published privacy/consent disclosure that names Kie as a processor. Nothing changed.';
 end if;
 if length(disclosure)>200 or disclosure !~ '^[!-~]+$' then
  raise exception 'KIE-ACTIVATION refused: processor_disclosure must be 1 to 200 visible ASCII characters (no spaces, tabs, line breaks, control or non-ASCII characters; percent-encode a URL); got % character(s). Nothing changed.',length(disclosure);
 end if;
 -- The exact baselines the operator read; never optional, never defaulted.
 if coalesce(expected_selector,'') !~ '^([0-9a-f]{64}|absent)$' then
  raise exception 'KIE-ACTIVATION refused: -v expected_selector_sha256=... is required: the sha256 (64 lowercase hex characters) of the current property_video_quality value, or the word absent, as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(expected_selector,'');
 end if;
 if coalesce(expected_route,'') not in ('true','false') then
  raise exception 'KIE-ACTIVATION refused: -v expected_route_enabled=... is required: true or false, the pinned Kie route''s current enabled value as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(expected_route,'');
 end if;
 if coalesce(expected_record,'') !~ '^([0-9a-f]{64}|absent)$' then
  raise exception 'KIE-ACTIVATION refused: -v expected_record_sha256=... is required: the sha256 of the current app_config.property_video_quality_kie_activation value, or the word absent, as KIE-READONLY-VERIFY.sql prints it; got "%". Nothing changed.',coalesce(expected_record,'');
 end if;
 -- The deployed identity must be exactly the reviewed one, and the literal
 -- written below exactly what the deployed selector accepts.
 if kie is distinct from reviewed or target->>'profile' is distinct from kie->>'profile'
  or target->'vendor_content_license' is distinct from kie->'content_license_ack' then
  raise exception 'KIE-ACTIVATION refused: the deployed Kie identity (md5 %) is not the reviewed canonical identity in this script. Nothing changed.',coalesce(md5(kie::text),'missing');
 end if;
 -- A row hidden by row level security would read as absent: refuse instead.
 if not coalesce((select bool_and(not c.relrowsecurity or r.rolsuper or r.rolbypassrls or (c.relowner=r.oid and not c.relforcerowsecurity))
                    from pg_class c cross join pg_roles r
                   where r.rolname=current_user and c.oid in ('public.app_config'::regclass,'public.ai_routes'::regclass)),false) then
  raise exception 'KIE-ACTIVATION refused: role % may not see every app_config/ai_routes row (row level security); run it as the role that applies migrations. Nothing changed.',current_user;
 end if;
 -- Operator scripts never interleave, even while there is no selector row to lock.
 perform pg_advisory_xact_lock(hashtextextended('rendprop:kie-operator-scripts',0));
 -- 1. Selector first (admission's lock order): exactly the expected baseline,
 -- then printed before any change.
 select value into previous from public.app_config where key='property_video_quality' for update;
 present:=found;
 selector_sha:=case when present then encode(sha256(convert_to(previous::text,'UTF8')),'hex') else 'absent' end;
 if selector_sha is distinct from expected_selector then
  raise exception 'KIE-ACTIVATION refused: property_video_quality is not the expected baseline (expected %, found % = %): it changed after it was read, or this activation already ran and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   expected_selector,selector_sha,case when present then previous::text else 'absent' end;
 end if;
 if present and coalesce(jsonb_typeof(previous)='object' and previous->>'profile'='hold-new-paid-admissions',false) then
  raise exception 'KIE-ACTIVATION refused: a new-admission hold is active (property_video_quality %); release it first with docs/handoff/KIE-RELEASE-HOLD.sql. Nothing changed.',previous::text;
 end if;
 if present and previous->>'profile'='kie-kling3-4k-steady-v1' then
  raise exception 'KIE-ACTIVATION refused: property_video_quality already names the Kie profile (%). Nothing changed. The activation record holds the rollback target.',previous::text;
 end if;
 if present and not coalesce(jsonb_typeof(previous)='object'
                             and (previous->'enabled'='false'::jsonb
                                  or (previous->'enabled'='true'::jsonb and previous->>'profile' in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2'))),false) then
  raise exception 'KIE-ACTIVATION refused: property_video_quality % is not a working pre-Kie selector ("enabled" false, or true with profile fal-kling3-4k-v1 or fal-kling3-4k-steady-v2), so KIE-ROLLBACK.sql could not restore it. Nothing changed.',previous::text;
 end if;
 raise notice 'KIE-ACTIVATION previous property_video_quality: %',case when present then previous::text else 'absent' end;
 -- 2. The pinned row second: exactly the expected enabled value, and still
 -- exactly the reviewed row in every other field.
 select * into route from public.ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21' for update;
 if not found then
  raise exception 'KIE-ACTIVATION refused: pinned Kie route differs from the reviewed identity (row missing). Nothing changed.';
 end if;
 if route.enabled::text is distinct from expected_route then
  raise exception 'KIE-ACTIVATION refused: the pinned Kie route is enabled=% but -v expected_route_enabled=%: it changed after it was read, or this activation already ran and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   route.enabled::text,expected_route;
 end if;
 if (route.task,route.position,route.provider,route.model,route.unit,route.unit_cents,route.capabilities,route.max_latency_s,
      route.min_plan,route.same_model_as,route.privacy_tier,route.retire_after,route.params)
     is distinct from ('video.property_reel_clip_kie'::text,1,'kie'::text,'kling-3.0/video'::text,'second'::text,33.5::numeric,
      array['i2v','1080p','5s','native4k','preserve_photo']::text[],1800,'free'::text,'kling_3_pro'::text,'trains_by_default'::text,
      null::date,'{"kie_mode":"4K","sound":false}'::jsonb)
  or route.id::text is distinct from kie->>'route_id' or route.task is distinct from kie->>'task'
  or route.provider is distinct from kie->>'provider' or route.model is distinct from kie->>'model'
  or route.unit is distinct from kie->>'unit' or route.unit_cents is distinct from (kie->>'unit_cents')::numeric
  or route.privacy_tier is distinct from kie->>'privacy_tier'
  or route.params is distinct from jsonb_build_object('kie_mode',kie->'mode','sound',kie->'sound')
  or (select count(*) from public.ai_routes where task='video.property_reel_clip_kie')<>1 then
  raise exception 'KIE-ACTIVATION refused: pinned Kie route differs from the reviewed identity (%). Nothing changed.',
   (to_jsonb(route)-'created_at'-'updated_at'-'note')::text;
 end if;
 -- 3. Records last, in the operator scripts' fixed order; no admission locks
 -- them. The activation record must be exactly the expected baseline.
 select value into old_record from public.app_config where key='property_video_quality_kie_activation' for update;
 old_record_sha:=case when found then encode(sha256(convert_to(old_record::text,'UTF8')),'hex') else 'absent' end;
 if old_record_sha is distinct from expected_record then
  raise exception 'KIE-ACTIVATION refused: the activation record app_config.property_video_quality_kie_activation is not the expected baseline (expected %, found %): it changed after it was read, or this activation already ran and its reply was lost. Nothing changed; run KIE-READONLY-VERIFY.sql and decide again.',
   expected_record,old_record_sha;
 end if;
 -- No new-admission hold may be outstanding, and its record must be readable.
 select value into hold_rec from public.app_config where key='property_video_quality_hold' for share;
 if found then
  if not coalesce(case when jsonb_typeof(hold_rec)='object' then
                   hold_rec ?& array['hold_id','previous_selector','reason','held_at','released_at']
                   and hold_rec - array['hold_id','previous_selector','reason','held_at','released_at']='{}'::jsonb
                   and jsonb_typeof(hold_rec->'hold_id')='string'
                   and hold_rec->>'hold_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   and case when jsonb_typeof(hold_rec->'previous_selector')='object' then
                         hold_rec->'previous_selector'='{"present":false}'::jsonb
                         or ((hold_rec->'previous_selector') ?& array['present','value']
                             and (hold_rec->'previous_selector') - array['present','value']='{}'::jsonb
                             and hold_rec#>'{previous_selector,present}'='true'::jsonb
                             and coalesce(hold_rec#>>'{previous_selector,value,profile}','')<>'hold-new-paid-admissions')
                       else false end
                   and jsonb_typeof(hold_rec->'reason')='string' and hold_rec->>'reason' ~ '^[ -~]{1,200}$'
                   and jsonb_typeof(hold_rec->'held_at')='string'
                   and jsonb_typeof(hold_rec->'released_at') in ('null','string')
                  else false end,false) then
   raise exception 'KIE-ACTIVATION refused: the new-admission hold record app_config.property_video_quality_hold is malformed (%), so whether new admissions are held is unknown. Nothing changed; it needs a reviewed manual correction (KIE-READONLY-VERIFY.sql shows it).',hold_rec::text;
  end if;
  if hold_rec->'released_at'='null'::jsonb then
   raise exception 'KIE-ACTIVATION refused: new-admission hold % (held %) is not released; release it with docs/handoff/KIE-RELEASE-HOLD.sql first. Nothing changed.',hold_rec->>'hold_id',hold_rec->>'held_at';
  end if;
 end if;
 -- The published processor-permission contract (customers accept it in a client;
 -- it is read, never written, here). It executes only as service_role.
 perform 1 from public.app_config where key='property_video_processor_consent' for share;
 perform set_config('role','service_role',true);
 consent:=public.property_video_processor_consent_current();
 perform set_config('role',operator_role,true);
 if consent is null then
  raise exception 'KIE-ACTIVATION refused: no processor-permission contract is published (public.property_video_processor_consent_current() is NULL: app_config.property_video_processor_consent is missing or invalid). Customers must first be able to give the fresh property-video-jobs-v2 permission for a published disclosure revision; an operator acknowledgement is never user permission. Nothing changed.';
 end if;
 -- 4. Enable only the pinned row.
 update public.ai_routes set enabled=true,updated_at=now() where id=route.id;
 -- 5. The selector with the exact owner acknowledgement.
 if present then
  update public.app_config set value=target,updated_at=now() where key='property_video_quality';
 else
  insert into public.app_config(key,value,updated_at) values('property_video_quality',target,now()) on conflict(key) do nothing;
  if not found then
   raise exception 'KIE-ACTIVATION refused: property_video_quality was created concurrently. Nothing changed; rerun.';
  end if;
 end if;
 -- 6. The activation record: exact previous selector (or its absence), the
 -- processor-disclosure attestation, the published permission revision and the
 -- content-license acknowledgement. It replaces exactly the expected record.
 activation:=jsonb_build_object('profile',kie->'profile','route_id',route.id,
  'previous_selector',case when present then jsonb_build_object('present',true,'value',previous) else jsonb_build_object('present',false) end,
  'route_enabled_before',route.enabled,'processor_disclosure',disclosure,'consent_disclosure_revision',consent->'disclosure_revision',
  'vendor_content_license',kie->'content_license_ack',
  'activated_at',now(),'rolled_back_at',null,'rollback_mode',null,'route_disabled_at',null);
 if old_record_sha='absent' then
  insert into public.app_config(key,value,updated_at) values('property_video_quality_kie_activation',activation,now()) on conflict(key) do nothing;
  if not found then
   raise exception 'KIE-ACTIVATION refused: the activation record was created concurrently. Nothing changed; rerun.';
  end if;
 else
  update public.app_config set value=activation,updated_at=now() where key='property_video_quality_kie_activation';
 end if;
 raise notice 'KIE-ACTIVATION done: route % enabled; property_video_quality = %; activation record = %',route.id,target::text,activation::text;
 -- 7. The baselines KIE-ROLLBACK.sql needs next.
 raise notice 'KIE-ACTIVATION new baselines: expected_selector_sha256=% expected_route_enabled=true expected_record_sha256=%',
  encode(sha256(convert_to(target::text,'UTF8')),'hex'),encode(sha256(convert_to(activation::text,'UTF8')),'hex');
end
$kie_activation$;

-- Read back what new admissions will see once this transaction commits, with
-- the digests the next operation takes as its baselines.
select r.id as kie_route_id,r.enabled as kie_route_enabled,
       coalesce(c.value::text,'absent') as property_video_quality,
       coalesce(encode(sha256(convert_to(c.value::text,'UTF8')),'hex'),'absent') as property_video_quality_sha256,
       coalesce(c.value->'enabled'='true'::jsonb and c.value->>'profile'='kie-kling3-4k-steady-v1'
        and c.value->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack',false) as selector_selects_kie,
       coalesce(a.value::text,'none') as kie_activation_record,
       coalesce(encode(sha256(convert_to(a.value::text,'UTF8')),'hex'),'absent') as kie_activation_record_sha256
  from public.ai_routes r
  left join public.app_config c on c.key='property_video_quality'
  left join public.app_config a on a.key='property_video_quality_kie_activation'
 where r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';
