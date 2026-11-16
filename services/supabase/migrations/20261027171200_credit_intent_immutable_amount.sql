-- A delayed Ask-to-Buy approval is a charged purchase, even if the pack is
-- later retired or its credit quantity changes. Snapshot the advertised pack
-- quantity before StoreKit opens; settlement uses that immutable commitment.
begin;

alter table public.credit_purchase_intents add column credits integer;
update public.credit_purchase_intents i set credits=p.credits
  from public.credit_products p where p.product_id=i.product_id;
alter table public.credit_purchase_intents alter column credits set not null;
alter table public.credit_purchase_intents add constraint credit_intent_amount_bound
  check(credits between 1 and 1000000);
create unique index credit_purchase_one_transaction_per_intent
  on public.credit_purchases(intent_id) where intent_id is not null;

create or replace function public.credit_purchase_intent_create(
  p_actor uuid,p_org uuid,p_product text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare old public.credit_purchase_intents; iid uuid; token uuid; amount integer;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_actor is null or p_org is null or p_product is null then
    raise exception 'RP400: A selected workspace and credit product are required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('credit-intent:'||p_actor||':'||p_product,71001));
  select credits into amount from public.credit_products where product_id=p_product and active;
  if amount is null then raise exception 'RP400: This credit pack is unavailable'; end if;
  if not exists(select 1 from public.orgs o join public.memberships m on m.org_id=o.id
      where o.id=p_org and o.deleted_at is null and m.user_id=p_actor and m.role in('owner','admin')) then
    raise exception 'RP403: Only a current workspace owner or admin can buy credits'; end if;
  if public.library_billing_org(p_org) is distinct from p_org then
    raise exception 'RP403: Buy credits from the Team billing workspace'; end if;
  select * into old from public.credit_purchase_intents
    where actor_id=p_actor and org_id=p_org and product_id=p_product and
      state='open' and created_at>now()-interval '1 minute'
    order by created_at desc limit 1 for update;
  if found then
    return jsonb_build_object('intent_id',old.id,'org_id',old.org_id,
      'product_id',old.product_id,'credits',old.credits,
      'app_account_token',old.app_account_token,'created_at',old.created_at,'replay',true);
  end if;
  insert into public.credit_purchase_intents(actor_id,org_id,product_id,credits)
    values(p_actor,p_org,p_product,amount) returning id,app_account_token into iid,token;
  return jsonb_build_object('intent_id',iid,'org_id',p_org,
    'product_id',p_product,'credits',amount,'app_account_token',token,
    'created_at',now(),'replay',false);
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
  if intent.apple_transaction_id is not null and intent.apple_transaction_id<>p_transaction then
    raise exception 'RP409: This purchase intent already settled another Apple transaction'; end if;
  amount:=intent.credits;
  if amount is null or amount<=0 then raise exception 'RP409: Original credit pack quantity unavailable'; end if;
  -- The actor was an owner/admin when this unique Apple token was prepared.
  -- Later Ask-to-Buy approval still belongs to that actor and original org.
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

commit;
