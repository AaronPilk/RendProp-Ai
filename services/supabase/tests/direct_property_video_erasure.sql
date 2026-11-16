-- Appended to the exact source fixture's synthetic setup by its owned driver.
-- No fixtures are pre-deleted to conceal foreign-key or accounting failures.
set local role service_role;
select pg_temp.direct(2);
select pg_temp.direct(3,'f8540000-0000-4000-8000-000000000002','f8580000-0000-4000-8000-000000000002',repeat('b',64));
create temp table input_source as select public.property_photo_reference(actor,listing,'f8540000-0000-4000-8000-000000000001',null)s from vf;
reset role;
-- Real background records; metadata boundaries only, no queue/provider work.
set local session_replication_role=replica;
insert into property_video_jobs(id,operation_id,actor_id,org_id,listing_id,library_org_id,manifest,manifest_sha256,source_count,state,consent_revision)
 select 'f8550000-0000-4000-8000-000000000001',gen_random_uuid(),actor,org,listing,org,'{"fixture":true}',repeat('a',64),1,'generating','property-video-jobs-v1'from vf;
insert into property_video_job_sources(job_id,position,photo_id,asset_id,version_id,source,motion,state,attempt_id,request_key)
 select 'f8550000-0000-4000-8000-000000000001',0,'selected-source','f8540000-0000-4000-8000-000000000001','saved-version',s,'push_in','processing','f8550000-0000-4000-8000-000000000002','direct-fixture:12'from input_source;
insert into property_video_preparations(operation_id,actor_id,listing_id,org_id,library_org_id,photo_id,version_id,original_asset_id,original_source)
 select gen_random_uuid(),actor,listing,org,org,'selected-source','saved-version','f8540000-0000-4000-8000-000000000001',s from vf,input_source;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type)
 select ('f8540000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,listing,case when i=6 then'video'else'photo'end,'renders',
 'renders/'||org||'/'||listing||'/private-'||i||case when i=6 then'.mp4'else'.jpg'end,100,repeat('c',64),true,2,case when i=6 then'video/mp4'else'image/jpeg'end from vf cross join generate_series(6,7)i;
insert into property_video_compositions(listing_id,org_id,actor_id,asset_id,poster_asset_id,manifest,disclosure,publication_key)
 select listing,org,actor,'f8540000-0000-4000-8000-000000000006','f8540000-0000-4000-8000-000000000007','{"fixture":true}','Private retained composition','private-fixture-composition'from vf;
-- Foreign listing/source/binding must survive even when this actor is also a
-- member of that shared library. Canonical deletion scope chooses solo only.
insert into memberships(org_id,user_id,role)select other_org,actor,'agent'from vf;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type)
 select 'f8540000-0000-4000-8000-000000000099',other_listing,'photo','uploads','uploads/'||other_org||'/'||other_listing||'/foreign-source.jpg',100,repeat('d',64),true,2,'image/jpeg'from vf;
insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,spent_bytes,state,settled_at)
 select 'f8540000-0000-4000-8000-000000000099',other_org,other_listing,other,current_date,'{}',0,100,'completed',now()from vf;
insert into upload_operations(asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,etag)
 select id,'copy',bucket,storage_key,bytes,bytes,content_type,true,kind,'retained','"foreign-etag"'from capture_assets where id='f8540000-0000-4000-8000-000000000099';
-- Financial identity triggers remain active for this actual settled fixture.
set local session_replication_role=origin;
insert into app_video_cost_reservations(org_id,actor_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)
 select other_org,other,'foreign-direct-key','reel','fal','fal-ai/kling-video/v3/4k/image-to-video',repeat('d',64),5,42,210,210,'{"task":"video.reel_clip"}'from vf;
insert into app_video_allowance_receipts(reservation_id,listing_id,monthly_key,monthly_window_start,burst_key,burst_window_start)
 select id,(select other_listing from vf),'foreign-month',now(),'foreign-burst',now()from app_video_cost_reservations where idempotency_key='foreign-direct-key';
insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,budget_source,state)
 select other_org,other,'foreign-direct-key','reel','fal','fal-ai/kling-video/v3/4k/image-to-video',repeat('d',64),'synthetic-existing-price',210,'ceiling','succeeded'from vf;
set local session_replication_role=origin;
set local role service_role;
select app_video_cost_settle(other,other_org,'foreign-direct-key','foreign-paid-request')from vf;
select record_direct_property_video_source(other,other_org,'foreign-direct-key',other_listing,'f8540000-0000-4000-8000-000000000099',null,'foreign-paid-request',repeat('d',64),repeat('d',32),null,null,null)from vf;
-- The unchanged normal background provenance function still gets its own row.
create temp table background_proof as select public.property_video_job_provenance('f8550000-0000-4000-8000-000000000001','f8550000-0000-4000-8000-000000000002','accepted-12','fal-ai/kling-video/v3/4k/image-to-video')g;
select bind_property_video_source(actor,listing,'f8540000-0000-4000-8000-000000000001',null,'accepted-12',(g).id,repeat('a',64),repeat('a',32))from vf,background_proof;
create temp table erasure_before as select
 (select sum(total_cents)from cost_ledger)total,(select count(*)from cost_ledger)ledger_count,
 (select jsonb_object_agg(id,to_jsonb(x))from app_video_cost_reservations x)app,
 (select jsonb_object_agg(id,to_jsonb(x))from serving_cost_reservations x)serving,
 (select to_jsonb(x)from property_video_sources x where request_id='foreign-paid-request')foreign_binding,
 (select to_jsonb(x)from cost_ledger x where meta->>'request_key'='foreign-direct-key')foreign_ledger;
select public.prepare_account_deletion(actor,'fixture-uploads','fixture-renders')from vf;
select pg_temp.ok(not exists(select 1 from property_video_sources where listing_id=(select listing from vf)),'direct and background source bindings erased within scope');
select pg_temp.ok(not exists(select 1 from capture_assets where listing_id=(select listing from vf)),'source and composition capture assets erase without FK failure');
select pg_temp.ok(not exists(select 1 from property_video_job_sources where job_id='f8550000-0000-4000-8000-000000000001')and not exists(select 1 from property_video_preparations where listing_id=(select listing from vf))and not exists(select 1 from property_video_compositions where listing_id=(select listing from vf)),'only scoped capture-binding children cleared');
select pg_temp.ok((select foreign_binding=(select to_jsonb(x)from property_video_sources x where request_id='foreign-paid-request')from erasure_before),'foreign owner shared-library binding untouched');
select pg_temp.ok(exists(select 1 from listings where id=(select other_listing from vf))and exists(select 1 from orgs where id=(select other_org from vf))and not exists(select 1 from memberships where user_id=(select actor from vf)and org_id=(select other_org from vf)),'shared owner content retained while departing membership removed');
select pg_temp.ok((select total=(select sum(total_cents)from cost_ledger)and ledger_count=(select count(*)from cost_ledger)from erasure_before),'financial ledger count and total retained');
select pg_temp.ok((select app=(select jsonb_object_agg(id,to_jsonb(x))from app_video_cost_reservations x)and serving=(select jsonb_object_agg(id,to_jsonb(x))from serving_cost_reservations x)from erasure_before),'paid/unknown app and serving tombstones unchanged');
select pg_temp.ok((select foreign_ledger=(select to_jsonb(x)from cost_ledger x where meta->>'request_key'='foreign-direct-key')from erasure_before),'other owner ledger byte-identical');
select pg_temp.ok(exists(select 1 from deletion_requests where user_id=(select actor from vf)and snapshot_version=2 and ownership_scope->>'db_purged'='true'),'canonical durable deletion intent preserved');
select pg_temp.denied('select pg_temp.direct(11)','pending/deleted scope cannot create new binding','RP404:');
reset role;
select jsonb_build_object('passed',true,'erasureAssertions',n)from checks;
rollback;
