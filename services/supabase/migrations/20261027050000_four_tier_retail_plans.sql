-- Four retail tiers. This is a forward-only catalog and authority migration;
-- Apple transaction IDs, funding rows, cost holds and trial history stay put.
-- The new Pro product must be created in App Store Connect before sale. Existing
-- $49 Starter, $99 Pro and $249 Team IDs continue to restore and renew, now
-- displayed as Max, Ultra and Team. The target .99 prices are catalog targets;
-- serving below caps the legacy SKUs at their currently verified lower prices.
-- Monthly customer credit grants are installed separately by the credit ledger
-- migration, only on verified paid terms. No credits are granted here.
begin;

alter table public.orgs drop constraint if exists orgs_plan_check;
alter table public.orgs add constraint orgs_plan_check
  check (plan in ('trial','free','solo','starter','legacy_pro','pro','max','ultra','team','brokerage'));
alter table public.ai_routes drop constraint if exists ai_routes_min_plan_check;
alter table public.ai_routes add constraint ai_routes_min_plan_check
  check (min_plan in ('free','trial','starter','solo','legacy_pro','pro','max','ultra','team','brokerage'));

-- An existing Pro-only route meant the old $99 tier. Move that threshold to
-- Ultra before the new $29.99 Pro can use the same public plan string. Keep
-- Starter gates intact so historical manual Starter/solo access survives.
update public.ai_routes set min_plan='ultra' where min_plan='pro';

-- Keep the exact old Pro allowance for non-Apple grants. The old Starter and
-- solo rows also remain untouched for historical/manual workspaces.
insert into public.plan_entitlements
  (plan,renders_per_month,photo_edits_per_month,reels_per_month,aerials_per_month,
   topaz_per_month,seats,cogs_ceiling_cents,price_cents)
select 'legacy_pro',renders_per_month,photo_edits_per_month,reels_per_month,
       aerials_per_month,topaz_per_month,seats,cogs_ceiling_cents,price_cents
  from public.plan_entitlements where plan='pro'
on conflict (plan) do nothing;

insert into public.plan_entitlements
  (plan,renders_per_month,photo_edits_per_month,reels_per_month,aerials_per_month,
   topaz_per_month,seats,cogs_ceiling_cents,price_cents)
values
  ('max',   4,100, 30,2,0,1, 2032, 4999),
  ('ultra',10,200, 60,4,0,1, 4157, 9999)
on conflict (plan) do update set
  renders_per_month=excluded.renders_per_month,
  photo_edits_per_month=excluded.photo_edits_per_month,
  reels_per_month=excluded.reels_per_month,
  aerials_per_month=excluded.aerials_per_month,
  topaz_per_month=excluded.topaz_per_month,
  seats=excluded.seats,cogs_ceiling_cents=excluded.cogs_ceiling_cents,
  price_cents=excluded.price_cents;
update public.plan_entitlements set
  renders_per_month=2,photo_edits_per_month=50,reels_per_month=15,
  aerials_per_month=1,topaz_per_month=0,seats=1,
  cogs_ceiling_cents=1200,price_cents=2999 where plan='pro';
update public.plan_entitlements set seats=3,price_cents=24999 where plan='team';

-- Preserve manual Pro's original service grant. Apple-owned rows move only
-- when the current recorded SKU and old plan agree; an expired/free org stays
-- free. apple_subscriptions is a current chain snapshot, not an event ledger.
update public.orgs set plan='legacy_pro'
 where plan='pro' and plan_source is distinct from 'apple';
update public.apple_subscriptions set plan='max'
 where product_id in ('com.rendprop.app.starter.monthly','com.rendprop.app.starter.annual')
   and plan='starter';
update public.apple_subscriptions set plan='ultra'
 where product_id in ('com.rendprop.app.pro.monthly','com.rendprop.app.pro.annual')
   and plan='pro';
update public.orgs set plan='max'
 where plan_source='apple' and plan='starter'
   and apple_product_id in ('com.rendprop.app.starter.monthly','com.rendprop.app.starter.annual');
update public.orgs set plan='ultra'
 where plan_source='apple' and plan='pro'
   and apple_product_id in ('com.rendprop.app.pro.monthly','com.rendprop.app.pro.annual');

-- Preserve any operator policy already selected for the old tiers before
-- reusing `pro` for the lower-price product. New Pro routes conservatively.
insert into public.plan_routing_policy(plan,policy)
select v.target,coalesce((select old.policy from public.plan_routing_policy old
                           where old.plan=v.source),v.fallback)
  from (values ('max','starter','cheapest'),('ultra','pro','best'),
               ('legacy_pro','pro','best')) as v(target,source,fallback)
on conflict(plan) do nothing;
insert into public.plan_routing_policy(plan,policy) values ('pro','cheapest')
on conflict(plan) do update set policy=excluded.policy;

-- Rewrite only reviewed allowlist/price expressions in the latest function
-- bodies. The helper rejects a changed or missing anchor instead of replacing
-- an unrelated protection, and is session-local to this migration.
create or replace function pg_temp.rewrite_plan_function(
  p_signature text,p_old text,p_new text,p_expected integer default 1)
returns void language plpgsql as $$
declare definition text;body text;hits integer;
begin
  select pg_get_functiondef(oid),prosrc into definition,body
    from pg_proc where oid=p_signature::regprocedure;
  if definition is null then raise exception 'Missing plan function %',p_signature;end if;
  if position(p_new in body)>0 then return;end if;
  hits:=(length(body)-length(replace(body,p_old,'')))/length(p_old);
  if hits=p_expected then execute replace(definition,p_old,p_new);return;end if;
  raise exception 'Review changed plan function %: expected % anchor(s), found %',p_signature,p_expected,hits;
end$$;

select pg_temp.rewrite_plan_function('public.org_entitlement(uuid)',
  $$('starter','solo','pro','team')$$,
  $$('starter','solo','legacy_pro','pro','max','ultra','team')$$,2);
select pg_temp.rewrite_plan_function('public.plan_serving_ceiling_before_team(uuid)',
  $$in('starter','solo','pro','team')$$,
  $$in('starter','solo','legacy_pro','pro','max','ultra','team')$$);
select pg_temp.rewrite_plan_function('public.hosting_retention_state_before_team(uuid)',
  $$in('starter','solo','pro','team')$$,
  $$in('starter','solo','legacy_pro','pro','max','ultra','team')$$);
select pg_temp.rewrite_plan_function('public.subscription_trial_paid_or_override_before_team(uuid)',
  $$in('starter','pro','team')$$,
  $$in('starter','legacy_pro','pro','max','ultra','team')$$,2);
select pg_temp.rewrite_plan_function('public.org_has_verified_retail_guest(uuid,uuid)',
  $$in('starter','pro','team')$$,
  $$in('starter','legacy_pro','pro','max','ultra','team')$$);
select pg_temp.rewrite_plan_function('public.grant_sandbox_trial(uuid,uuid,text,text,text,text,timestamptz,timestamptz)',
  $$in('starter','solo','pro','team','brokerage')$$,
  $$in('starter','solo','legacy_pro','pro','max','ultra','team','brokerage')$$);
select pg_temp.rewrite_plan_function('public.upload_new_admission(uuid,uuid,bigint)',
  $$not in('starter','pro','team')$$,
  $$not in('starter','legacy_pro','pro','max','ultra','team')$$);
select pg_temp.rewrite_plan_function('public.paid_quality_processing_budget(uuid)',
  $$not in('starter','solo','pro','team')$$,
  $$not in('starter','solo','legacy_pro','pro','max','ultra','team')$$);
select pg_temp.rewrite_plan_function('public.prepare_subscription_trial_purchase(uuid,uuid,text)',
  $$p_product not in('com.rendprop.app.starter.monthly'$$,
  $$p_product not in('com.rendprop.app.pro29.monthly','com.rendprop.app.starter.monthly'$$);
select pg_temp.rewrite_plan_function('public.admin_cohorts(interval,text)',
  $$in ('starter','solo','pro','team')$$,
  $$in ('starter','solo','legacy_pro','pro','max','ultra','team')$$);
select pg_temp.rewrite_plan_function('public.ops_health_findings()',
  $$in('starter','solo','pro','team')$$,
  $$in('starter','solo','legacy_pro','pro','max','ultra','team')$$);

-- Subscription terms from existing SKUs still reflect $49/$99/$249 until
-- App Store Connect is deliberately repriced. Never infer more funded service
-- from the target .99 price on a current legacy transaction.
select pg_temp.rewrite_plan_function('public.plan_serving_ceiling_before_team(uuid)',
  $$monthly_net numeric;envelope integer;sku text;trial_cap integer;$$,
  $$monthly_net numeric;envelope integer;sku text;billed_price integer;trial_cap integer;$$);
select pg_temp.rewrite_plan_function('public.plan_serving_ceiling_before_team(uuid)',
  $$sku:=o.apple_product_id;annual:=coalesce(sku,'')like '%.annual';$$,
  $$sku:=o.apple_product_id;annual:=coalesce(sku,'')like '%.annual';
  billed_price:=case
    when sku in('com.rendprop.app.starter.monthly','com.rendprop.app.starter.annual') then least(e.price_cents,4900)
    when sku in('com.rendprop.app.pro.monthly','com.rendprop.app.pro.annual') then least(e.price_cents,9900)
    when sku in('com.rendprop.app.team.monthly','com.rendprop.app.team.annual') then least(e.price_cents,24900)
    else coalesce(e.price_cents,0) end;$$);
select pg_temp.rewrite_plan_function('public.plan_serving_ceiling_before_team(uuid)',
  $$coalesce(e.price_cents,0)*10.0$$,$$billed_price*10.0$$);
select pg_temp.rewrite_plan_function('public.plan_serving_ceiling_before_team(uuid)',
  $$coalesce(e.price_cents,0)*(10000-commission)$$,$$billed_price*(10000-commission)$$);

-- This optional, disabled-by-default quality subsidy must not disappear for
-- remapped old subscriptions. Max and Ultra reuse their old policy values;
-- the new lower-price Pro is capped even if an operator enables the policy.
select pg_temp.rewrite_plan_function('public.paid_quality_processing_budget(uuid)',
  $$selected_plan text;amount numeric;quality boolean:=false;$$,
  $$selected_plan text;budget_key text;amount numeric;quality boolean:=false;$$);
select pg_temp.rewrite_plan_function('public.paid_quality_processing_budget(uuid)',
  $$if jsonb_typeof(c->(selected_plan||'_cents'))$$,
  $$budget_key:=case selected_plan when 'max' then 'starter_cents' when 'ultra' then 'pro_cents' when 'legacy_pro' then 'pro_cents' else selected_plan||'_cents' end;
 if jsonb_typeof(c->budget_key)$$);
select pg_temp.rewrite_plan_function('public.paid_quality_processing_budget(uuid)',
  $$amount:=(c->>(selected_plan||'_cents'))::numeric;$$,
  $$amount:=(c->>budget_key)::numeric;
 if selected_plan='pro' then amount:=least(amount,3500);end if;$$);

-- Reassert the original service-only function grants after CREATE OR REPLACE.
revoke all on function public.org_entitlement(uuid),
  public.plan_serving_ceiling_before_team(uuid),
  public.hosting_retention_state_before_team(uuid),
  public.subscription_trial_paid_or_override_before_team(uuid),
  public.org_has_verified_retail_guest(uuid,uuid),
  public.grant_sandbox_trial(uuid,uuid,text,text,text,text,timestamptz,timestamptz),
  public.upload_new_admission(uuid,uuid,bigint),
  public.paid_quality_processing_budget(uuid),
  public.prepare_subscription_trial_purchase(uuid,uuid,text),
  public.admin_cohorts(interval,text),public.ops_health_findings()
  from public,anon,authenticated;
grant execute on function public.org_entitlement(uuid) to authenticated,service_role,postgres;
grant execute on function public.plan_serving_ceiling_before_team(uuid),
  public.hosting_retention_state_before_team(uuid),
  public.subscription_trial_paid_or_override_before_team(uuid),
  public.paid_quality_processing_budget(uuid),
  public.ops_health_findings() to service_role,postgres;
grant execute on function public.admin_cohorts(interval,text) to service_role;
grant execute on function public.org_has_verified_retail_guest(uuid,uuid),
  public.grant_sandbox_trial(uuid,uuid,text,text,text,text,timestamptz,timestamptz),
  public.upload_new_admission(uuid,uuid,bigint),
  public.prepare_subscription_trial_purchase(uuid,uuid,text) to service_role;

commit;
