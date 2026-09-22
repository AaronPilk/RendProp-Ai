-- 0055: opt-in video reflection removal. No route flags or deployments changed.
-- Published Bria price verified 2026-09-19: https://fal.ai/models/bria/video/erase/prompt
-- $0.14/input second; strict source duration <5s. 240c total reserved per batch.
-- Service-only RPCs authorize caller identities against current membership.
-- Quota receipts retain the exact fixed window charged, not merely its length.

create table if not exists public.video_erase_batches (
  id uuid primary key,
  org_id uuid not null references public.orgs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  listing_id uuid references public.listings(id) on delete cascade,
  state text not null default 'open' check (state in ('open','cancelled','applied')),
  provenance_id uuid references public.media_provenance(id) on delete no action deferrable initially deferred,
  original_asset_id uuid references public.capture_assets(id) on delete no action deferrable initially deferred,
  altered_asset_id uuid references public.capture_assets(id) on delete no action deferrable initially deferred,
  created_at timestamptz not null default now(),
  check(state='cancelled' or listing_id is not null)
);
create table if not exists public.video_erase_jobs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  batch_id uuid not null references public.video_erase_batches(id) on delete cascade,
  asset_id uuid not null references public.capture_assets(id) on delete no action deferrable initially deferred,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[a-f0-9]{64}$'),
  duration_s numeric(12,6) not null check (duration_s > 0 and duration_s < 5),
  cost_cents numeric(14,6) not null check (cost_cents > 0 and cost_cents < 70),
  state text not null check (state in ('dispatching','processing','completed','failed','uncertain','cancelled')),
  provider_ref jsonb,
  output_url text,
  output_key text,
  error text,
  monthly_window timestamptz not null,
  burst_window timestamptz not null,
  allowance_refunded_at timestamptz,
  cost_hold_released_at timestamptz,
  cost_ledger_id uuid references public.cost_ledger(id) on delete no action deferrable initially deferred,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id,user_id,idempotency_key),
  unique (batch_id,asset_id)
);
create index if not exists video_erase_jobs_org on public.video_erase_jobs(org_id);
create index if not exists video_erase_jobs_batch on public.video_erase_jobs(batch_id);
alter table public.video_erase_batches enable row level security;
alter table public.video_erase_jobs enable row level security;
revoke all on public.video_erase_batches, public.video_erase_jobs from public,anon,authenticated;
grant select,insert,update,delete on public.video_erase_batches,public.video_erase_jobs to service_role;

-- Existing spend consumers (including log_job_cost and Topaz preflight) must
-- see unresolved paid-dispatch holds too. Keep the original ledger read under
-- invoker RLS; expose only an authorization-scoped aggregate of private jobs.
create or replace function public.video_erase_held_cents(p_org uuid)
returns numeric language plpgsql stable security definer set search_path=public as $$
begin
  if not (coalesce(auth.role()='service_role',false)
    or current_setting('role',true)='service_role'
    or (session_user=current_user and current_setting('role',true)='none')
    or exists(select 1 from memberships where org_id=p_org and user_id=auth.uid())) then return 0; end if;
  return (select coalesce(sum(cost_cents),0) from video_erase_jobs where org_id=p_org
    and cost_ledger_id is null and cost_hold_released_at is null);
end $$;
revoke all on function public.video_erase_held_cents(uuid) from public,anon,authenticated;
grant execute on function public.video_erase_held_cents(uuid) to authenticated,service_role;

create or replace function public.org_month_spend_cents(p_org uuid)
returns numeric language sql stable set search_path=public as $$
  select coalesce(sum(total_cents),0)+public.video_erase_held_cents(p_org)
    from cost_ledger where org_id=p_org and created_at>=date_trunc('month',now());
$$;

create or replace function public.video_erase_authorize(p_org uuid,p_user uuid,p_listing uuid default null)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from orgs o join memberships m on m.org_id=o.id
    where o.id=p_org and o.deleted_at is null and m.user_id=p_user and m.role in ('owner','admin','agent')) then
    raise exception 'RP403: Your role does not permit video reflection removal';
  end if;
  if p_listing is not null and not exists(select 1 from listings where id=p_listing and org_id=p_org and deleted_at is null) then
    raise exception 'RP404: Listing not found in this workspace';
  end if;
end $$;

-- Reclaim abandoned user allowance when the app returns, even if it never
-- persisted the submit receipt. Ambiguous provider COGS holds remain fenced.
create or replace function public.video_erase_expire(p_org uuid)
returns void language plpgsql security definer set search_path=public as $$
declare j video_erase_jobs;
begin
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));
  perform 1 from orgs where id=p_org for update;
  for j in select * from video_erase_jobs where org_id=p_org
    and ((state='dispatching' and created_at<now()-interval '2 minutes')
      or (state='processing' and created_at<now()-interval '30 minutes')) order by id for update loop
    perform video_erase_finish(j.id,case when j.provider_ref is null then 'uncertain' else 'failed' end,
      j.provider_ref,null,null,'Reflection processing expired. Your AI clip allowance was returned; no automatic retry was made.');
  end loop;
end $$;

create or replace function public.video_erase_quote(p_org uuid,p_user uuid,p_listing uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e plan_entitlements; used integer; spent numeric;
begin
  perform video_erase_authorize(p_org,p_user,p_listing);
  perform video_erase_expire(p_org);
  e:=org_entitlement(p_org);
  select coalesce(count,0) into used from rate_limits where key='reelmo:'||p_org
    and window_start>=now()-interval '30 days';
  spent:=org_month_spend_cents(p_org);
  return jsonb_build_object('available',e.reels_per_month>coalesce(used,0) and spent<e.cogs_ceiling_cents,
    'remaining_clips',greatest(0,e.reels_per_month-coalesce(used,0)),
    'max_clip_seconds',4.8,'max_batch_cents',least(240,greatest(0,e.cogs_ceiling_cents-spent)),'unit_cost_cents',14,
    'remaining_cost_cents',greatest(0,e.cogs_ceiling_cents-spent));
end $$;

create or replace function public.video_erase_existing(p_org uuid,p_user uuid,p_idem uuid,p_hash text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare j video_erase_jobs;
begin
  perform video_erase_authorize(p_org,p_user);
  perform video_erase_expire(p_org);
  select * into j from video_erase_jobs where org_id=p_org and user_id=p_user and idempotency_key=p_idem;
  if not found then return jsonb_build_object('job',null); end if;
  if j.request_hash<>p_hash then raise exception 'RP409: Idempotency key was used for a different request'; end if;
  return jsonb_build_object('job',to_jsonb(j));
end $$;

create or replace function public.video_erase_reserve(p_org uuid,p_user uuid,p_listing uuid,p_batch uuid,p_asset uuid,p_idem uuid,p_hash text,p_seconds numeric default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e plan_entitlements; a capture_assets; b video_erase_batches; j video_erase_jobs;
  cost numeric; batch_cost numeric; mw timestamptz; bw timestamptz;
begin
  perform video_erase_authorize(p_org,p_user,p_listing);
  -- One org lock serializes all reservations and applies/cancels for this feature.
  perform video_erase_expire(p_org);
  select * into j from video_erase_jobs where org_id=p_org and user_id=p_user and idempotency_key=p_idem;
  if found then
    if j.request_hash<>p_hash or j.batch_id<>p_batch or j.asset_id<>p_asset then raise exception 'RP409: Idempotency key was used for a different request'; end if;
    return jsonb_build_object('dispatch',false,'job',to_jsonb(j));
  end if;
  if p_batch is null or p_asset is null or p_idem is null or p_hash is null or p_hash !~ '^[a-f0-9]{64}$' then raise exception 'RP400: Invalid reflection request'; end if;
  select * into a from capture_assets where id=p_asset and listing_id=p_listing for share;
  if not found or not a.uploaded or a.bucket<>'renders' or a.kind<>'video' then raise exception 'RP400: A completed public video upload from this listing is required'; end if;
  if a.duration_s is null then raise exception 'RP409: Upload must have a probed duration'; end if;
  if not (a.duration_s>0 and a.duration_s<5) then raise exception 'RP400: Reflection clips must have positive finite duration under five seconds'; end if;
  if p_seconds is null then p_seconds:=a.duration_s; end if;
  if not(p_seconds>0 and p_seconds<5) or abs(p_seconds-a.duration_s)>0.15 then raise exception 'RP400: Probed clip duration does not match upload'; end if;
  cost:=p_seconds*14;
  select * into b from video_erase_batches where id=p_batch for update;
  if found then
    if b.org_id<>p_org or b.user_id<>p_user then raise exception 'RP404: Batch not found'; end if;
    if b.state<>'open' then raise exception 'RP409: This reflection batch is closed'; end if;
    if b.listing_id<>p_listing then raise exception 'RP404: Batch not found'; end if;
  else
    insert into video_erase_batches(id,org_id,user_id,listing_id) values(p_batch,p_org,p_user,p_listing);
  end if;
  if exists(select 1 from video_erase_jobs where batch_id=p_batch and asset_id=p_asset) then raise exception 'RP409: This clip already has a reflection job; reuse its idempotency key'; end if;
  select coalesce(sum(cost_cents),0) into batch_cost from video_erase_jobs where batch_id=p_batch;
  if batch_cost+cost>240 then raise exception 'RP402: Reflection batch exceeds its processing budget'; end if;
  e:=org_entitlement(p_org);
  if e.reels_per_month<=0 then raise exception 'RP402: Your plan does not include AI clips'; end if;
  if org_month_spend_cents(p_org)+cost>e.cogs_ceiling_cents then raise exception 'RP402: Workspace processing budget reached'; end if;
  if not bump_rate('aivideo:'||p_org,300,12,1) then raise exception 'RP429: Too many video jobs; try again later'; end if;
  select window_start into bw from rate_limits where key='aivideo:'||p_org;
  if not bump_rate('reelmo:'||p_org,2592000,e.reels_per_month,1) then raise exception 'RP402: Monthly AI clip allowance reached'; end if;
  select window_start into mw from rate_limits where key='reelmo:'||p_org;
  -- The claim commits BEFORE the network boundary. No caller can claim it again,
  -- even after a crash or an ambiguous provider response. A new paid retry is never automatic.
  insert into video_erase_jobs(org_id,user_id,batch_id,asset_id,idempotency_key,request_hash,duration_s,cost_cents,state,monthly_window,burst_window)
    values(p_org,p_user,p_batch,p_asset,p_idem,p_hash,p_seconds,cost,'dispatching',mw,bw) returning * into j;
  return jsonb_build_object('dispatch',true,'job',to_jsonb(j));
end $$;

-- Internal state transition. Service-only and addressed to a row already
-- authorized by the handler; provider accounting survives caller-role changes.
create or replace function public.video_erase_finish(p_job uuid,p_state text,p_ref jsonb default null,p_url text default null,p_key text default null,p_error text default null,p_no_charge boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare j video_erase_jobs; ledger uuid; oid uuid;
begin
  select org_id into oid from video_erase_jobs where id=p_job;
  if oid is null then raise exception 'RP404: Reflection job not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||oid::text,42));
  perform 1 from orgs where id=oid for update;
  select * into j from video_erase_jobs where id=p_job for update;
  if p_state not in ('processing','completed','failed','uncertain','cancelled') then raise exception 'RP400: Invalid reflection job state'; end if;
  if p_state='completed' and (p_ref is null or p_url is null or p_key is null) then raise exception 'RP400: Completed output must be persisted'; end if;
  -- A confirmed provider receipt records real published-rate COGS once, even if
  -- the user cancelled. No provider receipt => hold remains for reconciliation.
  if p_ref is not null and j.cost_ledger_id is null then
    insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)
    values(j.org_id,'video_declutter','fal','bria/video/erase/prompt',j.duration_s,14,j.cost_cents,
      jsonb_build_object('erase_job_id',j.id,'batch_id',j.batch_id,'request_id',p_ref->>'request_id',
        'price_estimated',false,'price_basis','authenticated fal pricing API input-second rate','price_verified_at','2026-09-19',
        'price_source','https://api.fal.ai/v1/models/pricing?endpoint_id=bria%2Fvideo%2Ferase%2Fprompt','billing_reconciled',false)) returning id into ledger;
    j.cost_ledger_id:=ledger;
  end if;
  if j.state not in ('completed','failed','uncertain','cancelled') then j.state:=p_state; end if;
  -- Exact-window refund: a late failure/cancel cannot mint quota in a new window.
  if j.state in ('failed','uncertain','cancelled') and j.allowance_refunded_at is null then
    update rate_limits set count=greatest(0,count-1) where key='reelmo:'||j.org_id
      and window_start=j.monthly_window and window_seconds=2592000 and window_start>=now()-interval '30 days';
    update rate_limits set count=greatest(0,count-1) where key='aivideo:'||j.org_id
      and window_start=j.burst_window and window_seconds=300 and window_start>=now()-interval '300 seconds';
    j.allowance_refunded_at:=now();
  end if;
  if p_no_charge and p_state='failed' and j.provider_ref is null and p_ref is null and j.cost_ledger_id is null then
    j.cost_hold_released_at:=coalesce(j.cost_hold_released_at,now());
  end if;
  update video_erase_jobs set state=j.state,provider_ref=coalesce(provider_ref,p_ref),
    output_url=case when j.state='completed' then coalesce(output_url,p_url) else output_url end,
    output_key=case when j.state='completed' then coalesce(output_key,p_key) else output_key end,
    error=coalesce(error,left(p_error,300)),cost_ledger_id=j.cost_ledger_id,
    allowance_refunded_at=j.allowance_refunded_at,cost_hold_released_at=j.cost_hold_released_at,updated_at=now() where id=p_job returning * into j;
  return to_jsonb(j);
end $$;

create or replace function public.video_erase_get(p_org uuid,p_user uuid,p_job uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare j video_erase_jobs;
begin
  perform video_erase_authorize(p_org,p_user);
  select * into j from video_erase_jobs where id=p_job and org_id=p_org and user_id=p_user;
  if not found then raise exception 'RP404: Reflection job not found'; end if;
  return to_jsonb(j);
end $$;

create or replace function public.video_erase_cancel(p_org uuid,p_user uuid,p_job uuid default null,p_batch uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare bid uuid; b video_erase_batches; j video_erase_jobs; count_jobs integer:=0;
begin
  perform video_erase_authorize(p_org,p_user);
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));
  perform 1 from orgs where id=p_org for update;
  if (p_job is null)=(p_batch is null) then raise exception 'RP400: Supply one request_id or batch_id'; end if;
  if p_job is not null then
    select batch_id into bid from video_erase_jobs where id=p_job and org_id=p_org and user_id=p_user;
    if not found then raise exception 'RP404: Reflection job not found'; end if;
  else bid:=p_batch; end if;
  select * into b from video_erase_batches where id=bid and org_id=p_org and user_id=p_user for update;
  if not found then
    if p_batch is null then raise exception 'RP404: Reflection batch not found'; end if;
    -- Cancellation can beat the first upload/POST. Reserve sees this durable
    -- tombstone and refuses a late request without consuming quota or dispatch.
    insert into video_erase_batches(id,org_id,user_id,state)
      values(p_batch,p_org,p_user,'cancelled') on conflict(id) do nothing;
    select * into b from video_erase_batches where id=bid and org_id=p_org and user_id=p_user for update;
    if not found then raise exception 'RP404: Reflection batch not found'; end if;
  end if;
  if b.state='applied' then raise exception 'RP409: Accepted reflection batch cannot be cancelled'; end if;
  update video_erase_batches set state='cancelled' where id=bid;
  for j in select * from video_erase_jobs where batch_id=bid order by id for update loop
    -- Discarding a completed edit refunds its allowance too; COGS stays recorded.
    if j.allowance_refunded_at is null then
      update rate_limits set count=greatest(0,count-1) where key='reelmo:'||j.org_id and window_start=j.monthly_window and window_seconds=2592000 and window_start>=now()-interval '30 days';
      update rate_limits set count=greatest(0,count-1) where key='aivideo:'||j.org_id and window_start=j.burst_window and window_seconds=300 and window_start>=now()-interval '300 seconds';
    end if;
    update video_erase_jobs set state='cancelled',allowance_refunded_at=coalesce(allowance_refunded_at,now()),updated_at=now() where id=j.id;
    count_jobs:=count_jobs+1;
  end loop;
  return jsonb_build_object('status','cancelled','batch_id',bid,'cancelled_clips',count_jobs);
end $$;

alter table public.media_provenance drop constraint if exists media_provenance_kind_check;
alter table public.media_provenance add constraint media_provenance_kind_check
  check(kind in ('photo_edit','virtual_stage','declutter','aerial','reel','other','video_reflection_removal'));

create or replace function public.video_erase_apply(p_org uuid,p_user uuid,p_batch uuid,p_original uuid,p_altered uuid,p_validate_only boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b video_erase_batches; orig capture_assets; edited capture_assets; prov media_provenance; count_jobs integer;
begin
  perform video_erase_authorize(p_org,p_user);
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));
  perform 1 from orgs where id=p_org for update;
  select * into b from video_erase_batches where id=p_batch and org_id=p_org and user_id=p_user for update;
  if not found then raise exception 'RP404: Reflection batch not found'; end if;
  if b.state='applied' then
    if b.original_asset_id is distinct from p_original or b.altered_asset_id is distinct from p_altered then raise exception 'RP409: Batch was already accepted with different video assets'; end if;
    select * into prov from media_provenance where id=b.provenance_id;
    return jsonb_build_object('disclosure',prov.disclosure,'provenance',jsonb_build_object('id',prov.id,'recorded',true));
  end if;
  if b.state<>'open' then raise exception 'RP409: Cancelled reflection batch cannot be accepted'; end if;
  perform video_erase_authorize(p_org,p_user,b.listing_id);
  select count(*) into count_jobs from video_erase_jobs where batch_id=p_batch;
  if count_jobs=0 or exists(select 1 from video_erase_jobs where batch_id=p_batch and (state<>'completed' or output_key is null or allowance_refunded_at is not null)) then raise exception 'RP409: Every selected reflection clip must finish before acceptance'; end if;
  select * into orig from capture_assets where id=p_original and listing_id=b.listing_id for share;
  select * into edited from capture_assets where id=p_altered and listing_id=b.listing_id for share;
  if orig.id is null or edited.id is null or orig.id=edited.id or not orig.uploaded or not edited.uploaded
    or orig.kind<>'video' or edited.kind<>'video' or orig.bucket<>'renders' or edited.bucket<>'renders'
    or orig.duration_s is null or edited.duration_s is null or not(orig.duration_s>0 and orig.duration_s<=600)
    or not(edited.duration_s>0 and edited.duration_s<=600)
    or abs(orig.duration_s-edited.duration_s)>0.15 then raise exception 'RP400: A complete original and edited video from this listing with matching duration are required'; end if;
  if exists(select 1 from video_erase_jobs where batch_id=p_batch and asset_id in (p_original,p_altered)) then raise exception 'RP400: Clip uploads cannot stand in for the complete walkthrough'; end if;
  if (select count(*) from media_provenance where listing_id=b.listing_id)>=500 then raise exception 'RP429: Listing provenance limit reached'; end if;
  if p_validate_only then return jsonb_build_object('ready',true); end if;
  insert into media_provenance(org_id,listing_id,kind,label,model_id,edit,original_key,altered_key,disclosure)
  values(p_org,b.listing_id,'video_reflection_removal','Walkthrough reflection removal','bria/video/erase/prompt','reflection_removal',orig.storage_key,edited.storage_key,
    'Selected portions of this walkthrough were edited with AI to remove visible people and reflections of the photographer or camera. The unedited walkthrough is provided for comparison.') returning * into prov;
  update video_erase_batches set state='applied',provenance_id=prov.id,original_asset_id=p_original,altered_asset_id=p_altered where id=p_batch;
  return jsonb_build_object('disclosure',prov.disclosure,'provenance',jsonb_build_object('id',prov.id,'recorded',true));
end $$;

-- Do not let the legacy photo-only PATCH substitute photographs into a verified
-- video pair after apply. Label edits remain safe; media and identity are fixed.
create or replace function public.protect_video_erase_provenance()
returns trigger language plpgsql set search_path=public as $$
begin
  if old.kind='video_reflection_removal' and (new.kind,new.org_id,new.listing_id,new.original_key,new.altered_key,new.disclosure)
    is distinct from (old.kind,old.org_id,old.listing_id,old.original_key,old.altered_key,old.disclosure) then
    raise exception 'RP409: Accepted reflection provenance cannot be relinked';
  end if;
  return new;
end $$;
drop trigger if exists video_erase_provenance_fixed on public.media_provenance;
create trigger video_erase_provenance_fixed before update on public.media_provenance for each row execute function public.protect_video_erase_provenance();

revoke all on function public.video_erase_authorize(uuid,uuid,uuid), public.video_erase_expire(uuid), public.video_erase_quote(uuid,uuid,uuid),
  public.video_erase_existing(uuid,uuid,uuid,text), public.video_erase_reserve(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric), public.video_erase_finish(uuid,text,jsonb,text,text,text,boolean),
  public.video_erase_get(uuid,uuid,uuid),public.video_erase_cancel(uuid,uuid,uuid,uuid),public.video_erase_apply(uuid,uuid,uuid,uuid,uuid,boolean),public.protect_video_erase_provenance() from public,anon,authenticated;
grant execute on function public.video_erase_authorize(uuid,uuid,uuid), public.video_erase_expire(uuid), public.video_erase_quote(uuid,uuid,uuid),
  public.video_erase_existing(uuid,uuid,uuid,text), public.video_erase_reserve(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric), public.video_erase_finish(uuid,text,jsonb,text,text,text,boolean),
  public.video_erase_get(uuid,uuid,uuid),public.video_erase_cancel(uuid,uuid,uuid,uuid),public.video_erase_apply(uuid,uuid,uuid,uuid,uuid,boolean) to service_role;
