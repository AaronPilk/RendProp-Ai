\set ON_ERROR_STOP on
-- Build 57 database controls: the build-56 reaudit claims are re-proved with
-- actual RPCs and rolled back. Non-switcher selection, legacy adoption
-- overload, deleted Team child settlement and device takeover fencing.
begin;
create temporary table b57_checks(n integer not null default 0);insert into b57_checks default values;grant select,update on b57_checks to service_role;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'BUILD57 FAIL: %',label;end if;update b57_checks set n=n+1;end$$;
create function pg_temp.refuse(command text,prefix text,label text)returns void language plpgsql as $$begin begin execute command;exception when raise_exception then if sqlerrm like prefix||'%'then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception 'BUILD57 FAIL: allowed %',label;end$$;
create function pg_temp.unprivileged(command text,label text)returns void language plpgsql as $$begin begin execute command;exception when insufficient_privilege then perform pg_temp.ok(true,label);return;end;raise exception 'BUILD57 FAIL: allowed %',label;end$$;

insert into auth.users(id,email,is_anonymous)values
('fe100000-0000-4000-8000-000000000001','b57-owner@fixture.invalid',false),
('fe100000-0000-4000-8000-000000000002','b57-agent@fixture.invalid',false),
('fe100000-0000-4000-8000-000000000003','b57-guest@fixture.invalid',true),
('fe100000-0000-4000-8000-000000000004','b57-plain@fixture.invalid',false),
('fe100000-0000-4000-8000-000000000005','b57-guest2@fixture.invalid',true),
('fe100000-0000-4000-8000-000000000006','b57-guest3@fixture.invalid',true),
('fe100000-0000-4000-8000-000000000007','b57-sibling@fixture.invalid',false);
create temp table b57 as select
 (select org_id from memberships where user_id='fe100000-0000-4000-8000-000000000001')team,
 (select org_id from memberships where user_id='fe100000-0000-4000-8000-000000000002')child,
 (select org_id from memberships where user_id='fe100000-0000-4000-8000-000000000003')guest,
 (select org_id from memberships where user_id='fe100000-0000-4000-8000-000000000004')plain,
 (select org_id from memberships where user_id='fe100000-0000-4000-8000-000000000005')guest2,
 (select org_id from memberships where user_id='fe100000-0000-4000-8000-000000000006')guest3,
 (select org_id from memberships where user_id='fe100000-0000-4000-8000-000000000007')sibling;
grant select on b57 to service_role;
update orgs set plan='team',plan_source='manual'where id=(select team from b57);
update plan_entitlements set seats=8 where plan='team';
insert into orgs(id,name)values('fe100000-0000-4000-8000-000000000090','Agent legacy library');
insert into memberships(user_id,org_id,role)values('fe100000-0000-4000-8000-000000000002','fe100000-0000-4000-8000-000000000090','owner');
set local role service_role;
select create_org_invite('fe100000-0000-4000-8000-000000000001',(select team from b57),null,'agent',repeat('b1',32));
select accept_org_invite('fe100000-0000-4000-8000-000000000002',repeat('b1',32));
select create_org_invite('fe100000-0000-4000-8000-000000000001',(select team from b57),null,'agent',repeat('b2',32));
select accept_org_invite('fe100000-0000-4000-8000-000000000007',repeat('b2',32));
select pg_temp.ok((select private_org_id=(select child from b57)from team_private_libraries where agent_user_id='fe100000-0000-4000-8000-000000000002'and revoked_at is null),'first-time acceptance binds the agent private library');
select pg_temp.ok((select active_org_id=(select child from b57)from user_workspace_state where user_id='fe100000-0000-4000-8000-000000000002'),'first-time acceptance activates the bound library');
-- (a) a bound non-switcher owning a second library can neither select nor be steered into it
select pg_temp.ok(not(workspace_directory('fe100000-0000-4000-8000-000000000002',null)->>'can_switch_agent_libraries')::boolean,'bound agent is not a switcher');
select pg_temp.refuse($q$select select_workspace('fe100000-0000-4000-8000-000000000002','fe100000-0000-4000-8000-000000000090')$q$,'RP403: Only the Team owner','non-switcher cannot select a second owned library');
select pg_temp.ok((select active_org_id=(select child from b57)from user_workspace_state where user_id='fe100000-0000-4000-8000-000000000002'),'refused selection leaves state untouched');
select pg_temp.refuse($q$select workspace_directory('fe100000-0000-4000-8000-000000000002','fe100000-0000-4000-8000-000000000090')$q$,'RP403: Only the Team owner','explicit second-library preference refuses');
select pg_temp.refuse(format('select workspace_directory(%L,%L)','fe100000-0000-4000-8000-000000000002',(select sibling from b57)),'RP403:','explicit foreign sibling preference refuses');
reset role;
update user_workspace_state set active_org_id='fe100000-0000-4000-8000-000000000090'where user_id='fe100000-0000-4000-8000-000000000002';
set local role service_role;
select pg_temp.ok((workspace_directory('fe100000-0000-4000-8000-000000000002',null)->>'active_org_id')::uuid=(select child from b57),'stale second-library state resolves to own');
select pg_temp.ok((workspace_directory('fe100000-0000-4000-8000-000000000002',null)->>'own_org_id')::uuid=(select child from b57),'own identity is the bound library');
select pg_temp.ok((select bool_and((d->>'active_org_id')=(d->>'own_org_id'))from(select workspace_directory('fe100000-0000-4000-8000-000000000002',x)d from(values(null::uuid),((select child from b57)))v(x))s),'non-switcher directory always reports active = own');
select pg_temp.ok((select_workspace('fe100000-0000-4000-8000-000000000002',(select child from b57))->>'active_org_id')::uuid=(select child from b57),'non-switcher can re-select own library');
select pg_temp.ok((select active_org_id=(select child from b57)from user_workspace_state where user_id='fe100000-0000-4000-8000-000000000002'),'own re-selection repairs stale state');
-- a plain two-library owner (adoption without any Team) is not a switcher either
select adopt_anonymous_org('fe100000-0000-4000-8000-000000000004','fe100000-0000-4000-8000-000000000005',(select guest2 from b57),'fe100000-0000-4000-8000-000000000098');
select pg_temp.ok((select count(*)=2 from memberships where user_id='fe100000-0000-4000-8000-000000000004'and role='owner'),'plain user owns two libraries after adoption');
select pg_temp.ok(not(workspace_directory('fe100000-0000-4000-8000-000000000004',null)->>'can_switch_agent_libraries')::boolean,'two owned libraries never confer switching');
select pg_temp.ok((workspace_directory('fe100000-0000-4000-8000-000000000004',null)->>'active_org_id')::uuid=(select guest2 from b57),'adopted library is the plain active library');
select pg_temp.refuse(format('select select_workspace(%L,%L)','fe100000-0000-4000-8000-000000000004',(select plain from b57)),'RP403: Only the Team owner','plain user cannot select the other owned library');
select pg_temp.refuse(format('select workspace_directory(%L,%L)','fe100000-0000-4000-8000-000000000004',(select plain from b57)),'RP403: Only the Team owner','plain explicit other-library preference refuses');
-- Team owner switching: only into a live accepted binding
select pg_temp.ok((workspace_directory('fe100000-0000-4000-8000-000000000001',null)->>'can_switch_agent_libraries')::boolean,'Team owner is a switcher');
select pg_temp.ok((select_workspace('fe100000-0000-4000-8000-000000000001',(select child from b57))->>'active_org_id')::uuid=(select child from b57),'Team owner selects the bound agent library');
select pg_temp.refuse($q$select select_workspace('fe100000-0000-4000-8000-000000000001','fe100000-0000-4000-8000-000000000090')$q$,'RP403:','Team owner cannot select the agent unbound legacy library');
select pg_temp.refuse(format('select select_workspace(%L,%L)','fe100000-0000-4000-8000-000000000001',(select plain from b57)),'RP403:','Team owner cannot select a foreign library');
-- (b) adoption after a live Team binding keeps the bound library active; the
-- legacy three-argument overload resolves through the same current function
select adopt_anonymous_org('fe100000-0000-4000-8000-000000000002','fe100000-0000-4000-8000-000000000003',(select guest from b57),'fe100000-0000-4000-8000-000000000099');
select pg_temp.ok((select active_org_id=(select child from b57)from user_workspace_state where user_id='fe100000-0000-4000-8000-000000000002'),'adoption after a live binding keeps the bound library active');
select pg_temp.ok((workspace_directory('fe100000-0000-4000-8000-000000000002',null)->>'billing_org_id')::uuid=(select team from b57),'adoption keeps Team billing identity');
select pg_temp.ok((adopt_anonymous_org('fe100000-0000-4000-8000-000000000002','fe100000-0000-4000-8000-000000000006',(select guest3 from b57))->>'adopted')::boolean,'legacy overload adopts a second guest');
select pg_temp.ok((select active_org_id=(select child from b57)from user_workspace_state where user_id='fe100000-0000-4000-8000-000000000002'),'legacy overload keeps the bound library active');
select pg_temp.ok(exists(select 1 from memberships where user_id='fe100000-0000-4000-8000-000000000002'and org_id=(select guest3 from b57)and role='owner'),'legacy overload transfers ownership without moving content');
select pg_temp.ok(adopt_anonymous_org('fe100000-0000-4000-8000-000000000002','fe100000-0000-4000-8000-000000000006',(select guest3 from b57))=adopt_anonymous_org('fe100000-0000-4000-8000-000000000002','fe100000-0000-4000-8000-000000000006',(select guest3 from b57),(select operation_id from anonymous_adoption_receipts where source_user_id='fe100000-0000-4000-8000-000000000006')),'legacy and explicit replays return one receipt');
select pg_temp.refuse(format('select adopt_anonymous_org(%L,%L,%L)','fe100000-0000-4000-8000-000000000001','fe100000-0000-4000-8000-000000000006',(select guest3 from b57)),'RP403:','legacy overload refuses a different destination');
select pg_temp.refuse(format('select adopt_anonymous_org(%L,%L,%L)','fe100000-0000-4000-8000-000000000002','fe100000-0000-4000-8000-000000000006',(select child from b57)),'RP403:','legacy overload refuses a different workspace');
select pg_temp.refuse($q$select adopt_anonymous_org('fe100000-0000-4000-8000-000000000002','fe100000-0000-4000-8000-000000000003','fe100000-0000-4000-8000-000000000090')$q$,'RP403:','legacy overload cannot rebind a settled source');
reset role;
-- (f) the legacy overload is service-only, definer with an empty search path, and delegates
select pg_temp.ok(has_function_privilege('service_role','public.adopt_anonymous_org(uuid,uuid,uuid)','execute')and not has_function_privilege('anon','public.adopt_anonymous_org(uuid,uuid,uuid)','execute')and not has_function_privilege('authenticated','public.adopt_anonymous_org(uuid,uuid,uuid)','execute')and not has_function_privilege('public','public.adopt_anonymous_org(uuid,uuid,uuid)','execute'),'legacy adoption overload is service-only');
select pg_temp.ok((select prosecdef and proconfig=array['search_path=""']::text[] and prosrc like '%public.adopt_anonymous_org(p_user,p_anon_user,p_anon_org,operation)%' from pg_proc where oid='public.adopt_anonymous_org(uuid,uuid,uuid)'::regprocedure),'legacy overload is a pinned definer that delegates to the current resolver');
select pg_temp.ok((select count(*)=2 from pg_proc where pronamespace='public'::regnamespace and proname='adopt_anonymous_org'),'exactly the two reviewed adoption overloads exist');
select pg_temp.unprivileged($q$select adopt_anonymous_org('fe100000-0000-4000-8000-000000000002','fe100000-0000-4000-8000-000000000006','fe100000-0000-4000-8000-000000000090')$q$,'legacy overload refuses a non-service caller');
-- (d) deleted Team child: the late ordinary-video settlement books the parent liability once
set local role service_role;
select serving_cost_reserve('fe100000-0000-4000-8000-000000000007',(select sibling from b57),'b57-deleted-child','reel','fal','synthetic/reel',repeat('b',64),31.5,'synthetic');
select app_video_cost_reserve('fe100000-0000-4000-8000-000000000007',(select sibling from b57),'b57-deleted-child','reel','fal','synthetic/reel',repeat('b',64),31.5,5,6.3,'{}');
select serving_cost_finish('fe100000-0000-4000-8000-000000000007',(select sibling from b57),'b57-deleted-child','reel','succeeded');
select pg_temp.ok(serving_ceiling_spent_cents((select team from b57),null,null)=31.5,'live child hold counts once in the parent envelope');
select prepare_account_deletion('fe100000-0000-4000-8000-000000000007','fixture-uploads','fixture-renders');
reset role;
delete from auth.users where id='fe100000-0000-4000-8000-000000000007';
select pg_temp.ok(not exists(select 1 from orgs where id=(select sibling from b57)),'child org is physically purged');
select pg_temp.ok(serving_ceiling_spent_cents((select team from b57),null,null)=31.5,'surviving hold keeps the parent liability');
set local role service_role;
select pg_temp.refuse(format('select app_video_cost_settle(%L,%L,%L,%L)','fe100000-0000-4000-8000-000000000001',(select sibling from b57),'b57-deleted-child','late-receipt'),'RP409:','another actor cannot settle the purged child reservation');
select app_video_cost_settle('fe100000-0000-4000-8000-000000000007',(select sibling from b57),'b57-deleted-child','late-receipt');
select pg_temp.ok((select ledger_id is not null and state='succeeded'from serving_cost_reservations where request_key='b57-deleted-child'),'exact late receipt settles the surviving hold');
select pg_temp.ok(serving_ceiling_spent_cents((select team from b57),null,null)=31.5,'late settlement books the parent liability exactly once');
select pg_temp.ok((select count(*)=1 from cost_ledger where billing_org_id=(select team from b57)and org_id is null and total_cents=31.5),'one org-less ledger row carries the immutable Team identity');
select pg_temp.refuse(format('select app_video_cost_settle(%L,%L,%L,%L)','fe100000-0000-4000-8000-000000000007',(select sibling from b57),'b57-deleted-child','different-receipt'),'RP409: Provider receipt is immutable','a different provider receipt cannot rewrite the settled reservation');
select pg_temp.ok((app_video_cost_settle('fe100000-0000-4000-8000-000000000007',(select sibling from b57),'b57-deleted-child','late-receipt')->>'ledger_id')::uuid=(select ledger_id from serving_cost_reservations where request_key='b57-deleted-child'),'settlement replay returns the single ledger row');
select pg_temp.ok(serving_ceiling_spent_cents((select team from b57),null,null)=31.5,'settlement replay changes nothing');
reset role;
-- a forged org-less receipt naming a live library reservation cannot settle anything
set local role service_role;
select serving_cost_reserve('fe100000-0000-4000-8000-000000000002',(select child from b57),'b57-live-child','reel','fal','synthetic/reel',repeat('c',64),12.25,'synthetic');
select app_video_cost_reserve('fe100000-0000-4000-8000-000000000002',(select child from b57),'b57-live-child','reel','fal','synthetic/reel',repeat('c',64),12.25,5,2.45,'{}');
select serving_cost_finish('fe100000-0000-4000-8000-000000000002',(select child from b57),'b57-live-child','reel','succeeded');
reset role;
do $$declare v public.app_video_cost_reservations;safe boolean:=false;begin
 select *into v from public.app_video_cost_reservations where idempotency_key='b57-live-child';
 begin
  insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta,idempotency_key)values(null,v.feature,v.provider,v.model,v.units,v.unit_cost_cents,v.total_cents,
   jsonb_build_object('app_video_reservation_id',v.id,'request_key',v.idempotency_key,'stage',v.feature),'app-video:'||v.id::text);
  if exists(select 1 from serving_cost_reservations where request_key='b57-live-child'and ledger_id is not null)then raise exception 'BUILD57 FAIL: org-less receipt settled a live library hold';end if;
  raise exception 'fixture_receipt_rollback';
 exception when raise_exception then if sqlerrm='fixture_receipt_rollback'or sqlerrm like 'RP403:%'then safe:=true;else raise;end if;end;
 perform pg_temp.ok(safe and not exists(select 1 from serving_cost_reservations where request_key='b57-live-child'and ledger_id is not null),'org-less receipt cannot settle a live library hold');
end$$;
select pg_temp.ok(serving_ceiling_spent_cents((select team from b57),null,null)=31.5+12.25,'live and settled liabilities each count once');
-- (e) token takeover: displaced sessions are fenced, exact current bindings stay usable
insert into auth.users(id,email,is_anonymous)values('fe200000-0000-4000-8000-000000000001','b57-phone-a@fixture.invalid',false),('fe200000-0000-4000-8000-000000000002','b57-phone-b@fixture.invalid',false);
insert into auth.sessions(id,user_id,created_at)values('fe210000-0000-4000-8000-000000000001','fe200000-0000-4000-8000-000000000001',clock_timestamp()-interval '2 days'),('fe210000-0000-4000-8000-000000000002','fe200000-0000-4000-8000-000000000002',clock_timestamp()-interval '1 day');
set local role service_role;
select notification_register_device_session('fe200000-0000-4000-8000-000000000001','fe210000-0000-4000-8000-000000000001',repeat('d1',32),null,'sandbox');
select notification_register_device_session('fe200000-0000-4000-8000-000000000002','fe210000-0000-4000-8000-000000000002',upper(repeat('d1',32)),null,'production');
select pg_temp.ok((select count(*)=1 from notification_devices where lower(device_token)=repeat('d1',32)),'one canonical row survives a mixed-case takeover');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('d1',32)and user_id='fe200000-0000-4000-8000-000000000002'and environment='production'and registration_session_id='fe210000-0000-4000-8000-000000000002'),'replacement registration owns the lower-cased token');
reset role;
select pg_temp.ok(exists(select 1 from notification_device_session_tombstones where user_id='fe200000-0000-4000-8000-000000000001'and session_id='fe210000-0000-4000-8000-000000000001'),'displaced session is tombstoned by the replacement');
set local role service_role;
select pg_temp.refuse($q$select notification_register_device_session('fe200000-0000-4000-8000-000000000001','fe210000-0000-4000-8000-000000000001',repeat('d1',32),null,'sandbox')$q$,'RP409: This device session has signed out','late old-session POST is refused');
select pg_temp.refuse($q$select notification_register_device_session('fe200000-0000-4000-8000-000000000001','fe210000-0000-4000-8000-000000000001',upper(repeat('d1',32)),null,'production')$q$,'RP409: This device session has signed out','late old-session POST is refused in the other environment and spelling');
select pg_temp.ok(not(notification_unregister_device('fe200000-0000-4000-8000-000000000001','fe210000-0000-4000-8000-000000000001',repeat('d1',32),'production')->>'removed')::boolean,'old-session DELETE cannot remove the new registration');
select pg_temp.ok(not(notification_unregister_device('fe200000-0000-4000-8000-000000000001','fe210000-0000-4000-8000-000000000001',repeat('d1',32),'sandbox')->>'removed')::boolean,'old-session DELETE in its own environment cannot remove the new registration');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('d1',32)and user_id='fe200000-0000-4000-8000-000000000002'),'new registration survives both late DELETEs');
select notification_register_device_session('fe200000-0000-4000-8000-000000000002','fe210000-0000-4000-8000-000000000002',repeat('d1',32),null,'production');
select pg_temp.ok((select registration_session_id='fe210000-0000-4000-8000-000000000002'and disabled_at is null from notification_devices where device_token=repeat('d1',32)),'exact already-current binding stays usable');
-- legacy rows without a session: a delayed old-account registration cannot reclaim in either environment
select notification_register_device('fe200000-0000-4000-8000-000000000001',repeat('d2',32),null,'production',null,null);
select pg_temp.ok((select registration_session_id is null from notification_devices where device_token=repeat('d2',32)),'legacy row carries no session');
select notification_register_device_session('fe200000-0000-4000-8000-000000000002','fe210000-0000-4000-8000-000000000002',repeat('d2',32),null,'sandbox');
reset role;
select pg_temp.ok(exists(select 1 from notification_legacy_device_retirements where user_id='fe200000-0000-4000-8000-000000000001'and environment='production'),'legacy owner retirement is recorded in the row environment');
set local role service_role;
select pg_temp.refuse($q$select notification_register_device_session('fe200000-0000-4000-8000-000000000001','fe210000-0000-4000-8000-000000000001',repeat('d2',32),null,'production')$q$,'RP409: This device session has signed out','delayed legacy owner cannot reclaim in the original environment');
select pg_temp.refuse($q$select notification_register_device_session('fe200000-0000-4000-8000-000000000001','fe210000-0000-4000-8000-000000000001',repeat('d2',32),null,'sandbox')$q$,'RP409: This device session has signed out','delayed legacy owner cannot reclaim in the other environment');
select pg_temp.refuse($q$select notification_register_device_session('fe200000-0000-4000-8000-000000000001','fe210000-0000-4000-8000-000000000009',repeat('d2',32),null,'production')$q$,'RP409: This device session has signed out','an unknown session is no evidence of a new sign-in');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('d2',32)and user_id='fe200000-0000-4000-8000-000000000002'),'new account keeps the formerly legacy token');
reset role;
insert into auth.sessions(id,user_id,created_at)values('fe210000-0000-4000-8000-000000000003','fe200000-0000-4000-8000-000000000001',clock_timestamp());
set local role service_role;
select notification_register_device_session('fe200000-0000-4000-8000-000000000001','fe210000-0000-4000-8000-000000000003',repeat('d2',32),null,'production');
select pg_temp.ok(exists(select 1 from notification_devices where device_token=repeat('d2',32)and user_id='fe200000-0000-4000-8000-000000000001'and registration_session_id='fe210000-0000-4000-8000-000000000003'),'a verified newer sign-in recovers the phone');
select pg_temp.refuse($q$select notification_register_device_session('fe200000-0000-4000-8000-000000000002','fe210000-0000-4000-8000-000000000002',repeat('d2',32),null,'sandbox')$q$,'RP409: This device session has signed out','the displaced account session is fenced in turn');
reset role;
-- (c) lock order: library selection takes the Team parent and the selected library sorted by id, after the profile, as account deletion does
select pg_temp.ok((select prosrc like '%from public.profiles where id=p_user for update;%from public.orgs where id in(p_org,public.library_team_org(p_org))and deleted_at is null order by id for update;%' and prosecdef and proconfig=array['search_path=""']::text[] from pg_proc where oid='public.select_workspace(uuid,uuid)'::regprocedure),'select_workspace locks libraries in deletion order after the profile');
select pg_temp.ok(not has_function_privilege('anon','public.select_workspace(uuid,uuid)','execute')and not has_function_privilege('authenticated','public.select_workspace(uuid,uuid)','execute')and has_function_privilege('service_role','public.select_workspace(uuid,uuid)','execute'),'select_workspace stays service-only');
select pg_temp.ok(not has_function_privilege('anon','public.notification_register_device_session(uuid,uuid,text,text,text,text,text)','execute')and not has_function_privilege('authenticated','public.notification_unregister_device(uuid,uuid,text,text)','execute')and not has_function_privilege('authenticated','public.notification_register_device(uuid,text,text,text,text,text)','execute'),'device registration stays service-only');
select jsonb_build_object('suite','build57_db_controls','assertions',n)from b57_checks;
rollback;
