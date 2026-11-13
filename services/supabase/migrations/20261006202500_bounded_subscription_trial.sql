begin;
-- Dormant product limits, not money. No sponsor dollars, schedules or pools are
-- seeded. A public offer also needs an atomic pre-purchase sponsor reservation;
-- that contract and trusted video-duration verification are not implemented here.
create table if not exists public.subscription_trial_config (
 singleton boolean primary key default true check(singleton), enabled boolean not null default false,
 walkthroughs integer not null default 1 check(walkthroughs=1),
 photo_edits integer not null default 5 check(photo_edits=5),
 published_listings integer not null default 1 check(published_listings=1),
 max_days integer not null default 7 check(max_days between 1 and 7),
 max_video_seconds integer not null default 90 check(max_video_seconds between 1 and 90),
 upload_budget_bytes bigint not null default 1073741824 check(upload_budget_bytes between 1 and 1073741824),
 created_at timestamptz not null default now()
);
insert into public.subscription_trial_config(singleton)values(true)on conflict do nothing;
-- No cascading FKs: deletion, switching workspace, restore or a calendar month
-- cannot replenish a lifetime trial. Account-related records retain actor/org
-- UUIDs, Apple chain/funding identifiers and a one-way confirmed-email digest;
-- no raw email, password, JWS or media capability. These are not anonymous.
create table if not exists public.subscription_trial_grants (
 id uuid primary key default gen_random_uuid(), actor_id uuid not null unique, identity_sha256 text not null unique check(identity_sha256 ~ '^[a-f0-9]{64}$'),
 org_id uuid not null unique, original_transaction_id text not null unique, funding_id uuid not null unique,
 starts_at timestamptz not null, ends_at timestamptz not null,
 walkthrough_cap integer not null check(walkthrough_cap=1), photo_cap integer not null check(photo_cap=5), listing_cap integer not null check(listing_cap=1),
 upload_budget_bytes bigint not null check(upload_budget_bytes between 1 and 1073741824),
 max_video_seconds integer not null check(max_video_seconds between 1 and 90),
 evidence_sha256 text not null check(evidence_sha256 ~ '^[a-f0-9]{64}$'), created_at timestamptz not null default now(),
 check(ends_at>starts_at and ends_at<=starts_at+interval '7 days')
);
create table if not exists public.subscription_trial_actions (
 grant_id uuid not null, kind text not null check(kind in('photo','walkthrough','publication','upload')),
 identity text not null check(length(identity)between 1 and 128), actor_id uuid not null, org_id uuid not null,
 listing_id uuid, asset_id uuid, held_bytes bigint not null default 0 check(held_bytes>=0),
 created_at timestamptz not null default now(), primary key(grant_id,kind,identity)
);
alter table public.subscription_trial_config enable row level security;
alter table public.subscription_trial_grants enable row level security;
alter table public.subscription_trial_actions enable row level security;
revoke all on public.subscription_trial_config,public.subscription_trial_grants,public.subscription_trial_actions from public,anon,authenticated,service_role;
grant select on public.subscription_trial_config,public.subscription_trial_grants,public.subscription_trial_actions to service_role;

-- Signed, currently funded paid service wins over old trial counters. Explicit
-- private/manual/contract authorities retain their existing product semantics.
create or replace function public.subscription_trial_paid_or_override(p_org uuid)returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.orgs o where o.id=p_org and o.deleted_at is null and (
  public.org_has_internal_testing_grant(p_org)or public.org_has_private_internal_testing(p_org)or public.org_has_app_review_funding(p_org)
  or(o.plan_source='manual'and public.effective_plan(p_org)in('starter','pro','team'))
  or exists(select 1 from public.brokerage_contracts c where c.org_id=p_org and c.status='active'and c.starts_at<=now()and(c.ends_at is null or c.ends_at>now()))
  or(o.plan_source='apple'and exists(select 1 from public.serving_funding f join public.apple_subscriptions s
   on s.original_transaction_id=f.apple_original_transaction_id and s.org_id=f.org_id
   where f.org_id=p_org and f.source='retail'and f.revoked_at is null and f.starts_at<=now()and f.ends_at>now()
    and s.environment='Production'and s.status='active'and s.expires_at>now()))));
$$;

create or replace function public.subscription_trial_register(p_funding uuid,p_original text,p_evidence text)returns uuid
language plpgsql security definer set search_path='' as $$
declare f public.serving_funding;c public.subscription_trial_config;prior public.subscription_trial_grants;identity_hash text;grant_id uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 select * into f from public.serving_funding where id=p_funding and source='trial'and apple_original_transaction_id=p_original;
 if f.id is null or f.revoked_at is not null or f.ends_at<=now()or f.ends_at>f.starts_at+interval '7 days'
  or p_evidence is null or p_evidence !~ '^[a-f0-9]{64}$'then raise exception 'RP403: A verified funded seven-day trial is required';end if;
 select * into c from public.subscription_trial_config where singleton;
 if not c.enabled then raise exception 'RP402: The bounded subscription trial is not activated';end if;
 select encode(sha256(convert_to(lower(btrim(u.email)),'UTF8')),'hex')into identity_hash from auth.users u
  where u.id=f.actor_id and u.is_anonymous is false and u.email_confirmed_at is not null and length(btrim(u.email))>0;
 if identity_hash is null then raise exception 'RP403: A confirmed named trial owner is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('subscription-trial:'||identity_hash,72453));
 select * into prior from public.subscription_trial_grants where identity_sha256=identity_hash or actor_id=f.actor_id or original_transaction_id=p_original or org_id=f.org_id;
 if prior.id is not null then
  if row(prior.actor_id,prior.org_id,prior.original_transaction_id,prior.funding_id)is distinct from row(f.actor_id,f.org_id,p_original,f.id)then
   raise exception 'RP409: This account or Apple chain already used its lifetime trial';end if;
  return prior.id;
 end if;
 insert into public.subscription_trial_grants(actor_id,identity_sha256,org_id,original_transaction_id,funding_id,starts_at,ends_at,walkthrough_cap,photo_cap,listing_cap,upload_budget_bytes,max_video_seconds,evidence_sha256)
 values(f.actor_id,identity_hash,f.org_id,p_original,f.id,f.starts_at,least(f.ends_at,f.starts_at+make_interval(days=>c.max_days)),c.walkthroughs,c.photo_edits,c.published_listings,c.upload_budget_bytes,c.max_video_seconds,p_evidence)returning id into grant_id;
 return grant_id;
end$$;

-- Patch only the accepted, service-owned funding overlay; Apple chronology and
-- old funding replay/refunds keep their existing order. Registration and pool
-- allocation share the SAME transaction: no funded-but-unmetered new trial.
do $patch$declare d text;b text;a text;r text;begin
 select pg_get_functiondef(oid),prosrc into d,b from pg_proc where oid='public.fund_verified_apple_transaction(uuid,text,text,text,bigint,text,text,integer,text,timestamptz,timestamptz,timestamptz,text)'::regprocedure;
 if position('bounded_trial_disabled'in b)=0 then
  a:=' if p_price_milliunits is null or p_price_milliunits<0';
  r:=E' if p_price_milliunits=0 and not(select enabled from public.subscription_trial_config where singleton)then return jsonb_build_object(''funded'',false,''reason'',''bounded_trial_disabled'');end if;\n'||a;
  if(length(b)-length(replace(b,a,'')))/length(a)<>1 then raise exception 'Unknown Apple funding admission body';end if;
  d:=replace(d,a,r);
  a:=' return result||jsonb_build_object(''funded'',true,''schedule_id'',schedule.id);';
  r:=E' if p_price_milliunits=0 then perform public.subscription_trial_register((result->>''funding_id'')::uuid,p_original,p_evidence_sha256);end if;\n'||a;
  if(length(b)-length(replace(b,a,'')))/length(a)<>1 then raise exception 'Unknown Apple funding completion body';end if;
  execute replace(d,a,r);
 end if;
end$patch$;

create or replace function public.subscription_trial_active(p_org uuid,p_actor uuid)returns public.subscription_trial_grants
language plpgsql security definer set search_path='' as $$
declare g public.subscription_trial_grants;
begin
 select t.* into g from public.subscription_trial_grants t join public.serving_funding f on f.id=t.funding_id
  where t.org_id=p_org and t.actor_id=p_actor and t.starts_at<=now()and t.ends_at>now()
   and f.org_id=t.org_id and f.actor_id=t.actor_id and f.source='trial'and f.revoked_at is null and f.starts_at<=now()and f.ends_at>now()
   and exists(select 1 from auth.users u where u.id=p_actor and u.is_anonymous is false)
   and exists(select 1 from public.memberships m where m.user_id=p_actor and m.org_id=p_org and m.role in('owner','admin','agent'))
   and not exists(select 1 from public.deletion_requests x where x.user_id=p_actor and x.status in('pending','processing'));
 return g;
end$$;

-- The grant-row lock serializes every feature and survives transport/day/month
-- resets. Photo credits are admissions: one operation, including fallbacks,
-- consumes one credit. Successful or ambiguous provider cost is never erased.
create or replace function public.subscription_trial_cost_guard()returns trigger
language plpgsql security definer set search_path='' as $$
declare f public.serving_funding;g public.subscription_trial_grants;used bigint;
begin
 if new.sponsored_unlimited then return new;end if;
 select * into f from public.serving_funding where id=new.funding_id;
 if f.source is distinct from 'trial'then return new;end if;
 select * into g from public.subscription_trial_grants where funding_id=f.id for update;
 -- Preserve earlier funded trial journals; do not invent a retrospective cap.
 if g.id is null and f.created_at<(select created_at from public.subscription_trial_config where singleton)then return new;end if;
 if g.id is null or(public.subscription_trial_active(new.org_id,new.actor_id)).id is distinct from g.id then raise exception 'RP402: A current funded bounded trial is required';end if;
 if new.stage in('photo.suggest','photo.improve_prompt')then
  if(select count(*)from public.subscription_trial_actions where grant_id=g.id and kind='photo')>=g.photo_cap
   and(select count(*)from public.subscription_trial_actions where grant_id=g.id and kind='walkthrough')>=g.walkthrough_cap
   and(select count(*)from public.subscription_trial_actions where grant_id=g.id and kind='publication')>=g.listing_cap then raise exception 'RP402: The included trial usage is exhausted';end if;
  return new;
 end if;
 if new.stage !~ '^photo\.(twilight|sky|lawn|declutter|stage|custom):[0-9]+$'then raise exception 'RP402: This generation feature is not included in the subscription trial';end if;
 if exists(select 1 from public.subscription_trial_actions where grant_id=g.id and kind='photo'and identity=new.request_key)then return new;end if;
 select count(*)into used from public.subscription_trial_actions where grant_id=g.id and kind='photo';
 if used>=g.photo_cap then raise exception 'RP402: The included trial photo edits are exhausted';end if;
 insert into public.subscription_trial_actions(grant_id,kind,identity,actor_id,org_id)values(g.id,'photo',new.request_key,new.actor_id,new.org_id);
 return new;
end$$;
drop trigger if exists subscription_trial_cost_admission on public.serving_cost_reservations;
create trigger subscription_trial_cost_admission before insert on public.serving_cost_reservations for each row execute function public.subscription_trial_cost_guard();

create or replace function public.subscription_trial_upload_guard()returns trigger
language plpgsql security definer set search_path='' as $$
declare g public.subscription_trial_grants;used numeric;
begin
 -- Cleanup of a retired v1 ticket records UNKNOWN historical physical spend;
 -- it grants no PUT/part/copy capability and does not refund lifetime bytes.
 if new.held_bytes=0 and new.state='cancelled'and new.settled_at is not null
  and new.spec='{"legacy_physical_bytes":"unknown"}'::jsonb and exists(
   select 1 from public.capture_assets a join public.listings l on l.id=a.listing_id
    where a.id=new.asset_id and a.transport_version=1 and a.uploaded is false
     and l.id=new.listing_id and l.org_id=new.org_id
     and exists(select 1 from public.memberships m where m.org_id=l.org_id and m.user_id=new.actor_id and m.role in('owner','admin','agent'))
  )then return new;end if;
 if public.subscription_trial_paid_or_override(new.org_id)then return new;end if;
 select * into g from public.subscription_trial_grants where org_id=new.org_id for update;
 if g.id is not null and g.actor_id<>new.actor_id then raise exception 'RP403: Trial uploads belong to the named subscription owner';end if;
 if g.id is null then select * into g from public.subscription_trial_grants where actor_id=new.actor_id for update;end if;
 if g.id is null then
  if exists(select 1 from public.orgs where id=new.org_id and plan_source='apple')and not exists(
   select 1 from public.serving_funding f where f.org_id=new.org_id and f.source='trial'and f.actor_id=new.actor_id
    and f.created_at<(select created_at from public.subscription_trial_config where singleton)and f.revoked_at is null and f.starts_at<=now()and f.ends_at>now()
  )then raise exception 'RP402: Subscription serving must be activated before new cloud uploads';end if;
  return new;
 end if;
 if g.org_id<>new.org_id or(public.subscription_trial_active(new.org_id,new.actor_id)).id is distinct from g.id then raise exception 'RP402: Trial uploads require the original active funded workspace';end if;
 if(select count(*)from public.subscription_trial_actions where grant_id=g.id and kind='photo')>=g.photo_cap
  and(select count(*)from public.subscription_trial_actions where grant_id=g.id and kind='walkthrough')>=g.walkthrough_cap
  and(select count(*)from public.subscription_trial_actions where grant_id=g.id and kind='publication')>=g.listing_cap then raise exception 'RP402: The included trial usage is exhausted';end if;
 select coalesce(sum(held_bytes),0)into used from public.subscription_trial_actions where grant_id=g.id and kind='upload';
 if new.held_bytes<=0 or used+new.held_bytes>g.upload_budget_bytes then raise exception 'RP402: The lifetime trial upload budget is exhausted';end if;
 insert into public.subscription_trial_actions(grant_id,kind,identity,actor_id,org_id,listing_id,asset_id,held_bytes)
 values(g.id,'upload',new.asset_id::text,new.actor_id,new.org_id,new.listing_id,new.asset_id,new.held_bytes);
 return new;
end$$;

create or replace function public.subscription_serving_activation(p_actor uuid,p_org uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o public.orgs;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 select * into o from public.orgs where id=p_org and deleted_at is null;
 if o.id is null or not exists(select 1 from public.memberships where user_id=p_actor and org_id=p_org)then raise exception 'RP403: Current service workspace access is required';end if;
 if public.org_has_internal_testing_grant(p_org)or public.org_has_private_internal_testing(p_org)then return jsonb_build_object('org_id',p_org,'available',true,'funded',false,'authority','private_sponsorship');end if;
 if public.org_has_app_review_funding(p_org)then return jsonb_build_object('org_id',p_org,'available',true,'funded',true,'authority','app_review');end if;
 if exists(select 1 from public.brokerage_contracts c where c.org_id=p_org and c.status='active'and c.starts_at<=now()and(c.ends_at is null or c.ends_at>now()))then return jsonb_build_object('org_id',p_org,'available',true,'funded',false,'authority','brokerage');end if;
 if o.plan_source is distinct from 'apple'then return jsonb_build_object('org_id',p_org,'available',true,'funded',false,'authority','existing_non_apple');end if;
 if exists(select 1 from public.serving_funding f join public.apple_subscriptions s on s.org_id=f.org_id and s.original_transaction_id=f.apple_original_transaction_id
  where f.org_id=p_org and f.source='retail'and f.revoked_at is null and f.starts_at<=now()and f.ends_at>now()
   and s.environment='Production'and s.status='active'and s.expires_at>now())then
  return jsonb_build_object('org_id',p_org,'available',true,'funded',true,'authority','verified_retail');
 end if;
 if exists(select 1 from public.serving_funding f where f.org_id=p_org and f.source='trial'and f.actor_id=p_actor
  and f.revoked_at is null and f.starts_at<=now()and f.ends_at>now()
  and exists(select 1 from auth.users u where u.id=p_actor and u.is_anonymous is false)
  and not exists(select 1 from public.deletion_requests d where d.user_id=p_actor and d.status in('pending','processing'))
  and((public.subscription_trial_active(p_org,p_actor)).id is not null or f.created_at<(select created_at from public.subscription_trial_config where singleton)))then
  return jsonb_build_object('org_id',p_org,'available',true,'funded',true,'authority','funded_trial');
 end if;
 return jsonb_build_object('org_id',p_org,'available',false,'funded',false,'authority','subscription_activation_unavailable');
end$$;
drop trigger if exists subscription_trial_upload_admission on public.upload_reservations;
create trigger subscription_trial_upload_admission before insert on public.upload_reservations for each row execute function public.subscription_trial_upload_guard();

create or replace function public.subscription_trial_render_guard()returns trigger
language plpgsql security definer set search_path='' as $$
declare org uuid;g public.subscription_trial_grants;asset uuid;listing uuid;used bigint;
begin
 if tg_table_name='render_jobs'then listing:=new.listing_id;asset:=new.capture_asset_id;
 else listing:=new.listing_id;select capture_asset_id into asset from public.render_jobs where id=new.job_id;end if;
 select org_id into org from public.listings where id=listing and deleted_at is null;
 if org is null then raise exception 'RP403: A current publication workspace is required';end if;
 if public.subscription_trial_paid_or_override(org)then return new;end if;
 -- Grandfather only an actually funded, finite prior trial for its named
 -- current editor. A bare historical row or nominal plan is no authority.
 if exists(select 1 from public.serving_funding f where f.org_id=org and f.actor_id=auth.uid()and f.source='trial'
  and f.created_at<(select created_at from public.subscription_trial_config where singleton)
  and f.sponsored_cents>0 and f.revoked_at is null and f.starts_at<=now()and f.ends_at>now()
  and exists(select 1 from public.serving_funding_slices s where s.funding_id=f.id and s.org_id=org
   and s.starts_at<=now()and s.ends_at>now()and s.total_budget_cents>0)
  and exists(select 1 from auth.users u where u.id=f.actor_id and u.is_anonymous is false)
  and exists(select 1 from public.memberships m where m.user_id=f.actor_id and m.org_id=org and m.role in('owner','admin','agent'))
  and not exists(select 1 from public.deletion_requests d where d.user_id=f.actor_id and d.status in('pending','processing'))
 )then return new;end if;
 select * into g from public.subscription_trial_grants where org_id=org for update;
 if g.id is null or(public.subscription_trial_active(org,auth.uid())).id is distinct from g.id then raise exception 'RP402: Subscribe to activate hosted publication';end if;
 if tg_table_name='render_jobs'then
  if new.source<>'app'or new.tier<>'smooth'or new.enhancements<>'{}'::jsonb then raise exception 'RP402: The trial includes a simple walkthrough from existing footage';end if;
  if exists(select 1 from public.subscription_trial_actions where grant_id=g.id and kind='walkthrough'and asset_id=asset and listing_id=listing)then return new;end if;
  select count(*)into used from public.subscription_trial_actions where grant_id=g.id and kind='walkthrough';
  if used>=g.walkthrough_cap then raise exception 'RP402: The included trial walkthrough is already reserved';end if;
  insert into public.subscription_trial_actions(grant_id,kind,identity,actor_id,org_id,listing_id,asset_id)values(g.id,'walkthrough',asset::text,g.actor_id,org,listing,asset);
 else
  -- Same exact owned asset remains an idempotent publication; a second asset
  -- cannot evade the walkthrough cap through a separate job or fresh slug.
  if not exists(select 1 from public.subscription_trial_actions where grant_id=g.id and kind='walkthrough'and asset_id=asset and listing_id=listing)then raise exception 'RP402: The trial walkthrough was not admitted';end if;
  if exists(select 1 from public.subscription_trial_actions where grant_id=g.id and kind='publication'and listing_id=listing)then return new;end if;
  select count(*)into used from public.subscription_trial_actions where grant_id=g.id and kind='publication';
  if used>=g.listing_cap then raise exception 'RP402: The included trial listing is already published';end if;
  insert into public.subscription_trial_actions(grant_id,kind,identity,actor_id,org_id,listing_id,asset_id)values(g.id,'publication',listing::text,g.actor_id,org,listing,asset);
 end if;
 return new;
end$$;
drop trigger if exists subscription_trial_render_admission on public.render_jobs;
create trigger subscription_trial_render_admission before insert on public.render_jobs for each row execute function public.subscription_trial_render_guard();
drop trigger if exists subscription_trial_publication_admission on public.renders;
create trigger subscription_trial_publication_admission before insert on public.renders for each row execute function public.subscription_trial_render_guard();

create or replace function public.subscription_trial_context(p_actor uuid,p_org uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare g public.subscription_trial_grants;photos integer;walks integer;published integer;bytes bigint;status text;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if not exists(select 1 from public.memberships where user_id=p_actor and org_id=p_org)
  or not exists(select 1 from public.orgs where id=p_org and deleted_at is null)then raise exception 'RP403: Current trial workspace access is required';end if;
 -- Until an atomic pre-purchase sponsor reservation exists, there is NO public
 -- numeric trial offer, even if an operator enables the dormant test config.
 if public.subscription_trial_paid_or_override(p_org)then return jsonb_build_object('trial_usage',null,'trial_offer',null);end if;
 select * into g from public.subscription_trial_grants where actor_id=p_actor and org_id=p_org;
 if g.id is null then return jsonb_build_object('trial_usage',null,'trial_offer',null);end if;
 select count(*)filter(where kind='photo'),count(*)filter(where kind='walkthrough'),count(*)filter(where kind='publication'),coalesce(sum(held_bytes)filter(where kind='upload'),0)
  into photos,walks,published,bytes from public.subscription_trial_actions where grant_id=g.id;
 status:=case when(public.subscription_trial_active(p_org,p_actor)).id is null then 'expired'
  when photos>=g.photo_cap and walks>=g.walkthrough_cap and published>=g.listing_cap then 'exhausted'else 'active'end;
 return jsonb_build_object('trial_offer',null,'trial_usage',jsonb_build_object('org_id',g.org_id,'status',status,'starts_at',g.starts_at,'ends_at',g.ends_at,
  'walkthroughs',jsonb_build_object('used',walks,'cap',g.walkthrough_cap,'remaining',greatest(0,g.walkthrough_cap-walks)),
  'photo_edits',jsonb_build_object('used',photos,'cap',g.photo_cap,'remaining',greatest(0,g.photo_cap-photos)),
  'published_listings',jsonb_build_object('used',published,'cap',g.listing_cap,'remaining',greatest(0,g.listing_cap-published)),
  'upload_budget_bytes',g.upload_budget_bytes,'upload_used_bytes',bytes));
end$$;

revoke all on function public.subscription_trial_paid_or_override(uuid),public.subscription_trial_register(uuid,text,text),
 public.subscription_trial_active(uuid,uuid),public.subscription_trial_context(uuid,uuid),public.subscription_serving_activation(uuid,uuid),public.subscription_trial_cost_guard(),
 public.subscription_trial_upload_guard(),public.subscription_trial_render_guard()from public,anon,authenticated;
grant execute on function public.subscription_trial_context(uuid,uuid),public.subscription_serving_activation(uuid,uuid),public.subscription_trial_paid_or_override(uuid),public.subscription_trial_register(uuid,text,text),public.subscription_trial_active(uuid,uuid)to service_role;
-- Trigger execution has no tenant grant and service users cannot write counters.
commit;
