-- A StoreKit price quote alone cannot open a Team seat charge. The public
-- paywall may show a variant only to a currently paid Team owner when its
-- exact SKU, wallet, margin, media and Apple funding schedule are active.
-- No catalog flag, cash receipt, or Apple product is activated here.
begin;

create or replace function public.team_seat_sale_products(p_org uuid)
returns text[] language plpgsql stable security definer set search_path='' as $$
declare products text[];
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege;
  end if;
  if p_org is null or not exists(
    select 1 from public.orgs o
    join public.apple_subscriptions sub on sub.org_id=o.id
      and sub.product_id=o.apple_product_id
      and sub.expires_at=o.plan_expires_at
    join public.serving_funding paid on paid.org_id=o.id
      and paid.source='retail' and paid.revoked_at is null
      and paid.apple_original_transaction_id=sub.original_transaction_id
      and paid.collection_ref='apple:'||sub.last_transaction_id
      and paid.starts_at<=now() and paid.ends_at>now()
    where o.id=p_org and o.deleted_at is null and o.plan='team'
      and o.plan_source='apple' and sub.environment='Production'
      and sub.status='active' and sub.expires_at>now()
      and sub.last_transaction_id is not null
  ) then return array[]::text[];end if;

  select coalesce(array_agg(distinct v.product_id order by v.product_id),array[]::text[])
    into products
    from public.team_paid_seat_variants v
    join public.credit_monthly_catalog c on c.product_id=v.product_id
      and c.active and c.credits=v.monthly_credits
    join public.credit_monthly_margin_policy margin on margin.product_id=v.product_id
      and margin.credits=v.monthly_credits
      and margin.target_us_price_cents=v.target_us_price_cents
    join public.paid_media_budget_policy media on media.product_id=v.product_id
      and media.enabled and media.activated_from<=now()
      and media.account_reserve_ref is not null
      and media.evidence_sha256 is not null
    join public.media_account_reserves account on account.receipt_ref=media.account_reserve_ref
      and account.cash_source='business_paid_cash'
      and account.starts_at<=now()
      and account.ends_at>now()+interval '121 days'
    join public.apple_serving_schedules schedule on schedule.product_id=v.product_id
      and schedule.storefront='USA' and schedule.currency='USD'
      and schedule.service_months=1
      and schedule.price_milliunits=v.target_us_price_cents::bigint*10
      and schedule.starts_at<=now() and schedule.ends_at>now()+interval '7 days'
    join public.app_config policy on policy.key='credit_combined_budget'
      and policy.value->'enabled'='true'::jsonb
      and policy.value->>'revision'='credit-combined-v2'
      and (policy.value->>'activated_from')::timestamptz<=now()
    where v.active
      and not exists(select 1 from public.subscription_trial_media_template trial
        where trial.singleton and trial.account_reserve_ref=account.receipt_ref)
      and public.serving_reserve_total(schedule.reserve_components) is not null
      and (schedule.reserve_components->>'storage')::integer>=margin.storage_cents
      and (schedule.reserve_components->>'delivery')::integer>=margin.delivery_cents
      and (schedule.reserve_components->>'compute')::integer>=margin.compute_cents
      and (schedule.reserve_components->>'email')::integer>=margin.email_cents
      and (schedule.reserve_components->>'support')::integer>=margin.support_cents
      and (schedule.reserve_components->>'retention')::integer>=margin.retention_cents
      and (schedule.reserve_components->>'uncertainty')::integer>=margin.uncertainty_cents
      and floor(least(
        floor((schedule.price_milliunits::numeric/10)*0.70),
        schedule.net_proceeds_floor_cents)::numeric*0.25)
        >=public.serving_reserve_total(schedule.reserve_components)
          +margin.credits*5+margin.noncredit_media_floor_cents;
  return products;
end$$;
revoke all on function public.team_seat_sale_products(uuid)
  from public,anon,authenticated;
grant execute on function public.team_seat_sale_products(uuid) to service_role;

commit;
