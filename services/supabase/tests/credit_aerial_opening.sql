-- Disposable funding proof. The real aerial policy, original-source receipt,
-- credit wallet, video journal, and terminal RPCs run unchanged. Only uploaded
-- R2 transport bytes and the KIE submission are synthetic.
begin;
create temporary table aerial_credit_checks(n integer not null default 0);
insert into aerial_credit_checks default values;
grant all on aerial_credit_checks to service_role;
create function pg_temp.aerial_ok(v boolean,label text) returns void language plpgsql as $$
begin
 if v is distinct from true then raise exception 'AERIAL CREDIT FAIL: %',label;end if;
 update aerial_credit_checks set n=n+1;
end$$;
create function pg_temp.aerial_refuses(statement text,needle text,label text)
returns void language plpgsql as $$
begin
 begin execute statement;exception when others then
  if position(needle in sqlerrm)>0 then perform pg_temp.aerial_ok(true,label);return;end if;
  raise;
 end;
 raise exception 'AERIAL CREDIT FAIL admitted: %',label;
end$$;
-- Model the KIE dispatch claim only; actual provider transport never runs.
create function pg_temp.synthetic_generation_claim(p_job uuid,p_lease uuid)
returns void language sql security definer set search_path='' as $$
 update public.property_video_aerial_openings set generation_lease=p_lease,
   generation_claimed_at=now(),state='dispatching' where id=p_job
$$;
grant execute on function pg_temp.synthetic_generation_claim(uuid,uuid) to service_role;
insert into auth.users(id,email,is_anonymous) values
 ('a0111111-1111-4111-8111-111111111111','credit-aerial@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source) values
 ('a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Aerial credit fixture','pro','manual');
insert into public.memberships(user_id,org_id,role) values
 ('a0111111-1111-4111-8111-111111111111','a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner');
insert into public.listings(id,org_id,agent_id,address) values
 ('a0222222-2222-4222-8222-222222222222','a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'a0111111-1111-4111-8111-111111111111','Synthetic front exterior');
-- The saved listing predates the simulated downgrade to a Free account that
-- subsequently buys independent one-off credits.
update public.orgs set plan='free',plan_source=null
 where id='a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
set local session_replication_role=replica;
insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,
  bytes,sha256,uploaded,transport_version,content_type,width,height) values
 ('a0333333-3333-4333-8333-333333333333','a0222222-2222-4222-8222-222222222222',
  'photo','uploads',
  'uploads/a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a0222222-2222-4222-8222-222222222222/exterior.jpg',
  1000000,repeat('a',64),true,2,'image/jpeg',2560,1440);
insert into public.photos(listing_id,original_key) values
 ('a0222222-2222-4222-8222-222222222222',
  'uploads/a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a0222222-2222-4222-8222-222222222222/exterior.jpg');
insert into public.upload_reservations(asset_id,org_id,listing_id,actor_id,day,
  spec,held_bytes,spent_bytes,state,settled_at)values
 ('a0333333-3333-4333-8333-333333333333','a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'a0222222-2222-4222-8222-222222222222','a0111111-1111-4111-8111-111111111111',
  current_date,'{"bucket":"uploads","kind":"photo"}',0,1000000,'completed',now());
insert into public.upload_operations(asset_id,kind,bucket,object_key,bytes,
  expected_bytes,content_type,content_type_declared,asset_kind,state,etag)values
 ('a0333333-3333-4333-8333-333333333333','copy','uploads',
  'uploads/a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a0222222-2222-4222-8222-222222222222/exterior.jpg',
  1000000,1000000,'image/jpeg',true,'photo','retained','"aerial-fixture"');
set local session_replication_role=origin;
insert into public.credit_grants(org_id,environment,source,reference,product_id,
 granted_credits,remaining_credits,expires_at) values
 ('a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Production','topup','aerial-topup-fixture',
 'com.rendprop.app.credits.100',100,100,null);
insert into public.ai_routes(id,task,position,provider,model,unit,unit_cents,
 capabilities,max_latency_s,min_plan,privacy_tier,enabled,retire_after,params,note) values
 ('7fd8d740-de05-4b37-b881-9b319fd31a73','video.aerial_opening_kie_pro',1,
  'kie','kling-3.0/video','second',9,array['i2v','1080p','5s','preserve_photo'],
  1800,'free','trains_by_default',true,null,
  '{"sound":false,"kie_mode":"pro","aerial_opening_profile":"kie-kling3-pro-aerial-opening-v1"}',
  'Synthetic bounded 1080p route for rollback-only credit test');
-- Production activation is deliberately absent from migrations. Supply a
-- structurally valid synthetic route/renderer policy inside this rollback.
insert into public.app_config(key,value)
select 'property_video_aerial_opening',jsonb_build_object(
 'enabled',true,'profile','kie-kling3-pro-aerial-opening-v1',
 'route_id','7fd8d740-de05-4b37-b881-9b319fd31a73',
 'assessment_route_id',r.id,'quality_route_id',r.id,
 'maximum_operation_cents',70,
 'vendor_content_license','kie-terms-2025-08-01-section-3-owner-accepted',
 'rate_evidence_sha256',repeat('b',64),
 'processor_consent',jsonb_build_object('token','aerial-opening-v1',
   'disclosure_revision','aerial-credit-disposable-20261027',
   'processors',jsonb_build_array('anthropic','kie')),
 'producer_identity',jsonb_build_object(
   'image_uri','registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-photo-motion@sha256:'||repeat('a',64),
   'controller_sha256',repeat('c',64),'renderer_source_sha256',repeat('d',64)))
from public.ai_routes r where r.provider='anthropic' and r.enabled=true
order by r.created_at limit 1;
select pg_temp.aerial_ok((select credits=20 and not active from public.credit_tariffs
 where operation='aerial.opening' and version='aerial-opening-v1'),
 'twenty-credit 1080p quote starts dormant');
update public.credit_tariffs set active=true
 where operation='aerial.opening' and version='aerial-opening-v1';

set local role service_role;
do $$
declare actor uuid:='a0111111-1111-4111-8111-111111111111';
 org uuid:='a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 listing uuid:='a0222222-2222-4222-8222-222222222222';
 asset uuid:='a0333333-3333-4333-8333-333333333333';
 op1 uuid:='a0444444-4444-4444-8444-444444444444';
 op2 uuid:='a0555555-5555-4555-8555-555555555555';
 manifest jsonb; quote jsonb; policy jsonb; consent jsonb;
 job public.property_video_aerial_openings; replay public.property_video_aerial_openings;
 lease uuid:='a0666666-6666-4666-8666-666666666666';receipt jsonb;
begin
 policy:=public.property_video_aerial_policy();
 manifest:=jsonb_build_object('schema',1,'profile',policy->>'profile',
  'operation_id',op1,'listing_id',listing,'expected_org_id',org,
  'source',jsonb_build_object('photo_asset_id',asset,
    'photo_version_id','asset:'||asset,'photo_provenance_id',null,
    'sha256',repeat('a',64),'bytes',1000000),
  'role','front_of_home','aspect','16:9','seconds',5,
  'reviewed_crop',jsonb_build_object('x',0,'y',0,'width',2560,'height',1440,
    'source_width',2560,'source_height',1440));
 quote:=jsonb_build_object('schema',1,'profile',policy->>'profile',
  'manifest_sha256',encode(sha256(convert_to(manifest::text,'UTF8')),'hex'),
  'route_id',policy->>'route_id','generation_cents',45,
  'assessment',jsonb_build_object('route_id',policy->>'assessment_route_id',
    'provider',policy#>>'{assessment_route,provider}',
    'model',policy#>>'{assessment_route,model}','cents',3),
  'quality',jsonb_build_object('route_id',policy->>'quality_route_id',
    'provider',policy#>>'{quality_route,provider}',
    'model',policy#>>'{quality_route,model}','cents',3),
  'processing_cents',16,'maximum_total_cents',67,
  'tariff_version','published-standard-20261006',
  'rate_evidence_sha256',policy->>'rate_evidence_sha256',
  'processor_consent',policy->'processor_consent',
  'expires_at',now()+interval '10 minutes','privacy_stop_at',null);
 consent:=policy->'processor_consent';
 perform pg_temp.aerial_refuses(format(
  'select public.property_video_aerial_admit_credit(%L,%L::jsonb,%L::jsonb,%L::jsonb,%L,%L)',
  actor,manifest,quote,consent,'Production','aerial-opening-typo'),
  'RP402:','wrong customer tariff cannot charge');
 perform pg_temp.aerial_ok((public.credit_wallet_state(org,'Production')->>'total_available')::integer=100,
  'rejected authorization changes no wallet credits');
 job:=public.property_video_aerial_admit_credit(actor,manifest,quote,consent,
   'Production','aerial-opening-v1');
 perform pg_temp.aerial_ok(job.id is not null and job.operation_id=op1 and
  (public.credit_wallet_state(org,'Production')->>'total_available')::integer=80,
  'one 1080p aerial admission freezes one 20-credit hold');
 perform pg_temp.aerial_ok((select count(*)=5 from public.serving_cost_reservations
    where credit_hold_id=(select hold_id from public.credit_aerial_openings where job_id=job.id)
      and budget_source='credits') and
   (select credit_hold_id is not null and credit_environment='Production' and
           billing_org_id=org and total_cents=45
      from public.app_video_cost_reservations where idempotency_key='aerial-opening:'||op1),
  'all supplier stages and video receipt share the immutable wallet hold');
 replay:=public.property_video_aerial_admit_credit(actor,manifest,quote,consent,
   'Production','aerial-opening-v1');
 perform pg_temp.aerial_ok(replay.id=job.id and
  (select count(*)=1 from public.credit_holds where org_id=org and operation='aerial.opening'),
  'replay cannot spend another 20 credits');
 perform pg_temp.aerial_refuses(format(
  'select public.property_video_aerial_admit_credit(%L,%L::jsonb,%L::jsonb,%L::jsonb,%L,%L)',
  actor,manifest,quote||'{"maximum_total_cents":68}'::jsonb,consent,
  'Production','aerial-opening-v1'),
  'RP409:','same operation cannot change frozen supplier quote');
 perform public.property_video_aerial_cancel(actor,job.id);
 perform public.property_video_aerial_release_future(job.id);
 perform pg_temp.aerial_ok((public.credit_wallet_state(org,'Production')->>'total_available')::integer=100
   and (select state='released' from public.credit_holds where request_key='aerial-opening:'||op1)
   and (select count(*)=5 from public.serving_cost_reservations
      where request_key='aerial-opening:'||op1 and state='rejected')
   and (select released_at is not null from public.app_video_cost_reservations
      where idempotency_key='aerial-opening:'||op1),
  'definitive pre-dispatch cancellation releases credits and every supplier hold');
 perform public.property_video_aerial_release_future(job.id);
 perform pg_temp.aerial_ok((public.credit_wallet_state(org,'Production')->>'total_available')::integer=100,
  'terminal replay never refunds twice');

 manifest:=jsonb_set(manifest,'{operation_id}',to_jsonb(op2));
 quote:=jsonb_set(quote,'{manifest_sha256}',to_jsonb(
   encode(sha256(convert_to(manifest::text,'UTF8')),'hex')));
 job:=public.property_video_aerial_admit_credit(actor,manifest,quote,consent,
   'Production','aerial-opening-v1');
 perform pg_temp.aerial_ok((public.credit_wallet_state(org,'Production')->>'total_available')::integer=80,
  'second independent operation reserves a new bounded hold');
 perform pg_temp.synthetic_generation_claim(job.id,lease);
 receipt:=jsonb_build_object('provider','kie','model',
   case when manifest->>'profile'='kie-kling3-omni-reference-aerial-opening-v1'
     then 'kling-3.0-omni/reference-to-video' else 'kling-3.0/video' end,
   'id','aerial-credit-accepted-1','submitted_at',now(),
   'poll_url','https://api.kie.ai/api/v1/jobs/recordInfo?taskId=aerial-credit-accepted-1');
 perform public.property_video_aerial_receipt(job.id,lease,receipt);
 perform pg_temp.aerial_ok((select state='settled' from public.credit_holds
     where request_key='aerial-opening:'||op2) and
   (select cost_ledger_id is not null and provider_request_id='aerial-credit-accepted-1'
     from public.app_video_cost_reservations where idempotency_key='aerial-opening:'||op2) and
   (select state='succeeded' from public.serving_cost_reservations
     where request_key='aerial-opening:'||op2 and stage='aerial'),
  'accepted KIE receipt atomically settles customer and supplier');
 perform public.property_video_aerial_receipt(job.id,lease,receipt);
 perform pg_temp.aerial_refuses(format(
  'select public.property_video_aerial_receipt(%L,%L,%L::jsonb)',
  job.id,lease,receipt||'{"id":"changed-receipt"}'::jsonb),
  'RP409:','accepted KIE receipt is immutable');
 perform public.property_video_aerial_cancel(actor,job.id);
 perform public.property_video_aerial_release_future(job.id);
 perform pg_temp.aerial_ok((public.credit_wallet_state(org,'Production')->>'total_available')::integer=80
   and (select state='settled' from public.credit_holds
      where request_key='aerial-opening:'||op2),
  'cancellation after accepted supplier receipt cannot refund spent credits');
end$$;
reset role;
select jsonb_build_object('passed',true,'assertions',(select n from aerial_credit_checks));
-- This disposable database persists the fixture only for the two-session
-- admission race immediately after it; the Python runner destroys the cluster.
commit;
