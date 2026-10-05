-- Synthetic deletion contracts: voice, private originals and logos coexist.
-- Every authority/inventory mutation below is rolled back.
begin;
create temp table deletion_media_checks(label text primary key,ok boolean not null);
create function pg_temp.deletion_media_ok(label text,value boolean) returns void language plpgsql security definer as $$begin
 if value is distinct from true then raise exception 'DELETION MEDIA FAIL: %',label;end if;
 insert into pg_temp.deletion_media_checks values(label,true);
end $$;
insert into auth.users(id,email,is_anonymous)values
 ('b0100508-0000-4000-8000-000000000001','voice-delete@fixture.invalid',false),
 ('b0100508-0000-4000-8000-000000000002','project-delete@fixture.invalid',false),
 ('b0100508-0000-4000-8000-000000000003','project-colleague@fixture.invalid',false),
 ('b0100508-0000-4000-8000-000000000004','mixed-delete@fixture.invalid',false);
create temp table deletion_media_fixture as select user_id actor,org_id org from memberships where user_id::text like 'b0100508-%';
grant select on deletion_media_fixture to service_role;
insert into memberships(user_id,org_id,role)select 'b0100508-0000-4000-8000-000000000002',org,'agent' from deletion_media_fixture where actor='b0100508-0000-4000-8000-000000000003';
insert into listings(id,org_id,agent_id,address)select 'b0100512-0000-4000-8000-000000000001',org,actor,'Synthetic aliased voice'from deletion_media_fixture where actor='b0100508-0000-4000-8000-000000000001';
select pg_temp.deletion_media_ok('deletion writer remains service only',not has_function_privilege('authenticated','prepare_account_deletion(uuid,text,text)','execute') and not has_function_privilege('anon','prepare_account_deletion(uuid,text,text)','execute') and has_function_privilege('service_role','prepare_account_deletion(uuid,text,text)','execute'));
select pg_temp.deletion_media_ok('Studio inventory helpers remain internal',not has_function_privilege('service_role','studio_voice_deletion_targets(uuid[],text)','execute') and not has_function_privilege('service_role','studio_project_deletion_targets(uuid,uuid[],text)','execute'));
set local role service_role;
-- A reservation and two aliases all reference the same immutable voice bytes.
select reserve_voice_storage(actor,org,'b0100509-0000-4000-8000-000000000001',null)from deletion_media_fixture where actor='b0100508-0000-4000-8000-000000000001';
select reserve_voice_storage(actor,org,'b0100509-0000-4000-8000-000000000004',null)from deletion_media_fixture where actor='b0100508-0000-4000-8000-000000000004';
select studio_project_media_write('b0100508-0000-4000-8000-000000000002',org,'b0100510-0000-4000-8000-000000000002','reserve',jsonb_build_object('sha256',repeat('a',64),'bytes',9437184,'mime','video/mp4','filename','private.mp4','modified',0))from deletion_media_fixture where actor='b0100508-0000-4000-8000-000000000003';
select studio_project_media_write(actor,org,'b0100510-0000-4000-8000-000000000003','reserve',jsonb_build_object('sha256',repeat('b',64),'bytes',3,'mime','audio/mpeg','filename','colleague.mp3','modified',0))from deletion_media_fixture where actor='b0100508-0000-4000-8000-000000000003';
select studio_project_media_write(actor,org,'b0100510-0000-4000-8000-000000000004','reserve',jsonb_build_object('sha256',repeat('c',64),'bytes',9437184,'mime','video/mp4','filename','mixed.mp4','modified',0))from deletion_media_fixture where actor='b0100508-0000-4000-8000-000000000004';
select prepare_org_brand_logo(actor,org,'b0100511-0000-4000-8000-000000000004',null,100,'image/png',repeat('d',64),'https://cdn.fixture.invalid/renders/'||org||'/brand/b0100511-0000-4000-8000-000000000004.png')from deletion_media_fixture where actor='b0100508-0000-4000-8000-000000000004';
reset role;
insert into studio_creative_results(user_id,org_id,listing_id,kind,bucket,storage_key,request_key,metadata)
 select actor,org,'b0100512-0000-4000-8000-000000000001','voice','uploads','ai-voice/'||org||'/b0100509-0000-4000-8000-000000000001.mp3','alias-'||n,'{"state":"completed"}'::jsonb from deletion_media_fixture cross join generate_series(1,2)n where actor='b0100508-0000-4000-8000-000000000001';
create temp table deletion_media_deadlines as
 select 'voice'kind,actor_id actor,write_deadline deadline from voice_storage_reservations where id::text like 'b0100509-%'
 union all select 'project',actor_id,write_deadline from studio_project_media where id::text like 'b0100510-%'
 union all select 'logo',r.actor_id,o.write_deadline from upload_reservations r join upload_operations o using(asset_id)where r.asset_id='b0100511-0000-4000-8000-000000000004';
grant select on deletion_media_deadlines to service_role;
set local role service_role;
select prepare_account_deletion('b0100508-0000-4000-8000-000000000001','fixture-uploads','fixture-renders');
select pg_temp.deletion_media_ok('voice aliases and reservation inventoried exactly once',(select jsonb_array_length(payload->'r2')=1 and payload->'r2'->0->>'bucket'='fixture-uploads' and payload->'r2'->0->>'key'='ai-voice/'||(select org from deletion_media_fixture where actor=d.user_id)||'/b0100509-0000-4000-8000-000000000001.mp3' from deletion_requests d where user_id='b0100508-0000-4000-8000-000000000001' and snapshot_version=2));
select pg_temp.deletion_media_ok('voice cleanup waits for original write deadline plus one hour',(select (payload->>'storage_not_before')::timestamptz=(select deadline+interval '1 hour'from deletion_media_deadlines where actor=d.user_id and kind='voice') from deletion_requests d where user_id='b0100508-0000-4000-8000-000000000001'and snapshot_version=2));
select prepare_account_deletion('b0100508-0000-4000-8000-000000000002','fixture-uploads','fixture-renders');
select pg_temp.deletion_media_ok('project reserved chunks inventoried exactly once',(select jsonb_array_length(payload->'r2')=2 and (select count(distinct t->>'key')=2 and bool_and(t->>'bucket'='fixture-uploads'and t->>'key' like 'studio-project/%/b0100508-0000-4000-8000-000000000002/b0100510-0000-4000-8000-000000000002/%')from jsonb_array_elements(payload->'r2')t) from deletion_requests where user_id='b0100508-0000-4000-8000-000000000002'and snapshot_version=2));
select pg_temp.deletion_media_ok('private project cleanup waits for original write deadline plus one hour',(select (payload->>'storage_not_before')::timestamptz=(select deadline+interval '1 hour'from deletion_media_deadlines where actor=d.user_id and kind='project')from deletion_requests d where user_id='b0100508-0000-4000-8000-000000000002'and snapshot_version=2));
select pg_temp.deletion_media_ok('deleting actor private project metadata removed',not exists(select 1 from studio_project_media where actor_id='b0100508-0000-4000-8000-000000000002'));
select pg_temp.deletion_media_ok('shared colleague media and workspace preserved',exists(select 1 from studio_project_media where id='b0100510-0000-4000-8000-000000000003')and exists(select 1 from orgs where id=(select org from deletion_media_fixture where actor='b0100508-0000-4000-8000-000000000003')));
select prepare_account_deletion('b0100508-0000-4000-8000-000000000004','fixture-uploads','fixture-renders');
select pg_temp.deletion_media_ok('mixed logo voice and private project physical objects each inventoried once',(select jsonb_array_length(payload->'r2')=4 and (select count(distinct t->>'key')=4 and count(*)filter(where t->>'key'like'ai-voice/%')=1 and count(*)filter(where t->>'key'like'studio-project/%')=2 and count(*)filter(where t->>'key'like'renders/%/brand/%')=1 from jsonb_array_elements(payload->'r2')t)from deletion_requests where user_id='b0100508-0000-4000-8000-000000000004'and snapshot_version=2));
select pg_temp.deletion_media_ok('mixed cleanup honors every independent write deadline',(select (payload->>'storage_not_before')::timestamptz=(select max(deadline)+interval '1 hour'from deletion_media_deadlines where actor=d.user_id)from deletion_requests d where user_id='b0100508-0000-4000-8000-000000000004'and snapshot_version=2));
reset role;
select count(*)as deletion_media_assertions from deletion_media_checks;
select 'PASS: Studio deletion inventory SQL assertions; all fixtures rolled back.';
rollback;
