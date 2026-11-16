-- App Review usage display: serving_ceiling_spent_cents (20261028010346) meters an
-- app_review-funded workspace only over the sponsor's exact window and raises
-- 'RP503: Reviewer supplier period changed' for any other window. The usage
-- summary behind GET /me asked for the calendar month, so every /me call for a
-- review workspace failed with 503. Report the sponsor window's spend instead.
-- Spending limits, admission and the reviewer guards are unchanged.
create or replace function public.library_usage_summary(p_actor uuid, p_org uuid, p_since timestamp with time zone)
 returns jsonb language plpgsql stable security definer set search_path to '' as $function$declare a jsonb;b uuid;ids uuid[];f public.serving_funding;cost numeric;begin
 a:=public.library_access(p_actor,p_org);b:=(a->>'billing_org_id')::uuid;ids:=public.library_listing_ids(p_actor,p_org);
 -- An App Review sponsor is metered only over its own fixed window (serving_ceiling_spent_cents
 -- refuses any other window for that org), so the usage display reports that window's spend.
 if b is not null and public.org_has_app_review_funding(b) then
  select * into f from public.serving_funding where org_id=b and source='app_review'and revoked_at is null and starts_at<=now()and ends_at>now();
 end if;
 cost:=case when f.id is not null then public.serving_ceiling_spent_cents(b,f.starts_at,f.ends_at)else public.serving_ceiling_spent_cents(b,p_since,null)end;
 return jsonb_build_object('actor_id',p_actor,'org_id',p_org,'billing_org_id',b,
 'listings',(select count(*)from public.listings where id=any(ids)),
 'leads',(select count(*)from public.leads where listing_id=any(ids)),
 'leads_new',(select count(*)from public.leads where listing_id=any(ids)and status='new'),
 'render_count',(select count(*)from public.render_jobs where billing_org_id=b and source='worker'and(p_since is null or created_at>=p_since)),
 'cost_cents',cost);
end$function$;
