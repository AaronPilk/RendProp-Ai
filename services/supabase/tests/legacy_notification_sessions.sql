\set ON_ERROR_STOP on
begin;
create temporary table legacy_push_checks(n integer not null default 0);insert into legacy_push_checks default values;grant select,update on legacy_push_checks to service_role;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'LEGACY PUSH FAIL: %',label;end if;update legacy_push_checks set n=n+1;end$$;
create function pg_temp.refuse(command text,label text)returns void language plpgsql as $$begin begin execute command;exception when raise_exception then if sqlerrm like 'RP409: This device session has signed out%'then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception 'LEGACY PUSH FAIL: allowed %',label;end$$;
insert into auth.users(id,email,is_anonymous)values('fc100000-0000-4000-8000-000000000001','legacy-a@fixture.invalid',false),('fc100000-0000-4000-8000-000000000002','legacy-b@fixture.invalid',false);
insert into auth.sessions(id,user_id,created_at)values
('fc110000-0000-4000-8000-000000000001','fc100000-0000-4000-8000-000000000001',clock_timestamp()-interval '1 day'),
('fc110000-0000-4000-8000-000000000003','fc100000-0000-4000-8000-000000000001',clock_timestamp()-interval '1 day'),
('fc110000-0000-4000-8000-000000000004','fc100000-0000-4000-8000-000000000001',null);
set local role service_role;
-- Legacy A has no stored session. B takes over without an outgoing DELETE.
select notification_register_device('fc100000-0000-4000-8000-000000000001',repeat('97',32),null,'sandbox',null,null);
select notification_register_device_session('fc100000-0000-4000-8000-000000000002','fc110000-0000-4000-8000-000000000002',upper(repeat('97',32)),null,'sandbox');
select pg_temp.refuse($q$select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000001',repeat('97',32),null,'sandbox')$q$,'delayed legacy A is refused');
select pg_temp.refuse($q$select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000003',repeat('97',32),null,'sandbox')$q$,'another preexisting A session is refused');
select pg_temp.refuse($q$select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000001',repeat('97',32),null,'production')$q$,'caller environment cannot erase global token chronology');
select pg_temp.refuse($q$select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000004',repeat('97',32),null,'sandbox')$q$,'undated Auth session is insufficient evidence');
select pg_temp.refuse($q$select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000005',repeat('97',32),null,'sandbox')$q$,'missing Auth session is insufficient evidence');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('97',32)and user_id='fc100000-0000-4000-8000-000000000002'),'B retains registration');
select pg_temp.ok(not(notification_unregister_device('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000001',repeat('97',32),'sandbox')->>'removed')::boolean,'old A DELETE preserves B');
reset role;
insert into auth.sessions(id,user_id,created_at)values('fc110000-0000-4000-8000-000000000006','fc100000-0000-4000-8000-000000000002',clock_timestamp());
set local role service_role;
select pg_temp.refuse($q$select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000006',repeat('97',32),null,'sandbox')$q$,'another users fresh Auth session cannot recover A');
reset role;
insert into auth.sessions(id,user_id,created_at)values('fc110000-0000-4000-8000-000000000007','fc100000-0000-4000-8000-000000000001',clock_timestamp());
set local role service_role;
select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000007',repeat('97',32),null,'sandbox');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('97',32)and registration_session_id='fc110000-0000-4000-8000-000000000007'),'genuinely fresh A sign-in recovers registration');
select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000007',repeat('97',32),null,'sandbox');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('97',32)and registration_session_id='fc110000-0000-4000-8000-000000000007'),'repeated current registration remains available');
select pg_temp.refuse($q$select notification_register_device_session('fc100000-0000-4000-8000-000000000002','fc110000-0000-4000-8000-000000000002',repeat('97',32),null,'sandbox')$q$,'modern exact tombstone still takes precedence');
-- A successful legacy DELETE must preserve the boundary before removing its row.
select notification_register_device('fc100000-0000-4000-8000-000000000001',repeat('98',32),null,'sandbox',null,null);
select pg_temp.ok((notification_unregister_device('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000001',repeat('98',32),'sandbox')->>'removed')::boolean,'legacy removal acknowledges actual deleted row');
select notification_register_device_session('fc100000-0000-4000-8000-000000000002','fc110000-0000-4000-8000-000000000002',repeat('98',32),null,'sandbox');
select pg_temp.refuse($q$select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000003',repeat('98',32),null,'sandbox')$q$,'another old A session cannot reclaim after successful legacy DELETE');
select pg_temp.refuse($q$select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000003',repeat('98',32),null,'production')$q$,'successful legacy DELETE fences caller environment variation');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('98',32)and user_id='fc100000-0000-4000-8000-000000000002'),'B survives late request after successful legacy DELETE');
-- First upgrade with the same account continues without forcing another sign-in.
select notification_register_device('fc100000-0000-4000-8000-000000000001',repeat('99',32),null,'sandbox',null,null);
select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000003',repeat('99',32),null,'sandbox');
select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000003',repeat('99',32),null,'sandbox');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('99',32)and registration_session_id='fc110000-0000-4000-8000-000000000003'),'same-user first upgrade and repeat preserve current binding');
select pg_temp.refuse($q$select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000001',repeat('99',32),null,'sandbox')$q$,'a different old session does not replace current upgraded binding');
-- Retirement is exact-token scoped; it does not disable the account globally.
select notification_register_device_session('fc100000-0000-4000-8000-000000000001','fc110000-0000-4000-8000-000000000003',repeat('9a',32),null,'sandbox');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('9a',32)),'other phone token is unaffected');
reset role;
select pg_temp.ok((select relrowsecurity from pg_class where oid='public.notification_legacy_device_retirements'::regclass),'retirement rows use RLS');
select pg_temp.ok(not has_table_privilege('anon','public.notification_legacy_device_retirements','select')and not has_table_privilege('authenticated','public.notification_legacy_device_retirements','select')and not has_table_privilege('service_role','public.notification_legacy_device_retirements','select'),'retirement rows have no direct client or service table access');
select pg_temp.ok(not exists(select 1 from pg_policy where polrelid='public.notification_legacy_device_retirements'::regclass),'retirement RLS is deny all');
select pg_temp.ok(exists(select 1 from notification_legacy_device_retirements where user_id='fc100000-0000-4000-8000-000000000001'),'retirement persisted before deletion');
delete from auth.users where id='fc100000-0000-4000-8000-000000000001';
select pg_temp.ok(not exists(select 1 from notification_legacy_device_retirements where user_id='fc100000-0000-4000-8000-000000000001'),'account deletion cascades private retirement metadata');
select jsonb_build_object('suite','legacy_notification_sessions','assertions',n)from legacy_push_checks;
rollback;
