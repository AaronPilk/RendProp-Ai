-- Ordinary app video admits ONE priced provider attempt before its POST.
-- An unconfirmed POST keeps its hold indefinitely; there is no retry lease,
-- expiry, automatic release or fallback permission in this journal.
create table if not exists public.app_video_cost_reservations (
  id uuid primary key default gen_random_uuid(),
  -- These immutable identifiers survive hard account/org deletion. They are
  -- accounting tombstones, not media capabilities or customer input content.
  org_id uuid not null,
  actor_id uuid not null,
  idempotency_key text not null check (idempotency_key ~ '^[!-~]{8,128}$'),
  feature text not null check (feature in ('drone_render','aerial','reel')),
  provider text not null check (provider in ('fal','kie','higgsfield')),
  model text not null check (length(model) between 1 and 240 and model ~ '^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$'),
  input_sha256 text not null check (input_sha256 ~ '^[a-f0-9]{64}$'),
  units numeric not null check (units > 0 and units <= 1000000),
  unit_cost_cents numeric not null check (unit_cost_cents > 0 and unit_cost_cents <= 999999),
  total_cents numeric(12,4) not null check (total_cents > 0 and total_cents = round(units*unit_cost_cents,4)),
  hold_cents numeric not null check (hold_cents >= total_cents and hold_cents <= 99999999),
  meta jsonb not null default '{}'::jsonb,
  provider_request_id text,
  -- Receipt identity remains immutable even when account deletion intentionally
  -- purges its ledger row. A FK here would block prepare_account_deletion.
  cost_ledger_id uuid unique,
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  unique (org_id,idempotency_key),
  check ((cost_ledger_id is null and provider_request_id is null and settled_at is null)
    or (cost_ledger_id is not null and provider_request_id is not null and settled_at is not null))
);
alter table public.app_video_cost_reservations
  drop constraint if exists app_video_cost_reservations_cost_ledger_id_fkey;
create index if not exists app_video_cost_unsettled_org
  on public.app_video_cost_reservations(org_id) where cost_ledger_id is null;
alter table public.app_video_cost_reservations enable row level security;
revoke all on public.app_video_cost_reservations from public,anon,authenticated,service_role;
grant select,insert,update on public.app_video_cost_reservations to service_role;

create or replace function public.app_video_cost_pin_receipt()
returns trigger language plpgsql set search_path='' as $$
begin
  if (new.id,new.org_id,new.actor_id,new.idempotency_key,new.feature,new.provider,new.model,
      new.input_sha256,new.units,new.unit_cost_cents,new.total_cents,new.hold_cents,new.meta,new.created_at)
     is distinct from
     (old.id,old.org_id,old.actor_id,old.idempotency_key,old.feature,old.provider,old.model,
      old.input_sha256,old.units,old.unit_cost_cents,old.total_cents,old.hold_cents,old.meta,old.created_at)
    or (old.cost_ledger_id is not null and
      (new.cost_ledger_id,new.provider_request_id,new.settled_at) is distinct from
      (old.cost_ledger_id,old.provider_request_id,old.settled_at)) then
    raise exception 'RP409: Video reservation identity, price and receipt are immutable';
  end if;
  return new;
end $$;
drop trigger if exists app_video_cost_receipt_fixed on public.app_video_cost_reservations;
create trigger app_video_cost_receipt_fixed before update on public.app_video_cost_reservations
  for each row execute function public.app_video_cost_pin_receipt();
revoke all on function public.app_video_cost_pin_receipt() from public,anon,authenticated;
grant execute on function public.app_video_cost_pin_receipt() to service_role;

-- Like the reflection aggregate, expose only a member-scoped sum. Holds have
-- no month filter: an earlier unresolved POST still fences today's budget.
create or replace function public.app_video_held_cents(p_org uuid)
returns numeric language plpgsql stable security definer set search_path='' as $$
begin
  if not (coalesce(auth.role()='service_role',false)
    or current_setting('role',true)='service_role'
    or (session_user=current_user and current_setting('role',true)='none')
    or exists(select 1 from public.memberships where org_id=p_org and user_id=auth.uid())) then return 0; end if;
  return (select coalesce(sum(hold_cents),0) from public.app_video_cost_reservations
    where org_id=p_org and cost_ledger_id is null);
end $$;
revoke all on function public.app_video_held_cents(uuid) from public,anon,authenticated;
grant execute on function public.app_video_held_cents(uuid) to authenticated,service_role;

-- Preserve INVOKER RLS on cost_ledger and the existing reflection sum.
create or replace function public.org_month_spend_cents(p_org uuid)
returns numeric language sql stable security invoker set search_path='' as $$
  select coalesce(sum(total_cents),0)+public.video_erase_held_cents(p_org)+public.app_video_held_cents(p_org)
    from public.cost_ledger where org_id=p_org and created_at>=date_trunc('month',now());
$$;
revoke all on function public.org_month_spend_cents(uuid) from public,anon,authenticated;
grant execute on function public.org_month_spend_cents(uuid) to authenticated,service_role;

create or replace function public.app_video_cost_reserve(
  p_actor uuid,p_org uuid,p_key text,p_feature text,p_provider text,p_model text,p_input_sha256 text,
  p_hold_cents numeric,p_units numeric,p_unit_cost_cents numeric,p_meta jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.plan_entitlements; r public.app_video_cost_reservations;
  priced numeric; spent numeric; cap integer;
begin
  if p_actor is null or p_org is null or p_key is null or p_key !~ '^[!-~]{8,128}$'
    or p_feature is null or p_feature not in ('drone_render','aerial','reel')
    or p_provider is null or p_provider not in ('fal','kie','higgsfield')
    or p_model is null or length(p_model) not between 1 and 240 or p_model !~ '^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$'
    or p_input_sha256 is null or p_input_sha256 !~ '^[a-f0-9]{64}$' then
    raise exception 'RP400: Invalid video reservation identity';
  end if;
  -- Bounded numeric comparisons reject NaN and both infinities as well as
  -- overflow. Retain precise input quantities; ledger total is rounded once.
  if p_units is null or not(p_units>0 and p_units<=1000000)
    or p_unit_cost_cents is null or not(p_unit_cost_cents>0 and p_unit_cost_cents<=999999)
    or p_hold_cents is null or not(p_hold_cents>0 and p_hold_cents<=99999999) then
    raise exception 'RP400: Video pricing must be positive, finite and bounded';
  end if;
  priced:=round(p_units*p_unit_cost_cents,4);
  if priced<=0 or priced>p_hold_cents then raise exception 'RP400: Video hold does not cover its priced attempt'; end if;
  -- Only server-generated scalar routing/price facts; never prompts, URLs,
  -- customer labels, arbitrary room text, secrets or media bodies.
  if p_meta is null or jsonb_typeof(p_meta)<>'object' or octet_length(p_meta::text)>4096 then
    raise exception 'RP400: Invalid video accounting metadata';
  end if;
  if exists(select 1 from jsonb_each(p_meta) x where x.key not in
      ('tier','upscale_factor','target_fps','interpolated','estimate_cents','output_fps',
       'grounded','seconds','aspect','motion','motion_requested','space_type',
       'route_id','task','unit','price_estimated')
      or jsonb_typeof(x.value) not in ('string','number','boolean','null')
      or (jsonb_typeof(x.value)='string' and
        (length(x.value#>>'{}')>128 or (x.value#>>'{}') !~ '^[A-Za-z0-9._:/+-]*$' or strpos(x.value#>>'{}','://')>0))) then
    raise exception 'RP400: Unsupported video accounting metadata';
  end if;

  -- Identical lock identity to reflection and log_job_cost. The hold commits
  -- before the caller receives reserved:true and may make its single POST.
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));
  perform 1 from public.orgs where id=p_org and deleted_at is null for update;
  if not found then raise exception 'RP403: Workspace is unavailable for video processing'; end if;
  perform 1 from public.memberships where org_id=p_org and user_id=p_actor and role in ('owner','admin','agent') for share;
  if not found then raise exception 'RP403: Your role does not permit video processing'; end if;
  if exists(select 1 from public.deletion_requests where user_id=p_actor and status in ('pending','processing')) then
    raise exception 'RP409: This account is being deleted; no video submission was admitted';
  end if;
  if exists(select 1 from public.app_video_cost_reservations where org_id=p_org and idempotency_key=p_key) then
    -- Even the same actor/input/route is never a second dispatch permission.
    raise exception 'RP409: This video submission already has a reservation; no retry was made';
  end if;
  e:=public.org_entitlement(p_org);
  cap:=case p_feature when 'drone_render' then e.topaz_per_month when 'aerial' then e.aerials_per_month else e.reels_per_month end;
  if coalesce(cap,0)<=0 or coalesce(e.cogs_ceiling_cents,0)<=0 then raise exception 'RP402: Video processing is not included in this workspace plan'; end if;
  spent:=public.org_month_spend_cents(p_org);
  if spent is null or spent<0 or spent+p_hold_cents>e.cogs_ceiling_cents then
    raise exception 'RP402: Workspace monthly processing budget would be exceeded';
  end if;
  insert into public.app_video_cost_reservations(org_id,actor_id,idempotency_key,feature,provider,model,
    input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)
  values(p_org,p_actor,p_key,p_feature,p_provider,p_model,p_input_sha256,p_units,p_unit_cost_cents,priced,p_hold_cents,p_meta)
  returning * into r;
  return jsonb_build_object('reserved',true,'id',r.id,'org_id',r.org_id,'key',r.idempotency_key,
    'hold_cents',r.hold_cents,'total_cents',r.total_cents);
end $$;

create or replace function public.app_video_cost_settle(p_actor uuid,p_org uuid,p_key text,p_provider_request_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.app_video_cost_reservations; ledger uuid; live_org uuid;
begin
  if p_provider_request_id is null or length(p_provider_request_id) not between 1 and 256
    or p_provider_request_id !~ '^[!-~]+$' then
    raise exception 'RP400: A bounded provider request receipt is required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));
  select id into live_org from public.orgs where id=p_org for update;
  select * into r from public.app_video_cost_reservations
    where org_id=p_org and idempotency_key=p_key and actor_id=p_actor for update;
  if not found then raise exception 'RP409: Video reservation does not match this actor, workspace and key'; end if;
  if r.cost_ledger_id is not null then
    if r.provider_request_id<>p_provider_request_id then raise exception 'RP409: Provider receipt is immutable'; end if;
    return jsonb_build_object('settled',true,'ledger_id',r.cost_ledger_id,'total_cents',r.total_cents);
  end if;
  -- An accepted paid receipt remains accountable after role revocation or
  -- deletion. Settlement grants neither a new dispatch nor media access.
  -- If the org was physically erased, retain its accounting identity in meta
  -- while honoring cost_ledger's existing nullable org FK.
  insert into public.cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta,idempotency_key)
  values(live_org,r.feature,r.provider,r.model,r.units,r.unit_cost_cents,r.total_cents,
    r.meta||jsonb_build_object('app_video_reservation_id',r.id,'billing_org_id',r.org_id,
      'request_id',p_provider_request_id,'input_sha256',r.input_sha256,'held_cents',r.hold_cents,
      'price_estimated',true,'billing_reconciled',false), 'app-video:'||r.id::text)
  returning id into ledger;
  update public.app_video_cost_reservations set provider_request_id=p_provider_request_id,
    cost_ledger_id=ledger,settled_at=now() where id=r.id;
  return jsonb_build_object('settled',true,'ledger_id',ledger,'total_cents',r.total_cents);
end $$;
revoke all on function public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb),
  public.app_video_cost_settle(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb),
  public.app_video_cost_settle(uuid,uuid,text,text) to service_role;

comment on table public.app_video_cost_reservations is
  'Private immutable priced admission for one ordinary drone/aerial/reel POST. Unresolved holds never expire or authorize retry; settlement replaces the hold with one estimated cost ledger row atomically. No customer input/media is stored.';
