-- A named, short-lived operator test account may buy the 100-credit pack in
-- Apple's Sandbox while the retail catalog and its cash evidence stay OFF.
-- No row is seeded by this migration. In particular, no customer, reviewer,
-- or production account gains an offer merely by claiming environment=Sandbox.
begin;

create table if not exists public.credit_pack_sandbox_test_authority (
  actor_id uuid not null references auth.users(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  product_id text not null references public.credit_products(product_id),
  authorized_at timestamptz not null default now(),
  expires_at timestamptz not null,
  evidence_sha256 text not null check (evidence_sha256 ~ '^[a-f0-9]{64}$'),
  primary key (actor_id,org_id,product_id),
  constraint credit_pack_sandbox_only_sku
    check (product_id='com.rendprop.app.credits.100'),
  constraint credit_pack_sandbox_short_window
    check (expires_at>authorized_at and expires_at<=authorized_at+interval '7 days')
);
alter table public.credit_pack_sandbox_test_authority enable row level security;
revoke all on public.credit_pack_sandbox_test_authority
  from public,anon,authenticated,service_role;

create or replace function public.credit_sandbox_pack_authorized(
  p_actor uuid,p_org uuid,p_product text
) returns boolean language sql stable security definer set search_path='' as $$
  select current_setting('role',true)='service_role'
    and p_product='com.rendprop.app.credits.100'
    and exists (
      select 1 from public.credit_pack_sandbox_test_authority a
      join public.orgs o on o.id=a.org_id and o.deleted_at is null
      join public.memberships m on m.org_id=a.org_id and m.user_id=a.actor_id
        and m.role in ('owner','admin')
      join auth.users u on u.id=a.actor_id and not u.is_anonymous
      where a.actor_id=p_actor and a.org_id=p_org and a.product_id=p_product
        and a.authorized_at<=now() and a.expires_at>now()
    )
$$;
revoke all on function public.credit_sandbox_pack_authorized(uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.credit_sandbox_pack_authorized(uuid,uuid,text)
  to service_role;

-- Existing unfulfilled purchase intents were prepared for Production. Keep
-- their original binding. New Sandbox intents snapshot the environment, so a
-- delayed Ask-to-Buy or a recovery can settle after the test window closes.
alter table public.credit_purchase_intents
  add column if not exists expected_environment text not null default 'Production'
    check (expected_environment in ('Production','Sandbox'));
-- A test intent consumes one of three lifetime preparation slots even if the
-- client abandons it: Apple can still approve an already pending transaction.
-- Keeping the marker on the intent also prevents a later authority renewal
-- from silently resetting the issuance ceiling.
alter table public.credit_purchase_intents
  add column if not exists sandbox_test_authority boolean not null default false;
do $$begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.credit_purchase_intents'::regclass
      and conname='credit_intent_sandbox_test_exact'
  ) then
    alter table public.credit_purchase_intents
      add constraint credit_intent_sandbox_test_exact check (
        not sandbox_test_authority or
        (expected_environment='Sandbox' and product_id='com.rendprop.app.credits.100'
          and credits=100));
  end if;
end$$;

create or replace function public.credit_purchase_intent_create(
  p_actor uuid,p_org uuid,p_product text,p_environment text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare old public.credit_purchase_intents; iid uuid; token uuid;
  amount integer; retail_active boolean; test_authorized boolean:=false;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege; end if;
  if p_actor is null or p_org is null or p_product is null or
     p_environment is null or p_environment not in ('Production','Sandbox') then
    raise exception 'RP400: A selected workspace, Apple environment and credit product are required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-intent:'||p_actor||':'||p_product,71001));
  select credits,active into amount,retail_active from public.credit_products
    where product_id=p_product;
  if amount is null then raise exception 'RP400: This credit pack is unavailable'; end if;
  if not retail_active then
    if p_environment is distinct from 'Sandbox' then
      raise exception 'RP400: This credit pack is unavailable'; end if;
    -- Serialize a new preparation with operator revocation or expiry edits.
    perform 1 from public.credit_pack_sandbox_test_authority a
      where a.actor_id=p_actor and a.org_id=p_org and a.product_id=p_product
      for update;
    if not found or not public.credit_sandbox_pack_authorized(p_actor,p_org,p_product) then
      raise exception 'RP400: This credit pack is unavailable'; end if;
    test_authorized:=true;
  end if;
  if not exists(select 1 from public.orgs o join public.memberships m on m.org_id=o.id
      where o.id=p_org and o.deleted_at is null and m.user_id=p_actor and m.role in('owner','admin')) then
    raise exception 'RP403: Only a current workspace owner or admin can buy credits'; end if;
  if public.library_billing_org(p_org) is distinct from p_org then
    raise exception 'RP403: Buy credits from the Team billing workspace'; end if;
  select * into old from public.credit_purchase_intents
    where actor_id=p_actor and org_id=p_org and product_id=p_product and
      expected_environment=p_environment and state='open' and
      created_at>now()-interval '1 minute'
    order by created_at desc limit 1 for update;
  if found then
    return jsonb_build_object('intent_id',old.id,'org_id',old.org_id,
      'product_id',old.product_id,'credits',old.credits,
      'app_account_token',old.app_account_token,'created_at',old.created_at,'replay',true);
  end if;
  if test_authorized and (select count(*) from public.credit_purchase_intents
    where actor_id=p_actor and product_id=p_product
      and expected_environment='Sandbox' and sandbox_test_authority) >= 3 then
    raise exception 'RP402: Sandbox test credit pack limit reached'; end if;
  insert into public.credit_purchase_intents(actor_id,org_id,product_id,credits,
    expected_environment,sandbox_test_authority)
    values(p_actor,p_org,p_product,amount,p_environment,test_authorized)
    returning id,app_account_token into iid,token;
  return jsonb_build_object('intent_id',iid,'org_id',p_org,
    'product_id',p_product,'credits',amount,'app_account_token',token,
    'created_at',now(),'replay',false);
end$$;
revoke all on function public.credit_purchase_intent_create(uuid,uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.credit_purchase_intent_create(uuid,uuid,text,text)
  to service_role;

-- Old clients can only prepare ordinary Production purchases. A Sandbox
-- claim cannot bypass the named authority by invoking the legacy signature.
create or replace function public.credit_purchase_intent_create(
  p_actor uuid,p_org uuid,p_product text
) returns jsonb language sql security definer set search_path='' as $$
  select public.credit_purchase_intent_create(p_actor,p_org,p_product,'Production')
$$;

-- `me/credits` verifies Apple's signed JWS before calling this service-only
-- function. Sandbox can skip the cash proceeds floor, but only for a pinned
-- Sandbox intent and exact 100-credit product; Production retains every
-- original retail check and can never settle the Sandbox intent.
create or replace function public.credit_purchase_grant(
  p_actor uuid,p_expected_org uuid,p_intent uuid,p_product text,
  p_environment text,p_transaction text,p_purchased_at timestamptz,
  p_signed_at timestamptz,p_account_token uuid,p_price_milliunits bigint,
  p_currency text,p_storefront text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare pack public.credit_products;intent public.credit_purchase_intents;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege; end if;
  select * into pack from public.credit_products where product_id=p_product;
  select * into intent from public.credit_purchase_intents
    where app_account_token=p_account_token;
  if pack.product_id is null or intent.id is null or intent.credits<>100 or
     p_signed_at is null or p_signed_at>now()+interval '5 minutes' then
    raise exception 'RP409: Credit pack has no reviewed margin policy'; end if;
  if p_environment='Sandbox' then
    if intent.expected_environment is distinct from 'Sandbox' or
       p_product is distinct from 'com.rendprop.app.credits.100' or
       (p_price_milliunits is not null and p_price_milliunits<>39990) or
       (p_currency is not null and p_currency<>'USD') or
       (p_storefront is not null and p_storefront<>'USA') then
      raise exception 'RP409: Signed Sandbox credit purchase differs from its test intent'; end if;
    return public.credit_purchase_grant_before_margin(p_actor,p_expected_org,p_intent,
      p_product,p_environment,p_transaction,p_purchased_at,p_signed_at,p_account_token);
  end if;
  if p_environment is distinct from 'Production' or
     intent.expected_environment is distinct from 'Production' or
     pack.target_price_milliunits is distinct from 39990 or
     pack.operating_reserve_cents is distinct from 190 or
     pack.verified_net_proceeds_floor_cents is null or
     pack.proceeds_evidence_sha256 is null or
     100*5+pack.operating_reserve_cents>floor(least(
       pack.verified_net_proceeds_floor_cents::numeric,
       (pack.target_price_milliunits::numeric/10)*0.70)*0.25) then
    raise exception 'RP409: Credit pack has no reviewed margin policy'; end if;
  if p_price_milliunits is distinct from pack.target_price_milliunits or
     p_currency is distinct from 'USD' or p_storefront is distinct from 'USA' then
    raise exception 'RP409: Signed Apple credit price or storefront differs from reviewed policy'; end if;
  return public.credit_purchase_grant_before_margin(p_actor,p_expected_org,p_intent,
    p_product,p_environment,p_transaction,p_purchased_at,p_signed_at,p_account_token);
end$$;

commit;
