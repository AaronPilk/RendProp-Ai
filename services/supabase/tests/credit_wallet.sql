-- Disposable local PostgreSQL proof for purchased credits; all rows roll back.
begin;
create temporary table credit_checks(n integer not null default 0);
insert into credit_checks default values;
grant all on credit_checks to service_role;
create function pg_temp.credit_ok(v boolean,label text) returns void language plpgsql as $$
begin
  if v is distinct from true then raise exception 'CREDIT FAIL: %',label; end if;
  update credit_checks set n=n+1;
end$$;
create function pg_temp.credit_refuses(statement text,needle text,label text)
returns void language plpgsql as $$
begin
  begin execute statement; exception when others then
    if position(needle in sqlerrm)>0 then perform pg_temp.credit_ok(true,label);return;end if;
    raise;
  end;
  raise exception 'CREDIT FAIL: admitted %',label;
end$$;
create function pg_temp.credit_backdate_intent(p_intent uuid) returns void
language sql security definer set search_path='' as $$
  update public.credit_purchase_intents set created_at=now()-interval '3 days' where id=p_intent
$$;
create function pg_temp.credit_reprice_product(p_active boolean,p_credits integer) returns void
language sql security definer set search_path='' as $$
  update public.credit_products set active=p_active,credits=p_credits
    where product_id='com.rendprop.app.credits.100'
$$;
create function pg_temp.credit_purchase_grant(
  p_actor uuid,p_expected_org uuid,p_intent uuid,p_product text,
  p_environment text,p_transaction text,p_purchased_at timestamptz,
  p_signed_at timestamptz,p_account_token uuid
) returns jsonb language sql as $$
  select public.credit_purchase_grant(p_actor,p_expected_org,p_intent,p_product,
    p_environment,p_transaction,p_purchased_at,p_signed_at,p_account_token,
    39990,'USD','USA')
$$;

select pg_temp.credit_ok(not has_function_privilege('authenticated',
  'public.credit_purchase_grant(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,uuid,bigint,text,text)',
  'execute') and not has_function_privilege('service_role',
  'public.credit_purchase_grant_before_margin(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,uuid)',
  'execute') and not has_table_privilege('authenticated','public.credit_grants','select'),
  'client cannot mint or read customer credit ledger directly');
select pg_temp.credit_ok((select credits=100 and not active and target_price_milliunits=39990
  and operating_reserve_cents=190 from public.credit_products
  where product_id='com.rendprop.app.credits.100'),
  '100-credit $39.99 Apple product remains dormant with a bounded reserve');
select pg_temp.credit_refuses(
  'update public.credit_products set active=true where product_id=''com.rendprop.app.credits.100''',
  'credit_pack_activation_requires_proceeds',
  'catalog toggle alone cannot bypass missing Apple proceeds evidence');
update public.credit_products set verified_net_proceeds_floor_cents=2759,
  proceeds_evidence_sha256=repeat('a',64)
  where product_id='com.rendprop.app.credits.100';
select pg_temp.credit_refuses(
  'update public.credit_products set active=true where product_id=''com.rendprop.app.credits.100''',
  'credit_pack_activation_requires_proceeds',
  'below-threshold Apple proceeds cannot fund full 100-credit liability and reserve');
update public.credit_products set verified_net_proceeds_floor_cents=2799
  where product_id='com.rendprop.app.credits.100';
select pg_temp.credit_reprice_product(true,100);

insert into auth.users(id,email,is_anonymous) values
  ('11111111-1111-4111-8111-111111111111','credits-a@example.invalid',false),
  ('22222222-2222-4222-8222-222222222222','credits-b@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Free credit workspace','free',null),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Other credit workspace','free',null);
insert into public.memberships(user_id,org_id,role) values
  ('11111111-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner'),
  ('11111111-1111-4111-8111-111111111111','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','owner'),
  ('22222222-2222-4222-8222-222222222222','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','owner');
select pg_temp.credit_ok((select credits=10 and active from public.credit_tariffs
  where operation='photo.declutter' and version='photo-declutter-v1'),
  'Declutter has one active bounded launch quote');
update public.credit_tariffs set active=false where operation='photo.declutter';
insert into public.credit_tariffs(operation,version,credits,active)
  values('photo.declutter','test-v1',30,true);
select pg_temp.credit_ok((select credits=250 and not active from public.credit_monthly_catalog
  where product_id='com.rendprop.app.pro.monthly'),
  'Ultra monthly allowance stays inactive until the verified pricing rollout');
update public.credit_monthly_catalog set active=true
  where product_id='com.rendprop.app.pro.monthly';
insert into public.apple_subscriptions(original_transaction_id,org_id,user_id,
  product_id,plan,environment,status,expires_at,auto_renew,last_transaction_id,
  transaction_purchased_at,transaction_signed_at) values(
  'monthly-chain','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  '11111111-1111-4111-8111-111111111111','com.rendprop.app.pro.monthly',
  'ultra','Production','active',now()+interval '29 days',true,'monthly-one',
  now()-interval '1 day',now()-interval '1 day'+interval '1 minute');

set local role service_role;
select pg_temp.credit_ok(
 (public.credit_verified_monthly_apply(
   'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','com.rendprop.app.pro.monthly',
   'Production','monthly-chain','monthly-one',now()-interval '1 day',
   now()+interval '29 days',99990,now()-interval '1 day'+interval '1 minute',
   now()-interval '1 day'+interval '1 minute','paid')->>'reason')
   ='combined_policy_inactive_or_preexisting_period',
 'turning on catalog alone cannot mint an unbudgeted monthly grant');
reset role;
update public.app_config set value=value||jsonb_build_object(
  'enabled',true,'activated_from',now())
  where key='credit_combined_budget';
set local role service_role;
select pg_temp.credit_ok(
 (public.credit_verified_monthly_apply(
   'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','com.rendprop.app.pro.monthly',
   'Production','monthly-chain','monthly-one',now()-interval '1 day',
   now()+interval '29 days',99990,now()-interval '1 day'+interval '1 minute',
   now()-interval '1 day'+interval '1 minute','paid')->>'reason')
   ='combined_policy_inactive_or_preexisting_period',
 'activation does not backfill a paid term that already began');
reset role;
update public.app_config set value=jsonb_set(value,'{activated_from}',
  to_jsonb(now()-interval '2 days')) where key='credit_combined_budget';

set local role service_role;
do $$
declare
  actor uuid:='11111111-1111-4111-8111-111111111111';
  stranger uuid:='22222222-2222-4222-8222-222222222222';
  org uuid:='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  other_org uuid:='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  sku text:='com.rendprop.app.credits.100';
  first_intent uuid; second_intent uuid; third_intent uuid; sandbox_intent uuid; other_intent uuid;
  first_token uuid; second_token uuid; third_token uuid; sandbox_token uuid;
  role_intent uuid; role_token uuid;
  r jsonb; b jsonb;
begin
  r:=public.credit_purchase_intent_create(actor,org,sku);
  first_intent:=(r->>'intent_id')::uuid;
  first_token:=(r->>'app_account_token')::uuid;
  perform pg_temp.credit_ok(r->>'org_id'=org::text and r->>'replay'='false',
    'purchase intent binds actor and original workspace');
  perform pg_temp.credit_refuses(format(
    'select public.credit_purchase_grant(%L,%L,%L,%L,%L,%L,now(),now(),%L,29990,%L,%L)',
    actor,org,first_intent,sku,'Production','tx-underpriced',first_token,'USD','USA'),
    'RP409: Signed Apple credit price',
    'old $29.99 signed price cannot mint the $39.99 pack');
  perform pg_temp.credit_refuses(format(
    'select public.credit_purchase_grant(%L,%L,%L,%L,%L,%L,now(),now(),%L,39990,%L,%L)',
    actor,org,first_intent,sku,'Production','tx-foreign',first_token,'EUR','FRA'),
    'RP409: Signed Apple credit price',
    'foreign currency and storefront cannot fund the US pack');
  r:=public.credit_purchase_intent_create(actor,org,sku);
  perform pg_temp.credit_ok((r->>'intent_id')::uuid=first_intent and r->>'replay'='true',
    'pre-purchase retry returns the same intent');
  perform pg_temp.credit_backdate_intent(first_intent);
  r:=public.credit_purchase_intent_create(actor,org,sku);
  perform pg_temp.credit_ok((r->>'intent_id')::uuid<>first_intent and
    r->>'replay'='false' and (r->>'app_account_token')::uuid<>first_token,
    'ambiguous prepared intent does not block a later fresh checkout');
  r:=public.credit_purchase_intent_create(actor,other_org,sku);
  other_intent:=(r->>'intent_id')::uuid;
  perform pg_temp.credit_ok(r->>'org_id'=other_org::text and
    (r->>'app_account_token')::uuid<>first_token,
    'a new workspace receives a distinct signed purchase token');
  r:=public.credit_purchase_intent_abandon(actor,other_intent,other_org);
  perform pg_temp.credit_ok(r->>'state'='abandoned',
    'definite user cancellation hides but does not destroy an intent');
  r:=public.credit_purchase_intent_create(actor,other_org,sku);
  perform pg_temp.credit_ok((r->>'intent_id')::uuid<>other_intent,
    'canceled attempt cannot trap a later purchase in the same workspace');
  perform pg_temp.credit_refuses(format(
    'select pg_temp.credit_purchase_grant(%L,%L,%L,%L,%L,%L,now(),now(),%L)',
    stranger,org,first_intent,sku,'Production','tx-wrong-owner',first_token),
    'RP409:','another actor cannot claim a signed purchase intent');
  r:=pg_temp.credit_purchase_grant(actor,org,first_intent,sku,
    'Production','tx-first',now(),now(),first_token);
  perform pg_temp.credit_ok(r->>'credits_granted'='100' and r->>'replay'='false',
    'first verified Apple transaction grants 100 credits');
  r:=pg_temp.credit_purchase_grant(actor,org,first_intent,sku,
    'Production','tx-first',now(),now(),first_token);
  perform pg_temp.credit_ok(r->>'credits_granted'='100' and r->>'replay'='true' and
    (select count(*)=1 from public.credit_grants where environment='Production' and
      source='topup' and reference='tx-first'),
    'exact receipt replay cannot double credit');
  perform pg_temp.credit_refuses(format(
    'select pg_temp.credit_purchase_grant(%L,%L,%L,%L,%L,%L,now(),now(),%L)',
    actor,org,first_intent,sku,'Production','tx-token-reused',first_token),
    'RP409:','a signed intent token cannot mint a second purchase');
  perform pg_temp.credit_refuses(format(
    'select pg_temp.credit_purchase_grant(%L,%L,%L,%L,%L,%L,now(),now(),%L)',
    actor,other_org,first_intent,sku,'Production','tx-first',first_token),
    'RP409:','one Apple receipt cannot move to another workspace');
  b:=public.credit_wallet_state(org,'Production');
  perform pg_temp.credit_ok(b->>'topup_available'='100' and b->>'monthly_available'='0' and
    b->>'total_available'='100' and (select plan='free' from public.orgs where id=org),
    'purchased credits exist and remain spendable on Free');
  perform pg_temp.credit_ok((public.credit_wallet_state(org,'Sandbox')->>'total_available')::integer=0,
    'Sandbox never reads Production credits');

  r:=public.credit_wallet_reserve(actor,org,'Production','declutter-one','photo.declutter','test-v1');
  perform pg_temp.credit_ok(r->>'credits'='30' and
    (public.credit_wallet_state(org,'Production')->>'total_available')::integer=70,
    'Free workspace atomically reserves server-priced AI credits');
  r:=public.credit_wallet_reserve(actor,org,'Production','declutter-one','photo.declutter','test-v1');
  perform pg_temp.credit_ok(r->>'replay'='true' and
    (select count(*)=1 from public.credit_holds where org_id=org),
    'same operation key cannot double debit');
  r:=public.credit_wallet_finish(actor,org,'Production','declutter-one','released');
  perform pg_temp.credit_ok(r->>'state'='released' and
    (public.credit_wallet_state(org,'Production')->>'total_available')::integer=100,
    'definitively rejected work restores the credit hold');
  r:=public.credit_wallet_reserve(actor,org,'Production','declutter-two','photo.declutter','test-v1');
  r:=public.credit_wallet_finish(actor,org,'Production','declutter-two','settled');
  perform pg_temp.credit_ok((public.credit_wallet_state(org,'Production')->>'total_available')::integer=70,
    'successful work consumes credits once');
  r:=public.credit_wallet_reserve(actor,org,'Production','declutter-three','photo.declutter','test-v1');
  perform pg_temp.credit_ok((public.credit_wallet_state(org,'Production')->>'held')::integer=30,
    'in-flight credit work remains visible as a hold');

  r:=public.credit_purchase_refund('Production','tx-first',repeat('a',64),now());
  b:=public.credit_wallet_state(org,'Production');
  perform pg_temp.credit_ok(r->>'removed_available'='40' and r->>'debt_credits'='60' and
    b->>'total_available'='0' and b->>'refund_debt'='60',
    'refund removes unspent balance and records consumed/in-flight liability');
  r:=public.credit_wallet_finish(actor,org,'Production','declutter-three','released');
  b:=public.credit_wallet_state(org,'Production');
  perform pg_temp.credit_ok(b->>'refund_debt'='30' and b->>'total_available'='0',
    'rejected in-flight job reduces refunded credit debt');
  r:=public.credit_purchase_refund('Production','tx-first',repeat('a',64),now());
  perform pg_temp.credit_ok(r->>'replay'='true', 'refund notification replay is idempotent');

  r:=public.credit_purchase_intent_create(actor,org,sku);
  second_intent:=(r->>'intent_id')::uuid;
  second_token:=(r->>'app_account_token')::uuid;
  perform pg_temp.credit_backdate_intent(second_intent);
  r:=pg_temp.credit_purchase_grant(actor,null,null,sku,'Production','tx-delayed',now(),now(),second_token);
  b:=public.credit_wallet_state(org,'Production');
  perform pg_temp.credit_ok(r->>'org_id'=org::text and r->>'credits_granted'='100' and
    b->>'total_available'='70',
    'Ask-to-Buy approval days later recovers original org after reinstall');
  perform pg_temp.credit_refuses(format(
    'select pg_temp.credit_purchase_grant(%L,%L,%L,%L,%L,%L,now(),now(),%L)',
    actor,other_org,second_intent,sku,'Production','tx-delayed',second_token),
    'RP409:','reinstalled client cannot rebind a delayed purchase');

  r:=public.credit_purchase_refund('Sandbox','tx-pre-refunded',repeat('b',64),now());
  perform pg_temp.credit_ok(r->>'pending_purchase'='true',
    'Apple refund may arrive before device acknowledgement');
  r:=public.credit_purchase_intent_create(actor,org,sku,'Sandbox');
  third_intent:=(r->>'intent_id')::uuid;
  third_token:=(r->>'app_account_token')::uuid;
  r:=pg_temp.credit_purchase_grant(actor,org,third_intent,sku,'Sandbox',
    'tx-pre-refunded',now(),now(),third_token);
  perform pg_temp.credit_ok(r->>'refunded'='true' and r->>'credits_granted'='0' and
    (public.credit_wallet_state(org,'Sandbox')->>'total_available')::integer=0,
    'pre-recorded Apple refund never becomes spendable');

  r:=public.credit_purchase_intent_create(actor,org,sku,'Sandbox');
  sandbox_intent:=(r->>'intent_id')::uuid;
  sandbox_token:=(r->>'app_account_token')::uuid;
  r:=pg_temp.credit_purchase_grant(actor,org,sandbox_intent,sku,'Sandbox',
    'tx-sandbox',now(),now(),sandbox_token);
  perform pg_temp.credit_ok((public.credit_wallet_state(org,'Sandbox')->>'total_available')::integer=100 and
    (public.credit_wallet_state(org,'Production')->>'total_available')::integer=70,
    'TestFlight credit balance is isolated from Production');

  r:=public.credit_verified_monthly_apply(other_org,'com.rendprop.app.pro.monthly',
    'Production','monthly-chain','monthly-one',now()-interval '1 day',
    now()+interval '29 days',99990,now()-interval '1 day'+interval '1 minute',
    now()-interval '1 day'+interval '1 minute','paid');
  perform pg_temp.credit_ok(r->>'reason'='paid_funding_unavailable' and
    (public.credit_wallet_state(other_org,'Production')->>'monthly_available')::integer=0,
    'monthly receipt waits for attested hosting and support funding');
  r:=public.credit_verified_monthly_apply(other_org,'com.rendprop.app.pro.monthly',
    'Production','monthly-chain','monthly-one',now()-interval '1 day',
    now()+interval '29 days',99990,now()-interval '1 day'+interval '1 minute',
    now()-interval '1 day'+interval '1 minute','paid');
  -- The period timestamps must be exactly stable across Apple JWS replays.
  -- The preceding call intentionally uses fresh now() within one transaction,
  -- which PostgreSQL keeps constant.
  perform pg_temp.credit_ok(r->>'reason'='paid_funding_unavailable' and
    (select count(*)=0 from public.credit_grants where source='monthly'),
    'replayed unfunded receipt cannot mint credits');
  perform pg_temp.credit_refuses(format(
    'select public.credit_verified_monthly_apply(%L,%L,%L,%L,%L,now()-interval ''1 day'',now()+interval ''29 days'',99990,now()-interval ''1 day''+interval ''1 minute'',now()-interval ''1 day''+interval ''1 minute'',''paid'')',
    org,'com.rendprop.app.pro.monthly','Production','monthly-chain','monthly-one'),
    'RP409:','monthly receipt cannot move to another workspace');

  r:=pg_temp.credit_purchase_grant(actor,other_org,other_intent,sku,
    'Production','tx-late-after-abandon',now(),now(),
    (select app_account_token from public.credit_purchase_intents where id=other_intent));
  perform pg_temp.credit_ok(r->>'credits_granted'='100' and r->>'org_id'=other_org::text,
    'verified late Ask-to-Buy approval settles original intent even after UI abandon');

  r:=public.credit_purchase_intent_create(actor,org,sku);
  role_intent:=(r->>'intent_id')::uuid;
  role_token:=(r->>'app_account_token')::uuid;
  insert into public.memberships(user_id,org_id,role) values(stranger,org,'owner');
  update public.memberships set role='agent' where user_id=actor and org_id=org;
  perform pg_temp.credit_refuses(format(
    'select public.credit_purchase_intent_create(%L,%L,%L)',actor,org,sku),
    'RP403:','former admin cannot prepare another credit purchase');
  perform pg_temp.credit_reprice_product(false,99);
  r:=pg_temp.credit_purchase_grant(actor,org,role_intent,sku,
    'Production','tx-approved-after-role-change',now(),now(),role_token);
  perform pg_temp.credit_ok(r->>'credits_granted'='100' and r->>'org_id'=org::text and
    (select count(*)=1 from public.credit_grants where source='topup' and
      reference='tx-approved-after-role-change' and org_id=org),
    'Ask-to-Buy settles original org and 100-credit quote after role loss and product retirement');
  perform pg_temp.credit_reprice_product(true,100);
  perform pg_temp.credit_refuses(format(
    'select pg_temp.credit_purchase_grant(%L,%L,%L,%L,%L,%L,now(),now(),%L)',
    stranger,org,role_intent,sku,'Production','tx-role-hijack',role_token),
    'RP409:','new owner cannot claim prior actors signed token');
end$$;

reset role;
select json_build_object('passed',true,'assertions',(select n from credit_checks));
rollback;
