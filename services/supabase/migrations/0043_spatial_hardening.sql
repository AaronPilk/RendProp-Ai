-- CLI scaffold: supabase migration new spatial_hardening. 0043 is the reserved
-- repo sequence (0042 is reserved by another slice). 0040 is live, so every
-- changed RPC below is a `create or replace` with its 0040 signature; nothing
-- here enables spending.
--
-- Three money/slot leaks in 0040, all confirmed by line-level review:
--   1. Cancelling a queued room left its worst-case reservation charged to both
--      budget windows. A cancelled job no longer counts toward the three-room
--      cap, so create -> attach -> start -> cancel in a loop drained the global
--      daily window without a single GPU second being bought.
--   2. Soft-deleting a listing made every actor call fail spatial_access, and
--      spatial_expire only ever touched `processing`. An uploading/queued room
--      of a binned listing therefore lived forever and held one of the org's
--      three active slots (plus its reservation, when queued).
--   3. Nothing aged out an uploading/queued room that simply stopped moving.
--
-- Lock order is unchanged from spatial_start: ownership locks (profile, org,
-- listing) -> job -> spatial_runtime -> spatial_budget_windows. spatial_expire
-- still takes no ownership lock at all.

-- The sweep now scans uploading/queued rooms by age; 0040 only indexed the
-- queue itself.
create index if not exists idx_spatial_pending on public.spatial_jobs(updated_at)
  where status in ('uploading','queued');

-- Hand a reservation back, but only when we are certain no GPU ever ran for
-- this attempt: the attempt never got a lease, and (once 0041 is deployed) the
-- provider journal holds no receipt for it other than a proven non-allocation.
-- An attempt that was claimed keeps its charge even if it later went nowhere,
-- exactly like 0040's expiry: uncertain spend is never refunded.
--
-- The caller already holds the job row lock. The windows released are the
-- ones the reservation was charged to (the UTC day and month of reserved_at),
-- never today's, so a next-day cancel cannot mint budget that was never held.
-- Returns the cents released (0 when nothing was, or when the charge stays).
create or replace function public.spatial_release_reservation(p_job uuid) returns integer
language plpgsql security invoker set search_path=public as $$
declare j spatial_jobs; day date; month date; orgscope text;
begin
  perform spatial_service_only();
  select * into strict j from spatial_jobs where id=p_job for update;
  if j.reserved_at is null or coalesce(j.max_cost_cents,0)<=0 then return 0; end if;
  if j.started_at is not null or j.lease_token is not null then return 0; end if;
  if to_regclass('public.spatial_provider_attempts') is not null then
    -- 0041 may not be deployed yet; this branch compiles lazily, so a missing
    -- journal is simply "no receipt", which the lease check above already
    -- covers (a receipt cannot exist without a lease).
    if exists(select 1 from spatial_provider_attempts
      where job_id=j.id and attempt_key=j.attempt_key and allocation_state<>'not_created') then return 0; end if;
  end if;
  day:=(j.reserved_at at time zone 'UTC')::date; month:=date_trunc('month',day)::date; orgscope:='org:'||j.org_id;
  perform 1 from spatial_runtime where singleton for update;
  perform 1 from spatial_budget_windows where (scope='global' and window_start=day) or (scope=orgscope and window_start=month)
    order by scope,window_start for update;
  update spatial_budget_windows set committed_cents=greatest(committed_cents-j.max_cost_cents,0)
    where (scope='global' and window_start=day) or (scope=orgscope and window_start=month);
  -- Clearing reserved_at is what makes a later resume -> start reserve again
  -- (and pass the budget check again) instead of reusing authority we gave back.
  update spatial_jobs set reserved_at=null,updated_at=clock_timestamp() where id=p_job;
  return j.max_cost_cents;
end $$;

-- spatial_access, minus the one clause that made a binned listing's room
-- immortal: the listing row may carry deleted_at. Everything else is identical
-- (same locks, same order, same deletion and membership checks, write roles
-- only). Only the cancel action uses this; every other action still goes
-- through spatial_access and is still refused for a soft-deleted listing.
create or replace function public.spatial_cancel_access(p_actor uuid,p_listing uuid) returns uuid
language plpgsql security invoker set search_path=public as $$
declare o uuid;
begin
  perform spatial_service_only();
  perform 1 from profiles where id=p_actor for update;
  if not found or exists
    (select 1 from deletion_requests where user_id=p_actor and status <> 'completed') then
    raise exception 'RP403: workspace is unavailable'; end if;
  select org_id into o from listings where id=p_listing;
  perform 1 from orgs where id=o and deleted_at is null for update;
  if not found then raise exception 'RP404: home not found'; end if;
  perform 1 from listings where id=p_listing and org_id=o for update;
  if not found or not exists(select 1 from memberships where org_id=o and user_id=p_actor
    and role in ('owner','admin','agent')) then raise exception 'RP403: home is not accessible'; end if;
  return o;
end $$;

-- 0040's spatial_recover with two changes, both confined to `cancel`: the
-- access check tolerates a soft-deleted listing, and a cancelled attempt that
-- never reached a worker gives its reservation back. resume and retry are
-- byte-for-byte 0040.
create or replace function public.spatial_recover(p_actor uuid,p_job uuid,p_action text,p_idem uuid default null)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare j spatial_jobs; l uuid; prior_attempt integer;
begin
  select listing_id into l from spatial_jobs where id=p_job;
  if p_action='cancel' then perform spatial_cancel_access(p_actor,l); else perform spatial_access(p_actor,l); end if;
  select * into strict j from spatial_jobs where id=p_job for update;
  if j.org_id is distinct from (select org_id from listings where id=j.listing_id) then raise exception 'RP403: room workspace changed'; end if;
  if p_action='cancel' then
    -- The early return is also what keeps a cancel replay from releasing twice.
    if j.status='failed' and j.failure_code='user_cancelled' then return to_jsonb(j); end if;
    if j.status not in ('uploading','queued') then raise exception 'RP409: only an undispatched room can be cancelled here'; end if;
    update spatial_jobs set status='failed',failure_code='user_cancelled',published_at=null,updated_at=clock_timestamp()
      where id=p_job;
    perform spatial_release_reservation(p_job);
    select * into strict j from spatial_jobs where id=p_job;
    return to_jsonb(j);
  elsif p_action='resume' then
    if j.status in ('uploading','queued') then return to_jsonb(j); end if;
    if j.status<>'failed' or j.failure_code is distinct from 'user_cancelled' or j.started_at is not null then
      raise exception 'RP409: only an undispatched cancelled capture can resume'; end if;
    if (select count(*) from spatial_jobs where org_id=j.org_id and status in ('uploading','queued','processing'))>=3 then
      raise exception 'RP429: finish another active room first'; end if;
    update spatial_jobs set status='uploading',failure_code=null,updated_at=clock_timestamp() where id=p_job returning * into j;
    return to_jsonb(j);
  elsif p_action<>'retry' or p_idem is null then raise exception 'RP400: explicit retry idempotency key is required'; end if;
  -- An exact transport replay acknowledges the already-created attempt even if
  -- that attempt subsequently finished. It never starts a third run by accident.
  if j.attempt_key=p_idem then
    if j.attempt_number=1 then raise exception 'RP409: retry needs a new operation key'; end if;
    return to_jsonb(j);
  end if;
  select attempt_number into prior_attempt from spatial_attempt_history where job_id=p_job and attempt_key=p_idem;
  if prior_attempt is not null then
    if prior_attempt=1 then raise exception 'RP409: retry needs a new operation key'; end if;
    return to_jsonb(j);
  end if;
  if j.status<>'failed' or j.failure_code='user_cancelled' or not j.inputs_complete then
    raise exception 'RP409: retry requires a failed generation with its complete saved capture'; end if;
  if j.attempt_number>=3 then raise exception 'RP429: this capture reached its three-attempt limit'; end if;
  if j.started_at is not null and not j.provider_stopped and (j.deadline_at is null or j.deadline_at>clock_timestamp()) then
    raise exception 'RP409: previous GPU termination is not confirmed; retry after its deadline'; end if;
  if (select count(*) from spatial_jobs where org_id=j.org_id and status in ('uploading','queued','processing'))>=3 then
    raise exception 'RP429: finish another active room first'; end if;
  insert into spatial_attempt_history(job_id,attempt_key,attempt_number,snapshot)
    values(j.id,j.attempt_key,j.attempt_number,to_jsonb(j));
  update spatial_jobs set attempt_number=attempt_number+1,attempt_key=p_idem,actor_id=p_actor,
    status='uploading',progress=0.25,failure_code=null,reserved_at=null,provider_stopped=false,cost_cents=0,
    lease_token=null,worker_id=null,lease_expires_at=null,deadline_at=null,started_at=null,
    artifact_revision=null,output_key=null,output_bytes=null,output_sha256=null,output_state=null,output_etag=null,
    scene_manifest=null,review_revision=null,reviewed_by=null,approved=false,excluded=false,redactions='[]',published_at=null,
    updated_at=clock_timestamp() where id=p_job;
  -- Revalidate the SAME immutable inputs and reserve atomically. A quota/config
  -- failure rolls this entire function back, including the attempted reset.
  return spatial_start(p_actor,p_job);
end $$;

-- 0040's expiry of overdue processing leases, unchanged, plus the two classes
-- of pending room that could previously never leave the active set:
--   * uploading/queued rooms whose listing (or workspace) is gone or binned,
--     which no actor call can reach any more (failure_code listing_deleted);
--   * uploading/queued rooms that have not moved in 48 hours
--     (failure_code capture_expired). Inputs stay saved; a complete capture
--     can still be retried explicitly, an incomplete one needs a recapture.
-- Each one gives its reservation back under the same never-allocated rule.
-- Still a separate short transaction with no ownership lock; rows another
-- transaction holds are skipped and picked up by the next sweep.
create or replace function public.spatial_expire(p_listing uuid default null) returns integer
language plpgsql security invoker set search_path=public as $$
declare n integer; stale record; freed integer:=0;
begin
  perform spatial_service_only();
  -- Separate short transaction: never take a job lock and then an ownership
  -- lock, which would invert the upload/adoption lock order.
  update spatial_jobs set status='failed',failure_code='worker_lease_expired',updated_at=clock_timestamp()
    where status='processing' and (p_listing is null or listing_id=p_listing)
      and (lease_expires_at<=clock_timestamp() or deadline_at<=clock_timestamp());
  get diagnostics n=row_count;
  for stale in
    select j.id,(l.id is null or l.deleted_at is not null or o.id is null or o.deleted_at is not null) as removed
      from spatial_jobs j left join listings l on l.id=j.listing_id left join orgs o on o.id=j.org_id
      where j.status in ('uploading','queued') and (p_listing is null or j.listing_id=p_listing)
        and (l.id is null or l.deleted_at is not null or o.id is null or o.deleted_at is not null
          or j.updated_at<=clock_timestamp()-interval '48 hours')
      order by j.id for update of j skip locked
  loop
    update spatial_jobs set status='failed',failure_code=case when stale.removed then 'listing_deleted' else 'capture_expired' end,
      published_at=null,updated_at=clock_timestamp() where id=stale.id;
    perform spatial_release_reservation(stale.id);
    freed:=freed+1;
  end loop;
  return n+freed;
end $$;

-- Same lockdown loop as 0040: the CI bootstrap mirrors Supabase's default
-- grant of ALL on new functions to the API roles, so this is load-bearing for
-- the two helpers created above and harmless to repeat.
do $$ declare f record; begin
  for f in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace and proname like 'spatial\_%' escape '\' loop
    execute format('revoke all on function %s from public,anon,authenticated',f.signature);
    execute format('grant execute on function %s to service_role',f.signature);
  end loop;
end $$;
