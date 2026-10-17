\set ON_ERROR_STOP on
begin;
create temporary table reaudit_checks(n integer not null default 0);insert into reaudit_checks default values;grant select,update on reaudit_checks to service_role;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'REAUDIT FAIL: %',label;end if;update reaudit_checks set n=n+1;end$$;
create function pg_temp.refuse(command text,prefix text,label text)returns void language plpgsql as $$begin begin execute command;exception when raise_exception then if sqlerrm like prefix||'%'then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception 'REAUDIT FAIL: allowed %',label;end$$;

insert into auth.users(id,email,is_anonymous)values('fa300000-0000-4000-8000-000000000001','settle-parent@fixture.invalid',false),('fa300000-0000-4000-8000-000000000002','settle-child@fixture.invalid',false);
create temp table reaudit_fixture as select(select org_id from memberships where user_id='fa300000-0000-4000-8000-000000000001')team,(select org_id from memberships where user_id='fa300000-0000-4000-8000-000000000002')child;
grant select on reaudit_fixture to service_role;
update orgs set plan='team',plan_source='manual'where id=(select team from reaudit_fixture);
set local role service_role;
select create_org_invite('fa300000-0000-4000-8000-000000000001',(select team from reaudit_fixture),null,'agent',repeat('93',32));
select accept_org_invite('fa300000-0000-4000-8000-000000000002',repeat('93',32));
select serving_cost_reserve('fa300000-0000-4000-8000-000000000002',(select child from reaudit_fixture),'deleted-team-video','reel','fal','synthetic/reel',repeat('a',64),24.3,'synthetic');
select app_video_cost_reserve('fa300000-0000-4000-8000-000000000002',(select child from reaudit_fixture),'deleted-team-video','reel','fal','synthetic/reel',repeat('a',64),24.3,5,4.86,'{}');
select serving_cost_finish('fa300000-0000-4000-8000-000000000002',(select child from reaudit_fixture),'deleted-team-video','reel','succeeded');
select pg_temp.ok(serving_ceiling_spent_cents((select team from reaudit_fixture),null,null)=24.3,'live app and serving receipts share one liability');
select prepare_account_deletion('fa300000-0000-4000-8000-000000000002','fixture-uploads','fixture-renders');
reset role;
delete from auth.users where id='fa300000-0000-4000-8000-000000000002';
select pg_temp.ok(not exists(select 1 from orgs where id=(select child from reaudit_fixture)),'actual child account deletion purges its content org');
select pg_temp.ok(serving_ceiling_spent_cents((select team from reaudit_fixture),null,null)=24.3,'parent liability survives actual child and Auth purge');
-- Malformed/forged service receipts cannot release a surviving hold. Each
-- synthetic receipt is rolled back independently so the real acceptance set
-- is not polluted by deliberately fabricated costs.
do $$declare v public.app_video_cost_reservations;field text;meta jsonb;safe boolean;begin
 select *into v from public.app_video_cost_reservations where idempotency_key='deleted-team-video';
 foreach field in array array['request_key','stage','provider','model','ledger_key','feature','units','unit_cost','total','reservation','actor','live_org']loop
  safe:=false;meta:=jsonb_build_object('app_video_reservation_id',v.id,'request_key',v.idempotency_key,'stage',v.feature);
  if field='request_key'then meta:=jsonb_set(meta,'{request_key}','"wrong-request"');end if;
  if field='stage'then meta:=jsonb_set(meta,'{stage}','"aerial"');end if;
  if field='reservation'then meta:=jsonb_set(meta,'{app_video_reservation_id}','"00000000-0000-4000-8000-000000000001"');end if;
  if field='actor'then meta:=meta||jsonb_build_object('actor_id','fa300000-0000-4000-8000-000000000001');end if;
  begin
   insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta,idempotency_key)values(
    case when field='live_org'then(select team from reaudit_fixture)else null end,
    case when field='feature'then'aerial'else v.feature end,
    case when field='provider'then'kie'else v.provider end,
    case when field='model'then'wrong-model'else v.model end,
    case when field='units'then v.units+1 else v.units end,
    case when field='unit_cost'then v.unit_cost_cents+1 else v.unit_cost_cents end,
    case when field='total'then v.total_cents+1 else v.total_cents end,
    meta,case when field='ledger_key'then'forged-key'else'app-video:'||v.id::text end);
   if exists(select 1 from serving_cost_reservations where request_key=v.idempotency_key and ledger_id is not null)then raise exception 'REAUDIT FAIL: forged receipt released hold: %',field;end if;
   raise exception 'fixture_receipt_rollback';
  exception when raise_exception then
   if sqlerrm='fixture_receipt_rollback'or sqlerrm like'RP403:%'then safe:=true;else raise;end if;
  end;
  perform pg_temp.ok(safe and not exists(select 1 from serving_cost_reservations where request_key=v.idempotency_key and ledger_id is not null),'forged receipt preserves exact deleted hold: '||field);
 end loop;
end$$;
set local role service_role;
select app_video_cost_settle('fa300000-0000-4000-8000-000000000002',(select child from reaudit_fixture),'deleted-team-video','actual-late-child');
select pg_temp.ok((select ledger_id is not null from serving_cost_reservations where request_key='deleted-team-video'),'exact late deleted-child receipt binds serving hold');
select pg_temp.ok(serving_ceiling_spent_cents((select team from reaudit_fixture),null,null)=24.3,'late child settlement cannot double count parent liability');
select pg_temp.ok((select c.billing_org_id=f.team and c.org_id is null and c.total_cents=24.3 from cost_ledger c cross join reaudit_fixture f where c.id=(select ledger_id from serving_cost_reservations where request_key='deleted-team-video')),'booked ledger keeps immutable Team billing identity');
select app_video_cost_settle('fa300000-0000-4000-8000-000000000002',(select child from reaudit_fixture),'deleted-team-video','actual-late-child');
select pg_temp.ok((select count(*)=1 from cost_ledger where billing_org_id=(select team from reaudit_fixture)),'late settlement replay books once');
reset role;
select pg_temp.ok(not has_function_privilege('anon','public.cost_ledger_settle_serving_hold()','execute')and not has_function_privilege('authenticated','public.cost_ledger_settle_serving_hold()','execute'),'settlement helper remains service-only');
select jsonb_build_object('suite','reaudit_deleted_team_video','assertions',n)from reaudit_checks;
rollback;
