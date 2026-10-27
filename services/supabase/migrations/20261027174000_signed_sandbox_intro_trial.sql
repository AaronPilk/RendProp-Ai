-- The TestFlight trial must come from a verified Apple free-intro transaction.
-- This is test-only: it never creates a Production entitlement or turns on the
-- public seven-day offer. Sponsor and per-workspace serving limits still apply.
begin;

do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef('public.grant_sandbox_trial(uuid,uuid,text,text,text,text,timestamptz,timestamptz)'::regprocedure);
  anchor:='current_plan in(''starter'',''solo'',''pro'',''team'',''brokerage'')';
  replacement:='current_plan in(''starter'',''solo'',''pro'',''max'',''ultra'',''team'',''brokerage'')';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Sandbox paid-workspace protection';end if;
  execute replace(definition,anchor,replacement);
end $patch$;

create or replace function public.grant_sandbox_intro_trial(
 p_org uuid,p_actor uuid,p_original text,p_transaction text,p_product text,
 p_status text,p_expires_at timestamptz,p_signed_at timestamptz,
 p_purchased_at timestamptz,p_price_milliunits bigint,p_currency text,
 p_storefront text,p_offer_type integer,p_offer_discount_type text,
 p_app_account_token uuid,p_product_type text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare verdict jsonb; pool jsonb; remaining numeric;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 if public.serving_mode()<>'ceiling' then
   raise exception 'RP403: Sandbox trials require ceiling serving mode';end if;
 if p_product not in('com.rendprop.app.pro29.monthly',
   'com.rendprop.app.starter.monthly','com.rendprop.app.pro.monthly',
   'com.rendprop.app.team.monthly') or
   p_price_milliunits is distinct from 0 or p_currency is distinct from 'USD' or
   p_storefront is distinct from 'USA' or p_offer_type is distinct from 1 or
   p_offer_discount_type is distinct from 'FREE_TRIAL' or
   p_app_account_token is distinct from p_actor or
   p_product_type is distinct from 'Auto-Renewable Subscription' or
   p_purchased_at is null or not pg_catalog.isfinite(p_purchased_at) or
   p_signed_at is null or not pg_catalog.isfinite(p_signed_at) or
   p_expires_at is null or not pg_catalog.isfinite(p_expires_at) or
   p_purchased_at>now()+interval '5 minutes' or
   p_signed_at<p_purchased_at-interval '5 minutes' or
   p_expires_at<=p_purchased_at or
   p_expires_at>p_purchased_at+interval '7 days 5 minutes' then
   raise exception 'RP400: Signed seven-day Sandbox free-intro evidence is required';end if;
 -- Serialize the new trial against sponsored supplier holds. A replay or a
 -- paid workspace leaves the sponsor allocation unchanged.
 perform pg_catalog.pg_advisory_xact_lock(
   pg_catalog.hashtextextended('serving:trial-sponsor',72452));
 verdict:=public.grant_sandbox_trial(p_org,p_actor,p_original,p_transaction,
   p_product,p_status,p_expires_at,p_signed_at);
 if (verdict->>'granted')::boolean then
   pool:=public.trial_sponsor_pool();
   if pool is null or now()<(pool->>'starts_at')::timestamptz or
     (pool->>'ends_at')::timestamptz<=now()+interval '7 days' then
     raise exception 'RP402: Test-trial sponsor allocation is closed or too short';end if;
   remaining:=(pool->>'cap_cents')::numeric-public.trial_sponsor_spent_cents();
   if remaining<500 then
     raise exception 'RP402: Test-trial sponsor allocation has less than one trial envelope';end if;
 end if;
 return verdict;
end$$;
revoke all on function public.grant_sandbox_intro_trial(uuid,uuid,text,text,text,text,
  timestamptz,timestamptz,timestamptz,bigint,text,text,integer,text,uuid,text)
  from public,anon,authenticated;
grant execute on function public.grant_sandbox_intro_trial(uuid,uuid,text,text,text,text,
  timestamptz,timestamptz,timestamptz,bigint,text,text,integer,text,uuid,text)
  to service_role;

commit;
