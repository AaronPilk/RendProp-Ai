-- Provisional paid-plan margin authority. It remains dormant until the
-- verified monthly catalog AND this exact policy are independently activated.
-- Reserve the full supplier face of every current monthly credit up front;
-- photos can still use every granted credit after video/assessment spend.
begin;

alter table public.credit_monthly_events
  add column price_milliunits bigint check(price_milliunits>0),
  add column period_start timestamptz,
  add column period_end timestamptz,
  add constraint credit_monthly_price_period check(
    (price_milliunits is null and period_start is null and period_end is null)
    or (price_milliunits is not null and period_start is not null and
        period_end is not null and period_end>period_start));

-- The Apple adapter supplies these facts only from a verified USA/USD JWS.
-- Old rows remain without a price, so they cannot establish new authority.
do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef('public.credit_verified_monthly_apply(uuid,text,text,text,text,timestamptz,timestamptz,bigint,timestamptz,timestamptz,text)'::regprocedure);
  anchor:=E'    insert into public.credit_monthly_events(environment,transaction_id,\n        original_transaction_id,org_id,product_id,state,event_signed_at)\n      values(p_environment,p_transaction,p_original,p_org,p_product,p_event,p_event_signed_at);';
  replacement:=E'    insert into public.credit_monthly_events(environment,transaction_id,\n        original_transaction_id,org_id,product_id,state,event_signed_at,price_milliunits,period_start,period_end)\n      values(p_environment,p_transaction,p_original,p_org,p_product,p_event,p_event_signed_at,\n        case when p_price_milliunits>0 then p_price_milliunits else null end,\n        case when p_price_milliunits>0 then p_start else null end,\n        case when p_price_milliunits>0 then p_end else null end);';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed paid-monthly event write before price snapshot';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='prior.product_id is distinct from p_product then';
  replacement:=E'prior.product_id is distinct from p_product or\n       (prior.price_milliunits is not null and p_price_milliunits is not null and prior.price_milliunits is distinct from p_price_milliunits) or\n       (prior.period_start is not null and prior.period_start is distinct from p_start) or\n       (prior.period_end is not null and prior.period_end is distinct from p_end) then';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed paid-monthly replay guard before price snapshot';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:=E'  if not found or p_event<>''refunded'' then';
  replacement:=E'  -- A catalog toggle alone cannot create an unbudgeted grant.\n  -- Existing signed periods stay on their legacy contract until renewal.\n  if existing.id is null and p_event in(''paid'',''reversed'') and p_environment=''Production'' and\n    not exists(select 1 from public.app_config cfg where cfg.key=''credit_combined_budget''\n      and cfg.value->>''revision''=''credit-combined-v1''\n      and cfg.value->''enabled''=''true''::jsonb\n      and cfg.value->>''activated_from'' is not null\n      and (cfg.value->>''activated_from'')::timestamptz<=p_start) then\n    return jsonb_build_object(''granted'',false,''reason'',''combined_policy_inactive_or_preexisting_period'');\n  end if;\n  if not found or p_event<>''refunded'' then';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed paid-monthly catalog admission';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

insert into public.app_config(key,value) values('credit_combined_budget',
  '{"enabled":false,"revision":"credit-combined-v1","activated_from":null,"supplier_fraction_bps":4500,"conservative_apple_commission_bps":3000,"hosting_reserve_cents":50}')
on conflict(key) do nothing;

create or replace function public.credit_combined_budget_state(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b uuid; policy jsonb; receipt public.credit_monthly_events;
  activated_from timestamptz;
  binding public.apple_subscriptions; face numeric; ceiling numeric; linked numeric;
begin
  -- A SECURITY DEFINER serving-envelope caller can have an authenticated
  -- session role while this function executes as postgres. Direct execution
  -- remains denied by the function grants below.
  if current_user not in('postgres','supabase_admin') then raise insufficient_privilege;end if;
  b:=public.library_billing_org(p_org);
  select value into policy from public.app_config where key='credit_combined_budget';
  if policy is null or policy->'enabled' is distinct from 'true'::jsonb then
    return jsonb_build_object('applicable',false,'reason','policy_dormant');end if;
  if policy->>'revision' is distinct from 'credit-combined-v1' or
    policy->>'supplier_fraction_bps' is distinct from '4500' or
    policy->>'conservative_apple_commission_bps' is distinct from '3000' or
    policy->>'hosting_reserve_cents' is distinct from '50' then
    raise exception 'RP503: Combined credit budget policy changed without review';end if;
  activated_from:=(policy->>'activated_from')::timestamptz;
  if activated_from is null or not pg_catalog.isfinite(activated_from) or
    activated_from>now()+interval '5 minutes' then
    raise exception 'RP503: Combined credit activation date is unavailable';end if;
  select s.* into binding from public.apple_subscriptions s
    where s.org_id=b and s.environment='Production' and s.status='active'
      and s.expires_at>now() order by s.expires_at desc limit 1;
  if binding.original_transaction_id is null then
    return jsonb_build_object('applicable',false,'reason','no_current_paid_subscription');end if;
  select e.* into receipt from public.credit_monthly_events e
    join public.credit_monthly_catalog c on c.product_id=e.product_id and c.active
    join public.credit_grants g on g.org_id=e.org_id and g.environment=e.environment
      and g.source='monthly' and g.reference='apple:'||e.transaction_id
      and g.product_id=e.product_id and g.revoked_at is null
      and g.starts_at=e.period_start and g.expires_at>=e.period_end
    where e.org_id=b and e.environment='Production' and e.state in('paid','reversed')
      and e.original_transaction_id=binding.original_transaction_id
      and e.transaction_id=binding.last_transaction_id
      and e.product_id=binding.product_id and e.period_start<=now()
      and e.period_end=binding.expires_at and e.price_milliunits>0
    limit 1;
  if receipt.transaction_id is null then
    return jsonb_build_object('applicable',false,'reason','no_exact_signed_paid_period');end if;
  if receipt.period_start<activated_from then
    return jsonb_build_object('applicable',false,'reason','pre_activation_paid_period');end if;
  ceiling:=greatest(0,floor((receipt.price_milliunits::numeric/10)
    *0.70*0.45)-50);
  select coalesce(sum(g.granted_credits),0)*5 into face from public.credit_grants g
    where g.org_id=b and g.environment='Production' and g.source='monthly'
      and g.revoked_at is null and g.starts_at<receipt.period_end
      and g.expires_at>receipt.period_start;
  if face>ceiling then
    raise exception 'RP503: Monthly credits exceed the conservative paid supplier budget';end if;
  -- Existing spend counts every cost-ledger row. Add back only a ledger row
  -- conclusively linked to a credit reservation, so top-up purchases remain
  -- independently funded. Unlinked/uncertain rows fail closed as noncredit.
  select coalesce(sum(c.total_cents),0) into linked from public.cost_ledger c
    where c.id in(select r.ledger_id from public.serving_cost_reservations r
      where r.billing_org_id=b and r.budget_source='credits'
        and r.ledger_id is not null)
      and c.billing_org_id=b and c.created_at>=receipt.period_start
      and c.created_at<receipt.period_end;
  return jsonb_build_object('applicable',true,'revision','credit-combined-v1',
    'billing_org_id',b,'product_id',receipt.product_id,
    'transaction_id',receipt.transaction_id,
    'period_start',receipt.period_start,'period_end',receipt.period_end,
    'signed_price_milliunits',receipt.price_milliunits,
    'combined_ceiling_cents',ceiling,'monthly_credit_face_cents',face,
    'noncredit_ceiling_cents',ceiling-face,
    'linked_credit_ledger_cents',linked);
end$$;
revoke all on function public.credit_combined_budget_state(uuid)
  from public,anon,authenticated;
grant execute on function public.credit_combined_budget_state(uuid) to service_role;

-- Preserve whichever plan/quality wrapper exists when integrations apply.
-- The new ceiling applies only to a current, signed paid credit-primary period.
do $patch$ declare definition text; renamed text;begin
  definition:=pg_get_functiondef('public.plan_serving_ceiling(uuid)'::regprocedure);
  renamed:=regexp_replace(definition,'FUNCTION public[.]plan_serving_ceiling[(]',
    'FUNCTION public.plan_serving_ceiling_before_credit(','i');
  if renamed=definition then raise exception 'Review changed plan ceiling signature';end if;
  execute renamed;
end $patch$;
revoke all on function public.plan_serving_ceiling_before_credit(uuid)
  from public,anon,authenticated;
grant execute on function public.plan_serving_ceiling_before_credit(uuid)
  to service_role,postgres;

create or replace function public.plan_serving_ceiling(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare prior jsonb; combined jsonb; start_at timestamptz; end_at timestamptz;
begin
  prior:=public.plan_serving_ceiling_before_credit(p_org);
  if prior->>'kind'<>'retail' then return prior;end if;
  combined:=public.credit_combined_budget_state(p_org);
  if combined->>'applicable'<>'true' then return prior;end if;
  start_at:=(prior->>'period_start')::timestamptz;
  end_at:=(prior->>'period_end')::timestamptz;
  if start_at is distinct from (combined->>'period_start')::timestamptz or
     end_at is distinct from (combined->>'period_end')::timestamptz then
    raise exception 'RP503: Paid credit and plan supplier periods differ';end if;
  return prior||jsonb_build_object(
    'ceiling_cents',(combined->>'noncredit_ceiling_cents')::numeric+
      (combined->>'linked_credit_ledger_cents')::numeric,
    'allowance_policy','credit-combined-v1',
    'combined_supplier_ceiling_cents',combined->'combined_ceiling_cents',
    'monthly_credit_face_cents',combined->'monthly_credit_face_cents',
    'linked_credit_ledger_cents',combined->'linked_credit_ledger_cents');
end$$;
revoke all on function public.plan_serving_ceiling(uuid)
  from public,anon,authenticated;
grant execute on function public.plan_serving_ceiling(uuid) to service_role,postgres;

-- Legacy early COGS preflights use org_month_spend_cents; keep their period
-- aligned with the signed Apple term and exclude independently funded credit
-- ledger rows. The atomic serving envelope above remains the money authority.
do $patch$ declare definition text;anchor text;replacement text;begin
  definition:=pg_get_functiondef('public.org_month_spend_cents(uuid)'::regprocedure);
  anchor:='b:=public.library_billing_org(p_org);';
  replacement:=E'b:=public.library_billing_org(p_org);\n env:=public.plan_serving_ceiling(b);\n if env->>''kind''=''retail'' and env->>''allowance_policy''=''credit-combined-v1'' then\n  ps:=(env->>''period_start'')::timestamptz;pe:=(env->>''period_end'')::timestamptz;\n  if ps is null or pe is null or ps>now() or pe<=now() or ps>=pe then raise exception ''RP503: Current paid credit period is unavailable'';end if;\n  return greatest(0,public.serving_ceiling_spent_cents(b,ps,pe)-(env->>''linked_credit_ledger_cents'')::numeric);\n end if;';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed early paid-month billing org';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='env->>''allowance_policy''=''bounded-paid-quality-v1''';
  replacement:='env->>''allowance_policy'' in(''bounded-paid-quality-v1'',''credit-combined-v1'')';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed early paid-month spend policy';end if;
  definition:=replace(definition,anchor,replacement);
  anchor:='return public.serving_ceiling_spent_cents(b,ps,pe);';
  replacement:='return greatest(0,public.serving_ceiling_spent_cents(b,ps,pe)-case when env->>''allowance_policy''=''credit-combined-v1'' then (env->>''linked_credit_ledger_cents'')::numeric else 0 end);';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed early paid-month spent return';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

create or replace function public.credit_primary_subscription(p_org uuid,p_environment text)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare combined jsonb; prior jsonb;
begin
  if current_setting('role',true)<>'service_role' or p_environment<>'Production'
    then return false;end if;
  combined:=public.credit_combined_budget_state(p_org);
  if combined->>'applicable'<>'true' then return false;end if;
  prior:=public.plan_serving_ceiling_before_credit(p_org);
  return prior->>'kind'='retail' and
    (prior->>'period_start')::timestamptz=(combined->>'period_start')::timestamptz and
    (prior->>'period_end')::timestamptz=(combined->>'period_end')::timestamptz;
end$$;
revoke all on function public.credit_primary_subscription(uuid,text)
  from public,anon,authenticated;
grant execute on function public.credit_primary_subscription(uuid,text)
  to service_role;

commit;
