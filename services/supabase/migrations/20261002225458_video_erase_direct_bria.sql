-- Direct Bria uses two separately admitted paid stages. Existing fal receipts
-- retain their provider, queue reference, price and transport. No secret is stored.
alter table public.video_erase_jobs add column if not exists provider text not null default 'fal';
alter table public.video_erase_jobs add column if not exists provider_config jsonb not null default
  '{"model":"bria/video/erase/prompt","unit_cost_cents":14,"price_version":"fal-2026-09-19"}'::jsonb;
alter table public.video_erase_jobs drop constraint if exists video_erase_jobs_provider_check;
alter table public.video_erase_jobs add constraint video_erase_jobs_provider_check check(provider in ('fal','bria'));
-- A direct clip holds mask + erase together; the batch fence stays exactly240c.
alter table public.video_erase_jobs drop constraint if exists video_erase_jobs_cost_cents_check;
alter table public.video_erase_jobs add constraint video_erase_jobs_cost_cents_check check(cost_cents>0 and cost_cents<=240);
create table if not exists public.video_erase_stages (
  job_id uuid not null references public.video_erase_jobs(id) on delete cascade,
  stage text not null check(stage in ('mask','erase')),
  state text not null check(state in ('pending','dispatching','processing','completed','failed','uncertain','cancelled')),
  cost_cents numeric(14,6) not null check(cost_cents>0 and cost_cents<=240),
  unit_cost_cents numeric(14,6) not null check(unit_cost_cents>0 and unit_cost_cents<=240),
  provider_ref jsonb,
  output_url text,
  cost_ledger_id uuid references public.cost_ledger(id) on delete no action deferrable initially deferred,
  cost_hold_released_at timestamptz,
  admitted_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(job_id,stage)
);
alter table public.video_erase_stages enable row level security;
revoke all on public.video_erase_stages from public,anon,authenticated;
grant select,insert,update,delete on public.video_erase_stages to service_role;

create or replace function public.video_erase_pin_provider()
returns trigger language plpgsql set search_path=public as $$
begin
  if (new.provider,new.provider_config,new.duration_s,new.cost_cents) is distinct from
     (old.provider,old.provider_config,old.duration_s,old.cost_cents) then
    raise exception 'RP409: Reflection provider and pricing receipt are immutable';
  end if;
  return new;
end $$;
drop trigger if exists video_erase_provider_fixed on public.video_erase_jobs;
create trigger video_erase_provider_fixed before update on public.video_erase_jobs
  for each row execute function public.video_erase_pin_provider();

create or replace function public.video_erase_held_cents(p_org uuid)
returns numeric language plpgsql stable security definer set search_path=public as $$
begin
  if not (coalesce(auth.role()='service_role',false)
    or current_setting('role',true)='service_role'
    or (session_user=current_user and current_setting('role',true)='none')
    or exists(select 1 from memberships where org_id=p_org and user_id=auth.uid())) then return 0; end if;
  return (select coalesce(sum(cost_cents),0) from video_erase_jobs where org_id=p_org and provider='fal'
      and cost_ledger_id is null and cost_hold_released_at is null)
    +(select coalesce(sum(s.cost_cents),0) from video_erase_stages s join video_erase_jobs j on j.id=s.job_id
      where j.org_id=p_org and s.cost_ledger_id is null and s.cost_hold_released_at is null);
end $$;

create or replace function public.video_erase_job_json(p_job uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select to_jsonb(j)||case when j.provider='bria' then jsonb_build_object('stages',
    (select coalesce(jsonb_agg(to_jsonb(s) order by s.stage),'[]'::jsonb) from video_erase_stages s where s.job_id=j.id))
    else '{}'::jsonb end from video_erase_jobs j where j.id=p_job;
$$;

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
  if p_state='completed' and (p_url is null or p_key is null or (j.provider='fal' and p_ref is null)) then raise exception 'RP400: Completed output must be persisted'; end if;
  -- A confirmed provider receipt records real published-rate COGS once, even if
  -- the user cancelled. No provider receipt => hold remains for reconciliation.
  if j.provider='bria' and p_ref is not null then raise exception 'RP400: Direct provider receipts belong to a stage'; end if;
  if j.provider='bria' and p_state='completed' and (p_key<>'video-reflections/'||j.org_id||'/'||j.id||'.mp4' or (select count(*) from video_erase_stages where job_id=j.id and state='completed')<>2) then raise exception 'RP400: Direct output requires completed stages and its scoped storage key'; end if;
  if j.provider='fal' and p_ref is not null and j.cost_ledger_id is null then
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
  if j.provider='bria' and j.state in ('failed','uncertain','cancelled') then
    update video_erase_stages set state='cancelled',cost_hold_released_at=coalesce(cost_hold_released_at,now()),updated_at=now() where job_id=j.id and state='pending';
  end if;
  return video_erase_job_json(j.id);
end $$;

create or replace function public.video_erase_reserve_direct(p_org uuid,p_user uuid,p_listing uuid,p_batch uuid,p_asset uuid,p_idem uuid,p_hash text,p_seconds numeric,p_config jsonb,p_consent text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e plan_entitlements; a capture_assets; b video_erase_batches; j video_erase_jobs;
  cost numeric; mask_rate numeric; erase_rate numeric; config jsonb; batch_cost numeric; mw timestamptz; bw timestamptz;
begin
  perform video_erase_authorize(p_org,p_user,p_listing);
  -- One org lock serializes all reservations and applies/cancels for this feature.
  perform video_erase_expire(p_org);
  select * into j from video_erase_jobs where org_id=p_org and user_id=p_user and idempotency_key=p_idem;
  if found then
    if j.request_hash<>p_hash or j.batch_id<>p_batch or j.asset_id<>p_asset then raise exception 'RP409: Idempotency key was used for a different request'; end if;
    return jsonb_build_object('dispatch',false,'job',video_erase_job_json(j.id));
  end if;
  if p_batch is null or p_asset is null or p_idem is null or p_hash is null or p_hash !~ '^[a-f0-9]{64}$' then raise exception 'RP400: Invalid reflection request'; end if;
  select * into a from capture_assets where id=p_asset and listing_id=p_listing for share;
  if not found or not a.uploaded or a.bucket<>'renders' or a.kind<>'video' then raise exception 'RP400: A completed public video upload from this listing is required'; end if;
  if a.duration_s is null then raise exception 'RP409: Upload must have a probed duration'; end if;
  if not (a.duration_s>0 and a.duration_s<5) then raise exception 'RP400: Reflection clips must have positive finite duration under five seconds'; end if;
  if p_seconds is null then p_seconds:=a.duration_s; end if;
  if not(p_seconds>0 and p_seconds<5) or abs(p_seconds-a.duration_s)>0.15 then raise exception 'RP400: Probed clip duration does not match upload'; end if;
  if p_consent is distinct from 'bria-video-v1' then raise exception 'RP403: Direct Bria processing consent is required'; end if;
  if p_config is null or jsonb_typeof(p_config->'mask_unit_cost_cents') is distinct from 'number'
    or jsonb_typeof(p_config->'erase_unit_cost_cents') is distinct from 'number'
    or coalesce(p_config->>'price_version','') !~ '^[A-Za-z0-9_.:-]{1,120}$'
    or jsonb_typeof(p_config->'output_hosts') is distinct from 'array'
    or jsonb_array_length(p_config->'output_hosts') not between 1 and 16
    or exists(select 1 from jsonb_array_elements_text(p_config->'output_hosts') h where h !~ '^[a-z0-9][a-z0-9.-]*[a-z0-9]$' or h like '%..%') then
    raise exception 'RP400: Confirmed account-specific Bria pricing and output hosts are required';
  end if;
  mask_rate:=(p_config->>'mask_unit_cost_cents')::numeric; erase_rate:=(p_config->>'erase_unit_cost_cents')::numeric;
  if not(mask_rate>0 and mask_rate<=240 and erase_rate>0 and erase_rate<=240)
    or round(mask_rate,6)<>mask_rate or round(erase_rate,6)<>erase_rate then raise exception 'RP400: Invalid Bria price'; end if;
  config:=jsonb_build_object('mask_model','/v2/video/segment/mask_by_prompt','erase_model','/v2/video/edit/erase',
    'mask_unit_cost_cents',mask_rate,'erase_unit_cost_cents',erase_rate,
    'price_version',p_config->>'price_version','output_hosts',p_config->'output_hosts','consent_version',p_consent);
  cost:=round(p_seconds*mask_rate,6)+round(p_seconds*erase_rate,6);
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
  insert into video_erase_jobs(org_id,user_id,batch_id,asset_id,idempotency_key,request_hash,duration_s,cost_cents,state,monthly_window,burst_window,provider,provider_config)
    values(p_org,p_user,p_batch,p_asset,p_idem,p_hash,p_seconds,cost,'dispatching',mw,bw,'bria',config) returning * into j;
  insert into video_erase_stages(job_id,stage,state,cost_cents,unit_cost_cents,admitted_at) values
    (j.id,'mask','dispatching',p_seconds*mask_rate,mask_rate,now()),
    (j.id,'erase','pending',p_seconds*erase_rate,erase_rate,null);
  return jsonb_build_object('dispatch',true,'job',video_erase_job_json(j.id));
end $$;

-- Admit erase only after the durable mask receipt, and never re-admit a
-- dispatching/uncertain stage. Cancellation and membership changes win here.
create or replace function public.video_erase_admit_stage(p_org uuid,p_user uuid,p_job uuid,p_consent text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare j video_erase_jobs; s video_erase_stages; b video_erase_batches;
begin
  perform video_erase_authorize(p_org,p_user);
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));
  perform 1 from orgs where id=p_org for update;
  select * into j from video_erase_jobs where id=p_job and org_id=p_org and user_id=p_user for update;
  if not found or j.provider<>'bria' then raise exception 'RP404: Direct reflection job not found'; end if;
  if p_consent is distinct from j.provider_config->>'consent_version' then raise exception 'RP403: Direct Bria processing consent is required'; end if;
  select * into b from video_erase_batches where id=j.batch_id for update;
  perform video_erase_authorize(p_org,p_user,b.listing_id);
  select * into s from video_erase_stages where job_id=j.id and stage='erase' for update;
  if j.state in ('completed','failed','uncertain','cancelled') or b.state<>'open' or s.state<>'pending' then
    return jsonb_build_object('dispatch',false,'job',video_erase_job_json(j.id));
  end if;
  if j.created_at<now()-interval '30 minutes' then raise exception 'RP409: Reflection job expired'; end if;
  if not exists(select 1 from video_erase_stages where job_id=j.id and stage='mask' and state='completed' and provider_ref is not null and output_url is not null) then
    raise exception 'RP409: The mask must complete before erase admission';
  end if;
  update video_erase_stages set state='dispatching',admitted_at=now(),updated_at=now() where job_id=j.id and stage='erase';
  update video_erase_jobs set state='processing',updated_at=now() where id=j.id;
  return jsonb_build_object('dispatch',true,'job',video_erase_job_json(j.id));
end $$;

create or replace function public.video_erase_finish_stage(p_job uuid,p_stage text,p_state text,p_ref jsonb default null,p_output text default null,p_no_charge boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare j video_erase_jobs; s video_erase_stages; oid uuid; ledger uuid;
begin
  select org_id into oid from video_erase_jobs where id=p_job;
  if oid is null then raise exception 'RP404: Reflection job not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||oid::text,42));
  perform 1 from orgs where id=oid for update;
  select * into j from video_erase_jobs where id=p_job for update;
  select * into s from video_erase_stages where job_id=p_job and stage=p_stage for update;
  if j.provider<>'bria' or s.job_id is null or p_state not in ('processing','completed','failed','uncertain') then raise exception 'RP400: Invalid direct stage transition'; end if;
  if s.admitted_at is null then raise exception 'RP409: The paid stage must be admitted before its receipt'; end if;
  if s.provider_ref is not null and p_ref is not null and s.provider_ref<>p_ref then raise exception 'RP409: Provider stage receipt is immutable'; end if;
  if s.output_url is not null and p_output is not null and s.output_url<>p_output then raise exception 'RP409: Provider stage output is immutable'; end if;
  if p_state='completed' and (coalesce(s.provider_ref,p_ref) is null or p_output is null) then raise exception 'RP400: Completed stage requires a provider reference and output'; end if;
  -- A receipt is charged exactly once even if cancellation raced the response.
  if p_ref is not null and s.cost_ledger_id is null then
    insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)
    values(j.org_id,'video_declutter','bria',case when p_stage='mask' then '/v2/video/segment/mask_by_prompt' else '/v2/video/edit/erase' end,
      j.duration_s,s.unit_cost_cents,s.cost_cents,jsonb_build_object('erase_job_id',j.id,'batch_id',j.batch_id,'stage',p_stage,
      'request_id',p_ref->>'request_id','price_estimated',false,'price_basis','confirmed account-specific input-second rate',
      'price_version',j.provider_config->>'price_version','billing_reconciled',false)) returning id into ledger;
    s.cost_ledger_id:=ledger;
  end if;
  if s.state not in ('completed','failed','uncertain','cancelled') then s.state:=p_state; end if;
  if p_no_charge and p_state='failed' and s.provider_ref is null and p_ref is null and s.cost_ledger_id is null then
    s.cost_hold_released_at:=coalesce(s.cost_hold_released_at,now());
  end if;
  update video_erase_stages set state=s.state,provider_ref=coalesce(provider_ref,p_ref),
    output_url=coalesce(output_url,p_output),cost_ledger_id=s.cost_ledger_id,cost_hold_released_at=s.cost_hold_released_at,updated_at=now()
    where job_id=p_job and stage=p_stage;
  if j.state not in ('completed','failed','uncertain','cancelled') then
    if s.state in ('failed','uncertain') then
      perform video_erase_finish(j.id,s.state,null,null,null,
        'Reflection provider processing could not be completed. Your AI clip allowance was returned; no automatic retry was made.');
    else update video_erase_jobs set state='processing',updated_at=now() where id=j.id; end if;
  end if;
  -- No unpaid later stage may survive a terminal job. Already dispatched spend
  -- keeps its ledger/hold until reconciliation, as with legacy fal jobs.
  if (select state from video_erase_jobs where id=j.id) in ('failed','uncertain','cancelled') then
    update video_erase_stages set state='cancelled',cost_hold_released_at=coalesce(cost_hold_released_at,now()),updated_at=now()
      where job_id=j.id and state='pending';
  end if;
  return video_erase_job_json(j.id);
end $$;

create or replace function public.video_erase_get(p_org uuid,p_user uuid,p_job uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare j video_erase_jobs;
begin
  perform video_erase_authorize(p_org,p_user);
  select * into j from video_erase_jobs where id=p_job and org_id=p_org and user_id=p_user;
  if not found then raise exception 'RP404: Reflection job not found'; end if;
  return video_erase_job_json(j.id);
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
  return jsonb_build_object('job',video_erase_job_json(j.id));
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
    update video_erase_stages set state='cancelled',cost_hold_released_at=coalesce(cost_hold_released_at,now()),updated_at=now() where job_id=j.id and state='pending';
    update video_erase_jobs set state='cancelled',allowance_refunded_at=coalesce(allowance_refunded_at,now()),updated_at=now() where id=j.id;
    count_jobs:=count_jobs+1;
  end loop;
  return jsonb_build_object('status','cancelled','batch_id',bid,'cancelled_clips',count_jobs);
end $$;

create or replace function public.video_erase_expire(p_org uuid)
returns void language plpgsql security definer set search_path=public as $$
declare j video_erase_jobs;
begin
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_org::text,42));
  perform 1 from orgs where id=p_org for update;
  for j in select * from video_erase_jobs where org_id=p_org and state in ('dispatching','processing')
    and ((provider='fal' and ((state='dispatching' and created_at<now()-interval '2 minutes') or (state='processing' and created_at<now()-interval '30 minutes')))
      or (provider='bria' and (created_at<now()-interval '30 minutes' or exists(select 1 from video_erase_stages s where s.job_id=video_erase_jobs.id and s.state='dispatching' and s.admitted_at<now()-interval '2 minutes'))))
    order by id for update loop
    perform video_erase_finish(j.id,case when j.provider='bria' or j.provider_ref is null then 'uncertain' else 'failed' end,
      j.provider_ref,null,null,'Reflection processing expired. Your AI clip allowance was returned; no automatic retry was made.');
    update video_erase_stages set state='cancelled',cost_hold_released_at=coalesce(cost_hold_released_at,now()),updated_at=now() where job_id=j.id and state='pending';
  end loop;
end $$;

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
  values(p_org,b.listing_id,'video_reflection_removal','Walkthrough reflection removal',(select string_agg(distinct case when provider='bria' then 'bria:/v2/video/segment/mask_by_prompt+/v2/video/edit/erase' else 'bria/video/erase/prompt' end,', ' order by case when provider='bria' then 'bria:/v2/video/segment/mask_by_prompt+/v2/video/edit/erase' else 'bria/video/erase/prompt' end) from video_erase_jobs where batch_id=p_batch),'reflection_removal',orig.storage_key,edited.storage_key,
    'Selected portions of this walkthrough were edited with AI to remove visible people and reflections of the photographer or camera. The unedited walkthrough is provided for comparison.') returning * into prov;
  update video_erase_batches set state='applied',provenance_id=prov.id,original_asset_id=p_original,altered_asset_id=p_altered where id=p_batch;
  return jsonb_build_object('disclosure',prov.disclosure,'provenance',jsonb_build_object('id',prov.id,'recorded',true));
end $$;

revoke all on function public.video_erase_pin_provider(),public.video_erase_job_json(uuid),
 public.video_erase_reserve_direct(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric,jsonb,text),
 public.video_erase_admit_stage(uuid,uuid,uuid,text),public.video_erase_finish_stage(uuid,text,text,jsonb,text,boolean)
 from public,anon,authenticated;
grant execute on function public.video_erase_job_json(uuid),
 public.video_erase_reserve_direct(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric,jsonb,text),
 public.video_erase_admit_stage(uuid,uuid,uuid,text),public.video_erase_finish_stage(uuid,text,text,jsonb,text,boolean)
 to service_role;
