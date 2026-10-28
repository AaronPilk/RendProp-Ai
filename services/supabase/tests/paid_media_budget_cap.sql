-- New paid StoreKit periods are bounded; older/manual service remains intact.
begin;
create temp table paid_media_checks(n integer default 0);insert into paid_media_checks default values;
grant all on paid_media_checks to service_role;
create function pg_temp.paid_media_ok(v boolean,label text)returns void language plpgsql as $$begin
 if v is distinct from true then raise exception 'PAID MEDIA FAIL: %',label;end if;
 update paid_media_checks set n=n+1;end$$;
create function pg_temp.paid_media_denied(q text,needle text,label text)returns void language plpgsql as $$begin
 begin execute q;exception when others then
  if position(needle in sqlerrm)>0 then perform pg_temp.paid_media_ok(true,label);return;end if;raise;end;
 raise exception 'PAID MEDIA FAIL accepted: %',label;end$$;
create temp table paid_media_fixture(actor uuid,org uuid,legacy_org uuid,sku text,original text,tx text,start_at timestamptz,end_at timestamptz,signed_at timestamptz);
insert into paid_media_fixture values('a1200000-0000-4000-8000-000000000001','a2200000-0000-4000-8000-000000000001','a2200000-0000-4000-8000-000000000002',
 'com.rendprop.app.starter.monthly','paid-media-original','paid-media-transaction',now()-interval '1 day',now()+interval '29 days',now()-interval '1 day'+interval '1 minute');
grant select on paid_media_fixture to service_role;
insert into auth.users(id,email,is_anonymous,email_confirmed_at)
 select actor,'paid-media@example.invalid',false,now()from paid_media_fixture;
insert into public.orgs(id,name,plan,plan_source,apple_product_id,plan_expires_at)
 select org,'Paid media fixture','max','apple',sku,end_at from paid_media_fixture;
insert into public.orgs(id,name,plan,plan_source)
 select legacy_org,'Manual media fixture','max','manual'from paid_media_fixture;
insert into public.memberships(user_id,org_id,role)
 select actor,org,'owner'from paid_media_fixture union all
 select actor,legacy_org,'owner'from paid_media_fixture;
insert into public.apple_subscriptions(original_transaction_id,org_id,user_id,product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,transaction_purchased_at,transaction_signed_at,app_account_token)
 select original,org,actor,sku,'max','Production','active',end_at,true,tx,start_at,signed_at,actor from paid_media_fixture;
insert into public.apple_serving_schedules(product_id,storefront,currency,price_milliunits,net_proceeds_floor_cents,service_months,starts_at,ends_at,reserve_components,trial_reserve_components,evidence_sha256)
 select sku,'USA','USD',49990,3499,1,start_at-interval '1 day',now()+interval '1 day',
 '{"storage":30,"delivery":30,"compute":15,"email":5,"support":35,"retention":15,"uncertainty":20}',
 '{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}',repeat('a',64)
 from paid_media_fixture;
select pg_temp.paid_media_ok((select count(*)=10 and bool_and(not enabled and account_reserve_ref is null)
 from public.paid_media_budget_policy),'all paid policies are dormant and cashless');
select pg_temp.paid_media_ok(not has_table_privilege('authenticated','public.paid_media_budget_policy','select,insert,update,delete')
 and not has_table_privilege('service_role','public.paid_media_budget_policy','insert,update,delete')
 and not has_function_privilege('authenticated','public.paid_media_gateway_required(uuid)','execute'),
 'tenants and service key cannot activate paid cash policy');
set local role service_role;
select pg_temp.paid_media_ok(not public.paid_media_gateway_required(org),
 'unfunded legacy workspace may keep old R2 signing route')from paid_media_fixture;
reset role;
update public.app_config set value=value||jsonb_build_object('enabled',true,'activated_from',now()-interval '2 days')
 where key='credit_combined_budget';
update public.credit_monthly_catalog set active=true where product_id='com.rendprop.app.starter.monthly';
set local role service_role;
do $$declare f record;q text;begin select * into f from paid_media_fixture;
 q:=format('select fund_verified_retail_apple_transaction(%L,%L,%L,%L,%L,49990,''USD'',''USA'',null,null,%L,%L,%L,%L)',
  f.actor,f.org,f.original,f.tx,f.sku,f.start_at,f.end_at,f.signed_at,repeat('b',64));
 perform pg_temp.paid_media_denied(q,'RP402: Paid media limits and account cash are unavailable',
  'unconfigured first paid sale cannot create a budgetless funding receipt');
 perform pg_temp.paid_media_ok(not exists(select 1 from public.serving_funding where org_id=f.org),
  'failed media funding rolls back the signed receipt conversion');
end$$;
reset role;
-- Two distinct, immutable paid-cash receipts can cover the same actual account
-- dates: the launch trial $500 allocation is not a paid subscriber reserve.
set local role service_role;
do $$declare f record;tariff jsonb;reserves jsonb;r jsonb;begin select * into f from paid_media_fixture;
 tariff:='{"r2_a_cents_per_million":450,"r2_b_cents_per_million":36,"worker_cents_per_million":30,"worker_cpu_cents_per_million_ms":2,"edge_cents_per_million":200,"db_cents":1,"logs_cents":1,"storage_cents_per_gb_month":1.5}';
 reserves:='{"storage":0,"delivery":5000,"compute":5000,"email":0,"support":0,"retention":0,"uncertainty":0}';
 r:=public.provision_media_account_reserve('synthetic-trial-cash','9c332c75b96cc642621dad5d86d4bf18','owner_paid_cash',repeat('c',64),f.start_at-interval '1 day',f.end_at+interval '100 days',20000,tariff,reserves);
 perform pg_temp.paid_media_ok(r->>'reserved'='true','first account cash evidence accepted');
 r:=public.provision_media_account_reserve('synthetic-paid-cash','9c332c75b96cc642621dad5d86d4bf18','business_paid_cash',repeat('d',64),f.start_at-interval '1 day',f.end_at+interval '100 days',20000,tariff,reserves);
 perform pg_temp.paid_media_ok(r->>'reserved'='true','distinct business cash may overlap the trial account coverage');
 perform pg_temp.paid_media_denied(format('select provision_media_account_reserve(''reused-paid-cash'',''9c332c75b96cc642621dad5d86d4bf18'',''business_paid_cash'',%L,%L,%L,20000,%L,%L)',
  repeat('d',64),f.start_at-interval '1 day',f.end_at+interval '100 days',tariff::text,reserves::text),
  'RP409:','same cash evidence cannot be counted twice');
end$$;
reset role;
update public.subscription_trial_media_template set account_reserve_ref='synthetic-trial-cash' where singleton;
update public.paid_media_budget_policy set enabled=true,activated_from=now()-interval '2 days',
 account_reserve_ref='synthetic-paid-cash',evidence_sha256=repeat('e',64)
 where product_id='com.rendprop.app.starter.monthly';
insert into public.media_storage_receipts(org_id,bucket,object_key,bytes)
 select org,'renders','renders/'||org||'/retained-large.mp4',3::bigint*1073741824+1
 from paid_media_fixture;
set local role service_role;
do $$declare f record;begin select * into f from paid_media_fixture;
 perform pg_temp.paid_media_denied(format(
  'select fund_verified_retail_apple_transaction(%L,%L,%L,%L,%L,49990,''USD'',''USA'',null,null,%L,%L,%L,%L)',
  f.actor,f.org,f.original,f.tx,f.sku,f.start_at,f.end_at,f.signed_at,repeat('b',64)),
  'RP402: Paid media storage cap is below retained physical bytes',
  'paid sale cannot issue a cap below existing physical retention');
end$$;
reset role;
delete from public.media_storage_receipts where object_key like '%/retained-large.mp4';
set local role service_role;
do $$declare f record;r jsonb;cash_before bigint;used_before bigint;begin select * into f from paid_media_fixture;
 r:=fund_verified_retail_apple_transaction(f.actor,f.org,f.original,f.tx,f.sku,49990,'USD','USA',null,null,
   f.start_at,f.end_at,f.signed_at,repeat('b',64));
 perform pg_temp.paid_media_ok(r->>'funded'='true'and r->>'media_budget_id' is not null
  and r->>'media_budget_replay'='false','bound signed paid receipt provisions one finite media budget');
 perform pg_temp.paid_media_ok((select count(*)=1 and min(request_limit)=3000 and min(byte_limit)=20::bigint*1073741824
  and min(storage_limit)=3::bigint*1073741824 from media_delivery_budgets where org_id=f.org and funding_id=(r->>'funding_id')::uuid),
  'new receipt carries reviewed Max request, byte and retained-storage bounds');
 perform pg_temp.paid_media_ok(public.paid_media_gateway_required(f.org),
  'new paid period requires gateway and cannot issue direct R2 read URLs');
 select allocated_org_cents into cash_before from media_account_reserves where receipt_ref='synthetic-paid-cash';
 perform public.media_delivery_admit(f.org,1024,true);
 select used_bytes into used_before from media_delivery_budgets where org_id=f.org;
 r:=fund_verified_retail_apple_transaction(f.actor,f.org,f.original,f.tx,f.sku,49990,'USD','USA',null,null,
   f.start_at,f.end_at,f.signed_at,repeat('b',64));
 perform pg_temp.paid_media_ok(r->>'media_budget_replay'='true' and
  (select count(*)=1 and min(used_bytes)=used_before from media_delivery_budgets where org_id=f.org)
  and (select allocated_org_cents=cash_before from media_account_reserves where receipt_ref='synthetic-paid-cash'),
  'duplicate signed receipt preserves spent counters and cash allocation');
 perform pg_temp.paid_media_ok((select used_requests=1 and used_bytes=1024 from media_delivery_budgets where org_id=f.org),
  'public media read debits funded request and exact admitted bytes');
 r:=public.media_delivery_admit(f.legacy_org,128,true);
 perform pg_temp.paid_media_ok(r->>'basis'='product_media_serving' and
  not exists(select 1 from public.media_delivery_budgets where org_id=f.legacy_org),
  'existing manual service keeps its historical unbudgeted usage path');
end$$;
reset role;
-- A paid Team seat writes under its private content org. That object must
-- consume the billing org's shared request and retained-byte allowance.
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values
 ('a1200000-0000-4000-8000-000000000002','paid-team-agent@example.invalid',false,now());
insert into public.orgs(id,name,plan,plan_source)values
 ('a2200000-0000-4000-8000-000000000003','Paid Team child','free','manual');
update public.orgs set plan='team',plan_source='manual' where id=(select org from paid_media_fixture);
insert into public.memberships(user_id,org_id,role)values
 ('a1200000-0000-4000-8000-000000000002',(select org from paid_media_fixture),'agent'),
 ('a1200000-0000-4000-8000-000000000002','a2200000-0000-4000-8000-000000000003','owner');
with invitation as (
 insert into public.org_invites(org_id,role,token_hash,invited_by,accepted_at,accepted_by)
 select org,'agent',repeat('f',64),actor,now()-interval '1 hour',
  'a1200000-0000-4000-8000-000000000002'::uuid from paid_media_fixture returning id
)
insert into public.team_private_libraries(team_org_id,team_owner_user_id,agent_user_id,private_org_id,accepted_invite_id)
select f.org,f.actor,'a1200000-0000-4000-8000-000000000002',
 'a2200000-0000-4000-8000-000000000003',i.id from paid_media_fixture f cross join invitation i;
set local role service_role;
do $$declare f record;before_requests bigint;r jsonb;begin select * into f from paid_media_fixture;
 perform pg_temp.paid_media_ok(public.library_billing_org('a2200000-0000-4000-8000-000000000003')=f.org
  and public.paid_media_gateway_required('a2200000-0000-4000-8000-000000000003'),
  'paid Team child resolves the same gateway and billing budget');
 select used_requests into before_requests from public.media_delivery_budgets where org_id=f.org;
 r:=public.media_storage_reserve('a2200000-0000-4000-8000-000000000003','renders',
  'renders/a2200000-0000-4000-8000-000000000003/test.jpg',1024);
 perform pg_temp.paid_media_ok(r->>'reserved'='true' and r->>'legacy_unbudgeted'='false'
  and (select used_requests=before_requests+1 from public.media_delivery_budgets where org_id=f.org),
  'child storage write charges shared paid Team request budget');
end$$;
reset role;
update public.media_delivery_budgets set storage_limit=1024 where org_id=(select org from paid_media_fixture);
set local role service_role;
select pg_temp.paid_media_denied(
 'select media_storage_reserve(''a2200000-0000-4000-8000-000000000003'',''renders'',''renders/a2200000-0000-4000-8000-000000000003/overflow.jpg'',1)',
 'RP429: Stored media allowance exhausted','child retained bytes cannot exceed Team cap');
reset role;
-- Synthetic counter reduction represents exhausted finite allowance; it is
-- deliberately outside service-role privilege and rolls back with this test.
update public.media_delivery_budgets set request_limit=used_requests where org_id=(select org from paid_media_fixture);
set local role service_role;
select pg_temp.paid_media_denied(format('select media_delivery_admit(%L,1,true)',org),
 'RP429: Media serving allowance exhausted','paid request budget exhaustion denies replay')
 from paid_media_fixture;
reset role;
select jsonb_build_object('assertions',n,'passed',true)from paid_media_checks;
rollback;
