\set ON_ERROR_STOP on
begin;
set local timezone='UTC';
create temporary table reviewer_assertions(n integer not null default 0);
insert into reviewer_assertions default values;
grant all on reviewer_assertions to service_role;
create function pg_temp.review_ok(ok boolean,label text) returns void language plpgsql as $$
begin
 if ok is distinct from true then raise exception 'FAIL: %',label;end if;
 update reviewer_assertions set n=n+1;
end$$;
create function pg_temp.review_refuse(statement text,expected text)
returns void language plpgsql as $$
begin
 begin execute statement;
 exception when others then
   if position(expected in sqlerrm)>0 then
     perform pg_temp.review_ok(true,expected);return;
   end if;
   raise;
 end;
 raise exception 'Expected refusal: %',expected;
end$$;
-- Exercise the actual app_video BEFORE INSERT guard as the service role. The
-- table is private, so this fixture-only definer copies a valid saved row.
create function pg_temp.inject_legacy_video()
returns void language sql security definer set search_path='' as $$
 insert into public.app_video_cost_reservations(org_id,billing_org_id,actor_id,
   idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,
   total_cents,hold_cents,meta)
 select org_id,billing_org_id,actor_id,'review-funded-video-01',feature,
   provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta
 from public.app_video_cost_reservations
 where idempotency_key='aerial-opening:ed400000-0000-4000-8000-000000000002';
$$;
grant execute on function pg_temp.inject_legacy_video() to service_role;

insert into auth.users(id,email,is_anonymous,email_confirmed_at)
values('ed000000-0000-4000-8000-000000000001','reviewer-sandbox@example.invalid',false,now()),
      ('ed000000-0000-4000-8000-000000000002','ordinary-sandbox@example.invalid',false,now());
insert into public.orgs(id,name,plan,plan_source)
values('ed100000-0000-4000-8000-000000000001','Reviewer fixture','free','manual'),
      ('ed100000-0000-4000-8000-000000000002','Ordinary fixture','free','manual');
insert into public.memberships(user_id,org_id,role)
values('ed000000-0000-4000-8000-000000000001',
       'ed100000-0000-4000-8000-000000000001','owner'),
      ('ed000000-0000-4000-8000-000000000002',
       'ed100000-0000-4000-8000-000000000002','owner');
-- Seed a synthetic listing without exercising the unrelated trial-creation
-- gate. Every admission and money guard below runs with triggers enabled.
set local session_replication_role=replica;
insert into public.listings(id,org_id,agent_id,address) values
 ('ed200000-0000-4000-8000-000000000001',
  'ed100000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000001','Synthetic reviewer photo');
-- Only the original transport is synthetic; the real quote/admission RPCs
-- below still validate its persisted provenance and supplier identity.
insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,
 bytes,sha256,uploaded,transport_version,content_type,width,height) values
 ('ed300000-0000-4000-8000-000000000001',
  'ed200000-0000-4000-8000-000000000001','photo','uploads',
  'uploads/ed100000-0000-4000-8000-000000000001/ed200000-0000-4000-8000-000000000001/front.jpg',
  1000000,repeat('a',64),true,2,'image/jpeg',2560,1440);
insert into public.photos(listing_id,original_key) values
 ('ed200000-0000-4000-8000-000000000001',
  'uploads/ed100000-0000-4000-8000-000000000001/ed200000-0000-4000-8000-000000000001/front.jpg');
insert into public.upload_reservations(asset_id,org_id,listing_id,actor_id,day,
 spec,held_bytes,spent_bytes,state,settled_at) values
 ('ed300000-0000-4000-8000-000000000001',
  'ed100000-0000-4000-8000-000000000001',
  'ed200000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000001',current_date,
  '{"bucket":"uploads","kind":"photo"}',0,1000000,'completed',now());
insert into public.upload_operations(asset_id,kind,bucket,object_key,bytes,
 expected_bytes,content_type,content_type_declared,asset_kind,state,etag) values
 ('ed300000-0000-4000-8000-000000000001','copy','uploads',
  'uploads/ed100000-0000-4000-8000-000000000001/ed200000-0000-4000-8000-000000000001/front.jpg',
  1000000,1000000,'image/jpeg',true,'photo','retained','"review-fixture"');
-- A forged ordinary Sandbox wallet is a stronger negative control than a
-- missing wallet: even with credits, it must never reach supplier dispatch.
insert into public.credit_grants(org_id,environment,source,reference,
 product_id,granted_credits,remaining_credits,starts_at,expires_at) values
 ('ed100000-0000-4000-8000-000000000002','Sandbox','monthly',
  'apple:ordinary-fixture','com.rendprop.app.pro.monthly',200,200,
  now()-interval '1 minute',now()+interval '1 day');
set local session_replication_role=origin;
update public.app_config set value=jsonb_set(value,'{enabled}','true'::jsonb)
 where key='property_video_jobs';
insert into public.app_config(key,value) values('photo_motion_renderer_v2',
 jsonb_build_object('enabled',true,
   'composition_profile','photo-motion-v2-cfr24',
   'producer_identity',jsonb_build_object(
      'image_uri','registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-photo-motion@sha256:f8bf65d52390bdd4470c36638b141251ec9fe924aa30bb7218fdbcba09a809ec',
      'controller_sha256','604b92b2c8b6a3ccfd49ac6bec6ff81993e52062c71ba6f910f057d1e2cb3db6',
      'renderer_source_sha256','a98b48825fbd819dbf49fd4c2cca4b836cdd81d57bedda5bf2de7774a42d98be')))
on conflict(key) do update set value=excluded.value;
update public.credit_monthly_catalog set active=true
where product_id='com.rendprop.app.pro.monthly';
-- The Photo Motion tariff remains dormant in source. Activate its exact
-- rollout shape only inside this rollback-only fixture to check routing.
drop trigger credit_photo_motion_activation_guard on public.app_config;
update public.app_config set value=jsonb_set(
  jsonb_set(value,'{enabled}','true'::jsonb),
  '{activation_ready}','true'::jsonb) where key='credit_photo_motion';
-- Activate the exact bounded 1080p aerial credit route only in this fixture.
insert into public.ai_routes(id,task,position,provider,model,unit,unit_cents,
 capabilities,max_latency_s,min_plan,privacy_tier,enabled,retire_after,params,note)
values('ed500000-0000-4000-8000-000000000001',
 'video.aerial_opening_kie_pro',1,'kie','kling-3.0/video','second',9,
 array['i2v','1080p','5s','preserve_photo'],1800,'free','trains_by_default',
 true,null,'{"sound":false,"kie_mode":"pro","aerial_opening_profile":"kie-kling3-pro-aerial-opening-v1"}',
 'Synthetic reviewer 1080p route');
insert into public.app_config(key,value)
select 'property_video_aerial_opening',jsonb_build_object(
 'enabled',true,'profile','kie-kling3-pro-aerial-opening-v1',
 'route_id','ed500000-0000-4000-8000-000000000001',
 'assessment_route_id',r.id,'quality_route_id',r.id,
 'maximum_operation_cents',70,
 'vendor_content_license','kie-terms-2025-08-01-section-3-owner-accepted',
 'rate_evidence_sha256',repeat('b',64),
 'processor_consent',jsonb_build_object('token','aerial-opening-v1',
   'disclosure_revision','reviewer-sandbox-disposable-20261028',
   'processors',jsonb_build_array('anthropic','kie')),
 'producer_identity',jsonb_build_object(
   'image_uri','registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-photo-motion@sha256:'||repeat('a',64),
   'controller_sha256',repeat('c',64),'renderer_source_sha256',repeat('d',64)))
from public.ai_routes r where r.provider='anthropic' and r.enabled=true
order by r.created_at limit 1
on conflict(key) do update set value=excluded.value;
update public.credit_tariffs set active=true
 where operation='aerial.opening' and version='aerial-opening-v1';
set local role service_role;
do $$
declare actor uuid:='ed000000-0000-4000-8000-000000000001';
  org uuid:='ed100000-0000-4000-8000-000000000001';
  ordinary uuid:='ed100000-0000-4000-8000-000000000002';
  t timestamptz:=now()-interval '1 minute';z timestamptz;
  f uuid; r jsonb; ce jsonb;manifest jsonb;quote_hash text;
  aerial_policy jsonb;aerial_manifest jsonb;aerial_quote jsonb;
  aerial_consent jsonb;aerial_job public.property_video_aerial_openings;
  photo_motion_spend numeric;legacy_hold numeric;
  reserve jsonb:='{"storage":10,"delivery":10,"compute":10,"email":5,"support":5,"retention":10,"uncertainty":0}';
  tariff jsonb:='{"r2_a_cents_per_million":450,"r2_b_cents_per_million":36,"worker_cents_per_million":30,"worker_cpu_cents_per_million_ms":2,"edge_cents_per_million":200,"db_cents":100,"logs_cents":100,"storage_cents_per_gb_month":1.5}';
begin
 z:=t+interval '7 days';
 perform pg_temp.review_ok(not has_function_privilege('authenticated',
   'public.reviewer_sandbox_signed_credit(uuid)','execute') and
   not has_function_privilege('authenticated',
   'public.review_shared_supplier_reserve_guard()','execute'),
   'reviewer money authority remains private');
 perform pg_temp.review_ok(public.serving_mode()='ceiling',
   'reviewer Sandbox credit path requires ceiling lock ordering');
 r:=public.provision_serving_funding(org,'app_review','synthetic-review-sandbox',
   actor,0,500,t,z,1,reserve,repeat('a',64));
 f:=(r->>'funding_id')::uuid;
 ce:=public.plan_serving_ceiling(org);
 perform pg_temp.review_ok(ce->>'kind'='app_review' and
   ce->>'window'='review_grant' and
   (ce->>'ceiling_cents')::integer=450 and
   (ce->>'period_start')::timestamptz=t and
   (ce->>'period_end')::timestamptz=z and
   (public.org_entitlement(org)).cogs_ceiling_cents=450,
   'seven-day sponsor has one 450-cent supplier allowance after media reserve');
 perform pg_temp.review_ok(not public.reviewer_sandbox_signed_credit(org) and
   not public.credit_primary_subscription(org,'Sandbox'),
   'sponsor without signed paid purchase has no Sandbox credit authority');
 perform pg_temp.review_refuse(format(
   'select public.record_apple_sandbox_receipt(%L,%L,''ordinary-original'',''ordinary-tx'',''com.rendprop.app.pro.monthly'',''active'',now())',
   ordinary,'ed000000-0000-4000-8000-000000000002'),'RP403');
 perform pg_temp.review_ok(not public.credit_primary_subscription(ordinary,'Sandbox'),
   'ordinary Sandbox wallet cannot become a paid primary subscription');
 perform public.serving_operation_begin('ed000000-0000-4000-8000-000000000002',
   ordinary,'ordinary-credit-01','photo.declutter',repeat('a',64));
 perform public.credit_wallet_reserve('ed000000-0000-4000-8000-000000000002',
   ordinary,'Sandbox','ordinary-credit-01','photo.declutter','photo-declutter-v1');
 perform pg_temp.review_refuse(format(
   'select public.credit_serving_cost_reserve(%L,%L,''ordinary-credit-01'',''photo.declutter:0'',''gemini'',''synthetic'',%L,1,''synthetic'',%L,''ordinary-credit-01'',''Sandbox'')',
   'ed000000-0000-4000-8000-000000000002',ordinary,repeat('a',64),ordinary),
   'RP403');
 perform pg_temp.review_ok(not exists(select 1 from public.serving_cost_reservations
   where billing_org_id=ordinary and budget_source='credits'),
   'ordinary Sandbox wallet cannot journal a supplier attempt');
 perform public.record_apple_sandbox_receipt(org,actor,'review-original',
   'review-paid-tx','com.rendprop.app.pro.monthly','active',now());
 perform pg_temp.review_ok(not public.reviewer_sandbox_signed_credit(org),
   'signed Sandbox receipt alone has no cash/media or monthly credit grant');
 r:=public.credit_verified_monthly_apply(org,'com.rendprop.app.pro.monthly',
   'Sandbox','review-original','review-paid-tx',t,z,49990,now(),now(),'paid');
 perform pg_temp.review_ok((r->>'granted')::boolean and
   not public.reviewer_sandbox_signed_credit(org),
   'a signed credit grant without funded media still cannot buy supplier work');
 perform public.serving_operation_begin(actor,org,'review-unfunded-01',
   'photo.declutter',repeat('1',64));
 perform public.credit_wallet_reserve(actor,org,'Sandbox','review-unfunded-01',
   'photo.declutter','photo-declutter-v1');
 perform pg_temp.review_refuse(format(
   'select public.credit_serving_cost_reserve(%L,%L,''review-unfunded-01'',''photo.declutter:0'',''gemini'',''synthetic'',%L,1,''synthetic'',%L,''review-unfunded-01'',''Sandbox'')',
   actor,org,repeat('1',64),org),'RP403');
 perform public.credit_wallet_finish(actor,org,'Sandbox',
   'review-unfunded-01','released');
 perform public.provision_media_account_reserve('synthetic-review-cash',
   '9c332c75b96cc642621dad5d86d4bf18','business_paid_cash',repeat('b',64),
   t-interval '1 day',z+interval '1 day',21000,tariff,
   '{"storage":0,"delivery":5000,"compute":5000,"email":0,"support":0,"retention":0,"uncertainty":0}');
 perform public.provision_media_delivery_budget(org,'synthetic-review-media',f,
   t,z,1000,1073741824,1342177280,tariff,
   '{"delivery":10,"compute":10,"storage":10,"retention":10}',
   repeat('c',64),'synthetic-review-cash');
 perform pg_temp.review_ok(
   public.reviewer_sandbox_signed_credit(org) and
   public.credit_primary_subscription(org,'Sandbox') and
   not public.credit_primary_subscription(org,'Production') and
   (public.credit_wallet_state(org,'Production')->>'total_available')::integer=0,
   'signed paid Sandbox period unlocks reviewer wallet only in Sandbox');
 perform pg_temp.review_ok((public.credit_wallet_state(org,'Sandbox')->>'total_available')::integer>0,
   'monthly Sandbox credits are visible in the isolated wallet');
 perform pg_temp.review_ok(public.credit_photo_motion_applicable(actor,org,'Sandbox')
   and public.credit_photo_motion_environment(actor,org,'{}'::jsonb,1)='Sandbox',
   'Photo Motion chooses the reviewer Sandbox wallet before any Production route');
 manifest:=jsonb_build_object(
   'source_mode','photo_motion_v1','composition_profile','photo-motion-v2-cfr24',
   'operation_id','ed400000-0000-4000-8000-000000000001',
   'listing_id','ed200000-0000-4000-8000-000000000001',
   'expected_org_id',org,'purpose','listing','aspect','16:9',
   'sources',jsonb_build_array(jsonb_build_object(
     'photo_id','synthetic-original-1',
     'photo_asset_id','ed300000-0000-4000-8000-000000000001',
     'photo_version_id','asset:ed300000-0000-4000-8000-000000000001',
     'photo_provenance_id',null,'motion','push_in','visible_frames',48,
     'source_sha256',repeat('a',64),'source_bytes',1000000)),
   'presentation',jsonb_build_object('transition','cut',
     'shot_caption_style','off','spoken_captions',false,
     'shot_labels',jsonb_build_array('')),
   'allow_original_photo_fallback',false,'music',null);
 quote_hash:=public.credit_photo_motion_quote(actor,manifest,'Sandbox')->>'quote_sha256';
 r:=public.property_video_job_admit_photo_motion_quoted(actor,manifest,quote_hash);
 perform pg_temp.review_ok((r->>'accepted')::boolean and
   (select count(*)=1 from public.credit_photo_motion_quotes q
     join public.serving_cost_reservations sr on sr.id=q.reservation_id
     where q.billing_org_id=org and q.environment='Sandbox'
       and sr.credit_environment='Sandbox' and sr.budget_source='credits'),
   'real Photo Motion admission binds reviewer Sandbox credits and supplier hold');
 aerial_policy:=public.property_video_aerial_policy();
 aerial_manifest:=jsonb_build_object('schema',1,'profile',aerial_policy->>'profile',
   'operation_id','ed400000-0000-4000-8000-000000000002',
   'listing_id','ed200000-0000-4000-8000-000000000001',
   'expected_org_id',org,
   'source',jsonb_build_object(
     'photo_asset_id','ed300000-0000-4000-8000-000000000001',
     'photo_version_id','asset:ed300000-0000-4000-8000-000000000001',
     'photo_provenance_id',null,'sha256',repeat('a',64),'bytes',1000000),
   'role','front_of_home','aspect','16:9','seconds',5,
   'reviewed_crop',jsonb_build_object('x',0,'y',0,'width',2560,'height',1440,
     'source_width',2560,'source_height',1440));
 aerial_quote:=jsonb_build_object('schema',1,'profile',aerial_policy->>'profile',
   'manifest_sha256',encode(sha256(convert_to(aerial_manifest::text,'UTF8')),'hex'),
   'route_id',aerial_policy->>'route_id','generation_cents',45,
   'assessment',jsonb_build_object(
     'route_id',aerial_policy->>'assessment_route_id',
     'provider',aerial_policy#>>'{assessment_route,provider}',
     'model',aerial_policy#>>'{assessment_route,model}','cents',3),
   'quality',jsonb_build_object(
     'route_id',aerial_policy->>'quality_route_id',
     'provider',aerial_policy#>>'{quality_route,provider}',
     'model',aerial_policy#>>'{quality_route,model}','cents',3),
   'processing_cents',16,'maximum_total_cents',67,
   'tariff_version','published-standard-20261006',
   'rate_evidence_sha256',aerial_policy->>'rate_evidence_sha256',
   'processor_consent',aerial_policy->'processor_consent',
   'expires_at',now()+interval '10 minutes','privacy_stop_at',null);
 aerial_consent:=aerial_policy->'processor_consent';
 -- Leave 50c of the 450c sponsor allowance. The aerial's largest one-row
 -- hold is 45c, but its five rows total 67c. A per-statement stale snapshot
 -- must not admit this multirow INSERT ... SELECT.
 photo_motion_spend:=public.org_month_spend_cents(org);
 legacy_hold:=400-photo_motion_spend;
 perform public.serving_cost_reserve(actor,org,'review-near-cap','photo.initial:0',
   'gemini','synthetic',repeat('b',64),legacy_hold,'synthetic');
 perform pg_temp.review_ok(public.org_month_spend_cents(org)=400,
   'near-cap test leaves exactly 50 cents for a five-stage aerial quote');
 perform pg_temp.review_refuse(format(
   'select public.property_video_aerial_admit_credit(%L,%L::jsonb,%L::jsonb,%L::jsonb,%L,%L)',
   actor,aerial_manifest,aerial_quote,aerial_consent,'Sandbox','aerial-opening-v1'),
   'RP402: Shared reviewer supplier budget');
 perform pg_temp.review_ok((select count(*)=0 from public.serving_cost_reservations
   where request_key='aerial-opening:ed400000-0000-4000-8000-000000000002'),
   'near-cap multirow rejection leaves no aerial supplier journal');
 perform public.serving_cost_finish(actor,org,'review-near-cap','photo.initial:0',
   'rejected',0);
 aerial_job:=public.property_video_aerial_admit_credit(actor,
   aerial_manifest,aerial_quote,aerial_consent,'Sandbox','aerial-opening-v1');
 perform pg_temp.review_ok(aerial_job.id is not null and
   (select count(*)=5 from public.serving_cost_reservations
     where request_key='aerial-opening:ed400000-0000-4000-8000-000000000002'
       and credit_environment='Sandbox' and budget_source='credits') and
   (select count(*)=1 from public.app_video_cost_reservations
     where idempotency_key='aerial-opening:ed400000-0000-4000-8000-000000000002'
       and credit_environment='Sandbox' and credit_hold_id is not null),
   'real aerial admission binds all Sandbox supplier stages and video liability');
 -- The legacy route and photo supplier share the remainder of the same cap.
 photo_motion_spend:=public.org_month_spend_cents(org);
 perform pg_temp.review_ok(photo_motion_spend>0 and photo_motion_spend<400,
   'Photo Motion quote is counted in the same sponsor allowance');
 legacy_hold:=400-photo_motion_spend;
 perform public.serving_cost_reserve(actor,org,'review-legacy-01','photo.initial:0',
   'gemini','synthetic',repeat('d',64),legacy_hold,'synthetic');
 perform pg_temp.review_ok(public.org_month_spend_cents(org)>=400,
   'legacy supplier hold counts against reviewer credit capacity');
 perform public.serving_operation_begin(actor,org,'review-credit-01',
   'photo.declutter',repeat('e',64));
 perform public.credit_wallet_reserve(actor,org,'Sandbox','review-credit-01',
   'photo.declutter','photo-declutter-v1');
 r:=public.credit_serving_cost_reserve(actor,org,'review-credit-01',
   'photo.declutter:0','gemini','synthetic',repeat('e',64),50,
   'synthetic',org,'review-credit-01','Sandbox');
 perform pg_temp.review_ok((r->>'reserved')::boolean and
   public.org_month_spend_cents(org)>=450,
   'credit supplier hold reaches but never exceeds the same 450c cap');
 perform public.serving_operation_begin(actor,org,'review-credit-02',
   'photo.declutter',repeat('f',64));
 perform public.credit_wallet_reserve(actor,org,'Sandbox','review-credit-02',
   'photo.declutter','photo-declutter-v1');
 perform pg_temp.review_refuse(format(
   'select public.credit_serving_cost_reserve(%L,%L,''review-credit-02'',''photo.declutter:0'',''gemini'',''synthetic'',%L,1,''synthetic'',%L,''review-credit-02'',''Sandbox'')',
   actor,org,repeat('f',64),org),'RP402: Shared reviewer supplier budget');
 perform pg_temp.review_refuse(format(
   'select public.serving_cost_reserve(%L,%L,''review-legacy-02'',''photo.initial:0'',''gemini'',''synthetic'',%L,1,''synthetic'')',
   actor,org,repeat('f',64)),'RP402');
	 perform pg_temp.review_ok((select count(*)=0 from public.serving_cost_reservations
	   where org_id=org and request_key in('review-credit-02','review-legacy-02')),
	   'refused supplier attempts leave no dispatch journal');
end$$;
-- Reproduce the terminal functions' financial transition inside this
-- rollback-only fixture: credits are refunded, but unresolved supplier risk is
-- retained as video_failure / aerial_failure. Those rows remain part of the
-- same nonrenewable reviewer sponsor cap, not a fresh failure allowance.
reset role;
update public.serving_cost_reservations set budget_source='video_failure'
 where request_key='photomotion:ed400000-0000-4000-8000-000000000001'
   and budget_source='credits' and credit_environment='Sandbox';
update public.credit_photo_motion_failure_budget set
 state='spent',spent_cents=maximum_cents,finished_at=now()
 where operation_id='ed400000-0000-4000-8000-000000000001';
set local role service_role;
do $$
declare actor uuid:='ed000000-0000-4000-8000-000000000001';
 org uuid:='ed100000-0000-4000-8000-000000000001';
begin
 perform public.credit_wallet_finish(actor,org,'Sandbox',
   'photomotion:ed400000-0000-4000-8000-000000000001','released');
 perform pg_temp.review_ok((select count(*)=1 from public.serving_cost_reservations
   where request_key='photomotion:ed400000-0000-4000-8000-000000000001'
     and budget_source='video_failure' and ledger_id is null) and
   (select count(*)=1 from public.credit_photo_motion_failure_budget
     where operation_id='ed400000-0000-4000-8000-000000000001'
       and state='spent') and
   (select count(*)=1 from public.credit_holds
     where org_id=org and request_key='photomotion:ed400000-0000-4000-8000-000000000001'
       and state='released'),
   'failed Photo Motion refunds credits but retains supplier risk');
 perform pg_temp.review_ok(public.org_month_spend_cents(org)=450,
   'refunded Photo Motion supplier risk still consumes the reviewer cap');
 perform pg_temp.review_refuse(format(
   'select public.credit_serving_cost_reserve(%L,%L,''review-credit-02'',''photo.declutter:0'',''gemini'',''synthetic'',%L,1,''synthetic'',%L,''review-credit-02'',''Sandbox'')',
   actor,org,repeat('f',64),org),'RP402: Shared reviewer supplier budget');
end$$;
reset role;
update public.serving_cost_reservations set budget_source='aerial_failure'
 where request_key='aerial-opening:ed400000-0000-4000-8000-000000000002'
   and budget_source='credits' and credit_environment='Sandbox';
update public.credit_aerial_failure_budget set
 state='spent',spent_cents=maximum_cents,finished_at=now()
 where hold_id=(select id from public.credit_holds
   where request_key='aerial-opening:ed400000-0000-4000-8000-000000000002');
set local role service_role;
do $$
declare actor uuid:='ed000000-0000-4000-8000-000000000001';
 org uuid:='ed100000-0000-4000-8000-000000000001';
begin
 perform public.credit_wallet_finish(actor,org,'Sandbox',
   'aerial-opening:ed400000-0000-4000-8000-000000000002','released');
 perform pg_temp.review_ok((select count(*)=5 from public.serving_cost_reservations
   where request_key='aerial-opening:ed400000-0000-4000-8000-000000000002'
     and budget_source='aerial_failure' and ledger_id is null) and
   (select count(*)=1 from public.credit_aerial_failure_budget
     where hold_id=(select id from public.credit_holds
       where request_key='aerial-opening:ed400000-0000-4000-8000-000000000002')
       and state='spent') and
   (select count(*)=1 from public.credit_holds
     where org_id=org and request_key='aerial-opening:ed400000-0000-4000-8000-000000000002'
       and state='released'),
   'failed aerial refunds credits but retains five supplier-risk stages');
 perform pg_temp.review_ok(public.org_month_spend_cents(org)=450,
   'refunded aerial supplier risk still consumes the reviewer cap');
 perform pg_temp.review_refuse(format(
   'select public.credit_serving_cost_reserve(%L,%L,''review-credit-02'',''photo.declutter:0'',''gemini'',''synthetic'',%L,1,''synthetic'',%L,''review-credit-02'',''Sandbox'')',
   actor,org,repeat('f',64),org),'RP402: Shared reviewer supplier budget');
end$$;
-- Funded mode uses a different legacy lock path. It cannot silently turn on
-- reviewer Sandbox credit spending until that ordering is independently safe.
reset role;
update public.app_config set value=jsonb_set(value,'{mode}','"funded"'::jsonb)
 where key='serving_mode';
set local role service_role;
do $$
declare actor uuid:='ed000000-0000-4000-8000-000000000001';
 org uuid:='ed100000-0000-4000-8000-000000000001';
begin
 perform pg_temp.review_ok(public.serving_mode()='funded' and
   not public.reviewer_sandbox_signed_credit(org) and
   not public.credit_primary_subscription(org,'Sandbox'),
   'funded mode closes reviewer Sandbox credit admission');
 perform pg_temp.review_refuse(format(
   'select public.credit_serving_cost_reserve(%L,%L,''review-credit-02'',''photo.declutter:0'',''gemini'',''synthetic'',%L,1,''synthetic'',%L,''review-credit-02'',''Sandbox'')',
   actor,org,repeat('f',64),org),'RP403');
 perform pg_temp.review_refuse(format(
   'select public.serving_cost_reserve(%L,%L,''review-funded-legacy'',''photo.initial:0'',''gemini'',''synthetic'',%L,1,''synthetic'')',
   actor,org,repeat('f',64)),'RP403: Reviewer serving requires ceiling mode');
 perform pg_temp.review_refuse('select pg_temp.inject_legacy_video()',
   'RP403: Reviewer serving requires ceiling mode');
end$$;
reset role;
update public.app_config set value=jsonb_set(value,'{mode}','"ceiling"'::jsonb)
 where key='serving_mode';
set local role service_role;
-- Expire the signed Sandbox monthly grant while leaving the sponsor active.
-- This is a rollback-only clock-state fixture, never a live account mutation.
reset role;
update public.credit_grants set expires_at=now()-interval '30 seconds'
 where environment='Sandbox' and reference='apple:review-paid-tx';
set local role service_role;
do $$
declare actor uuid:='ed000000-0000-4000-8000-000000000001';
 org uuid:='ed100000-0000-4000-8000-000000000001';
begin
 perform pg_temp.review_ok(not public.reviewer_sandbox_signed_credit(org) and
   not public.credit_primary_subscription(org,'Sandbox'),
   'expired signed monthly grant closes reviewer Sandbox credit authority');
 perform pg_temp.review_refuse(format(
   'select public.credit_serving_cost_reserve(%L,%L,''review-credit-02'',''photo.declutter:0'',''gemini'',''synthetic'',%L,1,''synthetic'',%L,''review-credit-02'',''Sandbox'')',
   actor,org,repeat('f',64),org),'RP403');
end$$;
reset role;
update public.credit_grants set expires_at=(select period_end
 from public.credit_monthly_events where environment='Sandbox'
   and transaction_id='review-paid-tx')
 where environment='Sandbox' and reference='apple:review-paid-tx';
set local role service_role;
do $$
declare actor uuid:='ed000000-0000-4000-8000-000000000001';
 org uuid:='ed100000-0000-4000-8000-000000000001';
begin
 perform pg_temp.review_ok(public.reviewer_sandbox_signed_credit(org),
   'restored current grant proves expiry and revocation controls are independent');
 perform public.revoke_serving_funding(org,'synthetic-review-sandbox',repeat('f',64));
 perform pg_temp.review_ok(not public.reviewer_sandbox_signed_credit(org) and
   not public.credit_primary_subscription(org,'Sandbox'),
   'revoked sponsor closes Sandbox primary access without minting Production');
 perform pg_temp.review_refuse(format(
   'select public.credit_serving_cost_reserve(%L,%L,''review-credit-02'',''photo.declutter:0'',''gemini'',''synthetic'',%L,1,''synthetic'',%L,''review-credit-02'',''Sandbox'')',
   actor,org,repeat('f',64),org),'RP403');
end$$;
-- Independently check a fully expired review sponsorship. Neither a prior
-- signed paid receipt nor its still-current wallet can revive it.
reset role;
set local session_replication_role=replica;
update public.serving_funding set revoked_at=null,revocation_kind=null,
 revocation_evidence_sha256=null,ends_at=now()-interval '30 seconds'
 where collection_ref='synthetic-review-sandbox';
update public.serving_funding_slices set ends_at=now()-interval '30 seconds'
 where funding_id=(select id from public.serving_funding
   where collection_ref='synthetic-review-sandbox');
set local session_replication_role=origin;
set local role service_role;
do $$
declare actor uuid:='ed000000-0000-4000-8000-000000000001';
 org uuid:='ed100000-0000-4000-8000-000000000001';
begin
 perform pg_temp.review_ok(not public.reviewer_sandbox_signed_credit(org) and
   not public.credit_primary_subscription(org,'Sandbox'),
   'expired seven-day reviewer sponsor cannot restore Sandbox credit authority');
 perform pg_temp.review_refuse(format(
   'select public.credit_serving_cost_reserve(%L,%L,''review-credit-02'',''photo.declutter:0'',''gemini'',''synthetic'',%L,1,''synthetic'',%L,''review-credit-02'',''Sandbox'')',
   actor,org,repeat('f',64),org),'RP403');
end$$;
select jsonb_build_object('assertions',n,'passed',true) from reviewer_assertions;
rollback;
