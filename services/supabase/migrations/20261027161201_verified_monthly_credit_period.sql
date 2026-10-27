-- A monthly credit allowance is minted only from a verified, paid Apple
-- transaction AFTER its entitlement has been bound to the workspace. The
-- catalog deliberately has no launch amounts here; pricing activation is a
-- separate reviewed decision. One Apple period is one grant in one environment.
begin;

create table public.credit_monthly_events (
  environment text not null check (environment in ('Production','Sandbox')),
  transaction_id text not null check (length(transaction_id) between 1 and 200),
  original_transaction_id text not null,
  org_id uuid references public.orgs(id) on delete set null,
  product_id text not null,
  state text not null check (state in ('paid','refunded','reversed')),
  event_signed_at timestamptz not null,
  created_at timestamptz not null default now(),
  primary key (environment,transaction_id)
);
alter table public.credit_monthly_events enable row level security;
revoke all on public.credit_monthly_events from public,anon,authenticated,service_role;
grant select on public.credit_monthly_events to service_role;

create or replace function public.credit_verified_monthly_apply(
  p_org uuid,p_product text,p_environment text,p_original text,p_transaction text,
  p_start timestamptz,p_end timestamptz,p_price_milliunits bigint,
  p_transaction_signed_at timestamptz,p_event_signed_at timestamptz,p_event text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  binding public.apple_subscriptions;
  sandbox_binding public.apple_sandbox_receipts;
  prior public.credit_monthly_events;
  existing public.credit_grants;
  amount integer;
  receipt_ref text;
  is_current boolean:=false;
  chain_active boolean:=false;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege;
  end if;
  if p_org is null or p_product is null or length(p_product) not between 1 and 200 or
     p_environment not in ('Production','Sandbox') or p_original is null or
     length(p_original) not between 1 and 200 or p_transaction is null or
     length(p_transaction) not between 1 and 200 or p_event not in ('paid','refunded','reversed') or
     p_start is null or p_end is null or p_start>=p_end or
     p_transaction_signed_at is null or p_event_signed_at is null or
     not pg_catalog.isfinite(p_start) or not pg_catalog.isfinite(p_end) or
     not pg_catalog.isfinite(p_transaction_signed_at) or not pg_catalog.isfinite(p_event_signed_at) or
     p_start>p_transaction_signed_at+interval '5 minutes' or
     p_transaction_signed_at>now()+interval '5 minutes' or
     p_event_signed_at>now()+interval '5 minutes' then
    raise exception 'RP400: Verified Apple monthly period is required';
  end if;
  if p_event in ('paid','reversed') and (p_price_milliunits is null or p_price_milliunits<=0) then
    return jsonb_build_object('granted',false,'reason','unpaid_period');
  end if;

  -- The same lock used by wallet holds serializes grants and refunds with
  -- spend admission. Apple notifications may lack a current actor, but the
  -- independently verified original subscription binding names this org.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('credit-wallet:'||p_org||':'||p_environment,71003));
  if p_environment='Production' then
    select * into binding from public.apple_subscriptions
      where original_transaction_id=p_original for update;
    if not found or binding.org_id is null then
      return jsonb_build_object('granted',false,'reason','unbound_subscription');
    end if;
    if binding.org_id is distinct from p_org or binding.environment is distinct from p_environment then
      raise exception 'RP409: This Apple subscription belongs to another workspace or environment';
    end if;
    chain_active:=binding.status in ('active','grace');
    is_current:=binding.last_transaction_id=p_transaction and binding.product_id=p_product and
      chain_active;
  else
    select * into sandbox_binding from public.apple_sandbox_receipts
      where original_transaction_id=p_original for update;
    if not found then
      return jsonb_build_object('granted',false,'reason','unbound_subscription');
    end if;
    if sandbox_binding.org_id is distinct from p_org then
      raise exception 'RP409: This Apple test receipt belongs to another workspace';
    end if;
    chain_active:=sandbox_binding.status in ('active','grace');
    is_current:=sandbox_binding.transaction_id=p_transaction and
      sandbox_binding.product_id=p_product and chain_active;
  end if;

  receipt_ref:='apple:'||p_transaction;
  select * into existing from public.credit_grants
    where environment=p_environment and source='monthly' and reference=receipt_ref for update;
  if found and (existing.org_id is distinct from p_org or
                existing.product_id is distinct from p_product or
                existing.starts_at is distinct from p_start) then
    raise exception 'RP409: This monthly Apple receipt is already bound';
  end if;
  if not found and p_event in ('paid','reversed') and not is_current then
    return jsonb_build_object('granted',false,'reason','not_current_paid_period');
  end if;
  if p_event='reversed' and not chain_active then
    return jsonb_build_object('granted',false,'reason','reversal_not_active');
  end if;
  if not found or p_event<>'refunded' then
    select credits into amount from public.credit_monthly_catalog
      where product_id=p_product and active;
    if (amount is null or amount=0) and existing.id is null then
      return jsonb_build_object('granted',false,'reason','not_configured');
    end if;
  end if;

  select * into prior from public.credit_monthly_events
    where environment=p_environment and transaction_id=p_transaction for update;
  if found then
    if prior.org_id is distinct from p_org or
       prior.original_transaction_id is distinct from p_original or
       prior.product_id is distinct from p_product then
      raise exception 'RP409: This monthly Apple event is already bound';
    end if;
    if p_event_signed_at<prior.event_signed_at or
       (p_event_signed_at=prior.event_signed_at and p_event<>prior.state) then
      return jsonb_build_object('granted',false,'reason','stale_apple_event');
    end if;
    -- A later re-signed device receipt cannot undo an Apple refund. Only an
    -- explicit REFUND_REVERSED notification may restore the same period.
    if p_event='paid' and prior.state in ('refunded','reversed') then
      return jsonb_build_object('granted',false,'reason','terminal_apple_event');
    end if;
    if p_event_signed_at>prior.event_signed_at then
      update public.credit_monthly_events set state=p_event,
        event_signed_at=p_event_signed_at
        where environment=p_environment and transaction_id=p_transaction;
    end if;
  else
    insert into public.credit_monthly_events(environment,transaction_id,
        original_transaction_id,org_id,product_id,state,event_signed_at)
      values(p_environment,p_transaction,p_original,p_org,p_product,p_event,p_event_signed_at);
  end if;

  if p_event='refunded' then
    if existing.id is not null then
      update public.credit_grants set revoked_at=coalesce(revoked_at,p_event_signed_at)
        where id=existing.id;
    end if;
    return jsonb_build_object('granted',false,'refunded',true,
      'revoked_grant',existing.id is not null);
  end if;
  if existing.id is not null then
    if p_event='reversed' and existing.revoked_at is not null then
      update public.credit_grants set revoked_at=null where id=existing.id;
    end if;
    -- Apple may extend the same purchased period. Its transaction remains a
    -- single allowance; only the expiry can grow, never the credit quantity.
    if is_current and p_end>existing.expires_at then
      update public.credit_grants set expires_at=p_end where id=existing.id;
    end if;
    return jsonb_build_object('granted',true,'credits',existing.granted_credits,
      'replay',true,'restored',p_event='reversed');
  end if;
  if not is_current then
    return jsonb_build_object('granted',false,'reason','not_current_paid_period');
  end if;
  insert into public.credit_grants(org_id,environment,source,reference,
      product_id,granted_credits,remaining_credits,starts_at,expires_at)
    values(p_org,p_environment,'monthly',receipt_ref,p_product,amount,amount,p_start,p_end);
  return jsonb_build_object('granted',true,'credits',amount,'replay',false);
end$$;

revoke execute on function public.credit_verified_monthly_apply(
  uuid,text,text,text,text,timestamptz,timestamptz,bigint,timestamptz,timestamptz,text)
  from public,anon,authenticated;
grant execute on function public.credit_verified_monthly_apply(
  uuid,text,text,text,text,timestamptz,timestamptz,bigint,timestamptz,timestamptz,text)
  to service_role;

-- Supersede the preliminary actor/org-only mint RPC. Its signature remains in
-- the schema for migration compatibility, but even the Edge service key must
-- use the signed subscription binding and positive-price adapter above.
revoke execute on function public.credit_monthly_grant(
  uuid,uuid,text,text,text,timestamptz,timestamptz) from service_role;

commit;
