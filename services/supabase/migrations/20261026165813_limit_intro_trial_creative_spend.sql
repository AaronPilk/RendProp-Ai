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
  if (select md5(prosrc) from pg_proc where oid='public.upload_new_admission(uuid,uuid,bigint)'::regprocedure)
       <> '1279cf160371121c27281b69224f4fba' then
    raise exception 'Review changed upload_new_admission before limited-trial migration';
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
  renders_per_month=0, photo_edits_per_month=5,
  reels_per_month=0, aerials_per_month=0, topaz_per_month=0,
  cogs_ceiling_cents=500
where plan='trial';

-- Industry-specific trial rows must not reintroduce a video quota or larger
-- photo/cost allowance over the base trial row.
update public.plan_entitlement_overrides set
  renders_per_month=0, photo_edits_per_month=5, reels_per_month=0,
  aerials_per_month=0, topaz_per_month=0, cogs_ceiling_cents=500
where plan='trial';

-- The older bounded-grant mechanism is disabled in production. Keep its photo
-- allowance consistent if it is ever deliberately enabled; its capture-video
-- duration field is not permission to generate AI video.
update public.subscription_trial_config set photo_edits=5 where singleton;

update public.app_config set
  value=jsonb_set(value,'{trial_ceiling_cents}','500'::jsonb)
where key='serving_envelope';

-- A zero video-render entitlement must not collapse photo ingress to five
-- hundred MiB: every upload reservation holds roughly twice the source bytes.
-- Forty ordinary 8 MiB iPhone photos reserve 640 MiB. Give the one-listing
-- intro a fixed 2 GiB monthly technical cap while its supplier spend remains
-- separately limited to five edits and 500 cents. New video uploads are
-- refused below unless a verified per-property website credit has been paid.
do $$declare def text;needle text;replacement text;begin
  def:=pg_get_functiondef('public.upload_new_admission(uuid,uuid,bigint)'::regprocedure);
  needle:='  cap:=e.renders_per_month::bigint*12884901888::bigint+e.photo_edits_per_month::bigint*104857600::bigint;';
  replacement:='  cap:=case when public.plan_serving_ceiling(public.library_actor_billing_org(p_actor,p_org))->>''kind''=''trial'' then 2147483648::bigint else e.renders_per_month::bigint*12884901888::bigint+e.photo_edits_per_month::bigint*104857600::bigint end;';
  if (length(def)-length(replace(def,needle,'')))/length(needle)<>1 then
    raise exception 'Review changed trial upload-cap anchor before limited-trial migration';
  end if;
  execute replace(def,needle,replacement);
end$$;
revoke all on function public.upload_new_admission(uuid,uuid,bigint)
  from public,anon,authenticated;
grant execute on function public.upload_new_admission(uuid,uuid,bigint)
  to service_role;

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
  -- (it calls org_entitlement and would recurse). Match the currently stored
  -- Apple SKU and service expiry; another active original transaction can be
  -- left behind after an upgrade or renewal and must not clamp a paid term.
  intro_week:=e.plan in ('starter','solo','pro','team')
    and not public.library_internal_content_unlimited(p_org)
    and not public.org_has_app_review_funding(b)
    and exists(select 1 from public.orgs o where o.id=b and o.deleted_at is null
      and o.plan_source='apple'
      and exists(select 1 from public.apple_subscriptions s
        where s.org_id=b and s.environment='Production' and s.status='active'
          and s.product_id=o.apple_product_id
          and s.expires_at=o.plan_expires_at
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

-- A free introductory account may prepare one listing, including its photos.
-- Reserve the same lifetime free-listing slot at INSERT, not at render upload:
-- neither a draft nor its gallery selection is a published video/website.
-- The parent billing org owns the slot for Team private libraries. Existing
-- listings remain editable and their uploads are untouched by this trigger.
create or replace function public.trial_intro_listing_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare billing uuid; existing integer;
begin
  billing:=public.library_billing_org(new.org_id);
  if public.plan_serving_ceiling(billing)->>'kind'='trial' then
    -- The count also catches listings made before this migration, including
    -- deleted ones. The advisory lock serializes two first-listing inserts.
    perform pg_advisory_xact_lock(hashtextextended('free_publication:'||billing,72454));
    select count(*) into existing from public.listings l
      where public.library_billing_org(l.org_id)=billing;
    if existing>0 or (public.serving_mode()='ceiling' and
       not public.free_publication_admit(billing,new.id)) then
      raise exception 'RP402: The introductory week includes one listing';
    end if;
  end if;
  return new;
end$$;
revoke all on function public.trial_intro_listing_guard()
  from public,anon,authenticated;
grant execute on function public.trial_intro_listing_guard()
  to service_role,postgres;
drop trigger if exists trial_intro_listing_admission on public.listings;
create trigger trial_intro_listing_admission before insert on public.listings
  for each row execute function public.trial_intro_listing_guard();

-- An unpaid photo workspace must not admit fresh video ingress merely
-- because its fixed photo upload cap has room. A separately paid website
-- credit can upload the exact property's on-device presentation. An existing
-- completed reservation is unaffected because this fires only on INSERT.
create or replace function public.trial_intro_upload_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare org uuid; billing uuid;
begin
  if new.spec->>'kind'='video' then
    select l.org_id into org from public.listings l where l.id=new.listing_id and l.deleted_at is null;
    if org is null then raise exception 'RP403: A current upload workspace is required';end if;
    billing:=public.library_actor_billing_org(new.actor_id,org);
    if public.plan_serving_ceiling(billing)->>'kind' in('trial','free') and not exists(
      select 1 from public.property_website_transactions t
      where t.assigned_listing_id=new.listing_id and t.revoked_at is null
        and t.environment in('Production','Sandbox')) then
      raise exception 'RP402: Video uploads start after payment';
    end if;
  end if;
  return new;
end$$;
revoke all on function public.trial_intro_upload_guard()
  from public,anon,authenticated;
grant execute on function public.trial_intro_upload_guard()
  to service_role,postgres;
drop trigger if exists trial_intro_upload_admission on public.upload_reservations;
create trigger trial_intro_upload_admission before insert on public.upload_reservations
  for each row execute function public.trial_intro_upload_guard();

-- Both server renders and on-device video publication create render_jobs.
-- The monthly render meter covers only workers; source='app' bypasses it.
-- Refuse both sources during an unpaid introductory or later free term. A verified one-time
-- website purchase for this exact property is a payment and may still publish
-- an on-device photo video; it never authorizes a supplier/worker render.
create or replace function public.trial_intro_publication_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare org uuid; billing uuid; listing uuid; source text; paid_website boolean;
begin
  -- Completion may lag admission. A job created while the account was paid
  -- must still publish after a later downgrade; no second generation or
  -- supplier reservation is granted by this completion path.
  if tg_table_name='renders' then
    if not exists(select 1 from public.render_jobs j
      where j.id=new.job_id and j.listing_id=new.listing_id) then
      raise exception 'RP403: A previously admitted video job is required';
    end if;
    return new;
  end if;
  listing:=new.listing_id;
  select l.org_id into org from public.listings l
    where l.id=listing and l.deleted_at is null;
  if org is null then raise exception 'RP403: A current publication workspace is required';end if;
  billing:=public.library_billing_org(org);
  if public.plan_serving_ceiling(billing)->>'kind' in('trial','free') then
    source:=new.source;
    select exists(select 1 from public.property_website_transactions t
      where t.assigned_listing_id=listing and t.revoked_at is null
        and t.environment in('Production','Sandbox')) into paid_website;
    if not (paid_website and source='app') then
      raise exception 'RP402: Video and public website creation start after payment';
    end if;
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
