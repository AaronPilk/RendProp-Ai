\set ON_ERROR_STOP on
begin;
-- Funded-model regression: pin funded serving mode for this transaction. The
-- live default since 2026-10-08 is ceiling mode (migration 20261008201736);
-- ceiling-mode admission is covered by launch_blockers.sql.
update public.app_config set value=value||'{"mode":"funded"}'::jsonb where key='serving_mode';
create temporary table funding_assertions(n integer not null default 0);
insert into funding_assertions default values;
grant all on funding_assertions to service_role;
create function pg_temp.fcheck(ok boolean,label text)returns void language plpgsql as $$begin
 if ok is distinct from true then raise exception 'FAIL: %',label;end if;
 update funding_assertions set n=n+1;
end$$;
create function pg_temp.frefuse(statement text,expected text)returns void language plpgsql as $$begin
 begin execute statement;exception when others then
  if position(expected in sqlerrm)>0 then perform pg_temp.fcheck(true,expected);return;end if;raise;end;
 raise exception 'Expected refusal: %',expected;
end$$;
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values('a1000000-0000-4000-8000-000000000001','funding-owner@example.invalid',false,now()),('a1000000-0000-4000-8000-000000000002','funding-outsider@example.invalid',false,now());
-- Local synthetic fixture only; source migration remains disabled/unfunded.
update subscription_trial_config set enabled=true;
insert into orgs(id,name,plan,plan_source)values
 ('a2000000-0000-4000-8000-000000000001','Synthetic retail','pro','manual'),
 ('a2000000-0000-4000-8000-000000000002','Synthetic annual','starter','manual'),
 ('a2000000-0000-4000-8000-000000000003','Synthetic review','free','manual'),
 ('a2000000-0000-4000-8000-000000000004','Synthetic QA','team','manual'),
 ('a2000000-0000-4000-8000-000000000005','Synthetic Apple','free','manual'),
 ('a2000000-0000-4000-8000-000000000006','Synthetic trial','free','manual'),
 ('a2000000-0000-4000-8000-000000000007','Synthetic trial pool competitor','free','manual');
insert into memberships(user_id,org_id,role)select 'a1000000-0000-4000-8000-000000000001',id,'owner'from orgs where name like 'Synthetic%'and id::text like 'a2000000%';
update profiles set is_admin=true where id='a1000000-0000-4000-8000-000000000001';
insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)values('a2000000-0000-4000-8000-000000000004','a1000000-0000-4000-8000-000000000001',true);
set local role service_role;
do $$declare
 u uuid:='a1000000-0000-4000-8000-000000000001';o uuid:='a2000000-0000-4000-8000-000000000001';
 annual uuid:='a2000000-0000-4000-8000-000000000002';review uuid:='a2000000-0000-4000-8000-000000000003';qa uuid:='a2000000-0000-4000-8000-000000000004';
 t timestamptz:=now()-interval '1 minute';e timestamptz;components jsonb:='{"storage":5,"delivery":5,"compute":5,"email":5,"support":5,"retention":5,"uncertainty":0}';
 zeros jsonb:='{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}';r jsonb;funding uuid;sig text;role_name text;
begin
 e:=t+interval '1 month';
 foreach role_name in array array['anon','authenticated']loop
  foreach sig in array array['public.provision_serving_funding(uuid,text,text,uuid,bigint,bigint,timestamptz,timestamptz,integer,jsonb,text)','public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text)','public.serving_cost_finish(uuid,uuid,text,text,text,integer)','public.fund_verified_apple_transaction(uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)']loop
   perform pg_temp.fcheck(not has_function_privilege(role_name,sig,'execute'),'service-only money authority');end loop;
  perform pg_temp.fcheck(not has_table_privilege(role_name,'public.serving_cost_reservations','SELECT,INSERT,UPDATE,DELETE'),'private immutable journal');
 end loop;
 perform pg_temp.fcheck(not has_table_privilege('service_role','public.serving_cost_reservations','INSERT,UPDATE,DELETE'),'service cannot rewrite liability');
 perform pg_temp.frefuse(format('select serving_cost_reserve(%L,%L,''no-money-key'',''photo'',''gemini'',''synthetic'',%L,1,''synthetic'')',u,o,repeat('a',64)),'RP402');
 perform pg_temp.frefuse(format('select serving_cost_reserve(%L,%L,''wrong-actor-key'',''photo'',''gemini'',''synthetic'',%L,1,''synthetic'')','a1000000-0000-4000-8000-000000000002',o,repeat('a',64)),'RP403');
 r:=provision_serving_funding(o,'retail','synthetic-collection',null,400,0,t,e,1,components,repeat('a',64));funding:=(r->>'funding_id')::uuid;
 perform pg_temp.fcheck((r->>'total_budget_cents')::numeric=100 and(r->>'provider_budget_cents')::numeric=70,'inclusive quarter after proceeds minus all reserves');
 perform pg_temp.fcheck((select retention_ends_at=e+interval '90 days'from serving_funding where id=funding),'new paid hosting has an immutable90daypostexpiry cutoff');
 r:=provision_serving_funding(o,'retail','synthetic-collection',null,400,0,t,e,1,components,repeat('a',64));
 perform pg_temp.fcheck((r->>'replay')::boolean,'exact replay never replenishes');
 perform pg_temp.frefuse(format('select provision_serving_funding(%L,''retail'',''synthetic-collection'',null,404,0,%L,%L,1,%L,%L)',o,t,e,components,repeat('a',64)),'RP409');
 perform pg_temp.frefuse(format('select serving_cost_reserve(%L,%L,''unpriced-key'',''photo'',''gemini'',''unknown'',%L,1,''unpriced-private-sponsorship'')',u,o,repeat('a',64)),'RP403');
 r:=serving_cost_reserve(u,o,'retail-paid-key','photo.initial:0','gemini','synthetic',repeat('a',64),60,'synthetic');
 perform pg_temp.fcheck((r->>'reserved')::boolean,'reserve before dispatch');
 perform serving_cost_finish(u,o,'retail-paid-key','photo.initial:0','uncertain',null);
 perform pg_temp.frefuse(format('select serving_cost_finish(%L,%L,''retail-paid-key'',''photo.initial:0'',''rejected'',400)',u,o),'RP409');
 perform pg_temp.frefuse(format('select serving_cost_reserve(%L,%L,''second-key'',''voice'',''elevenlabs'',''synthetic'',%L,11,''synthetic'')',u,o,repeat('a',64)),'RP402');
 perform pg_temp.frefuse(format('select serving_cost_reserve(%L,%L,''retail-paid-key'',''photo.initial:0'',''gemini'',''synthetic'',%L,60,''synthetic'')',u,o,repeat('a',64)),'RP409');
 perform serving_cost_reserve(u,o,'rejection-key','copy','openai','synthetic',repeat('a',64),10,'synthetic');
 perform serving_cost_finish(u,o,'rejection-key','copy','rejected',429);
 perform pg_temp.fcheck((select sum(hold_cents)from serving_cost_reservations where funding_id=funding and state<>'rejected')=60,'only proven prequeue refusal releases provider liability');
 perform serving_cost_reserve(u,o,'final-funded-key','chapters','gemini','synthetic',repeat('a',64),10,'synthetic');
 perform serving_cost_finish(u,o,'final-funded-key','chapters','succeeded',null);
 perform revoke_serving_funding(o,'synthetic-collection',repeat('b',64));
 perform pg_temp.fcheck((select revoked_at is not null and revocation_evidence_sha256=repeat('b',64)from serving_funding where id=funding),'refund evidence retained');
 perform pg_temp.fcheck((select sum(hold_cents)from serving_cost_reservations where funding_id=funding and state<>'rejected')=70,'refund cannot erase incurred and uncertain invoices');
 perform pg_temp.frefuse(format('select serving_cost_reserve(%L,%L,''after-refund'',''photo'',''gemini'',''synthetic'',%L,1,''synthetic'')',u,o,repeat('a',64)),'RP402');
 r:=provision_serving_funding(annual,'retail','synthetic-annual',null,41650,0,t,t+interval '12 months',12,components,repeat('a',64));funding:=(r->>'funding_id')::uuid;
 perform pg_temp.fcheck((select count(*)=12 and min(slice_index)=0 and max(slice_index)=11 and sum(total_budget_cents)=10412 and sum(recurring_reserve_cents)=30 from serving_funding_slices where funding_id=funding),'one annual collection funds exactly12 anchored intervals with exact penny remainder');
 perform pg_temp.frefuse(format('select serving_cost_reserve(%L,%L,''annual-overmonth'',''photo'',''gemini'',''synthetic'',%L,10412,''synthetic'')',u,annual,repeat('a',64)),'RP402');
 r:=provision_serving_funding(review,'app_review','synthetic-review',u,0,500,t,t+interval '7 days',1,'{"storage":10,"delivery":10,"compute":10,"email":5,"support":5,"retention":10,"uncertainty":0}',repeat('a',64));
 perform pg_temp.fcheck((r->>'provider_budget_cents')::int=450,'review500cTOTAL includes reserves');
 perform pg_temp.fcheck(org_has_app_review_funding(review)and effective_plan(review)='pro'and(org_entitlement(review)).plan='pro'and(org_entitlement(review)).seats=1 and(org_entitlement(review)).topaz_per_month=1,'review plan and features visible through actual client RPCs');
 r:=record_apple_sandbox_receipt(review,u,'synthetic-review-original','synthetic-review-tx','com.rendprop.app.pro.monthly','active',now());
 perform pg_temp.fcheck(r->>'environment'='Sandbox'and r->>'plan'='pro'and(r->>'test_only')::boolean,'review Sandbox restore exposes funded test plan');
 perform pg_temp.fcheck((select plan='free'and plan_source='manual'from orgs where id=review)and not exists(select 1 from apple_subscriptions where org_id=review),'review receipt cannot mint retail entitlement');
 perform serving_cost_reserve(u,review,'review-paid-key','video','fal','synthetic',repeat('a',64),450,'synthetic');
 perform pg_temp.frefuse(format('select serving_cost_reserve(%L,%L,''review-exhausted'',''photo'',''gemini'',''synthetic'',%L,1,''synthetic'')',u,review,repeat('a',64)),'RP402');
 perform revoke_serving_funding(review,'synthetic-review',repeat('b',64));
 perform pg_temp.fcheck(not org_has_app_review_funding(review)and effective_plan(review)='free','expired or revoked review loses features');
 perform pg_temp.frefuse(format('select provision_serving_funding(%L,''app_review'',''second-review-grant'',%L,0,500,%L,%L,1,%L,%L)',review,u,t,t+interval '7 days',zeros,repeat('a',64)),'RP403');
 perform pg_temp.frefuse(format('select record_apple_sandbox_receipt(%L,%L,''other-review-original'',''other-review-tx'',''com.rendprop.app.pro.monthly'',''active'',now())',review,u),'RP403');
 r:=serving_cost_reserve(u,qa,'unlimited-qa-key','photo','gemini','unpriced-model',repeat('a',64),1000000,'unpriced-private-sponsorship');
 perform pg_temp.fcheck((r->>'sponsored_unlimited')::boolean,'existing owner QA sponsorship stays unlimited and separate');
end$$;
-- Run actual accepted Apple chronology through the new money authority. These
-- service-attested prices/reserves are synthetic test facts, not launch seeds.
do $$declare
 u uuid:='a1000000-0000-4000-8000-000000000001';o uuid:='a2000000-0000-4000-8000-000000000005';trial uuid:='a2000000-0000-4000-8000-000000000006';competitor uuid:='a2000000-0000-4000-8000-000000000007';
 t timestamptz:=now()-interval '1 minute';e timestamptz;t2 timestamptz;s timestamptz:=now()-interval '30 seconds';r jsonb;funding uuid;pool uuid;
 zeros jsonb:='{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}';
 components jsonb:='{"storage":5,"delivery":5,"compute":5,"email":5,"support":5,"retention":5,"uncertainty":0}';
begin
 perform pg_temp.fcheck((serving_operation_begin(u,o,'logical-operation-key','coach.chat',repeat('a',64))->>'begun')::boolean,'logical operation journals before chain');
 perform pg_temp.frefuse(format('select serving_operation_begin(%L,%L,''logical-operation-key'',''copy.script'',%L)',u,o,repeat('b',64)),'RP409');
 perform pg_temp.fcheck(not has_function_privilege('authenticated','public.serving_operation_begin(uuid,uuid,text,text,text)','execute')and not has_table_privilege('service_role','serving_operations','INSERT,UPDATE,DELETE'),'operation tombstone cannot be rewritten by caller');
 perform pg_temp.fcheck((serving_operation_no_dispatch(u,o,'logical-operation-key')->>'retryable')::boolean,'zero-attempt refusal is explicitly retryable');
 perform pg_temp.fcheck((serving_operation_begin(u,o,'logical-operation-key','coach.chat',repeat('a',64))->>'begun')::boolean,'funding repair permits same zero-dispatch logical request');
 perform pg_temp.frefuse(format('select serving_operation_complete(%L,%L,''logical-operation-key'',''{"reply":"invented"}'')',u,o),'RP409');
 perform serving_operation_begin(u,'a2000000-0000-4000-8000-000000000004','saved-helper-key','coach.chat',repeat('a',64));
 perform serving_cost_reserve(u,'a2000000-0000-4000-8000-000000000004','saved-helper-key','coach','synthetic','synthetic',repeat('a',64),1,'synthetic');
 perform pg_temp.fcheck(not(serving_operation_no_dispatch(u,'a2000000-0000-4000-8000-000000000004','saved-helper-key')->>'retryable')::boolean,'admitted reserved stage never authorizes operation replay');
 perform serving_cost_finish(u,'a2000000-0000-4000-8000-000000000004','saved-helper-key','coach','succeeded',null);
 perform serving_operation_complete(u,'a2000000-0000-4000-8000-000000000004','saved-helper-key','{"reply":"saved generated reply"}');
 r:=serving_operation_begin(u,'a2000000-0000-4000-8000-000000000004','saved-helper-key','coach.chat',repeat('a',64));
 perform pg_temp.fcheck((r->>'replay')::boolean and r->'result'->>'reply'='saved generated reply','lost helper response restores owned generated result without new paid stage');
 perform pg_temp.frefuse(format('select serving_operation_complete(%L,%L,''saved-helper-key'',''{"reply":"altered"}'')',u,'a2000000-0000-4000-8000-000000000004'),'RP409');
 perform pg_temp.frefuse(format('select serving_operation_begin(%L,%L,''saved-helper-key'',''coach.chat'',%L)',u,'a2000000-0000-4000-8000-000000000004',repeat('b',64)),'RP409');
 perform pg_temp.fcheck(not has_table_privilege('authenticated','serving_operation_results','SELECT,INSERT,UPDATE,DELETE')and not has_table_privilege('service_role','serving_operation_results','INSERT,UPDATE,DELETE'),'bounded generated recovery is private and immutable');
 perform pg_temp.frefuse(format('insert into apple_serving_schedules(product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,service_months,starts_at,ends_at,reserve_components,trial_reserve_components,evidence_sha256)values(''bad'',''USA'',''USD'',49000,4165,1,%L,%L,''{}'',%L,%L)',t,t+interval '1 day',zeros,repeat('a',64)),'check constraint');
 insert into serving_sponsor_pools(collection_ref,source,funded_cents,starts_at,ends_at,evidence_sha256,admissions_enabled)values('synthetic-trial-pool','trial',200,t,t+interval '14 days',repeat('c',64),true)returning id into pool;
 insert into apple_serving_schedules(product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,service_months,starts_at,ends_at,reserve_components,trial_sponsored_cents,trial_reserve_components,trial_days,trial_pool_id,evidence_sha256)
 values('com.rendprop.app.starter.monthly','USA','USD',49000,4165,1,t-interval '1 day',t+interval '20 days',components,200,components,7,pool,repeat('c',64));
 e:=t+interval '1 month';
 perform apply_apple_entitlement_v2(o,u,'synthetic-paid-original','synthetic-paid-tx','com.rendprop.app.starter.monthly','starter','Production','active',e,true,'DID_RENEW',t,s,s,s);
 r:=fund_verified_apple_transaction(o,'synthetic-paid-original','synthetic-paid-tx','com.rendprop.app.starter.monthly',null,'USD','USA',null,null,t,e,s,repeat('a',64));
 perform pg_temp.fcheck(not(r->>'funded')::boolean and r->>'reason'='unsupported_payment_facts','missing trusted amount cannot mint retail funding');
 r:=fund_verified_apple_transaction(o,'synthetic-paid-original','synthetic-paid-tx','com.rendprop.app.starter.monthly',49000,'EUR','USA',null,null,t,e,s,repeat('a',64));
 perform pg_temp.fcheck(not(r->>'funded')::boolean,'unsupported currency cannot mint retail funding');
 r:=fund_verified_apple_transaction(o,'synthetic-paid-original','synthetic-paid-tx','com.rendprop.app.starter.monthly',49000,'USD','USA',null,null,t,e,s,repeat('a',64));funding:=(r->>'funding_id')::uuid;
 perform pg_temp.fcheck((r->>'funded')::boolean and(r->>'total_budget_cents')::int=1041 and(r->>'provider_budget_cents')::int=1011,'verified USA receipt funds quarter of attested net, including reserves');
 perform serving_cost_reserve(u,o,'apple-spent-key','photo','fal','synthetic',repeat('a',64),100,'synthetic');perform serving_cost_finish(u,o,'apple-spent-key','photo','uncertain',null);
 r:=fund_verified_apple_transaction(o,'synthetic-paid-original','synthetic-paid-tx','com.rendprop.app.starter.monthly',49000,'USD','USA',null,null,t,e,s,repeat('a',64));
 perform pg_temp.fcheck((r->>'replay')::boolean and(select count(*)=1 from serving_funding where org_id=o),'receipt restore retains same original budget');
 r:=fund_verified_apple_transaction(o,'synthetic-paid-original','stale-other-tx','com.rendprop.app.starter.monthly',49000,'USD','USA',null,null,t,e,s,repeat('a',64));
 perform pg_temp.fcheck(r->>'reason'='stale_or_unbound','stale notification never replenishes');
 perform apply_apple_entitlement_v2(o,u,'synthetic-paid-original','synthetic-paid-tx','com.rendprop.app.starter.monthly','starter','Production','refunded',e,true,'REFUND',t,s,now()-interval '20 seconds',s);
 r:=fund_verified_apple_transaction(o,'synthetic-paid-original','synthetic-paid-tx','com.rendprop.app.starter.monthly',49000,'USD','USA',null,null,t,e,s,repeat('b',64));
 perform pg_temp.fcheck(r->>'reason'='revoked'and(select revoked_at is not null from serving_funding where id=funding),'accepted refund closes money admission');
 perform apply_apple_entitlement_v2(o,u,'synthetic-paid-original','synthetic-paid-tx','com.rendprop.app.starter.monthly','starter','Production','active',e,true,'REFUND_REVERSED',t,s,now()-interval '10 seconds',s);
 r:=fund_verified_apple_transaction(o,'synthetic-paid-original','synthetic-paid-tx','com.rendprop.app.starter.monthly',49000,'USD','USA',null,null,t,e,s,repeat('c',64));
 perform pg_temp.fcheck((r->>'funded')::boolean and(select revoked_at is null and reactivation_evidence_sha256=repeat('c',64)from serving_funding where id=funding)and(select sum(hold_cents)=100 from serving_cost_reservations where funding_id=funding),'refund reversal restores remaining funds without erasing uncertain invoices');
 t2:=t+interval '1 second';
 perform apply_apple_entitlement_v2(o,u,'synthetic-paid-original','synthetic-unpaid-new-tx','com.rendprop.app.starter.monthly','starter','Production','active',t2+interval '7 days',true,'SUBSCRIBED',t2,now()-interval '5 seconds',now()-interval '5 seconds',s);
 r:=fund_verified_apple_transaction(o,'synthetic-paid-original','synthetic-unpaid-new-tx','com.rendprop.app.starter.monthly',0,'USD','USA',null,null,t2,t2+interval '7 days',now()-interval '5 seconds',repeat('a',64));
 perform pg_temp.fcheck(r->>'reason'='trial_purchase_reservation_required'and(select revoked_at is null from serving_funding where id=funding),'invalid zero-price offer cannot revoke previous valid paid funds');
 perform prepare_subscription_trial_purchase(u,trial,'com.rendprop.app.starter.monthly');
 t:=now();s:=now();e:=t+interval '7 days';
 perform apply_apple_entitlement_v2(trial,u,'synthetic-trial-original','synthetic-trial-tx','com.rendprop.app.starter.monthly','starter','Production','active',e,true,'SUBSCRIBED',t,s,s,s);
 r:=fund_reserved_subscription_trial(u,trial,'synthetic-trial-original','synthetic-trial-tx','com.rendprop.app.starter.monthly',0,'USD','USA',1,'FREE_TRIAL',t,e,s,repeat('a',64));
 perform pg_temp.fcheck((r->>'funded')::boolean and(r->>'total_budget_cents')::int=200 and(r->>'provider_budget_cents')::int=170,'trial uses inclusive committed sponsor cash, not zero retail proceeds');
 r:=fund_reserved_subscription_trial(u,trial,'synthetic-trial-original','synthetic-trial-tx','com.rendprop.app.starter.monthly',0,'USD','USA',1,'FREE_TRIAL',t,e,s,repeat('a',64));
 perform pg_temp.fcheck((r->>'funded')::boolean and(r->>'replay')::boolean and(select count(*)=1 from serving_funding where sponsor_pool_id=pool),'trial restore never revokes or doubles its per-chain pool commitment');
 -- A separate eligible account competes for the fully committed pool.
 insert into memberships(user_id,org_id,role)values('a1000000-0000-4000-8000-000000000002',competitor,'owner');
 begin perform prepare_subscription_trial_purchase('a1000000-0000-4000-8000-000000000002',competitor,'com.rendprop.app.starter.monthly');raise exception 'Pool overcommitted';exception when others then if position('RP402'in sqlerrm)=0 then raise;end if;end;
 perform pg_temp.fcheck(not exists(select 1 from serving_funding where org_id=competitor),'shared launch sponsor pool cannot overspend across chains');
 perform revoke_serving_funding(trial,'apple-trial:synthetic-trial-original',repeat('b',64));
 begin perform prepare_subscription_trial_purchase('a1000000-0000-4000-8000-000000000002',competitor,'com.rendprop.app.starter.monthly');raise exception 'Revoked cash recycled';exception when others then if position('RP402'in sqlerrm)=0 then raise;end if;end;
 perform pg_temp.fcheck(not exists(select 1 from subscription_trial_purchase_reservations where org_id=competitor),'revoked trial cannot replenish spent sponsor cash');
end$$;
reset role;
delete from auth.users where id='a1000000-0000-4000-8000-000000000001';
select pg_temp.fcheck(not exists(select 1 from serving_operation_results where actor_id='a1000000-0000-4000-8000-000000000001'),'account deletion removes cached private output content');
select pg_temp.fcheck(exists(select 1 from serving_cost_reservations where actor_id='a1000000-0000-4000-8000-000000000001')and exists(select 1 from serving_operations where actor_id='a1000000-0000-4000-8000-000000000001'),'account deletion preserves incurred liability and no-dispatch tombstone authority');
select jsonb_build_object('assertions',n,'passed',true)from funding_assertions;
rollback;
