\set ON_ERROR_STOP on
begin;
create temporary table reaudit_checks(n integer not null default 0);insert into reaudit_checks default values;grant select,update on reaudit_checks to service_role;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'REAUDIT FAIL: %',label;end if;update reaudit_checks set n=n+1;end$$;
create function pg_temp.refuse(command text,prefix text,label text)returns void language plpgsql as $$begin begin execute command;exception when raise_exception then if sqlerrm like prefix||'%'then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception 'REAUDIT FAIL: allowed %',label;end$$;

insert into auth.users(id,email,is_anonymous)values('fa200000-0000-4000-8000-000000000001','takeover-a@fixture.invalid',false),('fa200000-0000-4000-8000-000000000002','takeover-b@fixture.invalid',false);
set local role service_role;
select notification_register_device_session('fa200000-0000-4000-8000-000000000001','fa210000-0000-4000-8000-000000000001',repeat('91',32),null,'sandbox');
-- Simulate the reachable offline/expired DELETE: there is no unregister call.
select notification_register_device_session('fa200000-0000-4000-8000-000000000002','fa210000-0000-4000-8000-000000000002',upper(repeat('91',32)),null,'sandbox');
select pg_temp.refuse($q$select notification_register_device_session('fa200000-0000-4000-8000-000000000001','fa210000-0000-4000-8000-000000000001',repeat('91',32),null,'sandbox')$q$,'RP409: This device session has signed out','late displaced A POST is fenced without prior DELETE');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('91',32)and user_id='fa200000-0000-4000-8000-000000000002'),'B retains physical token after late A POST');
select pg_temp.ok(not(notification_unregister_device('fa200000-0000-4000-8000-000000000001','fa210000-0000-4000-8000-000000000001',repeat('91',32),'sandbox')->>'removed')::boolean,'late A DELETE cannot erase B');
select notification_register_device_session('fa200000-0000-4000-8000-000000000001','fa210000-0000-4000-8000-000000000003',repeat('91',32),null,'sandbox');
select pg_temp.refuse($q$select notification_register_device_session('fa200000-0000-4000-8000-000000000002','fa210000-0000-4000-8000-000000000002',repeat('91',32),null,'sandbox')$q$,'RP409:','new A sign-in fences displaced B session');
select notification_register_device_session('fa200000-0000-4000-8000-000000000001','fa210000-0000-4000-8000-000000000004',repeat('91',32),null,'sandbox');
select pg_temp.refuse($q$select notification_register_device_session('fa200000-0000-4000-8000-000000000001','fa210000-0000-4000-8000-000000000003',repeat('91',32),null,'sandbox')$q$,'RP409:','same-account new session fences old session');
select pg_temp.ok(not(notification_unregister_device('fa200000-0000-4000-8000-000000000001','fa210000-0000-4000-8000-000000000003',repeat('91',32),'sandbox')->>'removed')::boolean,'old same-account DELETE preserves new session');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('91',32)and registration_session_id='fa210000-0000-4000-8000-000000000004'),'new same-account registration remains live');
select notification_register_device_session('fa200000-0000-4000-8000-000000000001','fa210000-0000-4000-8000-000000000001',repeat('92',32),null,'sandbox');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('92',32)),'fence remains exact-token scoped');
reset role;
select pg_temp.ok(not has_table_privilege('anon','public.notification_device_session_tombstones','select')and not has_table_privilege('authenticated','public.notification_device_session_tombstones','select'),'tombstones remain private');
select jsonb_build_object('suite','reaudit_device_takeover','assertions',n)from reaudit_checks;
rollback;
