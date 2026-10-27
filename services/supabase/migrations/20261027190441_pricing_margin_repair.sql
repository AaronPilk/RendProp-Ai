-- Dormant launch repricing. No Apple product, retail activation, or cash
-- attestation is created here. A paid period must have an exact signed JWS,
-- matching retail funding, and reserves that fit the 75% net-receipts floor.
begin;

-- The Apple adapter maps these identifiers, but the service-only writer must
-- never trust a caller-supplied plan. Historical $49/$99 product IDs are Max
-- and Ultra even though their names still say starter/pro.
create function public.apple_sold_plan_for_product(p_product_id text)
returns text language sql immutable set search_path='' as $$
  select case
    when p_product_id='com.rendprop.app.pro29.monthly' then 'pro'
    when p_product_id in('com.rendprop.app.starter.monthly',
      'com.rendprop.app.starter.annual') then 'max'
    when p_product_id in('com.rendprop.app.pro.monthly',
      'com.rendprop.app.pro.annual') then 'ultra'
    when p_product_id in('com.rendprop.app.team.monthly',
      'com.rendprop.app.team.annual',
      'com.rendprop.app.team4.monthly','com.rendprop.app.team5.monthly',
      'com.rendprop.app.team6.monthly','com.rendprop.app.team7.monthly',
      'com.rendprop.app.team8.monthly','com.rendprop.app.team9.monthly') then 'team'
    else null end
$$;
revoke all on function public.apple_sold_plan_for_product(text)
  from public,anon,authenticated;
grant execute on function public.apple_sold_plan_for_product(text)
  to service_role,postgres;

do $patch$ declare definition text;anchor text;replacement text;begin
  definition:=pg_get_functiondef('public.apply_apple_entitlement_v2(uuid,uuid,text,text,text,text,text,text,timestamptz,boolean,text,timestamptz,timestamptz,timestamptz,timestamptz)'::regprocedure);
  anchor:='  if p_original_transaction_id is null or btrim(p_original_transaction_id)=';
  replacement:=E'  if public.apple_sold_plan_for_product(p_product_id) is null or\n'
    ||E'     p_plan is distinct from public.apple_sold_plan_for_product(p_product_id) then\n'
    ||E'    raise exception ''RP400: Apple product and plan disagree'';\n'
    ||E'  end if;\n'||anchor;
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Apple entitlement plan mapping';end if;
  execute replace(definition,anchor,replacement);
end$patch$;

do $$ begin
  if exists(select 1 from public.credit_monthly_catalog where active)
     or exists(select 1 from public.team_paid_seat_variants where active)
     or exists(select 1 from public.app_config where key='credit_combined_budget'
       and value->'enabled'='true'::jsonb) then
    raise exception 'RP409: Review active retail credits before repricing';
  end if;
  if exists(select 1 from public.credit_purchases where environment='Production') then
    raise exception 'RP409: Review existing paid credit packs before repricing';
  end if;
  if exists(select 1 from public.credit_grants
      where environment='Production' and source='monthly') then
    raise exception 'RP409: Review existing paid monthly credit balances before repricing';
  end if;
end$$;

update public.credit_monthly_catalog set credits=case product_id
  when 'com.rendprop.app.pro29.monthly' then 60
  when 'com.rendprop.app.starter.monthly' then 120
  when 'com.rendprop.app.pro.monthly' then 250
  when 'com.rendprop.app.team.monthly' then 600
  else credits end
where product_id in('com.rendprop.app.pro29.monthly','com.rendprop.app.starter.monthly',
  'com.rendprop.app.pro.monthly','com.rendprop.app.team.monthly');

alter table public.team_paid_seat_variants
  drop constraint team_paid_seat_variants_monthly_credits_check,
  drop constraint team_paid_seat_variants_check;
update public.team_paid_seat_variants
  set monthly_credits=600+100*(seats-3);
alter table public.team_paid_seat_variants
  add constraint team_paid_seat_variants_monthly_credits_check
    check(monthly_credits between 700 and 1200),
  add constraint team_paid_seat_variants_check
    check(monthly_credits=600+100*(seats-3));
update public.credit_monthly_catalog c set credits=v.monthly_credits
  from public.team_paid_seat_variants v where c.product_id=v.product_id;

-- Required monthly cash reserves are explicit minimums for all seven funded
-- serving categories. The signed schedule may reserve more, never less.
create table public.credit_monthly_margin_policy(
  product_id text primary key references public.credit_monthly_catalog(product_id),
  credits integer not null check(credits>0),
  target_us_price_cents integer not null check(target_us_price_cents>0),
  storage_cents integer not null check(storage_cents>=0),
  delivery_cents integer not null check(delivery_cents>=0),
  compute_cents integer not null check(compute_cents>=0),
  email_cents integer not null check(email_cents>=0),
  support_cents integer not null check(support_cents>=0),
  retention_cents integer not null check(retention_cents>=0),
  uncertainty_cents integer not null check(uncertainty_cents>=0),
  noncredit_media_floor_cents integer not null check(noncredit_media_floor_cents>0)
);
insert into public.credit_monthly_margin_policy values
 ('com.rendprop.app.pro29.monthly',60,2999,20,20,10,5,25,10,10,100),
 ('com.rendprop.app.starter.monthly',120,4999,30,30,15,5,35,15,20,100),
 ('com.rendprop.app.pro.monthly',250,9999,50,50,25,10,60,25,30,200),
 ('com.rendprop.app.team.monthly',600,24999,100,100,50,25,125,50,50,500);
insert into public.credit_monthly_margin_policy
select product_id,monthly_credits,target_us_price_cents,
  100+15*(seats-3),100+20*(seats-3),50+10*(seats-3),
  25+5*(seats-3),125+35*(seats-3),50+5*(seats-3),
  50+10*(seats-3),500+100*(seats-3)
from public.team_paid_seat_variants;
alter table public.credit_monthly_margin_policy enable row level security;
revoke all on public.credit_monthly_margin_policy from public,anon,authenticated,service_role;
grant select on public.credit_monthly_margin_policy to service_role;

-- The existing 100-credit identifier is retained because ASC has not created
-- it. Preparing a new top-up is closed until its $39.99 price is verified.
alter table public.credit_products add column target_price_milliunits bigint,
  add column operating_reserve_cents integer,
  add column verified_net_proceeds_floor_cents bigint
    check(verified_net_proceeds_floor_cents>=0),
  add column proceeds_evidence_sha256 text
    check(proceeds_evidence_sha256 ~ '^[a-f0-9]{64}$');
update public.credit_products set target_price_milliunits=39990,
  operating_reserve_cents=190,verified_net_proceeds_floor_cents=null,
  proceeds_evidence_sha256=null,active=false
  where product_id='com.rendprop.app.credits.100' and credits=100;
alter table public.credit_products
  add constraint credit_pack_margin_policy check(
    target_price_milliunits is null or
    (operating_reserve_cents is not null and operating_reserve_cents>=0 and
     credits*5+operating_reserve_cents<=
       floor((target_price_milliunits::numeric/10)*0.70*0.25))),
  add constraint credit_pack_activation_requires_proceeds check(
    product_id<>'com.rendprop.app.credits.100' or not active or
    (credits=100 and target_price_milliunits is not null and
     target_price_milliunits=39990 and operating_reserve_cents is not null and
     operating_reserve_cents=190 and
     verified_net_proceeds_floor_cents is not null and
     proceeds_evidence_sha256 is not null and
     credits*5+operating_reserve_cents<=floor(
       least(verified_net_proceeds_floor_cents::numeric,
         (target_price_milliunits::numeric/10)*0.70)*0.25)));

-- Only a reviewed, collected retail schedule can turn a signed monthly term
-- into spendable credits. The lesser of attested net cash and 70% of the
-- signed price funds the 25% all-serving envelope. The rest is margin.
create function public.credit_monthly_margin_allocation(
  p_org uuid,p_product text,p_original text,p_transaction text,
  p_price_milliunits bigint,p_start timestamptz,p_end timestamptz
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare terms public.credit_monthly_margin_policy;
  funding public.serving_funding;
  signed_net bigint;net_floor bigint;total_budget bigint;required_reserve integer;
  remaining bigint;
begin
  if current_user not in('postgres','supabase_admin') then raise insufficient_privilege;end if;
  select * into terms from public.credit_monthly_margin_policy where product_id=p_product;
  if terms.product_id is null or p_price_milliunits is null or p_price_milliunits<=0
     or p_price_milliunits is distinct from terms.target_us_price_cents::bigint*10
     or p_start is null or p_end is null or p_start>=p_end
     or not exists(select 1 from public.credit_monthly_catalog c
         where c.product_id=p_product and c.active and c.credits=terms.credits) then
    return jsonb_build_object('applicable',false,'reason','unreviewed_credit_catalog');
  end if;
  select f.* into funding
    from public.serving_funding f
    join public.apple_serving_schedules sc on sc.product_id=p_product
      and sc.storefront='USA' and sc.currency='USD'
      and sc.evidence_sha256=f.evidence_sha256
      and sc.net_proceeds_floor_cents=f.net_receipts_cents
      and sc.price_milliunits=p_price_milliunits
      and sc.starts_at<=p_start and sc.ends_at>p_start
    where f.org_id=p_org and f.source='retail' and f.revoked_at is null
      and f.collection_ref='apple:'||p_transaction
      and f.apple_original_transaction_id=p_original
      and f.starts_at=p_start and f.ends_at=p_end and f.service_months=1
    limit 1;
  if funding.id is null then
    return jsonb_build_object('applicable',false,'reason','no_exact_attested_paid_funding');
  end if;
  required_reserve:=terms.storage_cents+terms.delivery_cents+terms.compute_cents+
    terms.email_cents+terms.support_cents+terms.retention_cents+terms.uncertainty_cents;
  if public.serving_reserve_total(funding.reserve_components) is distinct from funding.recurring_reserve_cents
     or funding.recurring_reserve_cents<required_reserve
     or coalesce((funding.reserve_components->>'storage')::integer,-1)<terms.storage_cents
     or coalesce((funding.reserve_components->>'delivery')::integer,-1)<terms.delivery_cents
     or coalesce((funding.reserve_components->>'compute')::integer,-1)<terms.compute_cents
     or coalesce((funding.reserve_components->>'email')::integer,-1)<terms.email_cents
     or coalesce((funding.reserve_components->>'support')::integer,-1)<terms.support_cents
     or coalesce((funding.reserve_components->>'retention')::integer,-1)<terms.retention_cents
     or coalesce((funding.reserve_components->>'uncertainty')::integer,-1)<terms.uncertainty_cents then
    return jsonb_build_object('applicable',false,'reason','insufficient_serving_reserve');
  end if;
  signed_net:=floor((p_price_milliunits::numeric/10)*0.70)::bigint;
  net_floor:=least(signed_net,funding.net_receipts_cents);
  total_budget:=floor(net_floor::numeric*0.25)::bigint;
  remaining:=total_budget-funding.recurring_reserve_cents-terms.credits*5;
  if remaining<terms.noncredit_media_floor_cents then
    return jsonb_build_object('applicable',false,'reason','insufficient_noncredit_media_budget');
  end if;
  return jsonb_build_object('applicable',true,'net_floor_cents',net_floor,
    'total_serving_budget_cents',total_budget,
    'operating_reserve_cents',funding.recurring_reserve_cents,
    'supplier_ceiling_cents',total_budget-funding.recurring_reserve_cents,
    'credit_face_cents',terms.credits*5,
    'noncredit_media_cents',remaining,
    'noncredit_media_floor_cents',terms.noncredit_media_floor_cents);
end$$;
revoke all on function public.credit_monthly_margin_allocation(
  uuid,text,text,text,bigint,timestamptz,timestamptz)
  from public,anon,authenticated;
grant execute on function public.credit_monthly_margin_allocation(
  uuid,text,text,text,bigint,timestamptz,timestamptz)
  to service_role,postgres;

update public.app_config set value='{"enabled":false,"revision":"credit-combined-v2","activated_from":null,"total_serving_fraction_bps":2500,"conservative_apple_commission_bps":3000}'::jsonb
  where key='credit_combined_budget' and value->'enabled'='false'::jsonb;

-- Migrate the dormant policy revision through its protected callers. The new
-- allocation helper performs the actual cash and reserve checks.
do $patch$ declare definition text;anchor text;replacement text;begin
 definition:=pg_get_functiondef('public.credit_verified_monthly_apply_before_seat_variants(uuid,text,text,text,text,timestamptz,timestamptz,bigint,timestamptz,timestamptz,text)'::regprocedure);
 anchor:='cfg.value->>''revision''=''credit-combined-v1''';
 replacement:='cfg.value->>''revision''=''credit-combined-v2''';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'Review changed monthly credit policy gate';end if;
 definition:=replace(definition,anchor,replacement);
 anchor:='  if not found or p_event<>''refunded'' then';
 replacement:=E'  if existing.id is null and p_environment=''Production'' and p_event in(''paid'',''reversed'')\n'
   ||E'     and exists(select 1 from public.credit_monthly_catalog c where c.product_id=p_product and c.active)\n'
   ||E'     and public.credit_monthly_margin_allocation(p_org,p_product,p_original,p_transaction,p_price_milliunits,p_start,p_end)->>''applicable'' is distinct from ''true'' then\n'
   ||E'    return jsonb_build_object(''granted'',false,''reason'',''paid_funding_unavailable'');\n'
   ||E'  end if;\n'||anchor;
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
   raise exception 'Review changed monthly credit funding gate';end if;
 execute replace(definition,anchor,replacement);
end$patch$;

do $patch$ declare definition text;anchor text;replacement text;begin
 definition:=pg_get_functiondef('public.credit_combined_budget_state(uuid)'::regprocedure);
 anchor:='policy->>''revision'' is distinct from ''credit-combined-v1''';
 replacement:='policy->>''revision'' is distinct from ''credit-combined-v2''';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then raise exception 'Review changed combined policy revision';end if;
 definition:=replace(definition,anchor,replacement);
 anchor:='policy->>''supplier_fraction_bps'' is distinct from ''4500''';
 replacement:='policy->>''total_serving_fraction_bps'' is distinct from ''2500''';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then raise exception 'Review changed combined fraction';end if;
 definition:=replace(definition,anchor,replacement);
 anchor:=E' or\n    policy->>''hosting_reserve_cents'' is distinct from ''50''';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then raise exception 'Review changed combined reserve anchor';end if;
 definition:=replace(definition,anchor,'');
 anchor:=E'  ceiling:=greatest(0,floor((receipt.price_milliunits::numeric/10)\n    *0.70*0.45)-50);';
 replacement:=E'  allocation:=public.credit_monthly_margin_allocation(b,receipt.product_id,\n'
  ||E'    receipt.original_transaction_id,receipt.transaction_id,receipt.price_milliunits,\n'
  ||E'    receipt.period_start,receipt.period_end);\n'
  ||E'  if allocation->>''applicable'' is distinct from ''true'' then return allocation;end if;\n'
  ||E'  ceiling:=(allocation->>''supplier_ceiling_cents'')::numeric;';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then raise exception 'Review changed combined cash ceiling';end if;
 definition:=replace(definition,anchor,replacement);
 anchor:='  activated_from timestamptz;';
 replacement:='  activated_from timestamptz;allocation jsonb;';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then raise exception 'Review changed combined declarations';end if;
 definition:=replace(definition,anchor,replacement);
 anchor:='  if face>ceiling then';
 replacement:='  if face is distinct from (allocation->>''credit_face_cents'')::numeric then';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then raise exception 'Review changed credit-face check';end if;
 definition:=replace(definition,anchor,replacement);
 anchor:='''revision'',''credit-combined-v1''';
 replacement:='''revision'',''credit-combined-v2''';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then raise exception 'Review changed returned policy revision';end if;
 definition:=replace(definition,anchor,replacement);
 anchor:='''combined_ceiling_cents'',ceiling,';
 replacement:='''combined_ceiling_cents'',ceiling,''net_floor_cents'',allocation->''net_floor_cents'',''total_serving_budget_cents'',allocation->''total_serving_budget_cents'',''operating_reserve_cents'',allocation->''operating_reserve_cents'',''noncredit_media_floor_cents'',allocation->''noncredit_media_floor_cents'',';
 if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then raise exception 'Review changed combined return fields';end if;
 execute replace(definition,anchor,replacement);
end$patch$;

do $patch$ declare signature text;definition text;anchor text;replacement text;begin
 for signature in select unnest(array['public.plan_serving_ceiling(uuid)',
   'public.org_month_spend_cents(uuid)']) loop
   definition:=pg_get_functiondef(signature::regprocedure);
   anchor:='credit-combined-v1';replacement:='credit-combined-v2';
   if position(anchor in definition)=0 then raise exception 'Review changed credit policy caller %',signature;end if;
   definition:=replace(definition,anchor,replacement);
   if signature='public.plan_serving_ceiling(uuid)' then
     anchor:='  if combined->>''applicable''<>''true'' then return prior;end if;';
     replacement:=E'  if combined->>''applicable'' is distinct from ''true'' then\n'
       ||E'    if exists(select 1 from public.credit_grants g\n'
       ||E'      where g.org_id=public.library_billing_org(p_org)\n'
       ||E'        and g.environment=''Production'' and g.source=''monthly''\n'
       ||E'        and g.revoked_at is null and g.starts_at<=now()\n'
       ||E'        and g.expires_at>now()) then\n'
       ||E'      raise exception ''RP503: Current paid credit funding is unavailable'';\n'
       ||E'    end if;\n'
       ||E'    return prior;\n'
       ||E'  end if;';
     if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
       raise exception 'Review changed paid credit fallback';end if;
     definition:=replace(definition,anchor,replacement);
   end if;
   execute definition;
 end loop;
end$patch$;

-- A top-up is 100 credits at an exact $39.99 signed USA price. The old
-- service-only signature is hidden; both device and notification adapters
-- supply Apple's signed price, storefront, and currency to this wrapper.
alter function public.credit_purchase_grant(
  uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,uuid)
  rename to credit_purchase_grant_before_margin;
revoke all on function public.credit_purchase_grant_before_margin(
  uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,uuid)
  from public,anon,authenticated,service_role;
create function public.credit_purchase_grant(
  p_actor uuid,p_expected_org uuid,p_intent uuid,p_product text,
  p_environment text,p_transaction text,p_purchased_at timestamptz,
  p_signed_at timestamptz,p_account_token uuid,p_price_milliunits bigint,
  p_currency text,p_storefront text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare pack public.credit_products;intent public.credit_purchase_intents;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
  select * into pack from public.credit_products where product_id=p_product;
  select * into intent from public.credit_purchase_intents
    where app_account_token=p_account_token;
  if pack.product_id is null or intent.id is null or intent.credits<>100
     or pack.target_price_milliunits is distinct from 39990
     or pack.operating_reserve_cents is distinct from 190
     or pack.verified_net_proceeds_floor_cents is null
     or pack.proceeds_evidence_sha256 is null
     or 100*5+pack.operating_reserve_cents>floor(least(
       pack.verified_net_proceeds_floor_cents::numeric,
       (pack.target_price_milliunits::numeric/10)*0.70)*0.25) then
    raise exception 'RP409: Credit pack has no reviewed margin policy';end if;
  if p_price_milliunits is distinct from pack.target_price_milliunits
     or p_currency is distinct from 'USD' or p_storefront is distinct from 'USA'
     or p_signed_at is null or p_signed_at>now()+interval '5 minutes' then
    raise exception 'RP409: Signed Apple credit price or storefront differs from reviewed policy';end if;
  return public.credit_purchase_grant_before_margin(p_actor,p_expected_org,p_intent,
    p_product,p_environment,p_transaction,p_purchased_at,p_signed_at,p_account_token);
end$$;
revoke all on function public.credit_purchase_grant(
  uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,uuid,bigint,text,text)
  from public,anon,authenticated;
grant execute on function public.credit_purchase_grant(
  uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,uuid,bigint,text,text)
  to service_role;

commit;
