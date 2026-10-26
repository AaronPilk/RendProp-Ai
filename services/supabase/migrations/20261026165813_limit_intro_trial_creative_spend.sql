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
  if not exists(select 1 from public.plan_entitlements where plan='free'
      and renders_per_month=1 and photo_edits_per_month=5) then
    raise exception 'Review changed Free catalog before limited-trial migration';
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

-- A lapsed or never-subscribed Free workspace can still prepare its one
-- listing, but it cannot start a hosted render. The effective /me allowance
-- must agree with the publication gate.
update public.plan_entitlements set renders_per_month=0 where plan='free';

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
-- Forty ordinary 8 MiB iPhone photos reserve 640 MiB. Give unpaid
-- Trial and Free access a fixed 2 GiB monthly technical cap while its supplier spend remains
-- separately limited to five edits and 500 cents. New video uploads are
-- refused below unless a verified per-property website credit has been paid.
do $$declare def text;needle text;replacement text;begin
  def:=pg_get_functiondef('public.upload_new_admission(uuid,uuid,bigint)'::regprocedure);
  needle:='  cap:=e.renders_per_month::bigint*12884901888::bigint+e.photo_edits_per_month::bigint*104857600::bigint;';
  replacement:='  cap:=case when public.plan_serving_ceiling(public.library_actor_billing_org(p_actor,p_org))->>''kind'' in(''trial'',''free'') then 2147483648::bigint else e.renders_per_month::bigint*12884901888::bigint+e.photo_edits_per_month::bigint*104857600::bigint end;';
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

-- An unpaid account may prepare one lifetime listing, including its photos.
-- Reserve the same lifetime free-listing slot at INSERT, not at render upload:
-- neither a draft nor its gallery selection is a published video/website.
-- The parent billing org owns the slot for Team private libraries. Existing
-- listings remain editable and their uploads are untouched by this trigger.
create or replace function public.trial_intro_listing_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare billing uuid; existing integer;
begin
  billing:=public.library_billing_org(new.org_id);
  if public.plan_serving_ceiling(billing)->>'kind' in('trial','free') then
    -- The count also catches listings made before this migration, including
    -- deleted ones. The advisory lock serializes two first-listing inserts.
    perform pg_advisory_xact_lock(hashtextextended('free_publication:'||billing,72454));
    select count(*) into existing from public.listings l
      where public.library_billing_org(l.org_id)=billing;
    if existing>0 or (public.serving_mode()='ceiling' and
       not public.free_publication_admit(billing,new.id)) then
      raise exception 'RP402: Unpaid access includes one listing';
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

-- A background video may finish after its paid supplier attempt but before
-- the customer publishes the resulting MP4. Freeze the payment authority at
-- the provider reservation, since a queued recipe alone is no authority.
create table if not exists public.trial_intro_paid_video_attempts(
  reservation_id uuid primary key references public.app_video_cost_reservations(id) on delete cascade,
  content_org_id uuid not null, billing_org_id uuid not null,
  actor_id uuid not null, feature text not null check(feature='reel'),
  admitted_at timestamptz not null default now()
);
alter table public.trial_intro_paid_video_attempts enable row level security;
revoke all on public.trial_intro_paid_video_attempts from public,anon,authenticated,service_role;
grant select on public.trial_intro_paid_video_attempts to service_role;

create or replace function public.trial_intro_capture_paid_video_attempt()
returns trigger language plpgsql security definer set search_path='' as $$
declare billing uuid;
begin
  if new.feature<>'reel' then return new;end if;
  billing:=public.library_actor_billing_org(new.actor_id,new.org_id);
  if public.plan_serving_ceiling(billing)->>'kind' not in('trial','free') then
    insert into public.trial_intro_paid_video_attempts
      (reservation_id,content_org_id,billing_org_id,actor_id,feature,admitted_at)
    values(new.id,new.org_id,billing,new.actor_id,new.feature,new.created_at);
  end if;
  return new;
end$$;
revoke all on function public.trial_intro_capture_paid_video_attempt()
  from public,anon,authenticated;
grant execute on function public.trial_intro_capture_paid_video_attempt()
  to service_role,postgres;
drop trigger if exists trial_intro_video_cost_admitted on public.app_video_cost_reservations;
create trigger trial_intro_video_cost_admitted after insert on public.app_video_cost_reservations
  for each row execute function public.trial_intro_capture_paid_video_attempt();

-- Existing paid attempts in progress at rollout retain the same authority.
-- An earlier free/trial reservation is not converted into paid authority.
insert into public.trial_intro_paid_video_attempts
  (reservation_id,content_org_id,billing_org_id,actor_id,feature,admitted_at)
select r.id,r.org_id,public.library_actor_billing_org(r.actor_id,r.org_id),
  r.actor_id,r.feature,r.created_at
from public.app_video_cost_reservations r
where r.feature='reel' and r.released_at is null
  and public.plan_serving_ceiling(public.library_actor_billing_org(r.actor_id,r.org_id))->>'kind'
    not in('trial','free')
on conflict(reservation_id)do nothing;

-- The only unpaid late-publication exception is an exact ready server output
-- containing a clip with a settled paid reservation and its matching ledger.
-- The job's original content org, actor, source and output are all pinned;
-- preflight, unaccepted and cancelled requests cannot gain publication.
create or replace function public.trial_intro_paid_background_result(p_asset uuid,p_listing uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1
  from public.property_video_jobs j
  join public.property_video_job_outputs o on o.job_id=j.id and o.asset_id=p_asset
  join public.capture_assets ca on ca.id=o.asset_id and ca.listing_id=j.listing_id
  join public.property_video_job_sources s on s.job_id=j.id and s.state='ready'
  join public.app_video_cost_reservations r
    on r.org_id=j.org_id and r.actor_id=j.actor_id and r.idempotency_key=s.request_key
  join public.trial_intro_paid_video_attempts a on a.reservation_id=r.id
  join public.cost_ledger l on l.id=r.cost_ledger_id
  where j.listing_id=p_listing and j.output_asset_id=p_asset
    and j.state='ready' and j.cancelled_at is null and j.result is not null
    and j.manifest->>'purpose'='listing'
    and o.kind='video' and o.state='ready' and o.etag is not null
    and ca.kind='video' and ca.uploaded and not ca.upload_aborted
    and r.feature='reel' and r.released_at is null
    and r.provider_request_id=s.receipt->>'request_id'
    and r.cost_ledger_id is not null and r.settled_at is not null
    and a.content_org_id=j.org_id and a.actor_id=j.actor_id
    and a.billing_org_id=r.billing_org_id and a.feature=r.feature
    and l.org_id=r.org_id and l.feature='reel' and l.total_cents>0
    and l.meta->>'app_video_reservation_id'=r.id::text);
$$;
revoke all on function public.trial_intro_paid_background_result(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.trial_intro_paid_background_result(uuid,uuid)
  to service_role,postgres;

-- Capture publication authority when the job is admitted. A bare job row is
-- preflight, not proof that a worker was entitled to spend after a downgrade.
-- On-device app publication is cost-free and admitted when its job is created;
-- a worker is admitted to start billable work only at its first processing
-- claim while the workspace is still paid. The receipt is private and never
-- rewritten by the client. An already admitted worker may be reclaimed later.
create table if not exists public.trial_intro_render_admissions(
  job_id uuid primary key references public.render_jobs(id) on delete cascade,
  listing_id uuid not null, content_org_id uuid not null,
  billing_org_id uuid not null, source text not null
    check(source in('app','worker')),
  job_admitted_at timestamptz not null default now(),
  work_admitted_at timestamptz
);
alter table public.trial_intro_render_admissions enable row level security;
revoke all on public.trial_intro_render_admissions from public,anon,authenticated,service_role;
grant select on public.trial_intro_render_admissions to service_role;

create or replace function public.trial_intro_paid_job_can_finish(p_job uuid,p_listing uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.trial_intro_render_admissions a
  join public.render_jobs j on j.id=a.job_id
  join public.listings l on l.id=j.listing_id
  where j.id=p_job and j.listing_id=p_listing and a.listing_id=j.listing_id
   and a.content_org_id=l.org_id
   and (j.billing_org_id is null or j.billing_org_id=a.billing_org_id)
   and a.source=j.source
   and ((j.source='app' and a.job_admitted_at is not null)
     or(j.source='worker' and a.work_admitted_at is not null)));
$$;
revoke all on function public.trial_intro_paid_job_can_finish(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.trial_intro_paid_job_can_finish(uuid,uuid)
  to service_role,postgres;

create or replace function public.trial_intro_capture_job_admission()
returns trigger language plpgsql security definer set search_path='' as $$
declare billing uuid; content_org uuid; kind text; website_paid boolean;
begin
  select l.org_id,public.library_billing_org(l.org_id)
    into content_org,billing from public.listings l
    where l.id=new.listing_id and l.deleted_at is null;
  if billing is null then raise exception 'RP403: A current publication workspace is required';end if;
  kind:=public.plan_serving_ceiling(billing)->>'kind';
  if tg_op='INSERT' then
    select exists(select 1 from public.property_website_transactions t
      where t.assigned_listing_id=new.listing_id and t.revoked_at is null
        and t.environment in('Production','Sandbox')) into website_paid;
    if kind not in('trial','free') or(new.source='app' and
      (website_paid or public.trial_intro_paid_background_result(new.capture_asset_id,new.listing_id))) then
      insert into public.trial_intro_render_admissions
        (job_id,listing_id,content_org_id,billing_org_id,source)
      values(new.id,new.listing_id,content_org,billing,new.source);
    end if;
  elsif new.source='worker' and new.status='processing'
      and old.status in('created','queued') then
    if kind in('trial','free') and not exists(select 1
      from public.trial_intro_render_admissions a
      where a.job_id=new.id and a.work_admitted_at is not null) then
      raise exception 'RP402: A queued render needs paid service before processing';
    end if;
    if kind not in('trial','free') then
      update public.trial_intro_render_admissions a set work_admitted_at=coalesce(a.work_admitted_at,now())
      where a.job_id=new.id and a.source='worker' and a.billing_org_id=billing;
    end if;
  end if;
  return new;
end$$;
revoke all on function public.trial_intro_capture_job_admission()
  from public,anon,authenticated;
grant execute on function public.trial_intro_capture_job_admission()
  to service_role,postgres;
drop trigger if exists trial_intro_job_admitted on public.render_jobs;
create trigger trial_intro_job_admitted after insert on public.render_jobs
  for each row execute function public.trial_intro_capture_job_admission();
drop trigger if exists trial_intro_worker_cost_admitted on public.render_jobs;
create trigger trial_intro_worker_cost_admitted after update of status on public.render_jobs
  for each row execute function public.trial_intro_capture_job_admission();

-- Existing jobs that already entered work while paid need the same immutable
-- completion authority after rollout. Queued jobs deliberately receive no
-- worker-start receipt and must recheck the plan at claim time.
insert into public.trial_intro_render_admissions
  (job_id,listing_id,content_org_id,billing_org_id,source,job_admitted_at,work_admitted_at)
select j.id,j.listing_id,l.org_id,public.library_billing_org(l.org_id),j.source,j.created_at,
  case when j.source='worker' and j.status='processing' then coalesce(j.started_at,j.created_at) end
from public.render_jobs j join public.listings l on l.id=j.listing_id
where l.deleted_at is null and j.source in('app','worker')
  and (public.plan_serving_ceiling(public.library_billing_org(l.org_id))->>'kind' not in('trial','free')
    or(j.source='app' and exists(select 1 from public.property_website_transactions t
      where t.assigned_listing_id=j.listing_id and t.revoked_at is null
        and t.environment in('Production','Sandbox')))
  ) on conflict(job_id)do nothing;

-- The older bounded-trial trigger runs before our new render trigger. Permit
-- settlement only when this frozen paid admission belongs to the same job
-- and listing; its ordinary no-new-work and free-slot checks remain intact.
do $$declare def text;needle text;replacement text;begin
  if (select md5(prosrc) from pg_proc
      where oid='public.subscription_trial_render_guard()'::regprocedure)
      <> 'ef9c94cb23e294a11094ccc3b4961a16' then
    raise exception 'Review changed bounded-trial render guard before intro repair';
  end if;
  def:=pg_get_functiondef('public.subscription_trial_render_guard()'::regprocedure);
  needle:=' if public.subscription_trial_paid_or_override(org)then return new;end if;';
  replacement:=' if tg_table_name=''renders'' then'||E'\n'||
    '  if public.trial_intro_paid_job_can_finish(new.job_id,new.listing_id)then return new;end if;'||E'\n'||
    ' else'||E'\n'||
    '  if new.source=''app'' and public.trial_intro_paid_background_result(new.capture_asset_id,new.listing_id)then return new;end if;'||E'\n'||
    ' end if;'||E'\n'||needle;
  if (length(def)-length(replace(def,needle,'')))/length(needle)<>1 then
    raise exception 'Review changed bounded-trial completion anchor';
  end if;
  execute replace(def,needle,replacement);
end$$;
revoke all on function public.subscription_trial_render_guard()
  from public,anon,authenticated;

-- Both server renders and on-device video publication create render_jobs.
-- The monthly render meter covers only workers; source='app' bypasses it.
-- Refuse both sources during an unpaid introductory or later free term. A verified one-time
-- website purchase for this exact property is a payment and may still publish
-- an on-device photo video; it never authorizes a supplier/worker render.
create or replace function public.trial_intro_publication_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare org uuid; billing uuid; listing uuid; source text; paid_website boolean;
begin
  -- Completion may lag admission. A paid app job or a worker that began
  -- costed processing while paid can settle after a downgrade. A queued job
  -- alone is not authority to spend or publish under Free.
  if tg_table_name='renders' then
    select l.org_id into org from public.render_jobs j
      join public.listings l on l.id=j.listing_id
      where j.id=new.job_id and j.listing_id=new.listing_id and l.deleted_at is null;
    if org is null then raise exception 'RP403: A previously admitted video job is required';end if;
    billing:=public.library_billing_org(org);
    if public.plan_serving_ceiling(billing)->>'kind' in('trial','free')
      and not public.trial_intro_paid_job_can_finish(new.job_id,new.listing_id) then
      raise exception 'RP402: Video completion needs a paid admission';
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
    if not (source='app' and (paid_website or
      public.trial_intro_paid_background_result(new.capture_asset_id,listing))) then
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
