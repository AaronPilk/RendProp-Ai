-- Actual current writer and Data API roles; every synthetic fixture rolls back.
-- The companion disposable runner also holds an org join open in a second
-- session, proves deletion waits on that exact backend, and checks custody
-- after the actual invite acceptance commits. Removing only the post-lock
-- preflight must fail that unchanged custody oracle; no timed sleep is proof.
\set ON_ERROR_STOP on
begin;
create function pg_temp.integrity_ok(label text, ok boolean) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL deletion integrity: %',label;end if;raise notice 'ok %',label;end$$;
create temp table integrity_fixture(n text primary key,u uuid,o uuid,l uuid);
insert into integrity_fixture select n,gen_random_uuid(),null,gen_random_uuid() from unnest(array['removed','owner','studio','solo','admin','reflection'])n;
insert into auth.users(id,email,raw_user_meta_data,is_anonymous)select u,n||'@deletion-integrity.fixture.invalid','{}',false from integrity_fixture;
update integrity_fixture f set o=(select org_id from public.memberships where user_id=f.u);
insert into public.listings(id,org_id,agent_id,address)select l,o,u,n from integrity_fixture;
create function pg_temp.refuse_deletion(n text, fragment text) returns boolean language plpgsql as $$
begin
  perform set_config('role','service_role',true);
  begin perform public.prepare_account_deletion((select u from integrity_fixture f where f.n=$1),'fixture-uploads','fixture-renders');
  exception when others then perform set_config('role','postgres',true);return position(fragment in sqlerrm)>0;end;
  perform set_config('role','postgres',true);return false;
end$$;
grant select on integrity_fixture to service_role,authenticated;

insert into public.memberships(org_id,user_id,role)select o,(select u from integrity_fixture where n='removed'),'agent'from integrity_fixture where n='owner';
insert into public.listings(org_id,agent_id,address)select o,(select u from integrity_fixture where n='removed'),'former-member retained listing'from integrity_fixture where n='owner';
set local role service_role;
select public.remove_org_member((select o from integrity_fixture where n='owner'),(select u from integrity_fixture where n='owner'),(select u from integrity_fixture where n='removed'));
reset role;
select pg_temp.integrity_ok('former-member listing reference refuses before solo purge',pg_temp.refuse_deletion('removed','former workspace'));
select pg_temp.integrity_ok('refusal preserves unrelated solo listing and workspace',exists(select 1 from public.listings where id=(select l from integrity_fixture where n='removed'))and exists(select 1 from public.orgs where id=(select o from integrity_fixture where n='removed')));
select pg_temp.integrity_ok('refusal creates no destructive deletion intent',not exists(select 1 from public.deletion_requests where user_id=(select u from integrity_fixture where n='removed')));
select pg_temp.integrity_ok('former workspace keeps its exact original assignee',exists(select 1 from public.listings where org_id=(select o from integrity_fixture where n='owner')and agent_id=(select u from integrity_fixture where n='removed')));

insert into public.memberships(org_id,user_id,role)select o,(select u from integrity_fixture where n='studio'),'agent'from integrity_fixture where n='owner';
select pg_temp.integrity_ok('sole shared owner refuses before unrelated solo purge',pg_temp.refuse_deletion('owner','Transfer ownership'));
select pg_temp.integrity_ok('ownership refusal leaves all listing and membership data intact',exists(select 1 from public.listings where id=(select l from integrity_fixture where n='owner'))and not exists(select 1 from public.deletion_requests where user_id=(select u from integrity_fixture where n='owner')));
insert into public.studio_documents(user_id,org_id,key,listing_id,kind,payload)select (select u from integrity_fixture where n='studio'),o,'edit:'||l,l,'edit','{}'from integrity_fixture where n='owner';
insert into public.studio_production_versions(document_user_id,org_id,document_key,listing_id,document_revision,reason,payload)select user_id,org_id,key,listing_id,1,'submitted','{}'from public.studio_documents where user_id=(select u from integrity_fixture where n='studio');
select pg_temp.integrity_ok('shared document/history deletion refuses before solo purge',pg_temp.refuse_deletion('studio','retained work or likeness'));
select pg_temp.integrity_ok('shared Studio history remains intact',exists(select 1 from public.studio_production_versions where document_user_id=(select u from integrity_fixture where n='studio'))and exists(select 1 from public.listings where id=(select l from integrity_fixture where n='studio')));
delete from public.studio_documents where user_id=(select u from integrity_fixture where n='studio');
insert into public.studio_presenter_profiles(org_id,subject_user_id,source_listing_id,display_name,reference_asset_ids,reference_snapshot,revision,status)
select o,(select u from integrity_fixture where n='studio'),l,'Synthetic subject',array[gen_random_uuid()],'[]',1,'pending'from integrity_fixture where n='owner';
insert into public.studio_presenter_drafts(id,org_id,listing_id,author_user_id,subject_user_id,profile_id,profile_revision,title,script,source_asset_id,format,resolution,revision)
select gen_random_uuid(),p.org_id,p.source_listing_id,(select u from integrity_fixture where n='owner'),p.subject_user_id,p.id,1,'Retained agency draft','Synthetic fixture',gen_random_uuid(),'listing_intro','480p',1 from public.studio_presenter_profiles p where subject_user_id=(select u from integrity_fixture where n='studio');
insert into public.studio_creative_results(user_id,org_id,listing_id,kind,request_key,presenter_profile_id)
select (select u from integrity_fixture where n='owner'),p.org_id,p.source_listing_id,'video','synthetic-cross-subject-result',p.id from public.studio_presenter_profiles p where subject_user_id=(select u from integrity_fixture where n='studio');
select pg_temp.integrity_ok('subject Auth cascade cannot destroy another author result',pg_temp.refuse_deletion('studio','retained work or likeness'));
select pg_temp.integrity_ok('other author draft and output receipt preserved',exists(select 1 from public.studio_presenter_drafts where subject_user_id=(select u from integrity_fixture where n='studio'))and exists(select 1 from public.studio_creative_results where request_key='synthetic-cross-subject-result'));

-- No broad FK changes: operator resolution and the original current-member
-- custody policy work without transferring a former workspace implicitly.
update public.listings set agent_id=(select u from integrity_fixture where n='owner')where org_id=(select o from integrity_fixture where n='owner')and agent_id=(select u from integrity_fixture where n='removed');
set local role service_role;
select public.prepare_account_deletion((select u from integrity_fixture where n='removed'),'fixture-uploads','fixture-renders');
reset role;
select pg_temp.integrity_ok('resolved former reference permits original solo deletion',not exists(select 1 from public.orgs where id=(select o from integrity_fixture where n='removed')));
select pg_temp.integrity_ok('operator reassigning custody preserves former workspace listing',exists(select 1 from public.listings where org_id=(select o from integrity_fixture where n='owner')and agent_id=(select u from integrity_fixture where n='owner')));
do $$begin
  begin insert into public.listings(org_id,agent_id,address)select o,(select u from integrity_fixture where n='removed'),'late reference'from integrity_fixture where n='owner';raise exception 'late listing reference admitted';
  exception when others then if position('Account deletion is in progress'in sqlerrm)=0 then raise;end if;end;
end$$;
select pg_temp.integrity_ok('late listing FK cannot recreate a profile deletion blocker',not exists(select 1 from public.listings where agent_id=(select u from integrity_fixture where n='removed')));
do $$begin
  begin insert into public.studio_documents(user_id,org_id,key,kind,payload)select (select u from integrity_fixture where n='removed'),o,'late-doc','edit','{}'from integrity_fixture where n='owner';raise exception 'late Studio reference admitted';
  exception when others then if position('Account deletion is in progress'in sqlerrm)=0 then raise;end if;end;
end$$;
select pg_temp.integrity_ok('late Auth-cascade Studio child refused',not exists(select 1 from public.studio_documents where user_id=(select u from integrity_fixture where n='removed')));
delete from public.profiles where id=(select u from integrity_fixture where n='removed');
delete from auth.users where id=(select u from integrity_fixture where n='removed');
select pg_temp.integrity_ok('profile and Auth removal now complete without FK failure',not exists(select 1 from auth.users where id=(select u from integrity_fixture where n='removed')));

insert into public.studio_documents(user_id,org_id,key,kind,payload)select u,o,'solo-document','edit','{}'from integrity_fixture where n='solo';
set local role service_role;
select public.prepare_account_deletion((select u from integrity_fixture where n='solo'),'fixture-uploads','fixture-renders');
reset role;
select pg_temp.integrity_ok('ordinary solo Studio cascade cleanup is preserved',not exists(select 1 from public.studio_documents where user_id=(select u from integrity_fixture where n='solo')));
create temp table reflection_fixture as select gen_random_uuid()asset,gen_random_uuid()batch,gen_random_uuid()job,gen_random_uuid()late_asset,gen_random_uuid()late_job;
insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,bytes,uploaded,duration_s)
select a.asset,f.l,'video','renders','renders/'||f.o||'/'||f.l||'/input.mp4',100,true,3 from integrity_fixture f cross join reflection_fixture a where f.n='reflection';
insert into public.video_erase_batches(id,org_id,user_id,listing_id)
select a.batch,f.o,f.u,f.l from integrity_fixture f cross join reflection_fixture a where f.n='reflection';
insert into public.video_erase_jobs(id,org_id,user_id,batch_id,asset_id,idempotency_key,request_hash,duration_s,cost_cents,state,monthly_window,burst_window,output_key)
select a.job,f.o,f.u,a.batch,a.asset,gen_random_uuid(),repeat('a',64),3,42,'completed',now(),now(),'video-reflections/foreign/unsafe.mp4'from integrity_fixture f cross join reflection_fixture a where f.n='reflection';
select pg_temp.integrity_ok('unowned reflection key refuses before solo purge',pg_temp.refuse_deletion('reflection','Reflection output ownership'));
select pg_temp.integrity_ok('reflection refusal preserves original asset and job',exists(select 1 from public.capture_assets where id=(select asset from reflection_fixture))and exists(select 1 from public.video_erase_jobs where id=(select job from reflection_fixture)));
update public.video_erase_jobs set output_key='video-reflections/'||org_id||'/'||id||'.mp4'where id=(select job from reflection_fixture);
insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,bytes,uploaded,duration_s)
select a.late_asset,f.l,'video','renders','renders/'||f.o||'/'||f.l||'/late-input.mp4',100,true,3 from integrity_fixture f cross join reflection_fixture a where f.n='reflection';
insert into public.video_erase_jobs(id,org_id,user_id,batch_id,asset_id,idempotency_key,request_hash,duration_s,cost_cents,state,monthly_window,burst_window)
select a.late_job,f.o,f.u,a.batch,a.late_asset,gen_random_uuid(),repeat('b',64),3,42,'processing',now(),now()from integrity_fixture f cross join reflection_fixture a where f.n='reflection';
create temp table reflection_receipt(receipt jsonb);
grant all on reflection_receipt to service_role;
set local role service_role;
insert into reflection_receipt select public.prepare_account_deletion((select u from integrity_fixture where n='reflection'),'fixture-uploads','fixture-renders');
reset role;
select pg_temp.integrity_ok('exact reflection output survives cascade in cleanup payload',exists(select 1 from reflection_receipt cross join lateral jsonb_array_elements(receipt->'payload'->'r2')t where t->>'bucket'='fixture-renders'and t->>'key'='video-reflections/'||(select o from integrity_fixture where n='reflection')||'/'||(select job from reflection_fixture)||'.mp4'));
select pg_temp.integrity_ok('inventoried reflection rows cascade only after durable intent',not exists(select 1 from public.video_erase_jobs where id=(select job from reflection_fixture))and exists(select 1 from public.deletion_requests where user_id=(select u from integrity_fixture where n='reflection')));
select pg_temp.integrity_ok('unacknowledged reflection destination remains in exact cleanup journal',exists(select 1 from reflection_receipt cross join lateral jsonb_array_elements(receipt->'payload'->'r2')t where t->>'bucket'='fixture-renders'and t->>'key'='video-reflections/'||(select o from integrity_fixture where n='reflection')||'/'||(select late_job from reflection_fixture)||'.mp4'));
select pg_temp.integrity_ok('reflection cleanup waits beyond existing storage write grace',(select (receipt->'payload'->>'storage_not_before')::timestamptz>=now()+interval '1 hour'from reflection_receipt));
select pg_temp.integrity_ok('authenticated and anonymous listing hard DELETE privilege absent',not has_table_privilege('authenticated','public.listings','DELETE')and not has_table_privilege('anon','public.listings','DELETE'));
select pg_temp.integrity_ok('service cleanup retains listing DELETE privilege',has_table_privilege('service_role','public.listings','DELETE'));
select pg_temp.integrity_ok('new preflight service only',not has_function_privilege('authenticated','public.account_deletion_integrity_preflight(uuid)','EXECUTE')and not has_function_privilege('anon','public.account_deletion_integrity_preflight(uuid)','EXECUTE')and has_function_privilege('service_role','public.account_deletion_integrity_preflight(uuid)','EXECUTE'));
select pg_temp.integrity_ok('public hard-delete policy removed',not exists(select 1 from pg_policy where polrelid='public.listings'::regclass and polname='org listings delete'));
select set_config('request.jwt.claims',jsonb_build_object('sub',(select u from integrity_fixture where n='admin'),'role','authenticated')::text,true);
set local role authenticated;
update public.listings set deleted_at=now()where id=(select l from integrity_fixture where n='admin');
reset role;
select pg_temp.integrity_ok('ordinary authenticated soft delete remains available',exists(select 1 from public.listings where id=(select l from integrity_fixture where n='admin')and deleted_at is not null));
select pg_temp.integrity_ok('soft delete still queues exact media inventory',exists(select 1 from public.privacy_cleanup_jobs where kind='listing'and source_id=(select l from integrity_fixture where n='admin')));
select pg_temp.integrity_ok('all new reference admission triggers enabled',(select count(*)from pg_trigger where tgname like 'account_deletion_%_reference'and tgenabled='O')=7);
rollback;
\echo PASS account deletion integrity: 29 assertions
