-- Transactional proof that the first activated paid period can request an
-- exact retail receipt while legacy and Sandbox paths stay dormant.
begin;

do $$begin
  if has_function_privilege('anon',
      'public.credit_paid_funding_route(uuid,text,text,text,bigint,timestamptz)',
      'EXECUTE') or has_function_privilege('authenticated',
      'public.credit_paid_funding_route(uuid,text,text,text,bigint,timestamptz)',
      'EXECUTE') then
    raise exception 'public client can inspect service-only funding route';
  end if;
end$$;

set local role service_role;
do $$begin
  if public.credit_paid_funding_route(
      'c1000000-0000-4000-8000-000000000001',
      'com.rendprop.app.pro29.monthly','gate-chain','gate-paid-1',29990,now())
      is distinct from 'none' then
    raise exception 'dormant credit policy routed a paid sale';
  end if;
end$$;
reset role;

update public.app_config set value=jsonb_build_object(
  'enabled',true,'revision','credit-combined-v2',
  'activated_from',now()-interval '1 day',
  'total_serving_fraction_bps',2500,
  'conservative_apple_commission_bps',3000)
  where key='credit_combined_budget';
update public.credit_monthly_catalog set active=true
  where product_id='com.rendprop.app.pro29.monthly';

set local role service_role;
do $$begin
  if public.credit_paid_funding_route(
      'c1000000-0000-4000-8000-000000000001',
      'com.rendprop.app.pro29.monthly','gate-chain','gate-paid-1',29990,now())
      is distinct from 'activated_paid_period' then
    raise exception 'first paid credit period skipped signed funding';
  end if;
  if public.credit_paid_funding_route(
      'c1000000-0000-4000-8000-000000000001',
      'com.rendprop.app.pro29.monthly','gate-chain','gate-paid-1',29990,
      now()-interval '2 days') is distinct from 'none' then
    raise exception 'preactivation purchase was changed retroactively';
  end if;
  if public.credit_paid_funding_route(
      'c1000000-0000-4000-8000-000000000001',
      'unrecognized-product','gate-chain','gate-paid-1',29990,now())
      is distinct from 'none' then
    raise exception 'unrecognized product reached retail funding';
  end if;
end$$;
reset role;

update public.app_config set value=jsonb_set(value,'{enabled}','false'::jsonb)
  where key='credit_combined_budget';
update public.credit_monthly_catalog set active=false
  where product_id='com.rendprop.app.pro29.monthly';

insert into public.serving_funding(
  org_id,source,collection_ref,net_receipts_cents,sponsored_cents,
  starts_at,ends_at,retention_ends_at,service_months,
  recurring_reserve_cents,reserve_components,evidence_sha256,
  apple_original_transaction_id)
values(
  'c1000000-0000-4000-8000-000000000001','retail','apple:gate-paid-1',
  2099,0,now()-interval '1 hour',now()+interval '29 days',
  now()+interval '119 days',1,100,
  '{"storage":20,"delivery":20,"compute":10,"email":5,"support":25,"retention":10,"uncertainty":10}'::jsonb,
  repeat('a',64),'gate-chain');

set local role service_role;
do $$begin
  if public.credit_paid_funding_route(
      'c1000000-0000-4000-8000-000000000001',
      'com.rendprop.app.pro29.monthly','gate-chain','gate-paid-1',null,now())
      is distinct from 'existing_receipt' then
    raise exception 'retired paid receipt cannot settle a delayed refund';
  end if;
end$$;
reset role;

select 'PASS credit paid ceiling funding gate: 6 assertions';
rollback;
