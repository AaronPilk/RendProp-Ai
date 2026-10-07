\set ON_ERROR_STOP on
begin;
create temporary table guest_checks(n int);insert into guest_checks values(0);grant all on guest_checks to service_role;
create function pg_temp.ok(value boolean,label text)returns void language plpgsql as $$begin if value is distinct from true then raise exception 'FAIL: %',label;end if;update guest_checks set n=n+1;end$$;
create temporary table guest_fixture(u uuid,o uuid,t timestamptz,e timestamptz,s timestamptz);
insert into guest_fixture values('de100001-0000-4000-8000-000000000001','de200001-0000-4000-8000-000000000001',now()-interval '1 minute',now()-interval '1 minute'+interval '1 month',now()-interval '30 seconds');grant all on guest_fixture to service_role;
insert into auth.users(id,email,is_anonymous)values('de100001-0000-4000-8000-000000000001',null,true),('de100001-0000-4000-8000-000000000002','retail-named@example.invalid',false),('de100001-0000-4000-8000-000000000003',null,true);
insert into orgs(id,name,plan,plan_source)values('de200001-0000-4000-8000-000000000001','Synthetic exact retail guest','free','apple');
insert into memberships(user_id,org_id,role)select u,o,'owner'from guest_fixture;
insert into apple_serving_schedules(product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,service_months,starts_at,ends_at,reserve_components,trial_reserve_components,evidence_sha256)
 values('com.rendprop.app.pro.monthly','USA','USD',49000,4165,1,now()-interval '1 day',now()+interval '1 day','{"storage":1,"delivery":1,"compute":1,"email":1,"support":1,"retention":1,"uncertainty":1}','{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}',repeat('a',64));
set local role service_role;
do $$declare f record;r jsonb;begin select * into f from guest_fixture;
 perform pg_temp.ok(not org_has_verified_retail_guest(f.u,f.o),'unpaid anonymous guest denied');
 perform apply_apple_entitlement_v2(f.o,f.u,'synthetic-guest-original','synthetic-guest-tx','com.rendprop.app.pro.monthly','pro','Production','active',f.e,true,'SUBSCRIBED',f.t,f.s,f.s,f.s);
 perform pg_temp.ok(not org_has_verified_retail_guest(f.u,f.o),'signed but unfunded guest denied');
 r:=fund_verified_retail_apple_transaction(f.u,f.o,'synthetic-guest-original','synthetic-guest-tx','com.rendprop.app.pro.monthly',49000,'USD','USA',null,null,f.t,f.e,f.s,repeat('a',64));
 perform pg_temp.ok((r->>'funded')::boolean,'verified retail funds through atomic buyer binding');
 perform pg_temp.ok((select app_account_token=f.u from apple_subscriptions where original_transaction_id='synthetic-guest-original'),'verified buyer token persisted atomically');
 perform pg_temp.ok(org_has_verified_retail_guest(f.u,f.o),'exact Production paid guest admitted');
 perform pg_temp.ok(subscription_serving_activation(f.u,f.o)->>'authority'='verified_retail','exact guest activation presentation agrees');
 r:=fund_verified_retail_apple_transaction(f.u,f.o,'synthetic-guest-original','synthetic-guest-tx','com.rendprop.app.pro.monthly',49000,'USD','USA',null,null,f.t,f.e,f.s,repeat('a',64));
 perform pg_temp.ok((r->>'replay')::boolean and(select count(*)=1 from serving_funding where org_id=f.o),'restore funds once');
 perform serving_operation_begin(f.u,f.o,'guest-operation','coach.chat',repeat('b',64));
 perform serving_cost_reserve(f.u,f.o,'guest-operation','coach:0','openai','synthetic',repeat('b',64),1,'synthetic');
 perform serving_cost_finish(f.u,f.o,'guest-operation','coach:0','succeeded',null);
 r:=serving_operation_complete(f.u,f.o,'guest-operation','{"reply":"synthetic saved reply"}'::jsonb);
 perform pg_temp.ok((r->>'saved')::boolean,'guest actual begin/reserve/complete succeeds');
 perform pg_temp.ok((select count(*)=1 from serving_operation_results where actor_id=f.u),'guest owned result retained');
 perform pg_temp.ok(not org_has_verified_retail_guest('de100001-0000-4000-8000-000000000003',f.o),'other guest cannot borrow retail funding');
 perform pg_temp.ok(not has_function_privilege('authenticated','org_has_verified_retail_guest(uuid,uuid)','execute'),'guest reader service-only');
 perform pg_temp.ok(not has_function_privilege('authenticated','fund_verified_retail_apple_transaction(uuid,uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)','execute'),'buyer funding service-only');
end$$;
-- Mutate only ephemeral fixture authority as postgres, inside rolled-back
-- subtransactions. All three actual operation paths must reject before writes.
reset role;
create function pg_temp.reject(mutation text,label text)returns void language plpgsql security definer set search_path='' as $$declare f record;command text;seen boolean;before_ops bigint;before_cost bigint;begin
 select * into f from pg_temp.guest_fixture;
 select count(*)into before_ops from public.serving_operations;select count(*)into before_cost from public.serving_cost_reservations;
 begin
  execute mutation;
  if public.org_has_verified_retail_guest(f.u,f.o)then raise exception 'FAIL: %',label;end if;
  if exists(select 1 from public.memberships where org_id=f.o and user_id=f.u) and exists(select 1 from public.orgs where id=f.o and deleted_at is null) and public.subscription_serving_activation(f.u,f.o)->>'available'<>'false' then raise exception 'FAIL: % advertised guest allowance',label;end if;
  foreach command in array array[
   format('select public.serving_operation_begin(%L,%L,''denied-operation'',''coach.chat'',%L)',f.u,f.o,repeat('b',64)),
   format('select public.serving_cost_reserve(%L,%L,''denied-reserve'',''coach:0'',''openai'',''synthetic'',%L,1,''synthetic'')',f.u,f.o,repeat('b',64)),
   format('select public.serving_operation_complete(%L,%L,''guest-operation'',''{"reply":"poison"}''::jsonb)',f.u,f.o)
  ]loop
   seen:=false;begin execute command;exception when others then if position('RP403' in sqlerrm)>0 or position('RP409' in sqlerrm)>0 then seen:=true;else raise;end if;end;
   if not seen then raise exception 'FAIL: % admitted an operation',label;end if;
  end loop;
  if(select count(*)from public.serving_operations)<>before_ops or(select count(*)from public.serving_cost_reservations)<>before_cost then raise exception 'FAIL: % wrote before refusal',label;end if;
  raise no_data_found;
 exception when no_data_found then null;end;
 perform pg_temp.ok(true,label);
end$$;
set local role service_role;
select pg_temp.reject(mutation,label)from(values
 ('update public.apple_subscriptions set environment=''Sandbox'' where original_transaction_id=''synthetic-guest-original'';update public.apple_subscriptions set transaction_purchased_at=(select t from pg_temp.guest_fixture),transaction_signed_at=(select s from pg_temp.guest_fixture)where original_transaction_id=''synthetic-guest-original''','Sandbox is not retail guest authority'),
 ('update public.apple_subscriptions set app_account_token=null where original_transaction_id=''synthetic-guest-original''','missing buyer token denied'),
 ('update public.apple_subscriptions set app_account_token=''de100001-0000-4000-8000-000000000003'' where original_transaction_id=''synthetic-guest-original''','foreign buyer token denied'),
 ('update public.apple_subscriptions set status=''grace'' where original_transaction_id=''synthetic-guest-original''','unfunded grace extension denied'),
 ('update public.apple_subscriptions set user_id=''de100001-0000-4000-8000-000000000003'' where original_transaction_id=''synthetic-guest-original''','foreign subscription actor denied'),
 ('update public.apple_subscriptions set last_transaction_id=''other-current-tx'' where original_transaction_id=''synthetic-guest-original''','stale funding chain transaction denied'),
 ('update public.orgs set plan_source=''manual'' where id=(select o from pg_temp.guest_fixture)','anonymous private/manual grant cannot bypass'),
 ('update public.orgs set deleted_at=now() where id=(select o from pg_temp.guest_fixture)','deleted workspace denied'),
 ('delete from public.memberships where user_id=(select u from pg_temp.guest_fixture)','removed membership denied'),
 ('update public.serving_funding set revoked_at=now() where org_id=(select o from pg_temp.guest_fixture)','refunded funding denied'),
 ('update public.serving_funding set apple_original_transaction_id=''other-chain'' where org_id=(select o from pg_temp.guest_fixture)','foreign funding chain denied'),
 ('update public.serving_funding_slices set ends_at=now()-interval ''1 second'' where org_id=(select o from pg_temp.guest_fixture)','expired funding slice denied'),
 ('insert into public.deletion_requests(user_id,status)select u,''pending''from pg_temp.guest_fixture','deleting buyer denied')
 )v(mutation,label);
reset role;
-- A migrated named buyer may present the old guest token only through the
-- exact durable adoption receipt. No anonymous destination alias is admitted.
update apple_subscriptions set user_id='de100001-0000-4000-8000-000000000002'where original_transaction_id='synthetic-guest-original';
insert into memberships(user_id,org_id,role)select 'de100001-0000-4000-8000-000000000002',o,'owner'from guest_fixture;
set local role service_role;
do $$declare f record;r jsonb;begin select * into f from guest_fixture;
 r:=fund_verified_retail_apple_transaction(f.u,f.o,'synthetic-guest-original','synthetic-guest-tx','com.rendprop.app.pro.monthly',49000,'USD','USA',null,null,f.t,f.e,f.s,repeat('a',64));
 perform pg_temp.ok(r->>'reason'='stale_or_unbound_buyer','cross-account membership alone cannot claim signed buyer');end$$;
reset role;
insert into anonymous_adoption_receipts(operation_id,source_user_id,destination_user_id,org_id,receipt)
 select 'de300001-0000-4000-8000-000000000001',u,'de100001-0000-4000-8000-000000000002',o,
 jsonb_build_object('ok',true,'adopted',true,'operation_id','de300001-0000-4000-8000-000000000001','source_user_id',u,'destination_user_id','de100001-0000-4000-8000-000000000002','org_id',o)from guest_fixture;
set local role service_role;
do $$declare f record;r jsonb;begin select * into f from guest_fixture;
 r:=fund_verified_retail_apple_transaction(f.u,f.o,'synthetic-guest-original','synthetic-guest-tx','com.rendprop.app.pro.monthly',49000,'USD','USA',null,null,f.t,f.e,f.s,repeat('a',64));
 perform pg_temp.ok((r->>'replay')::boolean,'exact adopted named buyer restore preserved');
 perform pg_temp.ok(not org_has_verified_retail_guest(f.u,f.o),'old guest cannot spend adopted chain');end$$;
reset role;
update anonymous_adoption_receipts set receipt=receipt||'{"org_id":"de200001-0000-4000-8000-000000000002"}'::jsonb;
set local role service_role;
do $$declare f record;r jsonb;begin select * into f from guest_fixture;
 r:=fund_verified_retail_apple_transaction(f.u,f.o,'synthetic-guest-original','synthetic-guest-tx','com.rendprop.app.pro.monthly',49000,'USD','USA',null,null,f.t,f.e,f.s,repeat('a',64));
 perform pg_temp.ok(r->>'reason'='stale_or_unbound_buyer','forged adoption receipt cannot fund');end$$;
reset role;
-- Accepted refund revocation remains possible after buyer removal.
set local role service_role;
select apply_apple_entitlement_v2(o,'de100001-0000-4000-8000-000000000002','synthetic-guest-original','synthetic-guest-tx','com.rendprop.app.pro.monthly','pro','Production','refunded',e,false,'REFUND',t,s+interval '10 seconds',s+interval '10 seconds',s+interval '10 seconds')from guest_fixture;
do $$declare f record;r jsonb;begin select * into f from guest_fixture;
 r:=fund_verified_retail_apple_transaction(f.u,f.o,'synthetic-guest-original','synthetic-guest-tx','com.rendprop.app.pro.monthly',49000,'USD','USA',null,null,f.t,f.e,f.s+interval '10 seconds',repeat('c',64));
 perform pg_temp.ok((select revoked_at is not null from serving_funding where org_id=f.o),'refund revokes historical grant without buyer reauthorization');end$$;
reset role;
select 'VERIFIED RETAIL GUEST: '||n||' passed'from guest_checks;
rollback;
