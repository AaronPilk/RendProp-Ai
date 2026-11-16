-- Explicit bounded launch subsidy for quality workflows, NOT new customer fees.
-- OFF until reviewed activation. No counters, receipts, ledger rows or holds reset.
begin;
insert into public.app_config(key,value)values('paid_quality_processing',
 '{"enabled":false,"policy":"bounded-paid-quality-v1","starter_cents":6500,"solo_cents":6500,"pro_cents":12000,"team_cents":30000,"note":"Owner-authorized bounded monthly processing subsidy while reviewed quality profiles are active. Existing spend and uncertain holds count. No customer price change; no guaranteed margin."}')
on conflict(key)do nothing;

-- Pure eligibility/read helper; never journals, sponsors or reserves money.
-- It intentionally avoids org_entitlement/plan_serving_ceiling recursion.
create or replace function public.paid_quality_processing_budget(p_org uuid)returns integer language plpgsql stable security definer set search_path=''as $$
declare b uuid;o public.orgs;s public.apple_subscriptions;c jsonb;v jsonb;p jsonb;selected_plan text;amount numeric;quality boolean:=false;begin
 if public.serving_mode()<>'ceiling'then return 0;end if;
 select value into c from public.app_config where key='paid_quality_processing';
 if c is null or c->'enabled'='false'::jsonb then return 0;end if;
 if c->'enabled' is distinct from 'true'::jsonb or c->>'policy' is distinct from 'bounded-paid-quality-v1'then raise exception'RP503: Paid processing policy is unavailable';end if;
 select value into v from public.app_config where key='property_video_quality';
 quality:=coalesce(v->'enabled'='true'::jsonb and v->>'profile'='fal-kling3-4k-v1',false);
 select value into p from public.app_config where key='photo_preservation_quality';
 if p->'enabled'='true'::jsonb and p->>'profile'='gemini-pro-4k-preservation-v1'and jsonb_typeof(p->'tasks')='array'then
  if jsonb_array_length(p->'tasks')between 1 and 2 and(p->'tasks')<@'["photo.stage","photo.declutter"]'::jsonb
   and(select count(distinct x)=jsonb_array_length(p->'tasks')from jsonb_array_elements_text(p->'tasks')x)then quality:=true;end if;
 end if;
 if not quality then return 0;end if;
 b:=public.library_billing_org(p_org);select *into o from public.orgs where id=b and deleted_at is null;
 if o.id is null or o.plan_source is distinct from'apple'or o.plan_expires_at is null or o.plan_expires_at<=now()then return 0;end if;
 selected_plan:=public.effective_plan_before_team(b);
 if selected_plan not in('starter','solo','pro','team')or public.org_has_app_review_funding(b)then return 0;end if;
 select *into s from public.apple_subscriptions where org_id=b and environment='Production'and status='active'
  and product_id=o.apple_product_id and plan=selected_plan and expires_at=o.plan_expires_at and expires_at>now()
  and transaction_purchased_at is not null and transaction_purchased_at<=now()and transaction_signed_at is not null
  and expires_at>transaction_purchased_at+interval'8 days'order by expires_at desc limit 1;
 if s.original_transaction_id is null then return 0;end if;
 if jsonb_typeof(c->(selected_plan||'_cents'))is distinct from'number'then raise exception'RP503: Paid processing allowance is unavailable';end if;
 amount:=(c->>(selected_plan||'_cents'))::numeric;
 if amount<>trunc(amount)or amount<1 or amount>100000 then raise exception'RP503: Paid processing allowance is unavailable';end if;
 return amount::integer;
end$$;
revoke all on function public.paid_quality_processing_budget(uuid)from public,anon,authenticated;
grant execute on function public.paid_quality_processing_budget(uuid)to service_role,postgres;

-- Fail closed against unseen production changes; replays accept only OUR new body.
do $$begin
 if(select md5(prosrc)from pg_proc where oid='public.org_entitlement(uuid)'::regprocedure)not in('302e587671c7d110bdd772146f2a4d66','55223b9a9c6c8076705887f974257f2e') then raise exception'Review changed org_entitlement before paid quality allowance';end if;
 if(select md5(prosrc)from pg_proc where oid='public.plan_serving_ceiling(uuid)'::regprocedure)not in('d8ce26365f93ff96a8a9e129987990f9','fdc33f6975a4cfad628602722cc7964e') then raise exception'Review changed plan_serving_ceiling before paid quality allowance';end if;
 if(select md5(prosrc)from pg_proc where oid='public.org_month_spend_cents(uuid)'::regprocedure)not in('992057729d438565dd88d2c71303e2e4','3ef6fcbbe8aa4c70942ef2d8ef2e8d09')then raise exception'Review changed org_month_spend_cents before paid quality allowance';end if;
end$$;
create or replace function public.org_entitlement(p_org uuid)returns public.plan_entitlements language plpgsql stable security definer set search_path=''as $$
declare e public.plan_entitlements;b uuid;budget integer;begin b:=public.library_billing_org(p_org);e:=public.org_entitlement_before_team(b);
 if public.library_internal_content_unlimited(p_org)then e.plan:='team';e.price_cents:=0;e.seats:=1;e.renders_per_month:=2147483647;e.photo_edits_per_month:=2147483647;e.reels_per_month:=2147483647;e.aerials_per_month:=2147483647;e.topaz_per_month:=2147483647;e.cogs_ceiling_cents:=2147483647;elsif b<>p_org then e.seats:=1;end if;
 budget:=public.paid_quality_processing_budget(b);e.cogs_ceiling_cents:=greatest(e.cogs_ceiling_cents,budget);return e;end$$;
create or replace function public.plan_serving_ceiling(p_org uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare b uuid;env jsonb;budget integer;begin b:=public.library_billing_org(p_org);env:=public.plan_serving_ceiling_before_team(b);budget:=public.paid_quality_processing_budget(b);
 if budget>0 and env->>'kind'='retail'and env->>'window'in('apple_term','apple_slice')then
  env:=env||jsonb_build_object('ceiling_cents',greatest((env->>'ceiling_cents')::numeric,budget),'allowance_policy','bounded-paid-quality-v1','allowance_basis','bounded_paid_quality_launch','receipt_based_ceiling_cents',(env->>'ceiling_cents')::numeric,'paid_quality_floor_cents',budget);
 end if;return env;end$$;
revoke all on function public.org_entitlement(uuid),public.plan_serving_ceiling(uuid)from public,anon,authenticated;
grant execute on function public.org_entitlement(uuid)to authenticated,service_role,postgres;
grant execute on function public.plan_serving_ceiling(uuid)to service_role,postgres;

-- Same authoritative paid month for the legacy COGS gate and the atomic wallet.
-- The canonical spent query keeps unresolved holds across all period rollovers.
create or replace function public.org_month_spend_cents(p_org uuid)returns numeric language plpgsql stable security definer set search_path=''as $$
declare b uuid;env jsonb;ps timestamptz;pe timestamptz;begin
 if not(current_setting('role',true)in('service_role','postgres','supabase_admin')or(session_user=current_user and current_setting('role',true)='none')or public.library_content_access(auth.uid(),p_org,false))then return 0;end if;
 b:=public.library_billing_org(p_org);
 if public.paid_quality_processing_budget(b)>0 then
  env:=public.plan_serving_ceiling(b);
  if env->>'kind'='retail'and env->>'allowance_policy'='bounded-paid-quality-v1'and env->>'window'in('apple_term','apple_slice')then
   ps:=(env->>'period_start')::timestamptz;pe:=(env->>'period_end')::timestamptz;
   if ps is null or pe is null or ps>now()or pe<=now()or ps>=pe then raise exception'RP503: Current paid processing period is unavailable';end if;
   return public.serving_ceiling_spent_cents(b,ps,pe);
  end if;
 end if;
 return public.serving_ceiling_spent_cents(b,date_trunc('month',now()),date_trunc('month',now())+interval'1 month');
end$$;
revoke all on function public.org_month_spend_cents(uuid)from public,anon,authenticated;
grant execute on function public.org_month_spend_cents(uuid)to authenticated,service_role,postgres;
commit;
