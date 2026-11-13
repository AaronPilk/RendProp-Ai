-- Injected before the existing typed-publication fixture's first composition.
-- All rows are local synthetic retained metadata; no supplier/media operation.
reset role;
update public.orgs set plan='team',plan_source='manual',plan_expires_at=null where id=(select org from wf);
create temp table c4_before as select (select count(*) from public.cost_ledger) costs,(select count(*) from public.renders) renders;
select pg_temp.ok(not has_function_privilege('authenticated','public.assert_recorded_render_source(uuid,uuid)','execute') and not has_function_privilege('anon','public.assert_recorded_render_source(uuid,uuid)','execute'),'recorded classifier is not a public media oracle');
select pg_temp.ok(not exists(select 1 from public.property_video_compositions where asset_id='ea400000-0000-4000-8000-000000000008'),'unpublished photo output has no composition yet');
set local role authenticated;
-- An app job is free and does not authorize recorded presentation by itself.
select create_render_job('ea300000-0000-4000-8000-000000000002','ea400000-0000-4000-8000-000000000008','smooth','{}','recorded-c4-attested','app');
select pg_temp.refuse($q$select publish_recorded_render((select id from public.render_jobs where idem_key='recorded-c4-attested'),false,15,1,'[]',null)$q$,'RP409:','attested unpublished photo video cannot be recorded footage before composition');
select pg_temp.refuse($q$select create_render_job('ea300000-0000-4000-8000-000000000002','ea400000-0000-4000-8000-000000000008','smooth','{}','recorded-c4-paid','worker')$q$,'RP409:','typed photo output cannot start new paid recorded work');
select set_config('c4.job_id',(select id::text from public.render_jobs where idem_key='recorded-c4-attested'),true);
select set_config('request.jwt.claim.sub',(select other::text from wf),true);
select pg_temp.refuse($q$select publish_recorded_render(current_setting('c4.job_id')::uuid,false,15,1,'[]',null)$q$,'RP404:','foreign actor cannot classify or publish the retained job');
select set_config('request.jwt.claim.sub',(select actor::text from wf),true);
reset role;
set local session_replication_role=replica;
insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type)values
 ('ed400000-0000-4000-8000-000000000001','ea300000-0000-4000-8000-000000000002','video','renders','renders/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000002/normal-looking-ready.mp4',1000,repeat('3',64),true,2,'video/mp4'),
 ('ed400000-0000-4000-8000-000000000002','ea300000-0000-4000-8000-000000000002','photo','uploads','uploads/'||(select org from wf)||'/ea300000-0000-4000-8000-000000000002/normal-looking-prepared.jpg',100,repeat('4',64),true,2,'image/jpeg');
insert into public.property_video_jobs(id,operation_id,actor_id,listing_id,org_id,library_org_id,manifest,manifest_sha256,source_count,state,consent_revision,compose_lease,output_asset_id,poster_asset_id)
 values('ed500000-0000-4000-8000-000000000001','ed500000-0000-4000-8000-000000000002',(select actor from wf),'ea300000-0000-4000-8000-000000000002',(select org from wf),(select org from wf),'{}',repeat('a',64),1,'ready','property-video-jobs-v1','ed500000-0000-4000-8000-000000000003','ed400000-0000-4000-8000-000000000001','ea400000-0000-4000-8000-000000000009');
insert into public.property_video_job_outputs(asset_id,job_id,lease_token,kind,storage_key,bytes,sha256,content_type,etag,state)
 select id,'ed500000-0000-4000-8000-000000000001','ed500000-0000-4000-8000-000000000003',kind,storage_key,bytes,sha256,content_type,'"output-etag"','ready' from public.capture_assets where id='ed400000-0000-4000-8000-000000000001';
insert into public.property_video_preparations(id,operation_id,actor_id,listing_id,org_id,library_org_id,photo_id,version_id,original_asset_id,original_source,state,asset_id,storage_key,bytes,sha256)
 select 'ed600000-0000-4000-8000-000000000001','ed600000-0000-4000-8000-000000000002',(select actor from wf),listing_id,(select org from wf),(select org from wf),'selected-master','version','ea400000-0000-4000-8000-000000000010','{}','ready',id,storage_key,bytes,sha256 from public.capture_assets where id='ed400000-0000-4000-8000-000000000002';
set local session_replication_role=origin;
set local role authenticated;
select create_render_job('ea300000-0000-4000-8000-000000000002','ed400000-0000-4000-8000-000000000001','smooth','{}','recorded-c4-output','app');
select pg_temp.refuse($q$select publish_recorded_render((select id from public.render_jobs where idem_key='recorded-c4-output'),false,15,1,'[]',null)$q$,'RP409:','registered output without attestation/composition cannot be recorded footage');
select pg_temp.refuse($q$select create_render_job('ea300000-0000-4000-8000-000000000002','ed400000-0000-4000-8000-000000000001','smooth','{}','recorded-c4-output-paid','worker')$q$,'RP409:','registered output is refused before paid worker insertion');
select pg_temp.refuse($q$select create_render_job('ea300000-0000-4000-8000-000000000002','ed400000-0000-4000-8000-000000000002','smooth','{}','recorded-c4-prepared','worker')$q$,'RP409:','prepared video-only image cannot become a paid recorded source');
reset role;
set local session_replication_role=replica;
update public.property_video_job_outputs set bytes=999 where asset_id='ed400000-0000-4000-8000-000000000001';
set local session_replication_role=origin;
set local role authenticated;
select pg_temp.refuse($q$select publish_recorded_render((select id from public.render_jobs where idem_key='recorded-c4-output'),false,15,1,'[]',null)$q$,'RP409:','inconsistent typed identity fails closed rather than becoming recorded');
reset role;
set local session_replication_role=replica;
update public.property_video_job_outputs set bytes=1000 where asset_id='ed400000-0000-4000-8000-000000000001';
set local session_replication_role=origin;
select pg_temp.ok((select count(*) from public.cost_ledger)=(select costs from c4_before)and(select count(*) from public.renders)=(select renders from c4_before),'refused reclassification makes no ledger or publication change');
select pg_temp.ok(not exists(select 1 from public.render_jobs where idem_key in('recorded-c4-paid','recorded-c4-output-paid','recorded-c4-prepared')),'refused paid source makes no worker job');
set local role authenticated;
-- The remaining unchanged fixture proves typed publication still succeeds and
-- an actual recorded walkthrough republishes with its chapters/slug retained.
