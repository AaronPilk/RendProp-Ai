-- CLI scaffold: supabase migration new spatial_provider_attempts. 0041 is the
-- reserved repo sequence. This migration neither enables a worker nor spending.
-- No FKs: provider cleanup identities must outlive purged room/account records.
create table if not exists public.spatial_provider_attempts (
  lease_token uuid primary key, job_id uuid not null, attempt_key uuid not null,
  app_name text not null check(app_name='rendprop-spatial-worker'),
  sandbox_name text not null unique,
  sandbox_id text unique check(sandbox_id ~ '^sb-[A-Za-z0-9]{8,100}$'),
  source_sha256 text not null check(source_sha256 ~ '^[a-f0-9]{64}$'),
  allocation_state text not null default 'planned' check(allocation_state in ('planned','created','unknown','not_created')),
  deadline_at timestamptz not null,
  files_removed boolean not null default false, terminated boolean not null default false,
  exit_code integer check(exit_code between -255 and 255),
  reason_code text check(reason_code in ('billing_cycle_spend_limit','provider_terminal','unavailable')),
  last_error_code text check(last_error_code in ('allocation_unknown','files_remove_failed','termination_failed','journal_unavailable')),
  created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
  unique(job_id,attempt_key),
  check(sandbox_name='spatial-'||job_id::text||'-'||lease_token::text),
  check(allocation_state<>'created' or sandbox_id is not null),
  check(allocation_state<>'not_created' or (sandbox_id is null and files_removed and terminated))
);
create index if not exists idx_spatial_provider_pending on public.spatial_provider_attempts(updated_at)
  where not (files_removed and terminated);
alter table public.spatial_provider_attempts enable row level security;
revoke all on public.spatial_provider_attempts from public,anon,authenticated;
grant select,insert,update on public.spatial_provider_attempts to service_role;

create or replace function public.spatial_provider_attempt_update(
  p_job uuid,p_lease uuid,p_attempt uuid,p_action text,p_data jsonb)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare j spatial_jobs; r spatial_provider_attempts; l uuid; actor uuid; dispatch boolean:=false;
begin
  perform spatial_service_only();
  if p_job is null or p_lease is null or p_attempt is null or p_action is null
    or jsonb_typeof(p_data) is distinct from 'object' or octet_length(p_data::text)>4096 then
    raise exception 'RP400: invalid provider receipt'; end if;
  if p_action='plan' then
    -- Same ownership/lock order as claim/delete; commit intent BEFORE CREATE.
    select listing_id,actor_id into l,actor from spatial_jobs where id=p_job;
    perform spatial_access(actor,l);
    select * into strict j from spatial_jobs where id=p_job for update;
    if j.status<>'processing' or j.lease_token is distinct from p_lease or j.attempt_key is distinct from p_attempt
      or j.deadline_at is null or j.lease_expires_at is null
      or j.deadline_at<=clock_timestamp() or j.lease_expires_at<=clock_timestamp() then
      raise exception 'RP409: provider lease is not current'; end if;
    if p_data->>'app_name' is distinct from 'rendprop-spatial-worker'
      or p_data->>'sandbox_name' is distinct from 'spatial-'||p_job::text||'-'||p_lease::text
      or (p_data->>'source_sha256') is null or (p_data->>'source_sha256') !~ '^[a-f0-9]{64}$' then
      raise exception 'RP400: invalid provider identity'; end if;
    insert into spatial_provider_attempts(lease_token,job_id,attempt_key,app_name,sandbox_name,source_sha256,deadline_at)
      values(p_lease,p_job,p_attempt,p_data->>'app_name',p_data->>'sandbox_name',p_data->>'source_sha256',j.deadline_at)
      on conflict(lease_token) do nothing returning * into r;
    dispatch:=found;
  end if;
  select * into r from spatial_provider_attempts where lease_token=p_lease for update;
  if not found or r.job_id is distinct from p_job or r.attempt_key is distinct from p_attempt then
    raise exception 'RP409: provider attempt was not journaled'; end if;
  if p_action='plan' then
    if r.source_sha256 is distinct from p_data->>'source_sha256' then
      raise exception 'RP409: provider source changed'; end if;
  elsif p_action in ('created','cleanup','unknown','not_created') then
    -- Cleanup does NOT consult the deleted account/room. Identity was fenced in
    -- plan, and these updates cannot change it or authorize another allocation.
    if p_data ? 'sandbox_id' then
      if (p_data->>'sandbox_id') is null or (p_data->>'sandbox_id') !~ '^sb-[A-Za-z0-9]{8,100}$'
        or (r.sandbox_id is not null and r.sandbox_id is distinct from p_data->>'sandbox_id')
        or r.allocation_state='not_created' then raise exception 'RP409: provider identity changed'; end if;
      r.sandbox_id:=p_data->>'sandbox_id';
    end if;
    if p_action='created' then
      if r.sandbox_id is null or r.terminated then raise exception 'RP409: invalid created receipt'; end if;
      r.allocation_state:='created';
    elsif p_action='unknown' and r.allocation_state='planned' then r.allocation_state:='unknown';
    elsif p_action='not_created' then
      if r.sandbox_id is not null or r.allocation_state='created' or p_data->>'proof' is distinct from 'create_not_invoked' then
        raise exception 'RP409: absence of allocation is not proven'; end if;
      r.allocation_state:='not_created'; r.files_removed:=true; r.terminated:=true;
    end if;
    if p_data ? 'files_removed' then
      if jsonb_typeof(p_data->'files_removed')<>'boolean' then raise exception 'RP400: invalid cleanup flag'; end if;
      r.files_removed:=r.files_removed or (p_data->>'files_removed')::boolean;
    end if;
    if p_data ? 'terminated' then
      if jsonb_typeof(p_data->'terminated')<>'boolean' then raise exception 'RP400: invalid cleanup flag'; end if;
      r.terminated:=r.terminated or (p_data->>'terminated')::boolean;
    end if;
    if (r.files_removed or r.terminated) and r.sandbox_id is null and r.allocation_state<>'not_created' then
      raise exception 'RP409: cleanup requires a known provider identity'; end if;
    update spatial_provider_attempts set sandbox_id=r.sandbox_id,allocation_state=r.allocation_state,
      files_removed=r.files_removed,terminated=r.terminated,
      exit_code=coalesce((p_data->>'exit_code')::integer,exit_code),
      reason_code=coalesce(p_data->>'reason_code',reason_code),
      last_error_code=coalesce(p_data->>'last_error_code',last_error_code),updated_at=clock_timestamp()
      where lease_token=p_lease returning * into r;
  else raise exception 'RP400: unknown provider receipt transition'; end if;
  return jsonb_build_object('ok',true,'dispatch',dispatch,'lease_token',r.lease_token,
    'job_id',r.job_id,'attempt_key',r.attempt_key,'allocation_state',r.allocation_state,
    'files_removed',r.files_removed,'terminated',r.terminated,'sandbox_id',r.sandbox_id);
end $$;
revoke all on function public.spatial_provider_attempt_update(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.spatial_provider_attempt_update(uuid,uuid,uuid,text,jsonb) to service_role;
