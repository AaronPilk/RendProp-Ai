-- Synthetic Apple bindings and signed-fact RPC calls in a disposable database.
begin;
create temporary table monthly_checks(n integer not null default 0);
insert into monthly_checks default values;
grant all on monthly_checks to service_role;
create function pg_temp.monthly_ok(v boolean,label text) returns void language plpgsql as $$
begin
  if v is distinct from true then raise exception 'MONTHLY CREDIT FAIL: %',label; end if;
  update monthly_checks set n=n+1;
end$$;
create function pg_temp.monthly_refuses(statement text,needle text,label text)
returns void language plpgsql as $$
begin
  begin execute statement; exception when others then
    if position(needle in sqlerrm)>0 then perform pg_temp.monthly_ok(true,label);return;end if;
    raise;
  end;
  raise exception 'MONTHLY CREDIT FAIL: admitted %',label;
end$$;

select pg_temp.monthly_ok(not has_function_privilege('authenticated',
  'public.credit_verified_monthly_apply(uuid,text,text,text,text,timestamptz,timestamptz,bigint,timestamptz,timestamptz,text)',
  'execute') and not has_table_privilege('authenticated','public.credit_monthly_events','select')
  and not has_function_privilege('service_role',
    'public.credit_monthly_grant(uuid,uuid,text,text,text,timestamptz,timestamptz)','execute'),
  'client cannot mint credits and old service-key-only mint route is retired');

insert into auth.users(id,email,is_anonymous) values
  ('31111111-1111-4111-8111-111111111111','monthly-a@example.invalid',false),
  ('32222222-2222-4222-8222-222222222222','monthly-b@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source) values
  ('3aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Monthly owner','free',null),
  ('3bbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Other monthly owner','free',null);
insert into public.memberships(user_id,org_id,role) values
  ('31111111-1111-4111-8111-111111111111','3aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner'),
  ('32222222-2222-4222-8222-222222222222','3bbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','owner');
insert into public.apple_subscriptions(original_transaction_id,org_id,user_id,product_id,
  plan,environment,status,expires_at,auto_renew,last_transaction_id,
  transaction_purchased_at,transaction_signed_at) values
  ('monthly-original','3aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   '31111111-1111-4111-8111-111111111111','com.rendprop.app.pro.monthly',
   'pro','Production','active',now()+interval '20 days',true,'monthly-transaction',
   now()-interval '10 days',now()-interval '10 days'+interval '1 minute');
insert into public.apple_sandbox_receipts(original_transaction_id,org_id,actor_id,
  transaction_id,product_id,status,signed_at) values
  ('sandbox-original','3aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   '31111111-1111-4111-8111-111111111111','monthly-transaction',
   'com.rendprop.app.pro.monthly','active',now()-interval '10 days'+interval '1 minute');
-- Disposable fixture setup; the migration itself grants service_role read-only
-- access to the catalog. This extra test grant rolls back below.
grant insert,update on public.credit_monthly_catalog to service_role;

set local role service_role;
do $$
declare
  org uuid:='3aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  other_org uuid:='3bbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  sku text:='com.rendprop.app.pro.monthly';
  started timestamptz:=now()-interval '10 days';
  ended timestamptz:=now()+interval '20 days';
  signed timestamptz:=now()-interval '10 days'+interval '1 minute';
  r jsonb;
begin
  r:=public.credit_verified_monthly_apply(org,sku,'Production','monthly-original',
    'monthly-transaction',started,ended,99990,signed,signed,'paid');
  perform pg_temp.monthly_ok(r->>'reason'='not_configured' and
    (select count(*)=0 from public.credit_grants where org_id=org),
    'unapproved catalog cannot mint monthly credits');
  perform pg_temp.monthly_ok((select credits=440 and not active from public.credit_monthly_catalog
      where product_id=sku),'reviewed Ultra credit quantity is seeded but inactive');
  update public.credit_monthly_catalog set active=true where product_id=sku;
  r:=public.credit_verified_monthly_apply(org,sku,'Production','monthly-original',
    'monthly-transaction',started,ended,0,signed,signed,'paid');
  perform pg_temp.monthly_ok(r->>'reason'='unpaid_period' and
    (select count(*)=0 from public.credit_grants where org_id=org),
    'free introductory period never mints monthly credits');
  r:=public.credit_verified_monthly_apply(org,sku,'Production','monthly-original',
    'monthly-transaction',started,ended,99990,signed,signed,'paid');
  perform pg_temp.monthly_ok(r->>'granted'='true' and r->>'replay'='false' and
    (public.credit_wallet_state(org,'Production')->>'monthly_available')::int=440,
    'verified paid period grants exactly one allowance');
  r:=public.credit_verified_monthly_apply(org,sku,'Production','monthly-original',
    'monthly-transaction',started,ended,99990,signed,signed,'paid');
  perform pg_temp.monthly_ok(r->>'replay'='true' and
    (select count(*)=1 from public.credit_grants where org_id=org and source='monthly'),
    'device restore and notification replay cannot mint twice');
  perform pg_temp.monthly_refuses(format(
    'select public.credit_verified_monthly_apply(%L,%L,%L,%L,%L,%L,%L,%s,%L,%L,%L)',
    other_org,sku,'Production','monthly-original','monthly-transaction',
    started,ended,99990,signed,signed,'paid'),
    'RP409:','signed Apple chain cannot be moved to another workspace');
  r:=public.credit_verified_monthly_apply(org,sku,'Sandbox','sandbox-original',
    'monthly-transaction',started,ended,99990,signed,signed,'paid');
  perform pg_temp.monthly_ok(r->>'granted'='true' and
    (public.credit_wallet_state(org,'Sandbox')->>'monthly_available')::int=440 and
    (public.credit_wallet_state(org,'Production')->>'monthly_available')::int=440,
    'same Apple transaction ID in Sandbox is an isolated allowance');
  r:=public.credit_verified_monthly_apply(org,sku,'Production','monthly-original',
    'monthly-transaction',started,ended,99990,signed,signed+interval '2 days','refunded');
  perform pg_temp.monthly_ok(r->>'refunded'='true' and
    (public.credit_wallet_state(org,'Production')->>'monthly_available')::int=0 and
    (public.credit_wallet_state(org,'Sandbox')->>'monthly_available')::int=440,
    'refund removes only the matching Production period');
  r:=public.credit_verified_monthly_apply(org,sku,'Production','monthly-original',
    'monthly-transaction',started,ended,99990,signed+interval '3 days',
    signed+interval '3 days','paid');
  perform pg_temp.monthly_ok(r->>'reason'='terminal_apple_event' and
    (public.credit_wallet_state(org,'Production')->>'monthly_available')::int=0,
    'later re-signed device receipt cannot undo a refund');
  update public.apple_subscriptions set status='refunded'
    where original_transaction_id='monthly-original';
  r:=public.credit_verified_monthly_apply(org,sku,'Production','monthly-original',
    'monthly-transaction',started,ended,99990,signed,signed+interval '4 days','reversed');
  perform pg_temp.monthly_ok(r->>'reason'='reversal_not_active' and
    (public.credit_wallet_state(org,'Production')->>'monthly_available')::int=0,
    'refund reversal cannot restore credits before entitlement is active');
  update public.apple_subscriptions set status='active'
    where original_transaction_id='monthly-original';
  r:=public.credit_verified_monthly_apply(org,sku,'Production','monthly-original',
    'monthly-transaction',started,ended,99990,signed,signed+interval '4 days','reversed');
  perform pg_temp.monthly_ok(r->>'restored'='true' and
    (public.credit_wallet_state(org,'Production')->>'monthly_available')::int=440,
    'explicit later Apple refund reversal restores unspent credits once');
  r:=public.credit_verified_monthly_apply(org,sku,'Production','monthly-original',
    'monthly-transaction',started,ended,99990,signed,signed+interval '2 days','refunded');
  perform pg_temp.monthly_ok(r->>'reason'='stale_apple_event' and
    (public.credit_wallet_state(org,'Production')->>'monthly_available')::int=440,
    'older refund replay cannot override Apple refund reversal');
  update public.apple_subscriptions set last_transaction_id='newer-period',
    transaction_purchased_at=now(),transaction_signed_at=now()
    where original_transaction_id='monthly-original';
  r:=public.credit_verified_monthly_apply(org,sku,'Production','monthly-original',
    'newer-period',now(),now()+interval '30 days',99990,now(),now(),'paid');
  perform pg_temp.monthly_ok(r->>'granted'='true' and
    (select count(*)=2 from public.credit_grants where environment='Production' and
      source='monthly' and org_id=org),
    'genuine paid renewal receives its own period once');
end$$;
reset role;
select json_build_object('passed',true,'assertions',(select n from monthly_checks));
rollback;
