-- New signed, paid monthly periods must finance finite media delivery and
-- retained bytes. Earlier paid/manual terms and private QA keep their existing
-- service behavior. Nothing here activates a product or allocates cash.
begin;
do $$begin
 if to_regprocedure('public.fund_verified_apple_transaction_before_paid_media_20261027(uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)') is not null
 then raise exception 'Review paid media budget cap already installed';end if;
end$$;

-- Separate, independently evidenced business cash can cover the same actual
-- Cloudflare account period as the <=$500 trial account reserve. Each receipt
-- remains immutable, uniquely evidenced, and spends only its own balance.
do $patch$declare d text;a text;b text;begin
 d:=pg_get_functiondef('public.provision_media_account_reserve(text,text,text,text,timestamptz,timestamptz,bigint,jsonb,jsonb)'::regprocedure);
 a:='if exists(select 1 from public.media_account_reserves where cash_evidence_sha256=p_evidence or account_id=p_account and starts_at<p_end and ends_at>p_start)then';
 b:='if exists(select 1 from public.media_account_reserves where cash_evidence_sha256=p_evidence)then';
 if (length(d)-length(replace(d,a,'')))/length(a)<>1 then raise exception 'Review changed account cash overlap guard';end if;
 execute replace(d,a,b);
end$patch$;

-- SKU-specific finite limits are source policy, not paid cash. The operator
-- must bind each launch SKU to an actual separate business-cash account receipt
-- and its tariff before turning on the shared credit sale policy.
create table public.paid_media_budget_policy(
 product_id text primary key references public.credit_monthly_margin_policy(product_id),
 enabled boolean not null default false,
 activated_from timestamptz,
 account_reserve_ref text references public.media_account_reserves(receipt_ref),
 request_limit bigint not null check(request_limit between 1000 and 100000),
 byte_limit bigint not null check(byte_limit between 1073741824 and 10995116277760),
 storage_limit bigint not null check(storage_limit between 1073741824 and 1099511627776),
 evidence_sha256 text check(evidence_sha256~'^[a-f0-9]{64}$'),
 check(not enabled or (activated_from is not null and account_reserve_ref is not null and evidence_sha256 is not null))
);
insert into public.paid_media_budget_policy(product_id,request_limit,byte_limit,storage_limit)
select m.product_id,
 case when v.seats is not null then 10000+1500*(v.seats-3)
      when m.product_id='com.rendprop.app.pro29.monthly' then 2000
      when m.product_id='com.rendprop.app.starter.monthly' then 3000
      when m.product_id='com.rendprop.app.pro.monthly' then 5000
      else 10000 end,
 case when v.seats is not null then (100+20*(v.seats-3))::bigint*1073741824
      when m.product_id='com.rendprop.app.pro29.monthly' then 10::bigint*1073741824
      when m.product_id='com.rendprop.app.starter.monthly' then 20::bigint*1073741824
      when m.product_id='com.rendprop.app.pro.monthly' then 40::bigint*1073741824
      else 100::bigint*1073741824 end,
 case when v.seats is not null then (10+2*(v.seats-3))::bigint*1073741824
      when m.product_id='com.rendprop.app.pro29.monthly' then 2::bigint*1073741824
      when m.product_id='com.rendprop.app.starter.monthly' then 3::bigint*1073741824
      when m.product_id='com.rendprop.app.pro.monthly' then 5::bigint*1073741824
      else 10::bigint*1073741824 end
from public.credit_monthly_margin_policy m
left join public.team_paid_seat_variants v on v.product_id=m.product_id;
alter table public.paid_media_budget_policy enable row level security;
revoke all on public.paid_media_budget_policy from public,anon,authenticated,service_role;
grant select on public.paid_media_budget_policy to service_role;

-- A signed URL to R2 bypasses the media admission ledger entirely. The
-- signer must refuse that fallback as soon as this billing workspace has ever
-- carried a paid media budget, including after a plan downgrade or refund.
create function public.paid_media_gateway_required(p_org uuid) returns boolean
language plpgsql stable security definer set search_path='' as $$
declare billing uuid;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 if p_org is null then raise exception 'RP400: Media workspace required';end if;
 billing:=public.library_billing_org(p_org);
 if billing is null then raise exception 'RP404: Billing workspace unavailable';end if;
 return exists(select 1 from public.media_delivery_budgets b
  where b.org_id=billing and b.receipt_ref like 'paid-media:%');
end$$;
revoke all on function public.paid_media_gateway_required(uuid) from public,anon,authenticated;
grant execute on function public.paid_media_gateway_required(uuid) to service_role;

-- The signed Apple adapter and entitlement chronology are upstream of this
-- function. Keep their current exact-receipt checks intact, then provision
-- media in the same transaction as its new retail funding. A failed budget
-- rolls back the new funding instead of issuing an uncosted paid allowance.
alter function public.fund_verified_apple_transaction(uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)
 rename to fund_verified_apple_transaction_before_paid_media_20261027;
create function public.fund_verified_apple_transaction(
 p_org uuid,p_original text,p_transaction text,p_product text,p_price_milliunits bigint,
 p_currency text,p_storefront text,p_offer_type integer,p_offer_discount_type text,
 p_purchased_at timestamptz,p_expires_at timestamptz,p_signed_at timestamptz,p_evidence_sha256 text
)returns jsonb language plpgsql security definer set search_path='' set timezone='UTC' as $$
declare result jsonb;policy public.paid_media_budget_policy;funding public.serving_funding;
 account public.media_account_reserves;budget public.media_delivery_budgets;media_ref text;media_result jsonb;
 combined jsonb;trial_ref text;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 result:=public.fund_verified_apple_transaction_before_paid_media_20261027(
  p_org,p_original,p_transaction,p_product,p_price_milliunits,p_currency,p_storefront,
  p_offer_type,p_offer_discount_type,p_purchased_at,p_expires_at,p_signed_at,p_evidence_sha256);
 if result->>'funded' is distinct from 'true' or coalesce(p_price_milliunits,0)<=0 then return result;end if;
 select value into combined from public.app_config where key='credit_combined_budget';
 if combined->>'revision' is distinct from 'credit-combined-v2'
  or combined->>'activated_from' is null
  or p_purchased_at<(combined->>'activated_from')::timestamptz
  or not exists(select 1 from public.credit_monthly_catalog c where c.product_id=p_product and c.active)
 then return result;end if;
 media_ref:='paid-media:'||pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p_transaction,'UTF8')),'hex');
 select * into funding from public.serving_funding where id=(result->>'funding_id')::uuid for update;
 if funding.id is null or funding.org_id is distinct from p_org or funding.source<>'retail'
  or funding.collection_ref is distinct from 'apple:'||p_transaction
  or funding.apple_original_transaction_id is distinct from p_original
  or funding.starts_at is distinct from p_purchased_at or funding.ends_at is distinct from p_expires_at
  or funding.revoked_at is not null then raise exception 'RP402: Exact paid media funding is unavailable';end if;
 select * into budget from public.media_delivery_budgets where receipt_ref=media_ref;
 if budget.id is not null then
  if budget.org_id is distinct from p_org or budget.funding_id is distinct from funding.id then
   raise exception 'RP409: Paid media receipt belongs to another purchase';end if;
  return result||jsonb_build_object('media_budget_id',budget.id,'media_budget_replay',true);
 end if;
 if result->>'replay'='true' then raise exception 'RP402: Paid media budget missing from accepted receipt';end if;
 select * into policy from public.paid_media_budget_policy where product_id=p_product for share;
 if policy.product_id is null or not policy.enabled or policy.activated_from is null
  or policy.activated_from>p_purchased_at or policy.account_reserve_ref is null
  or policy.evidence_sha256 is null then raise exception 'RP402: Paid media limits and account cash are unavailable';end if;
 select * into account from public.media_account_reserves where receipt_ref=policy.account_reserve_ref;
 select account_reserve_ref into trial_ref from public.subscription_trial_media_template where singleton;
 if account.receipt_ref is null or account.cash_source<>'business_paid_cash'
  or account.receipt_ref is not distinct from trial_ref or account.starts_at>funding.starts_at
  or account.ends_at<funding.retention_ends_at then
  raise exception 'RP402: Separate business-paid media account reserve required';end if;
 media_result:=public.provision_media_delivery_budget(
  p_org,media_ref,funding.id,funding.starts_at,funding.retention_ends_at,
  policy.request_limit,policy.byte_limit,policy.storage_limit,account.tariff,
  jsonb_build_object('delivery',funding.reserve_components->'delivery',
   'compute',funding.reserve_components->'compute',
   'storage',funding.reserve_components->'storage',
   'retention',funding.reserve_components->'retention'),
  policy.evidence_sha256,policy.account_reserve_ref);
 return result||jsonb_build_object('media_budget_id',media_result->>'id','media_budget_replay',false);
end$$;
revoke all on function public.fund_verified_apple_transaction(uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text),
 public.fund_verified_apple_transaction_before_paid_media_20261027(uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)
 from public,anon,authenticated;
grant execute on function public.fund_verified_apple_transaction(uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text),
 public.fund_verified_apple_transaction_before_paid_media_20261027(uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text) to service_role;

-- Only a period that carries this new immutable paid budget uses the bounded
-- pre-October-15 request/byte ledger. A downgrade or refund cannot restore an
-- unmetered public path simply by changing an app-config toggle. Manual and
-- older paid/QA requests retain their existing read behavior.
alter function public.media_delivery_admit(uuid,bigint,boolean)
 rename to media_delivery_admit_before_paid_media_20261027;
create function public.media_delivery_admit(p_org uuid,p_bytes bigint,p_required boolean default true)
returns jsonb language plpgsql security definer set search_path='' as $$
declare billing uuid;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 if p_org is null or p_bytes is null or p_bytes not between 0 and 268435456 or p_required is null then
  raise exception 'RP400: Invalid media admission';end if;
 billing:=public.library_billing_org(p_org);
 if billing is null then raise exception 'RP404: Billing workspace unavailable';end if;
 if exists(select 1 from public.media_delivery_budgets b where b.org_id=billing and b.receipt_ref like 'paid-media:%') then
  return public.media_delivery_admit_before_owner_testing_20261015(billing,p_bytes,p_required);
 end if;
 return public.media_delivery_admit_before_paid_media_20261027(p_org,p_bytes,p_required);
end$$;
revoke all on function public.media_delivery_admit(uuid,bigint,boolean),
 public.media_delivery_admit_before_paid_media_20261027(uuid,bigint,boolean)
 from public,anon,authenticated;
grant execute on function public.media_delivery_admit(uuid,bigint,boolean),
 public.media_delivery_admit_before_paid_media_20261027(uuid,bigint,boolean) to service_role;

commit;
