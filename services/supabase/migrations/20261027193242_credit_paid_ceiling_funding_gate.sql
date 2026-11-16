-- A paid credit period needs the exact retail serving receipt even when the
-- rest of the launch continues in ceiling mode. Do not turn funded mode on
-- globally: existing paid subscriptions may have no attested schedule yet.
begin;

create or replace function public.credit_paid_funding_route(
  p_org uuid,p_product text,p_original text,p_transaction text,
  p_price_milliunits bigint,p_purchased_at timestamptz
) returns text language plpgsql stable security definer
set search_path='' set timezone='UTC' as $$
declare policy jsonb;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege;
  end if;
  if p_org is null or p_product is null or p_original is null or
     p_transaction is null or p_purchased_at is null then return 'none';end if;

  -- Preserve refund and refund-reversal settlement after a SKU or its sale
  -- policy has been retired. A prior receipt must never become invisible.
  if exists(select 1 from public.serving_funding f
      where f.org_id=p_org and f.source='retail'
        and (f.apple_original_transaction_id=p_original or
             f.collection_ref='apple:'||p_transaction)) then return 'existing_receipt';end if;

  select value into policy from public.app_config
    where key='credit_combined_budget';
  if policy is null or policy->'enabled' is distinct from 'true'::jsonb or
     policy->>'revision' is distinct from 'credit-combined-v2' or
     policy->>'activated_from' is null or
     p_purchased_at < (policy->>'activated_from')::timestamptz or
     coalesce(p_price_milliunits,0)<=0 then return 'none';end if;

  if exists(select 1 from public.credit_monthly_catalog c
    where c.product_id=p_product and c.active) then
    return 'activated_paid_period';
  end if;
  return 'none';
end$$;

revoke all on function public.credit_paid_funding_route(
  uuid,text,text,text,bigint,timestamptz) from public,anon,authenticated;
grant execute on function public.credit_paid_funding_route(
  uuid,text,text,text,bigint,timestamptz) to service_role;

commit;
