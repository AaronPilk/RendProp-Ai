\set ON_ERROR_STOP on
-- Synthetic local receipt fixtures, actual RPCs/roles, no Apple/R2/providers.
begin;
create temporary table website_checks(n integer);insert into website_checks values(0);grant all on website_checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'PROPERTY-SITE FAIL: %',label;end if;update website_checks set n=n+1;end$$;
create function pg_temp.refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception 'PROPERTY-SITE FAIL: allowed %',label;end$$;
insert into auth.users(id,email,is_anonymous)values('ea100000-0000-4000-8000-000000000001','website-owner@fixture.invalid',false),('ea100000-0000-4000-8000-000000000002','website-other@fixture.invalid',false);
create temporary table wf as select 'ea100000-0000-4000-8000-000000000001'::uuid actor,'ea100000-0000-4000-8000-000000000002'::uuid other,
 (select org_id from public.memberships where user_id='ea100000-0000-4000-8000-000000000001'and role='owner'limit 1)org,
 (select org_id from public.memberships where user_id='ea100000-0000-4000-8000-000000000002'and role='owner'limit 1)other_org;
grant select on wf to service_role,authenticated;
insert into public.listings(id,org_id,agent_id,address)values('ea300000-0000-4000-8000-000000000001',(select org from wf),(select actor from wf),'Synthetic property'),
 ('ea300000-0000-4000-8000-000000000002',(select org from wf),(select actor from wf),'Second synthetic property'),
 ('ea300000-0000-4000-8000-000000000003',(select other_org from wf),(select other from wf),'Foreign property');
select pg_temp.ok((select bool_and(relrowsecurity)from pg_class where relname in('property_video_sources','property_video_attestations','property_video_compositions','property_video_publication_ops','property_website_products','property_website_transactions','property_website_settings')),'new exposed tables all have RLS');
select pg_temp.ok(not exists(select 1 from information_schema.role_table_grants where table_name in('property_video_sources','property_video_attestations','property_video_compositions','property_video_publication_ops','property_website_products','property_website_transactions','property_website_settings')and grantee in('anon','authenticated')),'API roles have no direct table grants');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_website_transaction(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,timestamptz,text,boolean)','execute'),'client cannot forge verified transaction RPC');
select pg_temp.ok(not has_function_privilege('anon','public.publish_property_video(uuid,uuid,jsonb,uuid,text)','execute'),'guest key cannot publish property video');
select pg_temp.ok((select not production_enabled and not sandbox_enabled from public.property_website_products),'SKU starts disabled in both environments');
set local role service_role;
select pg_temp.ok(property_website_state((select actor from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf))->>'website_theme'='basic','basic website is included without an upgrade');
select pg_temp.refuse(format('select property_website_state(%L,%L,%L)',(select other from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf)),'RP404:','foreign account cannot read property entitlement');
select pg_temp.refuse(format('select set_property_website_theme(%L,%L,%L,%L)',(select actor from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf),'signature-estate'),'RP402:','client cannot choose unpaid premium theme');
select pg_temp.refuse(format('select property_website_transaction(%L,%L,%L,%L,%L,%L,%L,%L,null,%L,false)',(select actor from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf),'Production','website-purchase-1','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:01Z','purchase'),'RP503:','disabled product grants no upgrade');
reset role;
update public.property_website_products set production_enabled=true,sandbox_enabled=true;-- LOCAL test fixture only
set local role service_role;
select pg_temp.ok((property_website_transaction((select actor from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf),'Production','website-purchase-1','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:01Z',null,'purchase')->>'assigned')::boolean,'verified purchase assigned to exact property');
select pg_temp.ok(property_website_transaction((select actor from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf),'Production','website-purchase-1','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:01Z',null,'purchase')->>'transaction_id'='website-purchase-1','acknowledgement echoes exact signed transaction');
select pg_temp.ok((select count(*)=1 from property_website_transactions),'replay creates no second credit');
select pg_temp.ok(set_property_website_theme((select actor from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf),'signature-estate')->>'website_theme'='signature-estate','assigned credit unlocks Signature Estate');
select pg_temp.ok(set_property_website_theme((select actor from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf),'coastal-luxe')->>'website_theme'='coastal-luxe','same credit permits switching to Coastal Luxe');
select pg_temp.ok((select count(*)=1 from property_website_transactions),'theme switching never consumes another transaction');
select pg_temp.refuse(format('select property_website_transaction(%L,%L,%L,%L,%L,%L,%L,%L,null,%L,false)',(select actor from wf),'ea300000-0000-4000-8000-000000000002',(select org from wf),'Production','website-purchase-1','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:01Z','purchase'),'RP409:','one signed purchase cannot unlock a second property');
select property_website_transaction((select actor from wf),null,null,'Production','website-purchase-1','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:05Z','2026-10-14 10:04Z','refund',true);
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000001')->>'website_theme'='basic','refund returns public site to basic without a native sidecar');
select property_website_transaction((select actor from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf),'Production','website-purchase-1','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:01Z',null,'purchase');
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000001')->>'website_theme'='basic','stale device restore cannot resurrect a refund');
select property_website_transaction((select actor from wf),null,null,'Production','website-purchase-1','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:06Z',null,'refund_reversed',true);
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000001')->>'website_theme'='coastal-luxe','newer signed refund reversal restores original assignment/theme');
select property_website_transaction((select actor from wf),'ea300000-0000-4000-8000-000000000002',(select org from wf),'Sandbox','website-sandbox-1','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:01Z',null,'purchase');
select pg_temp.ok((set_property_website_theme((select actor from wf),'ea300000-0000-4000-8000-000000000002',(select org from wf),'signature-estate')->'premium_website'->>'test_only')::boolean,'Sandbox is explicitly test-only');
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000002')->>'website_theme'='basic','Sandbox cannot grant Production public premium');
select pg_temp.refuse(format('select property_website_state(%L,%L,%L)',(select actor from wf),'ea300000-0000-4000-8000-000000000001',(select other_org from wf)),'RP404:','stale workspace is refused');
select property_website_transaction((select actor from wf),null,null,'Production','website-refund-first','com.rendprop.app.website.premium.property','2026-10-14 11:00Z','2026-10-14 11:05Z','2026-10-14 11:04Z','refund',true);
select pg_temp.ok((property_website_transaction((select actor from wf),'ea300000-0000-4000-8000-000000000002',(select org from wf),'Production','website-refund-first','com.rendprop.app.website.premium.property','2026-10-14 11:00Z','2026-10-14 11:01Z',null,'purchase')->>'revoked')::boolean,'refund before device assignment remains revoked');
select pg_temp.ok(property_website_transaction((select actor from wf),'ea300000-0000-4000-8000-000000000002',(select org from wf),'Production','website-refund-first','com.rendprop.app.website.premium.property','2026-10-14 11:00Z','2026-10-14 11:01Z',null,'purchase')->>'assigned'='false','refunded unassigned receipt gives explicit false acknowledgement');
select property_website_transaction((select actor from wf),null,null,'Production','website-refund-first','com.rendprop.app.website.premium.property','2026-10-14 11:00Z','2026-10-14 11:03Z',null,'purchase',true);
select pg_temp.ok((select revoked_at is not null and assignment_identity is null from property_website_transactions where transaction_id='website-refund-first'),'late ONE_TIME_CHARGE cannot undo newer refund or assign a property');
select property_website_transaction((select actor from wf),null,null,'Production','website-purchase-1','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:04Z',null,'refund_reversed',true);
select pg_temp.ok((select notification_signed_at='2026-10-14 10:06Z'from property_website_transactions where transaction_id='website-purchase-1'),'older outer reversal cannot override newer notification even with fresh inner signature');
select property_website_transaction((select actor from wf),null,null,'Production','website-purchase-1','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:07Z','2026-10-14 10:07Z','refund',true);
select property_website_transaction((select actor from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf),'Production','website-purchase-new','com.rendprop.app.website.premium.property','2026-10-14 10:08Z','2026-10-14 10:09Z',null,'purchase');
select pg_temp.ok(property_website_transaction((select actor from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf),'Production','website-purchase-1','com.rendprop.app.website.premium.property','2026-10-14 10:00Z','2026-10-14 10:10Z',null,'purchase')->>'receipt_grants_upgrade'='false','revoked old receipt grants no upgrade even when another credit is active');
select pg_temp.ok(property_website_state((select actor from wf),'ea300000-0000-4000-8000-000000000001',(select org from wf))->>'website_theme'='coastal-luxe','old refunded receipt cannot revoke a separate newer valid property credit');
reset role;

-- Close only transport/provider boundary while seeding exact retained receipts.
-- All tested RPCs and permissions below execute unchanged with triggers active.
set local session_replication_role=replica;
insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type)values
 ('ea400000-0000-4000-8000-000000000001','ea300000-0000-4000-8000-000000000001','photo','uploads','uploads/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000001/input.jpg',100,repeat('a',64),true,2,'image/jpeg'),
 ('ea400000-0000-4000-8000-000000000002','ea300000-0000-4000-8000-000000000001','video','renders','renders/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000001/finished.mp4',1000,repeat('b',64),true,2,'video/mp4'),
 ('ea400000-0000-4000-8000-000000000003','ea300000-0000-4000-8000-000000000001','video','renders','renders/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000001/recorded.mp4',1000,repeat('c',64),true,2,'video/mp4'),
 ('ea400000-0000-4000-8000-000000000004','ea300000-0000-4000-8000-000000000003','photo','uploads','uploads/'||(select other_org from wf)||'/ea300000-0000-4000-8000-000000000003/foreign.jpg',100,repeat('d',64),true,2,'image/jpeg'),
 ('ea400000-0000-4000-8000-000000000005','ea300000-0000-4000-8000-000000000001','photo','renders','renders/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000001/first-clip.jpg',100,repeat('e',64),true,2,'image/jpeg'),
 ('ea400000-0000-4000-8000-000000000006','ea300000-0000-4000-8000-000000000001','video','renders','renders/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000001/other-finished.mp4',1000,repeat('f',64),true,2,'video/mp4'),
 ('ea400000-0000-4000-8000-000000000007','ea300000-0000-4000-8000-000000000001','video','renders','renders/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000001/ai-finished.mp4',1000,repeat('7',64),true,2,'video/mp4'),
 ('ea400000-0000-4000-8000-000000000008','ea300000-0000-4000-8000-000000000002','video','renders','renders/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000002/first-video.mp4',1000,repeat('8',64),true,2,'video/mp4'),
 ('ea400000-0000-4000-8000-000000000009','ea300000-0000-4000-8000-000000000002','photo','renders','renders/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000002/first-poster.jpg',100,repeat('9',64),true,2,'image/jpeg'),
 ('ea400000-0000-4000-8000-000000000010','ea300000-0000-4000-8000-000000000002','photo','uploads','uploads/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000002/first-source.jpg',100,repeat('0',64),true,2,'image/jpeg');
insert into public.upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,spent_bytes,state,settled_at)
 select id,case when listing_id='ea300000-0000-4000-8000-000000000003'then(select other_org from wf)else(select org from wf)end,listing_id,
 case when listing_id='ea300000-0000-4000-8000-000000000003'then(select other from wf)else(select actor from wf)end,current_date,'{}',0,bytes,'completed',now()from capture_assets where id::text like 'ea400000-%';
insert into public.upload_operations(asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,etag)
 select id,'copy',bucket,storage_key,bytes,bytes,content_type,true,kind,'retained','"owned-etag"'from capture_assets where id::text like 'ea400000-%';
insert into public.render_jobs(id,listing_id,capture_asset_id,status,source)values('ea500000-0000-4000-8000-000000000001','ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000003','ready','app');
insert into public.renders(id,job_id,listing_id,slug,duration_s,video_key,published_at)values('ea600000-0000-4000-8000-000000000001','ea500000-0000-4000-8000-000000000001','ea300000-0000-4000-8000-000000000001','synthetic-existing-walkthrough',20,'renders/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000001/recorded.mp4',now());
insert into public.capture_chapters(asset_id,label,t_ms,sort)values('ea400000-0000-4000-8000-000000000003','Recorded kitchen',8000,0);
insert into public.media_provenance(id,org_id,listing_id,kind,model_id,disclosure)values('ea800000-0000-4000-8000-000000000001',(select org from wf),'ea300000-0000-4000-8000-000000000001','reel','fixture-model','Simulated motion');
insert into public.cost_ledger(id,org_id,billing_org_id,feature,provider,model,total_cents,meta)values('ea900000-0000-4000-8000-000000000001',(select org from wf),(select org from wf),'reel','fal','fixture-model',1,
 jsonb_build_object('app_video_reservation_id','eaa00000-0000-4000-8000-000000000001','request_id','verified-clip-1','request_key','verified-clip-key-1','stage','reel'));
insert into public.app_video_cost_reservations(id,actor_id,org_id,billing_org_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta,provider_request_id,cost_ledger_id,settled_at)values
 ('eaa00000-0000-4000-8000-000000000001',(select actor from wf),(select org from wf),(select org from wf),'verified-clip-key-1','reel','fal','fixture-model',repeat('b',64),1,1,1,1,'{"task":"video.reel_clip"}','verified-clip-1','ea900000-0000-4000-8000-000000000001',now());
insert into public.app_video_allowance_receipts(reservation_id,listing_id,monthly_key,monthly_window_start,burst_key,burst_window_start)values
 ('eaa00000-0000-4000-8000-000000000001','ea300000-0000-4000-8000-000000000001','fixture-month',now(),'fixture-burst',now());
set local session_replication_role=origin;
set local role service_role;
select pg_temp.refuse(format('select property_owned_upload(%L,%L,%L,%L)',(select actor from wf),'ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000004','photo'),'RP409:','foreign source asset rejected');
select pg_temp.refuse(format('select record_property_video_attestation(%L,%L,%L,%L,1000,1080,1920,15)',(select actor from wf),'ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000002','"owned-etag"'),'RP400:','portrait output cannot become landscape website video');
select pg_temp.refuse(format('select record_property_video_attestation(%L,%L,%L,%L,1000,1280,720,15)',(select actor from wf),'ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000002','"owned-etag"'),'RP400:','720p output is refused');
select pg_temp.refuse(format('select record_property_video_attestation(%L,%L,%L,%L,1000,1920,1080,15)',(select actor from wf),'ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000002','"wrong-etag"'),'RP400:','changed upload identity is refused');
select record_property_video_attestation((select actor from wf),'ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000002','"owned-etag"',1000,1920,1080,15);
select record_property_video_attestation((select actor from wf),'ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000006','"owned-etag"',1000,1920,1080,15);
select record_property_video_attestation((select actor from wf),'ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000007','"owned-etag"',1000,1920,1080,15);
select record_property_video_attestation((select actor from wf),'ea300000-0000-4000-8000-000000000002','ea400000-0000-4000-8000-000000000008','"owned-etag"',1000,1920,1080,15);
select bind_property_video_source((select actor from wf),'ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000001',null,'verified-clip-1','ea800000-0000-4000-8000-000000000001',repeat('a',64),repeat('a',32));
select set_config('request.jwt.claim.sub',(select actor::text from wf),true);reset role;set local role authenticated;
create temporary table manifest as select jsonb_build_object('schema',1,'purpose','listing','aspect','16:9','branding_policy','unbranded','sources',jsonb_build_array(jsonb_build_object(
 'photo_asset_id','ea400000-0000-4000-8000-000000000001','photo_version_id','retained-photo-version','motion_kind','original_photo')))m;
select pg_temp.ok((publish_property_video('ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000002',(select m from manifest),'ea400000-0000-4000-8000-000000000005','photo-video:ea700000-0000-4000-8000-000000000001')).slug='synthetic-existing-walkthrough','photo publication keeps existing property URL');
select pg_temp.ok((publish_property_video('ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000002',(select m from manifest),'ea400000-0000-4000-8000-000000000005','photo-video:ea700000-0000-4000-8000-000000000001')).slug='synthetic-existing-walkthrough','replay preserves same publication');
select pg_temp.refuse($q$select publish_property_video('ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000002',(select jsonb_set(m,'{sources,0,motion_kind}','"ai"')from manifest),'ea400000-0000-4000-8000-000000000005','photo-video:ea700000-0000-4000-8000-000000000009')$q$,'RP409:','AI clip needs verified generation identity');
select publish_property_video('ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000006',(select m from manifest),'ea400000-0000-4000-8000-000000000005','photo-video:ea700000-0000-4000-8000-000000000002');
select pg_temp.refuse($q$select publish_property_video('ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000002',(select m from manifest),'ea400000-0000-4000-8000-000000000005','photo-video:ea700000-0000-4000-8000-000000000001')$q$,'publication_superseded:','lost reply for old A cannot replace newer B');
select publish_property_video('ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000002',(select m from manifest),'ea400000-0000-4000-8000-000000000005','photo-video:ea700000-0000-4000-8000-000000000003');
select pg_temp.refuse($q$select publish_property_video('ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000002',(select m from manifest),'ea400000-0000-4000-8000-000000000005','photo-video:ea700000-0000-4000-8000-000000000001')$q$,'publication_superseded:','old A operation remains superseded after explicit new A selection');
reset role;set local role service_role;
select pg_temp.ok((select asset_id='ea400000-0000-4000-8000-000000000002'from property_video_compositions where selected),'explicit A reselect succeeds without duplicating immutable video');
select pg_temp.ok((select count(*)=3 and max(selection_revision)=3 from property_video_publication_ops),'only new explicit selections advance revision');
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000001')->'listing_video'->>'poster_key'like '%/first-clip.jpg','poster stays attached to photo composition separately from recorded render');
select pg_temp.ok((select video_key like '%/recorded.mp4'and duration_s=20 and presentation_kind='recorded_walkthrough'from renders where id='ea600000-0000-4000-8000-000000000001'),'photo video does not overwrite recorded walkthrough');
select pg_temp.ok((select count(*)=1 and min(label)='Recorded kitchen'from capture_chapters where asset_id='ea400000-0000-4000-8000-000000000003'),'recorded chapters are untouched');
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000001')->'listing_video'->>'width'='1920','public projection comes from verified actual dimensions');
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000001')->'listing_video'->>'disclosure'like '%not recorded walkthrough footage%','pure original-photo motion is honestly labeled');
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000001')->'listing_video'->>'disclosure'not like '%AI-generated%','pure photo motion never claims generative video');
select pg_temp.ok((select count(*)=2 from property_video_compositions),'reselect and replay keep one immutable composition per output');
reset role;set local role authenticated;
create temporary table ai_manifest as select jsonb_set(m,'{sources}',jsonb_build_array(jsonb_build_object('photo_asset_id','ea400000-0000-4000-8000-000000000001','photo_version_id','retained-ai-version','motion_kind','ai','generation_request_id','verified-clip-1','generation_provenance_id','ea800000-0000-4000-8000-000000000001')))m from manifest;
select pg_temp.refuse($q$select publish_property_video('ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000007',(select m from ai_manifest),'ea400000-0000-4000-8000-000000000005','photo-video:ea700000-0000-4000-8000-000000000004')$q$,'RP409:','successful generation alone never authorizes unchecked AI composition');
reset role;
insert into public.cost_ledger(org_id,billing_org_id,feature,provider,model,total_cents,meta)values((select org from wf),(select org from wf),'qc','openai','fixture-qc',1,
 jsonb_build_object('kind','video_drift','request_id','verified-clip-1','provenance_id','ea800000-0000-4000-8000-000000000001','source_asset_id','ea400000-0000-4000-8000-000000000001','source_sha256',repeat('a',32),'action','accept','publishable',true));
set local role authenticated;
select pg_temp.refuse($q$select publish_property_video('ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000007',(select m from ai_manifest),'ea400000-0000-4000-8000-000000000005','photo-video:ea700000-0000-4000-8000-000000000004')$q$,'RP409:','passing ledger alone needs matching completed quality journal');
reset role;
insert into public.app_video_drift_checks(reservation_id,actor_id,org_id,listing_id,source_sha256,state,result)values('eaa00000-0000-4000-8000-000000000001',(select actor from wf),(select org from wf),'ea300000-0000-4000-8000-000000000001',repeat('a',32),'accept','{"drift":{"action":"accept","publishable":true}}');
set local role authenticated;
select publish_property_video('ea300000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000007',(select m from ai_manifest),'ea400000-0000-4000-8000-000000000005','photo-video:ea700000-0000-4000-8000-000000000004');
reset role;set local role service_role;
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000001')->'listing_video'->>'disclosure'like '%AI-generated movement%','owned generated source+exact QC ledger+journal produce honest AI disclosure');
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000001')->'listing_video'->>'branding_policy'='unbranded','typed immutable unbranded recipe is retained in public projection');
reset role;
-- Explicit manual/legacy publication authority is a LOCAL test fixture, not a
-- serving grant or supplier dispatch. New first photo-only website has no old
-- recorded render to borrow for its permalink.
update public.orgs set plan='team',plan_source='manual',plan_expires_at=null where id=(select org from wf);
set local role authenticated;
select publish_property_video('ea300000-0000-4000-8000-000000000002','ea400000-0000-4000-8000-000000000008',jsonb_build_object('schema',1,'purpose','listing','aspect','16:9','branding_policy','unbranded','sources',jsonb_build_array(jsonb_build_object('photo_asset_id','ea400000-0000-4000-8000-000000000010','photo_version_id','first-retained-version','motion_kind','original_photo'))),'ea400000-0000-4000-8000-000000000009','photo-video:ea700000-0000-4000-8000-000000000008');
reset role;set local role service_role;
select pg_temp.ok((select count(*)=1 and bool_and(presentation_kind='photo_video'and published_at is not null)from renders where listing_id='ea300000-0000-4000-8000-000000000002'),'first photo-only publication creates its own live typed permalink');
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000002')->'listing_video'->>'asset_id'='ea400000-0000-4000-8000-000000000008','first photo-only public selection uses exact attested output');
reset role;set local role authenticated;
select publish_recorded_render('ea500000-0000-4000-8000-000000000001',true,20,1,'[]'::jsonb,null);
reset role;set local role service_role;
select pg_temp.ok(property_public_presentation('ea300000-0000-4000-8000-000000000001')->'listing_video'->>'asset_id'='ea400000-0000-4000-8000-000000000007','explicit recorded publication preserves selected photo-video primary');
reset role;set local role authenticated;
select pg_temp.refuse($q$select publish_recorded_render((select job_id from public.renders where listing_id='ea300000-0000-4000-8000-000000000002'),true,15,1,'[]'::jsonb,null)$q$,'RP409:','known photo master cannot be relabeled recorded footage through the old route');
reset role;set local role service_role;
select jsonb_build_object('passed',true,'assertions',n,'scope','actual RPC/role/retained receipt fixtures, no Apple/R2/provider')from website_checks;
rollback;
