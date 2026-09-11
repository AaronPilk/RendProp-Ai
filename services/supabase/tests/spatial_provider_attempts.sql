\set ON_ERROR_STOP on
do $$ begin
 if current_database()<>'rendprop_provider_audit' or current_setting('listen_addresses')<>'' or current_setting('data_directory') !~ '^/tmp/rendprop-provider-db-[^/]+/cluster$' then raise exception 'provider fixture refuses existing databases'; end if;
end $$;
begin;
create temp table _checks(label text primary key);
create function pg_temp.a(ok boolean,label text) returns void language plpgsql as $$ begin
 if ok is distinct from true then raise exception 'provider assertion failed: %',label; end if; insert into _checks values(label);
end $$;
create function pg_temp.denied(command text,expected text,label text) returns void language plpgsql as $$ begin
 begin execute command; raise exception 'fixture accepted forbidden operation'; exception when others then
 if sqlerrm not like expected then raise exception 'wrong failure for %: %',label,sqlerrm; end if; end; perform pg_temp.a(true,label);
end $$;
select pg_temp.a(to_regclass('public.spatial_provider_attempts') is not null,'durable provider table exists');
create temp table _fixture(job uuid,lease uuid,attempt uuid);
insert into _fixture values('a0410000-0000-4000-8000-000000000003','a0410000-0000-4000-8000-000000000004','a0410000-0000-4000-8000-000000000005');
insert into auth.users(id,email,raw_user_meta_data) values('a0410000-0000-4000-8000-000000000001','provider@fixture.invalid','{}');
insert into listings(id,org_id,agent_id) select 'a0410000-0000-4000-8000-000000000002',org_id,user_id from memberships where user_id='a0410000-0000-4000-8000-000000000001';
insert into spatial_jobs(id,org_id,listing_id,actor_id,capture_id,idem_key,attempt_key,room_label,capture_manifest,status,lease_token,lease_expires_at,deadline_at)
 select f.job,l.org_id,l.id,l.agent_id,f.job,f.job,f.attempt,'Fixture','{}','processing',f.lease,clock_timestamp()+interval '2 minutes',clock_timestamp()+interval '2 hours' from _fixture f cross join listings l where l.id='a0410000-0000-4000-8000-000000000002';
create function pg_temp.call(action text,data jsonb) returns jsonb language sql as $$select spatial_provider_attempt_update(job,lease,attempt,action,data) from _fixture$$;
create function pg_temp.plan() returns jsonb language sql as $$select pg_temp.call('plan',jsonb_build_object('app_name','rendprop-spatial-worker','sandbox_name','spatial-'||job::text||'-'||lease::text,'source_sha256',repeat('a',64))) from _fixture$$;
create function pg_temp.no_allocation() returns jsonb language sql as $$select pg_temp.call('not_created',jsonb_build_object('origin','before_provider_entry','proof','create_not_invoked','app_name','rendprop-spatial-worker','sandbox_name','spatial-'||job::text||'-'||lease::text,'source_sha256',repeat('a',64))) from _fixture$$;
do $$ declare ns text;begin select nspname into ns from pg_namespace where oid=pg_my_temp_schema();execute format('grant usage on schema %I to service_role,anon,authenticated',ns);end $$;
grant select,insert,update on _checks,_fixture to service_role,anon,authenticated;
grant execute on all functions in schema pg_temp to service_role,anon,authenticated;
select pg_temp.a(not has_table_privilege('authenticated','spatial_provider_attempts','SELECT,INSERT,UPDATE,DELETE'),'member Data API journal denied');
select pg_temp.a(not has_function_privilege('anon','spatial_provider_attempt_update(uuid,uuid,uuid,text,jsonb)','EXECUTE'),'anonymous journal RPC denied');
select pg_temp.denied('select pg_temp.plan()','RP403:%','invoker service guard enforced');
set local role authenticated;
select pg_temp.denied('select pg_temp.plan()','permission denied%','actual member role RPC denied');
reset role;
set local role service_role;
select pg_temp.denied('select pg_temp.call(''cleanup'',''{"files_removed":true,"terminated":true}'')','RP409:%','unjournaled cleanup rejected');
select pg_temp.a(pg_temp.no_allocation()->>'dispatch'='false','early failure grants no dispatch');
select pg_temp.a((select allocation_state='not_created' and files_removed and terminated and sandbox_id is null from spatial_provider_attempts),'early failure has durable no-allocation proof');
reset role;
delete from spatial_provider_attempts where lease_token=(select lease from _fixture);
set local role service_role;
select pg_temp.a(pg_temp.plan()->>'dispatch'='true','first durable plan grants one dispatch');
select pg_temp.a(pg_temp.plan()->>'dispatch'='false','plan replay never grants another dispatch');
select pg_temp.denied('select spatial_provider_attempt_update(job,gen_random_uuid(),attempt,''plan'',jsonb_build_object(''app_name'',''rendprop-spatial-worker'',''sandbox_name'',''spatial-''||job::text||''-''||lease::text,''source_sha256'',repeat(''a'',64))) from _fixture','RP409:%','stale lease cannot plan allocation');
select pg_temp.denied('select pg_temp.call(''cleanup'',''{"files_removed":true,"terminated":true}'')','RP409:%','unknown identity cannot claim cleanup');
select pg_temp.call('unknown','{"last_error_code":"allocation_unknown"}');
select pg_temp.a((select allocation_state='unknown' and not terminated and not files_removed from spatial_provider_attempts),'ambiguous allocation remains pending');
select pg_temp.no_allocation();
select pg_temp.a((select allocation_state='unknown' and not terminated and not files_removed from spatial_provider_attempts),'early failure cannot overwrite another ambiguous create');
select pg_temp.call('created','{"sandbox_id":"sb-fixture1234"}');
select pg_temp.denied('select pg_temp.call(''created'',''{"sandbox_id":"sb-different1234"}'')','RP409:%','provider identity immutable');
select pg_temp.denied('select spatial_provider_attempt_update(job,lease,gen_random_uuid(),''cleanup'',''{}'') from _fixture','RP409:%','paid attempt identity distinct from lease');
select pg_temp.denied('select pg_temp.call(''not_created'',''{"proof":"create_not_invoked"}'')','RP409:%','created allocation cannot claim no rental');
select pg_temp.call('cleanup','{"sandbox_id":"sb-fixture1234","terminated":true,"files_removed":false,"exit_code":137,"reason_code":"billing_cycle_spend_limit"}');
select pg_temp.a((select terminated and not files_removed and exit_code=137 and reason_code='billing_cycle_spend_limit' from spatial_provider_attempts),'termination alone does not erase cleanup debt');
reset role;
delete from spatial_jobs where id=(select job from _fixture);
delete from listings where id='a0410000-0000-4000-8000-000000000002';
set local role service_role;
select pg_temp.call('cleanup','{"sandbox_id":"sb-fixture1234","files_removed":true,"terminated":true}');
select pg_temp.a((select files_removed and terminated from spatial_provider_attempts),'cleanup survives deleted parent job and listing');
select pg_temp.call('cleanup','{"files_removed":false,"terminated":false}');
select pg_temp.a((select files_removed and terminated from spatial_provider_attempts),'cleanup flags cannot regress on delayed response');
select pg_temp.denied('select pg_temp.call(''cleanup'',''{"files_removed":null}'')','RP400:%','null proof rejected');
select pg_temp.denied('select pg_temp.call(''cleanup'',''{"reason_code":"raw provider body with credentials"}'')','new row for relation "spatial_provider_attempts" violates check constraint%','arbitrary provider error body not retained');
reset role;
select pg_temp.a((select count(*)=22 from _checks),'all expected provider assertions executed');
select 'PASS: '||count(*)||' provider SQL assertions' from _checks;
rollback;
