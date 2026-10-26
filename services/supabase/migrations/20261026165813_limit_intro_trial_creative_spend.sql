-- The seven-day introductory week pays for one listing and a handful of photo
-- edits. It does not buy video, aerial or reflection generation. Apple records
-- an introductory transaction as a paid-plan org, so changing only the trial
-- row would leave Starter/Pro/Team video quotas available before renewal.
--
-- Admission remains server-side and is checked again by the atomic video and
-- reflection reservations through org_entitlement(). Existing cost holds,
-- receipts, customer subscriptions and paid-plan catalog rows are untouched.
begin;

do $$begin
  if (select md5(prosrc) from pg_proc where oid='public.org_entitlement(uuid)'::regprocedure)
       <> '55223b9a9c6c8076705887f974257f2e' then
    raise exception 'Review changed org_entitlement before limited-trial migration';
  end if;
  if not exists(select 1 from public.plan_entitlements where plan='trial'
      and renders_per_month=3 and photo_edits_per_month=20 and reels_per_month=20
      and aerials_per_month=2 and topaz_per_month=1 and cogs_ceiling_cents=1500) then
    raise exception 'Review changed trial catalog before limited-trial migration';
  end if;
  if not exists(select 1 from public.app_config where key='serving_envelope'
      and value->'trial_ceiling_cents'='1500'::jsonb) then
    raise exception 'Review changed trial serving ceiling before limited-trial migration';
  end if;
  if not exists(select 1 from public.subscription_trial_config where singleton
      and enabled=false and max_days=7 and photo_edits=20) then
    raise exception 'Review changed bounded-trial configuration before limited-trial migration';
  end if;
end$$;

update public.plan_entitlements set
  photo_edits_per_month=5,
  reels_per_month=0, aerials_per_month=0, topaz_per_month=0,
  cogs_ceiling_cents=500
where plan='trial';

-- Industry-specific trial rows must not reintroduce a video quota or larger
-- photo/cost allowance over the base trial row.
update public.plan_entitlement_overrides set
  photo_edits_per_month=5, reels_per_month=0,
  aerials_per_month=0, topaz_per_month=0, cogs_ceiling_cents=500
where plan='trial';

-- The older bounded-grant mechanism is disabled in production. Keep its photo
-- allowance consistent if it is ever deliberately enabled; its capture-video
-- duration field is not permission to generate AI video.
update public.subscription_trial_config set photo_edits=5 where singleton;

update public.app_config set
  value=jsonb_set(value,'{trial_ceiling_cents}','500'::jsonb)
where key='serving_envelope';

create or replace function public.org_entitlement(p_org uuid)
returns public.plan_entitlements language plpgsql stable security definer
set search_path='' as $$
declare
  e public.plan_entitlements;
  trial_limit public.plan_entitlements;
  b uuid;
  budget integer;
  intro_week boolean;
begin
  b:=public.library_billing_org(p_org);
  e:=public.org_entitlement_before_team(b);
  if public.library_internal_content_unlimited(p_org) then
    e.plan:='team';e.price_cents:=0;e.seats:=1;
    e.renders_per_month:=2147483647;e.photo_edits_per_month:=2147483647;
    e.reels_per_month:=2147483647;e.aerials_per_month:=2147483647;
    e.topaz_per_month:=2147483647;e.cogs_ceiling_cents:=2147483647;
  elsif b<>p_org then
    e.seats:=1;
  end if;

  -- A full-price Apple plan is displayed from the verified transaction even
  -- while its first seven days are free. Detect the same short active term
  -- used by plan_serving_ceiling_before_team(), without calling that function
  -- (it calls org_entitlement and would recurse). A paid renewal has a longer
  -- signed service term and restores the purchased allowances automatically.
  intro_week:=e.plan in ('starter','solo','pro','team')
    and not public.library_internal_content_unlimited(p_org)
    and not public.org_has_app_review_funding(b)
    and exists(select 1 from public.orgs o where o.id=b and o.deleted_at is null
      and o.plan_source='apple'
      and exists(select 1 from public.apple_subscriptions s
        where s.org_id=b and s.environment='Production' and s.status='active'
          and s.expires_at>now() and s.transaction_purchased_at is not null
          and s.expires_at<=s.transaction_purchased_at+interval '8 days'));

  budget:=public.paid_quality_processing_budget(b);
  e.cogs_ceiling_cents:=greatest(e.cogs_ceiling_cents,budget);
  if intro_week then
    trial_limit:=public.plan_entitlement('trial');
    -- Keep e.plan and e.price_cents as the purchased SKU for renewal/restore;
    -- only the free service window gets the small trial creative allowance.
    e.renders_per_month:=least(e.renders_per_month,trial_limit.renders_per_month);
    e.photo_edits_per_month:=least(e.photo_edits_per_month,trial_limit.photo_edits_per_month);
    e.reels_per_month:=0;e.aerials_per_month:=0;e.topaz_per_month:=0;
    e.cogs_ceiling_cents:=least(e.cogs_ceiling_cents,trial_limit.cogs_ceiling_cents);
  end if;
  return e;
end$$;

revoke all on function public.org_entitlement(uuid) from public,anon,authenticated;
grant execute on function public.org_entitlement(uuid) to authenticated,service_role,postgres;

-- In ceiling mode an Apple introductory transaction is intentionally a
-- purchased SKU for StoreKit restore, so the older bounded-grant publication
-- guard treats it as paid. Reserve the included single listing at the actual
-- render/publication boundary without changing upload or purchase authority.
create or replace function public.trial_intro_publication_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare org uuid; listing uuid;
begin
  listing:=new.listing_id;
  select l.org_id into org from public.listings l
    where l.id=listing and l.deleted_at is null;
  if org is null then raise exception 'RP403: A current publication workspace is required';end if;
  if public.serving_mode()='ceiling'
    and public.plan_serving_ceiling(org)->>'kind'='trial'
    and not public.free_publication_admit(org,listing) then
    raise exception 'RP402: The included trial listing is already published';
  end if;
  return new;
end$$;
revoke all on function public.trial_intro_publication_guard()
  from public,anon,authenticated;
grant execute on function public.trial_intro_publication_guard()
  to service_role,postgres;
drop trigger if exists trial_intro_render_admission on public.render_jobs;
create trigger trial_intro_render_admission before insert on public.render_jobs
  for each row execute function public.trial_intro_publication_guard();
drop trigger if exists trial_intro_publication_admission on public.renders;
create trigger trial_intro_publication_admission before insert on public.renders
  for each row execute function public.trial_intro_publication_guard();

commit;
