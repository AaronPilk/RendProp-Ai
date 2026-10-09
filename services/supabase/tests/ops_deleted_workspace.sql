\set ON_ERROR_STOP on
-- Missing-cost alerts must ignore intentionally retired workspaces while
-- preserving their charged provider liability. All data is synthetic/rollback.
begin;
create temporary table ops_deletion_assertions(n integer not null default 0);insert into ops_deletion_assertions default values;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin
 if v is distinct from true then raise exception 'OPS-DELETED-WORKSPACE FAIL: %',label;end if;
 update ops_deletion_assertions set n=n+1;
end$$;
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values
 ('f6100000-0000-4000-8000-000000000001','ops-live@example.invalid',false,now()),
 ('f6100000-0000-4000-8000-000000000002','ops-retired@example.invalid',false,now());
insert into orgs(id,name,plan)values
 ('f6200000-0000-4000-8000-000000000001','Synthetic live ledger gap','free'),
 ('f6200000-0000-4000-8000-000000000002','Synthetic soft-deleted ledger gap','free'),
 ('f6200000-0000-4000-8000-000000000003','Synthetic account deletion','free');
insert into memberships(user_id,org_id,role)values
 ('f6100000-0000-4000-8000-000000000001','f6200000-0000-4000-8000-000000000001','owner'),
 ('f6100000-0000-4000-8000-000000000001','f6200000-0000-4000-8000-000000000002','owner'),
 ('f6100000-0000-4000-8000-000000000002','f6200000-0000-4000-8000-000000000003','owner');
update orgs set deleted_at=now()where id='f6200000-0000-4000-8000-000000000002';
update app_config set value='{"mode":"ceiling","free_published_listings":1}'::jsonb where key='serving_mode';
insert into serving_cost_reservations(id,org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,budget_source,state,created_at,settled_at)values
 ('f6300000-0000-4000-8000-000000000001','f6200000-0000-4000-8000-000000000001','f6100000-0000-4000-8000-000000000001','live-photo-cost','photo.declutter:0','gemini','gemini-3.1-flash-image',repeat('a',64),'synthetic',8.3584,'ceiling','succeeded',now()-interval '2 hours',now()-interval '2 hours'),
 ('f6300000-0000-4000-8000-000000000002','f6200000-0000-4000-8000-000000000002','f6100000-0000-4000-8000-000000000001','soft-deleted-photo','photo.declutter:0','gemini','gemini-3.1-flash-image',repeat('b',64),'synthetic',8.3584,'ceiling','succeeded',now()-interval '2 hours',now()-interval '2 hours'),
 ('f6300000-0000-4000-8000-000000000003','f6200000-0000-4000-8000-000000000003','f6100000-0000-4000-8000-000000000002','delete-settled-photo','photo.declutter:0','gemini','gemini-3.1-flash-image',repeat('c',64),'synthetic',8.3584,'ceiling','succeeded',now()-interval '2 hours',now()-interval '2 hours'),
 ('f6300000-0000-4000-8000-000000000004','f6200000-0000-4000-8000-000000000001','f6100000-0000-4000-8000-000000000001','young-photo-cost','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('d',64),'synthetic',8.3584,'ceiling','succeeded',now()-interval '5 minutes',now()-interval '5 minutes'),
 ('f6300000-0000-4000-8000-000000000005','f6200000-0000-4000-8000-000000000001','f6100000-0000-4000-8000-000000000001','unknown-photo-cost','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('e',64),'synthetic',8.3584,'ceiling','uncertain',now()-interval '2 hours',now()-interval '2 hours');
insert into cost_ledger(id,org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values
 ('f6400000-0000-4000-8000-000000000001','f6200000-0000-4000-8000-000000000003','photo_edit','gemini','gemini-3.1-flash-image',1,6.7,6.7,'{"request_key":"delete-settled-photo","stage":"photo.declutter:0"}');
select pg_temp.ok((select ledger_id='f6400000-0000-4000-8000-000000000001'from serving_cost_reservations where id='f6300000-0000-4000-8000-000000000003'),'a successful edit binds before account deletion');
select pg_temp.ok((select(data->>'holds')::integer=1 from ops_health_findings()where code='holds_unledgered'),'active old unlinked hold alerts; soft-deleted, young, uncertain and settled do not');
-- Invoke the real account-deletion preparation that deleted the launch QA
-- ledger; do not approximate the lifecycle with an unrelated manual DELETE.
set local role service_role;
select prepare_account_deletion('f6100000-0000-4000-8000-000000000002','synthetic-uploads','synthetic-renders');
reset role;
select pg_temp.ok(not exists(select 1 from orgs where id='f6200000-0000-4000-8000-000000000003'),'real solo account-deletion path retires its workspace');
select pg_temp.ok(not exists(select 1 from cost_ledger where id='f6400000-0000-4000-8000-000000000001'),'real deletion removes the fixture ledger as designed');
select pg_temp.ok((select state='succeeded'and ledger_id is null and hold_cents=8.3584 from serving_cost_reservations where id='f6300000-0000-4000-8000-000000000003'),'deletion retains charged liability and clears only the deleted ledger reference');
select pg_temp.ok((select(data->>'holds')::integer=1 from ops_health_findings()where code='holds_unledgered'),'hard-deleted orphan does not add an alert while active gap still does');
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values
 ('f6200000-0000-4000-8000-000000000001','photo_edit','gemini','gemini-3.1-flash-image',1,6.7,6.7,'{"request_key":"live-photo-cost","stage":"photo.declutter:0"}');
select pg_temp.ok(not exists(select 1 from ops_health_findings()where code='holds_unledgered'),'exact active receipt clears the warning without forgiving deleted liabilities');
select pg_temp.ok((select state='succeeded'and hold_cents=8.3584 from serving_cost_reservations where id='f6300000-0000-4000-8000-000000000002'),'soft-deleted liability also remains unchanged');
-- Counterfactual: the pre-fix criterion reports both retired liabilities.
do $$declare current_definition text;old_definition text;begin
 current_definition:=pg_get_functiondef('public.ops_health_findings()'::regprocedure);
 old_definition:=replace(current_definition,
  $new$select count(*) into n from public.serving_cost_reservations hold_row join public.orgs live_org on live_org.id=hold_row.org_id and live_org.deleted_at is null where hold_row.budget_source='ceiling' and hold_row.state='succeeded' and hold_row.ledger_id is null and hold_row.settled_at<now()-interval '1 hour';$new$,
  $old$select count(*) into n from public.serving_cost_reservations where budget_source='ceiling' and state='succeeded' and ledger_id is null and settled_at<now()-interval '1 hour';$old$);
 perform pg_temp.ok(old_definition<>current_definition,'negative control reinstates the exact prior criterion');
 execute old_definition;
 perform pg_temp.ok((select(data->>'holds')::integer=2 from public.ops_health_findings()where code='holds_unledgered'),'prior criterion reproduces the false warning for both retired workspaces');
 execute current_definition;
end$$;
select pg_temp.ok(not has_function_privilege('anon','public.ops_health_findings()','execute')and not has_function_privilege('authenticated','public.ops_health_findings()','execute'),'admin finding privileges unchanged');
select jsonb_build_object('suite','ops_deleted_workspace','assertions',n,'real_account_delete_used',true,'provider_liabilities_preserved',true,'prior_criterion_negative_control',true)from ops_deletion_assertions;
rollback;
