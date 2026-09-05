-- 0015: worker job leases, attempt counting and stuck-job recovery
--       (2026-09-04, audit F-G-05).
--
-- Without this a worker that dies mid-render (SIGKILL from a platform deploy
-- timeout below FFMPEG_TIMEOUT_S, an OOM, a lost node) leaves its job at
-- `status='processing'` FOREVER. Nothing re-queues it, the app polls a job that
-- never finishes, and — because 0011's in-flight guard counts every
-- source='worker' job in (created, queued, claimed, processing) — after three
-- such orphans `create_render_job` raises RP429 for EVERY subsequent publish in
-- that org, including free app-published base tours. The workspace is locked
-- out of publishing until someone edits rows by hand.
--
-- The lease is a wall-clock deadline on the claim: the owning worker refreshes
-- it from a heartbeat thread every WORKER_HEARTBEAT_S (default 60 s), so a
-- deadline in the past with status='processing' means the holder is gone.
-- `attempts` bounds the retries so a poison input cannot loop; at
-- WORKER_MAX_ATTEMPTS (default 3) the worker's reaper marks the job failed with
-- error->>'type' = 'poison' instead of reclaiming it again.
--
-- The worker (services/worker/db.py) probes for these three columns ONCE at
-- first claim and, when they are absent, runs exactly as before behind a loud
-- warning — so this migration is what LIGHTS UP recovery, not what unblocks the
-- worker. Deploy order: apply the migration first, then restart the workers (a
-- worker started before the migration latches "no lease support" for the life
-- of its process).
--
-- Idempotent: `add column if not exists` / `create index if not exists` /
-- `create or replace function`, and the one-off orphan release in §2 is guarded
-- on the lease so a replay can never yank a job that is legitimately running.

-- ── 1. lease columns ─────────────────────────────────────────────────────────

alter table public.render_jobs
  add column if not exists lease_expires_at timestamptz,
  add column if not exists attempts         integer not null default 0,
  add column if not exists worker_id        text;

comment on column public.render_jobs.lease_expires_at is
  'Wall-clock deadline on the current claim. The owning worker refreshes it every '
  'WORKER_HEARTBEAT_S (default 60s). Past this instant with status=processing the '
  'job is orphaned and reclaimable.';
comment on column public.render_jobs.attempts is
  'Times this job has been claimed. At WORKER_MAX_ATTEMPTS (default 3) the reaper '
  'marks it failed with error->>type = ''poison'' instead of looping forever.';
comment on column public.render_jobs.worker_id is
  'Host:pid (or WORKER_ID) of the worker holding the lease. The heartbeat filters on '
  'it so a worker that lost the race can never extend someone else''s lease.';

-- The claim/reclaim/reaper queries all filter on (status, lease_expires_at).
create index if not exists idx_jobs_lease
  on public.render_jobs (status, lease_expires_at)
  where status = 'processing';

-- ── 2. one-off: release orphans that already exist ───────────────────────────
-- Rows stranded by a worker that died BEFORE leases existed. `lease_expires_at`
-- is null on every such row, which is also what makes this replay-safe: once
-- workers are leasing, a long-running render (FFMPEG_TIMEOUT_S defaults to
-- 5400 s, so >2 h wall clock is normal for a cinematic 4K job) carries a lease
-- in the FUTURE and is skipped. Without that guard a second run of this file
-- would re-queue live work and publish the same tour twice.
--
-- Released, not failed: the capture is fine, nobody has been billed for a
-- finished tour, and the next worker to poll picks it up. `error` is cleared
-- because this is not a failure.

update public.render_jobs
   set status = 'queued', started_at = null, progress = 0,
       current_step = 'requeued: orphaned before 0015', error = null
 where status = 'processing'
   and source = 'worker'
   and started_at < now() - interval '2 hours'
   and lease_expires_at is null;

-- ── 3. create_render_job(): an expired lease is not "in flight" ──────────────
-- Reproduced verbatim from 0011 §5 (the LATEST definition of this function —
-- 0009's 5-argument version is skipped whenever the 6-argument one exists, and
-- 0011 drops it outright). Signature, security definer, search_path, every
-- authorization check, both caps and the grants are UNCHANGED. The single edit
-- is the in-flight-count predicate below:
--
--     was:  and rj.status in ('created','queued','claimed','processing')
--     now:  and ( rj.status in ('created','queued','claimed')
--                 or (rj.status = 'processing'
--                     and (rj.lease_expires_at is null
--                          or rj.lease_expires_at > now())) )
--
-- An orphan is not in flight; it is dead. `lease_expires_at is null` keeps
-- pre-0015 rows (and rows written by a worker too old to lease) counted, which
-- is the safe direction: a job is never silently uncapped. 'created', 'queued'
-- and 'claimed' stay counted unconditionally — no worker holds a lease in those
-- states, so lease-checking them would weaken the cap.

create or replace function public.create_render_job(
  p_listing uuid,
  p_asset uuid,
  p_tier text default 'smooth',
  p_enhancements jsonb default '{}'::jsonb,
  p_idem text default null,
  p_source text default 'worker'
) returns public.render_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_role text;
  v_plan text;
  v_cap integer;
  v_used integer;
  v_active integer;
  v_recent integer;
  v_job render_jobs;
  v_asset capture_assets;
  v_source text := coalesce(nullif(trim(p_source), ''), 'worker');
  v_idem text := case when p_idem is not null and length(p_idem) between 8 and 128 then p_idem else null end;
begin
  if v_source not in ('worker','app') then
    raise exception 'RP400: source must be worker or app';
  end if;

  select l.org_id into v_org from listings l where l.id = p_listing and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  -- Role, not just membership: marketing is read-only on product data and must
  -- not be able to spend the workspace's paid render entitlement.
  v_role := org_role(v_org);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit creating renders';
  end if;

  -- The asset must exist for this listing AND actually be uploaded (audit:
  -- creating a job for an unuploaded asset burned entitlement, then failed).
  select a.* into v_asset from capture_assets a
    where a.id = p_asset and a.listing_id = p_listing and a.uploaded is true;
  if not found then
    raise exception 'RP409: asset not found for this listing, or its upload is not complete';
  end if;
  -- An app publish must point at a role=render upload; checking here (not only
  -- in publish_render) means a bad asset fails BEFORE a job row exists.
  if v_source = 'app' then
    if coalesce(v_asset.bucket, 'uploads') <> 'renders' then
      raise exception 'RP400: an app publish must reference a role=render upload (renders bucket)';
    end if;
    if v_asset.kind <> 'video' then
      raise exception 'RP400: the publish asset must be a video';
    end if;
  end if;

  if p_tier not in ('smooth','premium4k','cinematic') then
    raise exception 'RP400: tier must be smooth, premium4k, or cinematic';
  end if;

  -- Fast path: an already-recorded idempotent replay.
  if v_idem is not null then
    select rj.* into v_job from render_jobs rj
      where rj.listing_id = p_listing and rj.idem_key = v_idem;
    if found then return v_job; end if;
  end if;

  -- Serialize job creation per org so caps can't be raced past.
  perform pg_advisory_xact_lock(hashtextextended('render_jobs:' || v_org::text, 42));

  -- RE-CHECK after the lock: a concurrent caller with the same key may have
  -- inserted while we waited (audit: the loser hit the unique index).
  if v_idem is not null then
    select rj.* into v_job from render_jobs rj
      where rj.listing_id = p_listing and rj.idem_key = v_idem;
    if found then return v_job; end if;
  end if;

  -- Self-heal: an app-source job that never reached publish_render (a crash
  -- between the two RPCs) is dead after an hour. Mark it failed so it can never
  -- be mistaken for in-flight work by anything that lists this org's jobs.
  update render_jobs rj
     set status = 'failed',
         finished_at = now(),
         error = coalesce(rj.error, '{}'::jsonb)
                 || jsonb_build_object('message', 'publish did not complete', 'code', 'stale_app_job')
    from listings l
   where l.id = rj.listing_id and l.org_id = v_org
     and rj.source = 'app' and rj.status = 'created'
     and rj.created_at < now() - interval '1 hour';

  if v_source = 'worker' then
    -- In-flight guard counts ONLY worker jobs: app jobs are transient (created →
    -- ready in the same request) and must never lock a workspace (F-supabase-05).
    select count(*) into v_active
      from render_jobs rj join listings l on l.id = rj.listing_id
      where l.org_id = v_org and rj.source = 'worker'
        and (
          rj.status in ('created','queued','claimed')
          or (rj.status = 'processing'
              and (rj.lease_expires_at is null or rj.lease_expires_at > now()))
        );
    if v_active >= 3 then
      raise exception 'RP429: this workspace already has % renders in flight — wait for one to finish', v_active;
    end if;

    -- Monthly cap from plan_entitlements via effective_plan() (an expired trial
    -- is `free` here exactly as it is for the AI routes). App publishes are
    -- excluded from the count: pricing promises publishing is free.
    v_plan := coalesce(effective_plan(v_org), 'free');
    v_cap := coalesce(plan_render_cap(v_plan), 0);
    select count(*) into v_used
      from render_jobs rj join listings l on l.id = rj.listing_id
      where l.org_id = v_org and rj.source = 'worker'
        and rj.created_at >= date_trunc('month', now());
    if v_used >= v_cap then
      raise exception 'RP402: monthly render limit reached for the % plan (% of %)', v_plan, v_used, v_cap;
    end if;
  else
    -- Free, but not unbounded: a runaway client loop must not mint slugs forever.
    select count(*) into v_recent
      from render_jobs rj join listings l on l.id = rj.listing_id
      where l.org_id = v_org and rj.source = 'app'
        and rj.created_at >= now() - interval '1 hour';
    if v_recent >= 60 then
      raise exception 'RP429: too many publishes in the last hour for this workspace — try again later';
    end if;
  end if;

  insert into render_jobs (listing_id, capture_asset_id, tier, enhancements, status, progress, idem_key, source)
  values (p_listing, p_asset, p_tier, coalesce(p_enhancements, '{}'::jsonb), 'created', 0, v_idem, v_source)
  returning * into v_job;
  return v_job;
end;
$$;

revoke execute on function public.create_render_job(uuid, uuid, text, jsonb, text, text) from public, anon;
grant  execute on function public.create_render_job(uuid, uuid, text, jsonb, text, text) to authenticated, service_role;
