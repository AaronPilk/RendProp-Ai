-- Do not activate the seven-day offer here. Before any StoreKit sheet opens,
-- cash must be committed in a dated sponsor pool and each live USA SKU needs
-- an inclusive seven-day schedule. This read-only audit exposes those gates.
begin;

do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef('public.prepare_subscription_trial_purchase(uuid,uuid,text)'::regprocedure);
  anchor:='p_product not in(''com.rendprop.app.starter.monthly''';
  replacement:='p_product not in(''com.rendprop.app.pro29.monthly'',''com.rendprop.app.starter.monthly''';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed trial purchase SKU allowlist before Pro29 admission';
  end if;
  execute replace(definition,anchor,replacement);
end $patch$;

create or replace function public.subscription_trial_activation_readiness()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.subscription_trial_config; runtime_pool jsonb; runtime_cap bigint;
  runtime_end timestamptz; runtime_ready boolean:=false; runtime_spent numeric:=0;
  wanted text; missing text[]:=array[]::text[]; schedule_ok boolean;
  committed bigint; available bigint:=0; bounded boolean;
  products text[]:=array['com.rendprop.app.pro29.monthly',
    'com.rendprop.app.starter.monthly','com.rendprop.app.pro.monthly',
    'com.rendprop.app.team.monthly'];
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  select * into c from public.subscription_trial_config where singleton;
  bounded:=c.singleton is true and c.walkthroughs=1 and c.photo_edits=5 and
    c.published_listings=1 and c.max_days=7 and c.max_video_seconds<=90 and
    c.upload_budget_bytes<=1073741824;
  runtime_pool:=public.trial_sponsor_pool();
  if runtime_pool is not null and
     coalesce(runtime_pool->>'cap_cents','') ~ '^[0-9]{1,10}$' and
     coalesce(runtime_pool->>'ends_at','') ~ '^20[0-9]{2}-' then
    begin
      runtime_cap:=(runtime_pool->>'cap_cents')::bigint;
      runtime_end:=(runtime_pool->>'ends_at')::timestamptz;
      runtime_spent:=public.trial_sponsor_spent_cents();
      runtime_ready:=runtime_cap>runtime_spent and runtime_end>now()+interval '7 days';
    exception when invalid_text_representation or datetime_field_overflow then
      runtime_ready:=false;
    end;
  end if;
  for wanted in select unnest(products) loop
    select exists(
      select 1 from public.apple_serving_schedules s
      join public.serving_sponsor_pools p on p.id=s.trial_pool_id
      where s.product_id=wanted and s.storefront='USA' and s.currency='USD'
        and s.starts_at<=now() and s.ends_at>now()+interval '7 days'
        and s.trial_days=7 and s.trial_sponsored_cents>0
        and public.serving_reserve_total(s.trial_reserve_components)<s.trial_sponsored_cents
        and p.source='trial' and p.admissions_enabled and
          p.starts_at<=now() and p.ends_at>now()+interval '7 days'
        and p.funded_cents-(
          select coalesce(sum(f.sponsored_cents),0) from public.serving_funding f
          where f.sponsor_pool_id=p.id)-(
          select coalesce(sum(h.sponsored_cents),0)
          from public.subscription_trial_purchase_reservations h
          where h.pool_id=p.id and h.funding_id is null
        )>=s.trial_sponsored_cents
    ) into schedule_ok;
    if not schedule_ok then missing:=array_append(missing,wanted); end if;
  end loop;
  select coalesce(max(p.funded_cents-(
      select coalesce(sum(f.sponsored_cents),0) from public.serving_funding f
      where f.sponsor_pool_id=p.id)-(
      select coalesce(sum(h.sponsored_cents),0)
      from public.subscription_trial_purchase_reservations h
      where h.pool_id=p.id and h.funding_id is null)),0)
    into available from public.serving_sponsor_pools p
    where p.source='trial' and p.admissions_enabled and
      p.starts_at<=now() and p.ends_at>now()+interval '7 days';
  return jsonb_build_object(
    'currently_enabled',c.enabled,
    'bounded_terms',bounded,
    'serving_envelope_ready',runtime_ready,
    'serving_envelope_available_cents',greatest(0,coalesce(runtime_cap,0)-runtime_spent),
    'purchase_pool_available_cents',greatest(0,available),
    'missing_funded_skus',to_jsonb(missing),
    'local_prerequisites_met',bounded and runtime_ready and cardinality(missing)=0,
    'external_checks_required',jsonb_build_array(
      'Owner-funded sponsor deposit and evidence verified against bank or provider receipt',
      'App Store Connect USA seven-day free intro verified for each SKU',
      'Signed Apple Production purchase, renewal, expiration and refund receipts tested',
      'Actual photo assessment and generation cost bounds approved'));
end$$;
revoke all on function public.subscription_trial_activation_readiness() from public,anon,authenticated;
grant execute on function public.subscription_trial_activation_readiness() to service_role;

commit;
