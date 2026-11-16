-- Customer credits are a separate org-scoped liability from supplier COGS.
-- Purchased top-ups never expire. Sandbox and Production never share balance.
begin;

create table if not exists public.credit_products(
  product_id text primary key,
  credits integer not null check(credits between 1 and 1000000),
  active boolean not null default false,
  created_at timestamptz not null default now()
);
insert into public.credit_products(product_id,credits,active)
values('com.rendprop.app.credits.100',100,true)
on conflict(product_id) do nothing;

create table if not exists public.credit_tariffs(
  operation text not null,
  version text not null,
  credits integer not null check(credits between 1 and 1000000),
  active boolean not null default false,
  primary key(operation,version),
  check(operation ~ '^[a-z][a-z0-9_.-]{2,79}$')
);
create unique index if not exists credit_tariff_one_active
  on public.credit_tariffs(operation) where active;

create table if not exists public.credit_monthly_catalog(
  product_id text primary key,
  credits integer not null check(credits between 0 and 1000000),
  active boolean not null default false
);

-- A unique token per intent is signed into Apple's consumable transaction.
-- It keeps Ask-to-Buy bound to the original workspace for days, while an
-- abandoned/canceled attempt cannot block a fresh purchase for another org.
create table if not exists public.credit_purchase_intents(
  id uuid primary key default gen_random_uuid(),
  app_account_token uuid not null unique default gen_random_uuid(),
  actor_id uuid not null references public.profiles(id) on delete cascade,
  org_id uuid not null references public.orgs(id) on delete cascade,
  product_id text not null references public.credit_products(product_id),
  state text not null default 'open' check(state in('open','fulfilled','abandoned')),
  apple_transaction_id text,
  created_at timestamptz not null default now(),
  fulfilled_at timestamptz
);
create index if not exists credit_intents_actor_open
  on public.credit_purchase_intents(actor_id,created_at desc) where state='open';

-- Apple transaction identity survives account deletion as a replay tombstone.
-- Personal/workspace foreign keys become NULL on deletion; money is never
-- reassigned to a different workspace from the same JWS.
create table if not exists public.credit_purchases(
  environment text not null check(environment in('Production','Sandbox')),
  transaction_id text not null check(length(transaction_id) between 1 and 200),
  product_id text not null references public.credit_products(product_id),
  app_account_token uuid not null,
  actor_id uuid references public.profiles(id) on delete set null,
  org_id uuid references public.orgs(id) on delete set null,
  intent_id uuid references public.credit_purchase_intents(id) on delete set null,
  credits integer not null check(credits>0),
  apple_purchased_at timestamptz not null,
  apple_signed_at timestamptz,
  granted_at timestamptz not null default now(),
  refunded_at timestamptz,
  refund_evidence_sha256 text check(refund_evidence_sha256 is null or refund_evidence_sha256 ~ '^[a-f0-9]{64}$'),
  primary key(environment,transaction_id)
);

create table if not exists public.credit_grants(
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  environment text not null check(environment in('Production','Sandbox')),
  source text not null check(source in('topup','monthly')),
  reference text not null,
  product_id text not null,
  granted_credits integer not null check(granted_credits>0),
  remaining_credits integer not null check(remaining_credits>=0 and remaining_credits<=granted_credits),
  starts_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  unique(environment,source,reference),
  check((source='topup' and expires_at is null) or
        (source='monthly' and expires_at is not null and expires_at>starts_at))
);
create index if not exists credit_grants_spend_order
  on public.credit_grants(org_id,environment,source,expires_at,created_at)
  where revoked_at is null and remaining_credits>0;

create table if not exists public.credit_holds(
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  actor_id uuid not null references public.profiles(id) on delete cascade,
  environment text not null check(environment in('Production','Sandbox')),
  request_key text not null check(request_key ~ '^[A-Za-z0-9:_-]{8,128}$'),
  operation text not null,
  tariff_version text not null,
  credits integer not null check(credits>0),
  state text not null default 'reserved' check(state in('reserved','settled','released')),
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  unique(org_id,environment,actor_id,request_key)
);
create table if not exists public.credit_hold_allocations(
  hold_id uuid not null references public.credit_holds(id) on delete cascade,
  grant_id uuid not null references public.credit_grants(id) on delete cascade,
  credits integer not null check(credits>0),
  primary key(hold_id,grant_id)
);

-- A refunded purchase may already have funded completed or in-flight work.
-- Debt blocks later reservations; a later rejected hold reduces that debt.
create table if not exists public.credit_refund_debts(
  environment text not null,
  transaction_id text not null,
  org_id uuid not null references public.orgs(id) on delete cascade,
  debt_credits integer not null check(debt_credits>=0),
  primary key(environment,transaction_id),
  foreign key(environment,transaction_id)
    references public.credit_purchases(environment,transaction_id)
);
create table if not exists public.credit_refund_events(
  environment text not null check(environment in('Production','Sandbox')),
  transaction_id text not null,
  evidence_sha256 text not null check(evidence_sha256 ~ '^[a-f0-9]{64}$'),
  apple_revoked_at timestamptz,
  received_at timestamptz not null default now(),
  primary key(environment,transaction_id)
);

alter table public.credit_products enable row level security;
alter table public.credit_tariffs enable row level security;
alter table public.credit_monthly_catalog enable row level security;
alter table public.credit_purchase_intents enable row level security;
alter table public.credit_purchases enable row level security;
alter table public.credit_grants enable row level security;
alter table public.credit_holds enable row level security;
alter table public.credit_hold_allocations enable row level security;
alter table public.credit_refund_debts enable row level security;
alter table public.credit_refund_events enable row level security;
revoke all on public.credit_products,public.credit_tariffs,public.credit_monthly_catalog,
  public.credit_purchase_intents,public.credit_purchases,public.credit_grants,
  public.credit_holds,public.credit_hold_allocations,public.credit_refund_debts,
  public.credit_refund_events
  from public,anon,authenticated,service_role;
grant select on public.credit_products,public.credit_tariffs,public.credit_monthly_catalog,
  public.credit_purchase_intents,public.credit_purchases,public.credit_grants,
  public.credit_holds,public.credit_hold_allocations,public.credit_refund_debts,
  public.credit_refund_events to service_role;

create or replace function public.credit_purchase_intent_create(
  p_actor uuid,p_org uuid,p_product text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare old public.credit_purchase_intents; iid uuid; token uuid;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_actor is null or p_org is null or p_product is null then
    raise exception 'RP400: A selected workspace and credit product are required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-intent:'||p_actor||':'||p_product,71001));
  if not exists(select 1 from public.credit_products where product_id=p_product and active) then
    raise exception 'RP400: This credit pack is unavailable'; end if;
  if not exists(select 1 from public.orgs o join public.memberships m on m.org_id=o.id
      where o.id=p_org and o.deleted_at is null and m.user_id=p_actor and m.role in('owner','admin')) then
    raise exception 'RP403: Only a current workspace owner or admin can buy credits'; end if;
  -- Network retries within a minute reuse the same preparation; later starts
  -- get a fresh token, including after .userCancelled or another workspace.
  select * into old from public.credit_purchase_intents
    where actor_id=p_actor and org_id=p_org and product_id=p_product and
      state='open' and created_at>now()-interval '1 minute'
    order by created_at desc limit 1 for update;
  if found then
    return jsonb_build_object('intent_id',old.id,'org_id',old.org_id,
      'product_id',old.product_id,'app_account_token',old.app_account_token,
      'created_at',old.created_at,'replay',true);
  end if;
  insert into public.credit_purchase_intents(actor_id,org_id,product_id)
    values(p_actor,p_org,p_product) returning id,app_account_token into iid,token;
  return jsonb_build_object('intent_id',iid,'org_id',p_org,
    'product_id',p_product,'app_account_token',token,
    'created_at',now(),'replay',false);
end$$;

create or replace function public.credit_purchase_intent_abandon(
  p_actor uuid,p_intent uuid,p_expected_org uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare intent public.credit_purchase_intents;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  select * into intent from public.credit_purchase_intents where id=p_intent for update;
  if not found or intent.actor_id is distinct from p_actor or
     intent.org_id is distinct from p_expected_org then
    raise exception 'RP403: This purchase intent belongs to another workspace'; end if;
  if intent.state='open' then
    update public.credit_purchase_intents set state='abandoned' where id=p_intent;
  end if;
  return jsonb_build_object('intent_id',p_intent,'org_id',intent.org_id,
    'state',case when intent.state='fulfilled' then 'fulfilled' else 'abandoned' end);
end$$;

create or replace function public.credit_purchase_grant(
  p_actor uuid,p_expected_org uuid,p_intent uuid,p_product text,
  p_environment text,p_transaction text,p_purchased_at timestamptz,
  p_signed_at timestamptz,p_account_token uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare old public.credit_purchases; intent public.credit_purchase_intents;
  amount integer; was_refunded boolean;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_actor is null or p_account_token is null or
     p_environment not in('Production','Sandbox') or p_transaction is null or
     length(p_transaction) not between 1 and 200 or p_product is null or
     p_purchased_at is null or p_purchased_at>now()+interval '5 minutes' then
    raise exception 'RP400: A verified actor-bound Apple consumable is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-tx:'||p_environment||':'||p_transaction,71002));
  select * into old from public.credit_purchases
    where environment=p_environment and transaction_id=p_transaction for update;
  if found then
    if old.actor_id is distinct from p_actor or old.product_id is distinct from p_product or
       old.app_account_token is distinct from p_account_token or
       (p_expected_org is not null and old.org_id is distinct from p_expected_org) or
       (p_intent is not null and old.intent_id is distinct from p_intent) then
      raise exception 'RP409: This Apple transaction is bound to another purchase'; end if;
    return jsonb_build_object('transaction_id',old.transaction_id,'org_id',old.org_id,
      'environment',old.environment,'credits_granted',case when old.refunded_at is null then old.credits else 0 end,
      'refunded',old.refunded_at is not null,'replay',true);
  end if;
  select credits into amount from public.credit_products
    where product_id=p_product and active;
  if amount is null then raise exception 'RP400: This credit pack is unavailable'; end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-intent-token:'||p_account_token,71001));
  if p_intent is not null then
    select * into intent from public.credit_purchase_intents where id=p_intent for update;
  else
    select * into intent from public.credit_purchase_intents
      where app_account_token=p_account_token for update;
  end if;
  if intent.id is null or intent.app_account_token is distinct from p_account_token or
     intent.actor_id is distinct from p_actor or
     intent.product_id is distinct from p_product or
     (p_expected_org is not null and intent.org_id is distinct from p_expected_org) or
     p_purchased_at<intent.created_at-interval '2 minutes' then
    raise exception 'RP409: Recover the original credit purchase intent'; end if;
  -- The actor was an owner/admin when this unique Apple token was prepared.
  -- Ask-to-Buy can approve after a later role change; denying settlement then
  -- would strand a charged consumable. The signed token still pins this actor,
  -- product, and original org, and a removed org cannot receive new credit.
  if not exists(select 1 from public.orgs o
      where o.id=intent.org_id and o.deleted_at is null) then
    raise exception 'RP409: The original credit workspace was removed. Contact support for an Apple refund'; end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-wallet:'||intent.org_id||':'||p_environment,71003));
  select exists(select 1 from public.credit_refund_events
      where environment=p_environment and transaction_id=p_transaction) into was_refunded;
  insert into public.credit_purchases(environment,transaction_id,product_id,app_account_token,actor_id,org_id,
      intent_id,credits,apple_purchased_at,apple_signed_at,refunded_at)
    values(p_environment,p_transaction,p_product,p_account_token,p_actor,intent.org_id,intent.id,
      amount,p_purchased_at,p_signed_at,case when was_refunded then now() else null end);
  if not was_refunded then
    insert into public.credit_grants(org_id,environment,source,reference,product_id,
        granted_credits,remaining_credits,expires_at)
      values(intent.org_id,p_environment,'topup',p_transaction,p_product,amount,amount,null);
  end if;
  update public.credit_purchase_intents set state='fulfilled',
      apple_transaction_id=coalesce(apple_transaction_id,p_transaction),
      fulfilled_at=coalesce(fulfilled_at,now()) where id=intent.id;
  return jsonb_build_object('transaction_id',p_transaction,'org_id',intent.org_id,
    'environment',p_environment,'credits_granted',case when was_refunded then 0 else amount end,
    'refunded',was_refunded,'replay',false);
end$$;

create or replace function public.credit_monthly_grant(
  p_actor uuid,p_org uuid,p_product text,p_environment text,p_transaction text,
  p_start timestamptz,p_end timestamptz
) returns jsonb language plpgsql security definer set search_path='' as $$
declare amount integer; existing public.credit_grants; ref text;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_actor is null or p_org is null or p_environment not in('Production','Sandbox') or
     p_transaction is null or length(p_transaction) not between 1 and 200 or
     p_start is null or p_end is null or p_end<=p_start then
    raise exception 'RP400: Verified monthly service period is required'; end if;
  select credits into amount from public.credit_monthly_catalog
    where product_id=p_product and active;
  if amount is null or amount=0 then return jsonb_build_object('granted',false,'reason','not_configured'); end if;
  if not exists(select 1 from public.orgs o join public.memberships m on m.org_id=o.id
      where o.id=p_org and o.deleted_at is null and m.user_id=p_actor and
            m.role in('owner','admin')) then raise exception 'RP403: Current billing workspace required'; end if;
  ref:='apple:'||p_transaction;
  perform pg_advisory_xact_lock(hashtextextended('credit-wallet:'||p_org||':'||p_environment,71003));
  select * into existing from public.credit_grants
    where environment=p_environment and source='monthly' and reference=ref for update;
  if found then
    if existing.org_id is distinct from p_org or existing.product_id is distinct from p_product or
       existing.granted_credits is distinct from amount or existing.starts_at is distinct from p_start or
       existing.expires_at is distinct from p_end then
      raise exception 'RP409: This monthly Apple receipt is already bound'; end if;
    return jsonb_build_object('granted',true,'credits',amount,'replay',true);
  end if;
  insert into public.credit_grants(org_id,environment,source,reference,product_id,
      granted_credits,remaining_credits,starts_at,expires_at)
    values(p_org,p_environment,'monthly',ref,p_product,amount,amount,p_start,p_end);
  return jsonb_build_object('granted',true,'credits',amount,'replay',false);
end$$;

create or replace function public.credit_wallet_state(p_org uuid,p_environment text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare monthly bigint; topup bigint; debt bigint; held bigint;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_org is null or p_environment not in('Production','Sandbox') then
    raise exception 'RP400: Workspace and Apple environment required'; end if;
  select coalesce(sum(remaining_credits)filter(where source='monthly'),0),
         coalesce(sum(remaining_credits)filter(where source='topup'),0)
    into monthly,topup from public.credit_grants
    where org_id=p_org and environment=p_environment and revoked_at is null and
      starts_at<=now() and (expires_at is null or expires_at>now());
  select coalesce(sum(debt_credits),0) into debt from public.credit_refund_debts
    where org_id=p_org and environment=p_environment;
  select coalesce(sum(credits),0) into held from public.credit_holds
    where org_id=p_org and environment=p_environment and state='reserved';
  return jsonb_build_object('org_id',p_org,'environment',p_environment,
    'monthly_available',greatest(0,monthly-debt),
    'topup_available',greatest(0,topup-greatest(0,debt-monthly)),
    'total_available',greatest(0,monthly+topup-debt),
    'held',held,'refund_debt',debt);
end$$;

create or replace function public.credit_wallet_reserve(
  p_actor uuid,p_org uuid,p_environment text,p_key text,p_operation text,p_version text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare price integer; available bigint; wanted integer; grant_row public.credit_grants;
  prior public.credit_holds; hold_id uuid;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_actor is null or p_org is null or p_environment not in('Production','Sandbox') or
     p_key is null or p_key !~ '^[A-Za-z0-9:_-]{8,128}$' then
    raise exception 'RP400: A bounded credit operation is required'; end if;
  if not exists(select 1 from public.orgs o join public.memberships m on m.org_id=o.id
      where o.id=p_org and o.deleted_at is null and m.user_id=p_actor) then
    raise exception 'RP403: Current workspace membership required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-wallet:'||p_org||':'||p_environment,71003));
  select * into prior from public.credit_holds
    where org_id=p_org and environment=p_environment and actor_id=p_actor and request_key=p_key for update;
  if found then
    if prior.operation is distinct from p_operation or prior.tariff_version is distinct from p_version then
      raise exception 'RP409: Credit operation key already used for another request'; end if;
    return jsonb_build_object('reserved',prior.state='reserved','state',prior.state,
      'credits',prior.credits,'hold_id',prior.id,'replay',true);
  end if;
  select credits into price from public.credit_tariffs
    where operation=p_operation and version=p_version and active;
  if price is null then raise exception 'RP400: This credit quote is unavailable'; end if;
  available:=(public.credit_wallet_state(p_org,p_environment)->>'total_available')::bigint;
  if available<price then raise exception 'RP402: Add credits before starting this AI operation'; end if;
  insert into public.credit_holds(org_id,actor_id,environment,request_key,operation,tariff_version,credits)
    values(p_org,p_actor,p_environment,p_key,p_operation,p_version,price) returning id into hold_id;
  wanted:=price;
  for grant_row in
    select * from public.credit_grants where org_id=p_org and environment=p_environment and
      revoked_at is null and remaining_credits>0 and starts_at<=now() and
      (expires_at is null or expires_at>now())
      order by case when source='monthly' then 0 else 1 end,expires_at nulls last,created_at,id
      for update
  loop
    exit when wanted=0;
    insert into public.credit_hold_allocations(hold_id,grant_id,credits)
      values(hold_id,grant_row.id,least(wanted,grant_row.remaining_credits));
    update public.credit_grants set remaining_credits=remaining_credits-least(wanted,grant_row.remaining_credits)
      where id=grant_row.id;
    wanted:=wanted-least(wanted,grant_row.remaining_credits);
  end loop;
  if wanted<>0 then raise exception 'RP503: Credit allocation changed during reservation'; end if;
  return jsonb_build_object('reserved',true,'state','reserved','credits',price,
    'hold_id',hold_id,'replay',false);
end$$;

create or replace function public.credit_wallet_finish(
  p_actor uuid,p_org uuid,p_environment text,p_key text,p_state text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare held public.credit_holds; alloc record; source_grant public.credit_grants;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_state not in('settled','released') then raise exception 'RP400: A terminal credit outcome is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-wallet:'||p_org||':'||p_environment,71003));
  select * into held from public.credit_holds where org_id=p_org and environment=p_environment
    and actor_id=p_actor and request_key=p_key for update;
  if not found then raise exception 'RP404: Credit hold not found'; end if;
  if held.state<>'reserved' then
    if held.state<>p_state then raise exception 'RP409: Credit outcome cannot be rewritten'; end if;
    return jsonb_build_object('state',held.state,'credits',held.credits,'replay',true);
  end if;
  if p_state='released' then
    for alloc in select * from public.credit_hold_allocations where hold_id=held.id loop
      select * into source_grant from public.credit_grants where id=alloc.grant_id for update;
      if source_grant.revoked_at is null then
        update public.credit_grants set remaining_credits=remaining_credits+alloc.credits
          where id=alloc.grant_id;
      elsif source_grant.source='topup' then
        update public.credit_refund_debts set debt_credits=greatest(0,debt_credits-alloc.credits)
          where environment=source_grant.environment and transaction_id=source_grant.reference;
      end if;
    end loop;
  end if;
  update public.credit_holds set state=p_state,finished_at=now() where id=held.id;
  return jsonb_build_object('state',p_state,'credits',held.credits,'replay',false);
end$$;

create or replace function public.credit_purchase_refund(
  p_environment text,p_transaction text,p_evidence_sha256 text,p_revoked_at timestamptz
) returns jsonb language plpgsql security definer set search_path='' as $$
declare purchase public.credit_purchases; source_grant public.credit_grants;
  debt integer;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_environment not in('Production','Sandbox') or p_transaction is null or
     length(p_transaction) not between 1 and 200 or
     p_evidence_sha256 is null or p_evidence_sha256 !~ '^[a-f0-9]{64}$' then
    raise exception 'RP400: Verified Apple refund evidence is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-tx:'||p_environment||':'||p_transaction,71002));
  insert into public.credit_refund_events(environment,transaction_id,evidence_sha256,apple_revoked_at)
    values(p_environment,p_transaction,p_evidence_sha256,p_revoked_at)
    on conflict(environment,transaction_id) do nothing;
  select * into purchase from public.credit_purchases
    where environment=p_environment and transaction_id=p_transaction for update;
  if not found then return jsonb_build_object('refunded',true,'pending_purchase',true); end if;
  if purchase.refunded_at is not null then
    return jsonb_build_object('refunded',true,'pending_purchase',false,'replay',true); end if;
  if purchase.org_id is null then
    update public.credit_purchases set refunded_at=now(),refund_evidence_sha256=p_evidence_sha256
      where environment=p_environment and transaction_id=p_transaction;
    return jsonb_build_object('refunded',true,'workspace_deleted',true); end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-wallet:'||purchase.org_id||':'||p_environment,71003));
  select * into source_grant from public.credit_grants
    where environment=p_environment and source='topup' and reference=p_transaction for update;
  if not found then raise exception 'RP503: Granted credit purchase has no wallet entry'; end if;
  debt:=source_grant.granted_credits-source_grant.remaining_credits;
  update public.credit_grants set revoked_at=now(),remaining_credits=0 where id=source_grant.id;
  insert into public.credit_refund_debts(environment,transaction_id,org_id,debt_credits)
    values(p_environment,p_transaction,purchase.org_id,debt);
  update public.credit_purchases set refunded_at=now(),refund_evidence_sha256=p_evidence_sha256
    where environment=p_environment and transaction_id=p_transaction;
  return jsonb_build_object('refunded',true,'removed_available',source_grant.remaining_credits,
    'debt_credits',debt,'replay',false);
end$$;

revoke all on function public.credit_purchase_intent_create(uuid,uuid,text),
  public.credit_purchase_intent_abandon(uuid,uuid,uuid),
  public.credit_purchase_grant(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,uuid),
  public.credit_monthly_grant(uuid,uuid,text,text,text,timestamptz,timestamptz),
  public.credit_wallet_state(uuid,text),
  public.credit_wallet_reserve(uuid,uuid,text,text,text,text),
  public.credit_wallet_finish(uuid,uuid,text,text,text),
  public.credit_purchase_refund(text,text,text,timestamptz)
  from public,anon,authenticated;
grant execute on function public.credit_purchase_intent_create(uuid,uuid,text),
  public.credit_purchase_intent_abandon(uuid,uuid,uuid),
  public.credit_purchase_grant(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,uuid),
  public.credit_monthly_grant(uuid,uuid,text,text,text,timestamptz,timestamptz),
  public.credit_wallet_state(uuid,text),
  public.credit_wallet_reserve(uuid,uuid,text,text,text,text),
  public.credit_wallet_finish(uuid,uuid,text,text,text),
  public.credit_purchase_refund(text,text,text,timestamptz)
  to service_role;

commit;
