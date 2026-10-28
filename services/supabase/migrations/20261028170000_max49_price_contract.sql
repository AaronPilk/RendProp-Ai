-- Forward-only correction for environments that already applied the dormant
-- $49.99 Max draft. Apple remains at $49.00; no retail flag is activated.
begin;

do $$ begin
  if exists(select 1 from public.credit_monthly_catalog where active)
     or exists(select 1 from public.app_config
               where key='credit_combined_budget' and value->'enabled'='true'::jsonb)
     or exists(select 1 from public.credit_grants
               where environment='Production' and source='monthly') then
    raise exception 'RP409: Review active monthly credits before correcting Max price';
  end if;
  if not exists(select 1 from public.plan_entitlements
                where plan='max' and price_cents in(4900,4999))
     or not exists(select 1 from public.credit_monthly_margin_policy
                   where product_id='com.rendprop.app.starter.monthly'
                     and credits=120 and target_us_price_cents in(4900,4999)
                     and storage_cents=30 and delivery_cents=30
                     and compute_cents=15 and email_cents=5
                     and support_cents=35 and retention_cents=15
                     and uncertainty_cents=20
                     and noncredit_media_floor_cents=100) then
    raise exception 'RP409: Review changed Max catalog or reserve policy';
  end if;
end$$;

update public.plan_entitlements set price_cents=4900 where plan='max';
update public.credit_monthly_margin_policy set target_us_price_cents=4900
 where product_id='com.rendprop.app.starter.monthly';

commit;
