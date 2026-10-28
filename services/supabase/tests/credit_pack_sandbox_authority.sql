-- Disposable local PostgreSQL proof. The Edge route separately verifies the
-- Apple JWS; this fixture probes its service-only database settlement boundary.
begin;
create temporary table sandbox_pack_checks(n integer not null default 0);
insert into sandbox_pack_checks default values;
grant all on sandbox_pack_checks to service_role;
create function pg_temp.sandbox_ok(v boolean,label text) returns void language plpgsql as $$
begin
  if v is distinct from true then raise exception 'SANDBOX PACK FAIL: %',label; end if;
  update sandbox_pack_checks set n=n+1;
end$$;
create function pg_temp.sandbox_refuses(statement text,needle text,label text)
returns void language plpgsql as $$
begin
  begin execute statement; exception when others then
    if position(needle in sqlerrm)>0 then perform pg_temp.sandbox_ok(true,label);return;end if;
    raise;
  end;
  raise exception 'SANDBOX PACK FAIL: admitted %',label;
end$$;

insert into auth.users(id,email,is_anonymous) values
 ('33111111-1111-4111-8111-111111111111','sandbox-pack-owner@example.invalid',false),
 ('33222222-2222-4222-8222-222222222222','sandbox-pack-other@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source) values
 ('33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Sandbox pack QA','free',null),
 ('33bbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Other account','free',null);
insert into public.memberships(user_id,org_id,role) values
 ('33111111-1111-4111-8111-111111111111','33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner'),
 ('33222222-2222-4222-8222-222222222222','33bbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','owner');

select pg_temp.sandbox_ok((select not active and
  verified_net_proceeds_floor_cents is null from public.credit_products
  where product_id='com.rendprop.app.credits.100'),
  'retail pack remains closed without proceeds evidence');
select pg_temp.sandbox_ok(not has_table_privilege('authenticated',
  'public.credit_pack_sandbox_test_authority','SELECT,INSERT,UPDATE,DELETE') and
  not has_table_privilege('service_role',
  'public.credit_pack_sandbox_test_authority','SELECT,INSERT,UPDATE,DELETE') and
  not has_function_privilege('authenticated',
  'public.credit_sandbox_pack_authorized(uuid,uuid,text)','EXECUTE'),
  'neither customer nor API role can create a Sandbox test authority');

set local role service_role;
select pg_temp.sandbox_ok(not public.credit_sandbox_pack_authorized(
  '33111111-1111-4111-8111-111111111111',
  '33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','com.rendprop.app.credits.100'),
  'an empty test-authority table grants nothing');
select pg_temp.sandbox_refuses(
  'select public.credit_purchase_intent_create(''33111111-1111-4111-8111-111111111111'',''33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'',''com.rendprop.app.credits.100'',''Sandbox'')',
  'RP400: This credit pack is unavailable',
  'an owner claiming Sandbox cannot prepare without operator authority');
select pg_temp.sandbox_refuses(
  'select public.credit_purchase_intent_create(''33111111-1111-4111-8111-111111111111'',''33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'',''com.rendprop.app.credits.100'')',
  'RP400: This credit pack is unavailable',
  'the legacy intent RPC cannot switch to Sandbox');
reset role;

-- The migration itself seeds no row. This named fixture simulates a separate
-- operator's short-lived approval, not a public activation flag.
insert into public.credit_pack_sandbox_test_authority
  (actor_id,org_id,product_id,expires_at,evidence_sha256) values (
  '33111111-1111-4111-8111-111111111111',
  '33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'com.rendprop.app.credits.100',now()+interval '1 day',repeat('a',64));

set local role service_role;
do $$
declare actor uuid:='33111111-1111-4111-8111-111111111111';
  other uuid:='33222222-2222-4222-8222-222222222222';
  org uuid:='33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  foreign_org uuid:='33bbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  sku text:='com.rendprop.app.credits.100';
  first_intent uuid;first_token uuid;late_intent uuid;late_token uuid;
  result jsonb;
begin
  perform pg_temp.sandbox_ok(public.credit_sandbox_pack_authorized(actor,org,sku) and
    not public.credit_sandbox_pack_authorized(other,foreign_org,sku) and
    not public.credit_sandbox_pack_authorized(actor,foreign_org,sku),
    'approval is bound to the exact signed-in actor and billing workspace');
  perform pg_temp.sandbox_refuses(format(
    'select public.credit_purchase_intent_create(%L,%L,%L,%L)',
    other,foreign_org,sku,'Sandbox'),'RP400:',
    'another owner cannot claim the test account offer');
  perform pg_temp.sandbox_refuses(format(
    'select public.credit_purchase_intent_create(%L,%L,%L,%L)',
    actor,org,sku,'Production'),'RP400:',
    'test authority cannot prepare a Production purchase');
  result:=public.credit_purchase_intent_create(actor,org,sku,'Sandbox');
  first_intent:=(result->>'intent_id')::uuid;
  first_token:=(result->>'app_account_token')::uuid;
  perform pg_temp.sandbox_ok((select expected_environment='Sandbox' and credits=100
    from public.credit_purchase_intents where id=first_intent),
    'prepared intent snapshots Sandbox and 100 credits');
  perform pg_temp.sandbox_refuses(format(
    'select public.credit_purchase_grant(%L,%L,%L,%L,%L,%L,now(),now(),%L,39990,%L,%L)',
    actor,org,first_intent,sku,'Production','sandbox-cross-to-prod',first_token,'USD','USA'),
    'RP409: Credit pack has no reviewed margin policy',
    'a Sandbox intent cannot create Production credit or bypass retail cash gate');
  perform pg_temp.sandbox_refuses(format(
    'select public.credit_purchase_grant(%L,%L,%L,%L,%L,%L,now(),now(),%L,29990,%L,%L)',
    actor,org,first_intent,sku,'Sandbox','sandbox-wrong-price',first_token,'USD','USA'),
    'RP409: Signed Sandbox credit purchase differs',
    'wrong signed Sandbox price is rejected when Apple supplies it');
  result:=public.credit_purchase_grant(actor,org,first_intent,sku,'Sandbox',
    'sandbox-first',now(),now(),first_token,39990,'USD','USA');
  perform pg_temp.sandbox_ok(result->>'credits_granted'='100' and
    result->>'environment'='Sandbox' and result->>'replay'='false' and
    (public.credit_wallet_state(org,'Sandbox')->>'topup_available')::int=100 and
    (public.credit_wallet_state(org,'Production')->>'topup_available')::int=0,
    'signed Sandbox settlement grants only the isolated test wallet');
  result:=public.credit_purchase_grant(actor,org,first_intent,sku,'Sandbox',
    'sandbox-first',now(),now(),first_token,39990,'USD','USA');
  perform pg_temp.sandbox_ok(result->>'replay'='true' and
    (select count(*)=1 from public.credit_grants
      where environment='Sandbox' and reference='sandbox-first'),
    'recovering the same Sandbox transaction cannot double grant');
  perform pg_temp.sandbox_refuses(format(
    'select public.credit_purchase_grant(%L,%L,%L,%L,%L,%L,now(),now(),%L,39990,%L,%L)',
    other,foreign_org,first_intent,sku,'Sandbox','sandbox-hijack',first_token,'USD','USA'),
    'RP409:','another actor cannot recover the test purchase');
  -- Ask-to-Buy can arrive after the short test authority expires. Preserve
  -- the charged transaction's original binding without reopening the offer.
  perform pg_temp.sandbox_refuses(format(
    'select public.credit_purchase_intent_create(%L,%L,%L,%L)',
    actor,org,sku,'Production'),'RP400:',
    'retail preparation stays closed after a Sandbox purchase');
end$$;
reset role;

-- Prepare one more test transaction and then expire the operator authority;
-- a delayed signed receipt must still recover its exact original intent.
set local role service_role;
create temporary table sandbox_late_purchase as
  select (r->>'intent_id')::uuid as intent_id,
         (r->>'app_account_token')::uuid as app_account_token
  from (select public.credit_purchase_intent_create(
    '33111111-1111-4111-8111-111111111111',
    '33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'com.rendprop.app.credits.100','Sandbox') as r) prepared;
reset role;
-- Even if retail proceeds are later evidenced and the public catalog opens,
-- a previously prepared Sandbox intent cannot become a Production grant.
update public.credit_products set active=true,
  verified_net_proceeds_floor_cents=2799,
  proceeds_evidence_sha256=repeat('b',64)
  where product_id='com.rendprop.app.credits.100';
set local role service_role;
select pg_temp.sandbox_refuses(format(
  'select public.credit_purchase_grant(%L,%L,%L,%L,%L,%L,now(),now(),%L,39990,%L,%L)',
  '33111111-1111-4111-8111-111111111111',
  '33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  (select intent_id from sandbox_late_purchase),
  'com.rendprop.app.credits.100','Production','sandbox-late-prod',
  (select app_account_token from sandbox_late_purchase),'USD','USA'),
  'RP409: Credit pack has no reviewed margin policy',
  'Sandbox intent cannot be laundered into Production even after retail activation');
reset role;
update public.credit_products set active=false,
  verified_net_proceeds_floor_cents=null,
  proceeds_evidence_sha256=null
  where product_id='com.rendprop.app.credits.100';
update public.credit_pack_sandbox_test_authority
  set authorized_at=now()-interval '2 days',expires_at=now()-interval '1 day'
  where actor_id='33111111-1111-4111-8111-111111111111';
set local role service_role;
select pg_temp.sandbox_ok(not public.credit_sandbox_pack_authorized(
  '33111111-1111-4111-8111-111111111111',
  '33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','com.rendprop.app.credits.100'),
  'expired operator approval closes the Sandbox offer');
select pg_temp.sandbox_refuses(
  'select public.credit_purchase_intent_create(''33111111-1111-4111-8111-111111111111'',''33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'',''com.rendprop.app.credits.100'',''Sandbox'')',
  'RP400: This credit pack is unavailable',
  'an expired approval cannot prepare another purchase');
create temporary table sandbox_late_receipt as
select public.credit_purchase_grant(
    '33111111-1111-4111-8111-111111111111',
    '33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    (select intent_id from sandbox_late_purchase),
    'com.rendprop.app.credits.100','Sandbox','sandbox-late',now(),now(),
    (select app_account_token from sandbox_late_purchase),
    null,null,null) as result;
select pg_temp.sandbox_ok(
  (select result->>'credits_granted'='100' from sandbox_late_receipt) and
  (public.credit_wallet_state('33aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Sandbox')
    ->>'topup_available')::int=200,
  'late signed Sandbox recovery honors its prepared intent without cash evidence');
reset role;

select pg_temp.sandbox_ok((select not active and
  verified_net_proceeds_floor_cents is null from public.credit_products
  where product_id='com.rendprop.app.credits.100'),
  'Sandbox purchase did not activate Production catalog or invent cash');
select json_build_object('passed',true,'assertions',(select n from sandbox_pack_checks));
rollback;
