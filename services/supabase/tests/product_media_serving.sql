\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'product_media_serving' or inet_server_addr()is not null then raise exception 'Owned socket-only product media fixture required';end if;end$$;
create temporary table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated,anon;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'PRODUCT_MEDIA FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception 'PRODUCT_MEDIA FAIL: allowed %',label;end$$;
create temporary table fixture(kind text,actor uuid,org uuid,listing uuid);grant select on fixture to service_role,authenticated,anon;
do $$declare k text;a uuid;o uuid;l uuid;prior_plan text;prior_source text;prior_expires timestamptz;prior_trial_ends timestamptz;begin foreach k in array array['free','trial','paid','owner']loop
 a:=gen_random_uuid();l:=gen_random_uuid();insert into auth.users(id,email,email_confirmed_at,is_anonymous)values(a,k||'-product-media@fixture.invalid',now(),false);
 select org_id into o from memberships where user_id=a;
 select plan,plan_source,plan_expires_at,trial_ends_at into prior_plan,prior_source,prior_expires,prior_trial_ends from orgs where id=o;
 -- Seed a lawful listing, then restore the exact free baseline for each case.
 update orgs set plan='starter',plan_source='manual' where id=o;
 insert into listings(id,org_id,agent_id,address)values(l,o,a,'Synthetic media fixture');
 update orgs set plan=prior_plan,plan_source=prior_source,plan_expires_at=prior_expires,trial_ends_at=prior_trial_ends where id=o;
 if k='paid'then
  perform public.apply_apple_entitlement_v2(o,a,'product-media-paid-original','product-media-paid-transaction','com.rendprop.app.starter.monthly','starter','Production','active',now()+interval'29 days',true,'DID_RENEW',now()-interval'1 day',now()+interval'1 second',now()+interval'1 second',now()+interval'1 second');
 elsif k='trial'then
  insert into subscription_trial_grants(actor_id,identity_sha256,org_id,original_transaction_id,funding_id,starts_at,ends_at,walkthrough_cap,photo_cap,listing_cap,upload_budget_bytes,max_video_seconds,evidence_sha256)
   values(a,repeat('c',64),o,'product-media-trial',gen_random_uuid(),now(),now()+interval'6 days',1,5,1,1048576,90,repeat('a',64));
 elsif k='owner'then
  update profiles set is_admin=true where id=a;update orgs set plan='team',plan_source='manual',plan_expires_at=null where id=o;
  insert into org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)values(o,a,true);
 end if;
 insert into fixture values(k,a,o,l);
 end loop;end$$;
-- This is a deliberately exhausted LOCAL financial fixture, not fabricated
-- production cash. New reads must not reset or rewrite this historical receipt.
insert into public.media_delivery_budgets(org_id,receipt_ref,starts_at,ends_at,request_limit,byte_limit,storage_limit,used_requests,used_bytes,tariff,reserves,evidence_sha256)
 select org,'synthetic-exhausted-media',now()-interval'1 day',now()+interval'1 day',1,1000,1000,1,1000,'{}','{}',repeat('b',64)from fixture where kind='paid';
create temporary table money_before as select
 (select jsonb_agg(to_jsonb(x)order by id)from media_delivery_budgets x) budgets,
 (select count(*)from media_account_reserves) reserves,(select count(*)from serving_funding)funding,
 (select count(*)from cost_ledger)ledgers,(select count(*)from serving_cost_reservations)ai_holds;
grant select on money_before to service_role;
select pg_temp.ok((select relrowsecurity from pg_class where oid='public.media_serving_usage'::regclass),'private usage has RLS');
select pg_temp.ok(not has_table_privilege(r,'public.media_serving_usage','insert,update,delete'),'no direct usage writer '||r)from unnest(array['anon','authenticated','service_role'])r;
select pg_temp.ok(not has_table_privilege(r,'public.media_serving_usage','select'),'no customer usage reader '||r)from unnest(array['anon','authenticated'])r;
select pg_temp.ok(not has_function_privilege(r,'public.media_delivery_admit(uuid,bigint,boolean)','execute'),'service-only admission '||r)from unnest(array['anon','authenticated'])r;
select pg_temp.ok((select prosecdef and proconfig=array['search_path=""']::text[]from pg_proc where oid='public.media_delivery_admit(uuid,bigint,boolean)'::regprocedure),'pinned definer');
select pg_temp.ok((select md5(prosrc)='df4b527bf5c38dabbfcae08494367cdd'from pg_proc where oid='public.media_delivery_admit_before_product_serving_20261015(uuid,bigint,boolean)'::regprocedure),'previous owner financial wrapper preserved');
select pg_temp.ok((select md5(prosrc)='d55db25df05adaed4e92b8ddde197f8b'from pg_proc where oid='public.library_media_delivery_admit(uuid,uuid,bigint,boolean)'::regprocedure),'current actor/library wrapper byte-identical');
set local role service_role;
do $$declare f record;r jsonb;begin for f in select *from fixture loop
 r:=public.hosting_retention_state(f.org);perform pg_temp.ok((r->>'hosting_available')::boolean,'valid hosting retained '||f.kind);
 r:=public.media_delivery_admit(f.org,0,true);perform pg_temp.ok(r->>'admitted'='true'and r->>'basis'='product_media_serving'and r->>'infrastructure_cost'='unpriced'and r->>'financial_budget_bypassed'='true','no cash activation barrier '||f.kind);
 r:=public.library_media_delivery_admit(f.actor,f.org,1234,true);perform pg_temp.ok(r->>'request_counted'='true'and r->>'bytes_counted'='1234'and r->>'legacy_unbudgeted'='false','exact scoped byte usage '||f.kind);
 perform pg_temp.ok((select used_requests=2 and used_bytes=1234 from public.media_serving_usage where org_id=f.org and usage_day=(now()at time zone'UTC')::date),'HEAD and byte metering '||f.kind);
 end loop;
 select *into f from fixture where kind='free';
 perform pg_temp.refuse(format('select public.media_delivery_admit(%L,268435457,true)',f.org),'RP400:','byte ceiling unchanged');
 perform pg_temp.refuse(format('select public.media_delivery_admit(%L,-1,true)',f.org),'RP400:','negative bytes refused');
 perform pg_temp.refuse(format('select public.media_delivery_admit(%L,0,null)',f.org),'RP400:','null contract refused');
 perform pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',gen_random_uuid()),'RP404:','missing org refused');
 perform pg_temp.refuse(format('select public.library_media_delivery_admit(%L,%L,0,true)',f.actor,(select org from fixture where kind='paid')),'RP403:','foreign actor library refused');
 perform pg_temp.ok((select jsonb_agg(to_jsonb(x)order by id)from media_delivery_budgets x)is not distinct from(select budgets from money_before),'financial budgets not reset or consumed');
 perform pg_temp.ok((select count(*)from media_account_reserves)=(select reserves from money_before)and(select count(*)from serving_funding)=(select funding from money_before)and(select count(*)from cost_ledger)=(select ledgers from money_before)and(select count(*)from serving_cost_reservations)=(select ai_holds from money_before),'metering creates no cash cost entitlement or AI hold');
end$$;
reset role;
insert into deletion_requests(user_id,status)select actor,'pending'from fixture where kind='free';
set local role service_role;
select pg_temp.refuse(format('select public.library_media_delivery_admit(%L,%L,0,true)',actor,org),'RP403:','pending account deletion refused')from fixture where kind='free';
reset role;
update orgs set deleted_at=now()where id=(select org from fixture where kind='paid');
set local role service_role;
select pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',org),'RP404:','deleted workspace refused')from fixture where kind='paid';
reset role;
set local role authenticated;
select pg_temp.refuse(format('select public.media_delivery_admit(%L,0,true)',org),'permission denied','client cannot self-authorize media')from fixture where kind='trial';
select pg_temp.refuse('insert into public.media_serving_usage(org_id,usage_day)values(gen_random_uuid(),current_date)','permission denied','client cannot forge/reset usage');
reset role;
select jsonb_build_object('passed',true,'assertions',(select n from checks),'scope','Synthetic actual PG Free/trial/Apple-paid/owner media metering; no live media/provider/Apple')::text;
rollback;
