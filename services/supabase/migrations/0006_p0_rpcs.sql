-- 0006: P0 hardening — additive half (deploy THIS, then the new function
-- versions, then 0007_p0_lockdown.sql which revokes the old direct-write paths).
--
-- Fixes from the 2026-08-27 release audit:
--   P0-3  monthly rate-limit counters were deleted daily by bump_rate cleanup
--   P0-3  render job creation had no entitlement / budget / idempotency
--   P0-3  cost ledger was a non-atomic read/sum/insert/update sequence
--   P0-2  upload ticket limits were charged per batch, not per file (cost arg)
--   P0-4  account deletion needs a durable, retryable tombstone
--   (+)   beacon metering upsert made atomic

-- ── 1. bump_rate v2: per-row window length + cost, correct cleanup ───────────
-- The old cleanup deleted EVERY counter older than 1 day, silently resetting
-- 30-day monthly caps. Rows now remember their own window; cleanup only removes
-- rows whose window has fully expired (plus a day of grace).

alter table public.rate_limits
  add column if not exists window_seconds integer not null default 86400;

drop function if exists public.bump_rate(text, integer, integer);

create or replace function public.bump_rate(
  p_key text,
  p_window_seconds integer,
  p_max integer,
  p_cost integer default 1
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  allowed boolean;
  v_cost integer := greatest(1, coalesce(p_cost, 1));
begin
  insert into rate_limits as r (key, window_start, count, window_seconds)
  values (p_key, now(), v_cost, p_window_seconds)
  on conflict (key) do update set
    count = case
      when r.window_start < now() - make_interval(secs => p_window_seconds) then excluded.count
      else r.count + excluded.count
    end,
    window_start = case
      when r.window_start < now() - make_interval(secs => p_window_seconds) then now()
      else r.window_start
    end,
    window_seconds = excluded.window_seconds
  returning count <= p_max into allowed;

  -- Opportunistic cleanup (~1% of calls): only rows whose OWN window expired.
  if random() < 0.01 then
    delete from rate_limits
      where window_start < now() - make_interval(secs => window_seconds) - interval '1 day';
  end if;

  return allowed;
end;
$$;

revoke execute on function public.bump_rate(text, integer, integer, integer) from public, anon, authenticated;
grant  execute on function public.bump_rate(text, integer, integer, integer) to service_role;

-- ── 2. Role helper (P0-7 groundwork) ─────────────────────────────────────────
-- owner/admin/agent may write product data; marketing is read-only.

create or replace function public.org_role(target uuid) returns text
language sql security definer stable
set search_path = public
as $$
  select m.role from memberships m where m.org_id = target and m.user_id = auth.uid() limit 1;
$$;
revoke execute on function public.org_role(uuid) from public, anon;
grant  execute on function public.org_role(uuid) to authenticated, service_role;

-- ── 3. Render job idempotency + 1:1 render invariant ─────────────────────────

alter table public.render_jobs add column if not exists idem_key text;
create unique index if not exists uq_render_jobs_idem
  on public.render_jobs (listing_id, idem_key) where idem_key is not null;

-- One published render per job → publish becomes naturally idempotent.
create unique index if not exists uq_renders_job on public.renders (job_id);

-- ── 4. create_render_job: atomic entitlement + budget + idempotency ─────────
-- Plan caps are the launch defaults (free early access = 20 tours/month;
-- pro = 100; team = 400). One org can hold at most 3 unfinished jobs.

create or replace function public.create_render_job(
  p_listing uuid,
  p_asset uuid,
  p_tier text default 'smooth',
  p_enhancements jsonb default '{}'::jsonb,
  p_idem text default null
) returns public.render_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_plan text;
  v_cap integer;
  v_used integer;
  v_active integer;
  v_job render_jobs;
begin
  select l.org_id into v_org from listings l where l.id = p_listing and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;
  if not is_org_member(v_org) then raise exception 'RP403: not a member of this workspace'; end if;

  perform 1 from capture_assets a where a.id = p_asset and a.listing_id = p_listing;
  if not found then raise exception 'RP404: asset not found for this listing'; end if;

  if p_tier not in ('smooth','premium4k','cinematic') then
    raise exception 'RP400: tier must be smooth, premium4k, or cinematic';
  end if;

  -- Idempotent replay: same listing + Idempotency-Key returns the original job.
  if p_idem is not null and length(p_idem) between 8 and 128 then
    select rj.* into v_job from render_jobs rj
      where rj.listing_id = p_listing and rj.idem_key = p_idem;
    if found then return v_job; end if;
  end if;

  -- Serialize job creation per org so caps can't be raced past.
  perform pg_advisory_xact_lock(hashtextextended('render_jobs:' || v_org::text, 42));

  select count(*) into v_active
    from render_jobs rj join listings l on l.id = rj.listing_id
    where l.org_id = v_org and rj.status in ('created','queued','claimed','processing');
  if v_active >= 3 then
    raise exception 'RP429: this workspace already has % renders in flight — wait for one to finish', v_active;
  end if;

  select o.plan into v_plan from orgs o where o.id = v_org;
  v_cap := case v_plan when 'team' then 400 when 'pro' then 100 else 20 end;
  select count(*) into v_used
    from render_jobs rj join listings l on l.id = rj.listing_id
    where l.org_id = v_org and rj.created_at >= date_trunc('month', now());
  if v_used >= v_cap then
    raise exception 'RP402: monthly render limit reached for the % plan (% of %)', coalesce(v_plan,'free'), v_used, v_cap;
  end if;

  insert into render_jobs (listing_id, capture_asset_id, tier, enhancements, status, progress, idem_key)
  values (p_listing, p_asset, p_tier, coalesce(p_enhancements, '{}'::jsonb), 'created', 0,
          case when p_idem is not null and length(p_idem) between 8 and 128 then p_idem else null end)
  returning * into v_job;
  return v_job;
end;
$$;

revoke execute on function public.create_render_job(uuid, uuid, text, jsonb, text) from public, anon;
grant  execute on function public.create_render_job(uuid, uuid, text, jsonb, text) to authenticated, service_role;

-- ── 5. publish_render: server-derived keys, atomic, idempotent ───────────────
-- Callers can no longer supply video_key/stream_uid/poster_key/staged state:
-- the video key comes from the job's completed role=render upload, staging is
-- derived from the job's enhancements, and the whole publish (render row +
-- chapters + job/listing status) commits or rolls back together.

create or replace function public.publish_render(
  p_job uuid,
  p_duration numeric default null,
  p_speed numeric default 2.0,
  p_staged boolean default null,
  p_chapters jsonb default '[]'::jsonb
) returns public.renders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job render_jobs;
  v_org uuid;
  v_asset capture_assets;
  v_render renders;
  v_slug text;
  v_dur numeric;
  v_staged boolean;
  v_style text;
  c jsonb;
  v_label text;
  v_n integer := 0;
  attempt integer;
begin
  select rj.* into v_job from render_jobs rj where rj.id = p_job;
  if not found then raise exception 'RP404: render job not found'; end if;
  select l.org_id into v_org from listings l where l.id = v_job.listing_id;
  if v_org is null or not is_org_member(v_org) then
    raise exception 'RP403: not a member of this workspace';
  end if;

  -- Idempotent: a job publishes exactly once.
  select r.* into v_render from renders r where r.job_id = p_job;
  if found then return v_render; end if;

  if v_job.capture_asset_id is null then raise exception 'RP400: job has no capture asset'; end if;
  select a.* into v_asset from capture_assets a where a.id = v_job.capture_asset_id;
  if not found then raise exception 'RP404: capture asset not found'; end if;
  if coalesce(v_asset.bucket, 'uploads') <> 'renders' then
    raise exception 'RP400: the job asset is not a role=render upload';
  end if;
  if v_asset.uploaded is not true then
    raise exception 'RP409: the render upload is not complete';
  end if;

  v_dur := coalesce(p_duration, v_asset.duration_s);
  if v_dur is null or v_dur <= 0 or v_dur > 7200 then
    raise exception 'RP400: duration_s is required (0 < s <= 7200)';
  end if;

  v_style := lower(trim(coalesce(v_job.enhancements->>'style', '')));
  v_staged := coalesce(p_staged,
    coalesce((v_job.enhancements->>'declutter')::boolean, false)
      or (v_style <> '' and v_style not in ('as_is','as-is','asis','none')));

  -- Chapters: bounded, sanitized, replacing any prior rows for the asset.
  delete from capture_chapters where asset_id = v_asset.id;
  for c in select value from jsonb_array_elements(coalesce(p_chapters, '[]'::jsonb)) limit 60 loop
    v_label := left(trim(coalesce(c->>'label', c->>'name', '')), 80);
    if v_label <> '' then
      insert into capture_chapters (asset_id, label, t_ms, sort)
      values (
        v_asset.id,
        v_label,
        greatest(0, least(86400000, coalesce((c->>'t_ms')::integer, (c->>'tMs')::integer, 0))),
        coalesce((c->>'sort')::integer, v_n)
      );
      v_n := v_n + 1;
    end if;
  end loop;

  for attempt in 1..6 loop
    v_slug := (
      select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', (random()*30)::integer + 1, 1), '')
      from generate_series(1, 10)
    );
    begin
      insert into renders (job_id, listing_id, slug, duration_s, speed_factor,
                           video_key, stream_uid, poster_key, staged, published_at)
      values (v_job.id, v_job.listing_id, v_slug, v_dur,
              greatest(0.25, least(8.0, coalesce(p_speed, 2.0))),
              v_asset.storage_key, null, null, v_staged, now())
      returning * into v_render;
      exit;
    exception when unique_violation then
      if attempt = 6 then raise exception 'RP500: could not allocate a unique slug'; end if;
    end;
  end loop;

  update render_jobs
     set status = 'ready', progress = 1, finished_at = now()
   where id = v_job.id;
  update listings set status = 'ready' where id = v_job.listing_id;

  return v_render;
end;
$$;

revoke execute on function public.publish_render(uuid, numeric, numeric, boolean, jsonb) from public, anon;
grant  execute on function public.publish_render(uuid, numeric, numeric, boolean, jsonb) to authenticated, service_role;

-- ── 6. log_job_cost: atomic ledger write + cap under a row lock ──────────────

create or replace function public.log_job_cost(
  p_job uuid,
  p_org uuid,
  p_feature text,
  p_provider text,
  p_model text,
  p_units numeric,
  p_unit_cost numeric,
  p_meta jsonb,
  p_cap_cents numeric
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total numeric;
  v_line numeric;
begin
  perform 1 from render_jobs where id = p_job for update;
  if not found then raise exception 'RP404: render job not found'; end if;

  select coalesce(sum(total_cents), 0) into v_total from cost_ledger where job_id = p_job;
  v_line := round((coalesce(p_units, 1) * coalesce(p_unit_cost, 0))::numeric, 4);

  if v_total + v_line > p_cap_cents then
    raise exception 'RP402: cost cap exceeded — job at %¢, +%¢ would pass the %¢ cap', v_total, v_line, p_cap_cents;
  end if;

  insert into cost_ledger (job_id, org_id, feature, provider, model, units, unit_cost_cents, total_cents, meta)
  values (p_job, p_org, p_feature, p_provider, p_model, coalesce(p_units, 1), coalesce(p_unit_cost, 0), v_line, coalesce(p_meta, '{}'::jsonb));

  update render_jobs set cost_cents = round(v_total + v_line) where id = p_job;
  return v_total + v_line;
end;
$$;

revoke execute on function public.log_job_cost(uuid, uuid, text, text, text, numeric, numeric, jsonb, numeric) from public, anon, authenticated;
grant  execute on function public.log_job_cost(uuid, uuid, text, text, text, numeric, numeric, jsonb, numeric) to service_role;

-- ── 7. bump_metering: atomic view-metering upsert with server-side clamps ────

create or replace function public.bump_metering(
  p_render uuid,
  p_org uuid,
  p_views integer,
  p_watch_ms bigint,
  p_streamed numeric,
  p_scroll numeric
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into metering as m (render_id, org_id, day, views, watch_ms, streamed_minutes, max_scroll_depth)
  values (
    p_render, p_org, current_date,
    least(1, greatest(0, coalesce(p_views, 0))),
    least(300000, greatest(0, coalesce(p_watch_ms, 0))),
    least(60, greatest(0, coalesce(p_streamed, 0))),
    least(1, greatest(0, coalesce(p_scroll, 0)))
  )
  on conflict (render_id, day) do update set
    views            = m.views + least(1, greatest(0, coalesce(p_views, 0))),
    watch_ms         = m.watch_ms + least(300000, greatest(0, coalesce(p_watch_ms, 0))),
    streamed_minutes = round((m.streamed_minutes + least(60, greatest(0, coalesce(p_streamed, 0))))::numeric, 2),
    max_scroll_depth = greatest(m.max_scroll_depth, least(1, greatest(0, coalesce(p_scroll, 0))));
end;
$$;

revoke execute on function public.bump_metering(uuid, uuid, integer, bigint, numeric, numeric) from public, anon, authenticated;
grant  execute on function public.bump_metering(uuid, uuid, integer, bigint, numeric, numeric) to service_role;

-- ── 8. Durable account deletion (P0-4) ───────────────────────────────────────
-- DELETE /me writes a tombstone BEFORE destroying anything; every external
-- cleanup (R2, Stream, CRM, Apple revocation) that fails stays queued here and
-- is retried by the sweeper until the payload is empty.

create table if not exists public.deletion_requests (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null,               -- auth id (profile row will be gone)
  email         text,
  status        text not null default 'pending'
                check (status in ('pending','processing','completed','failed')),
  attempts      integer not null default 0,
  payload       jsonb not null default '{}', -- { r2:[{bucket,key}], stream_uids:[], ghl_emails:[], apple_refresh_token? }
  last_error    text,
  requested_at  timestamptz not null default now(),
  completed_at  timestamptz
);
alter table public.deletion_requests enable row level security;  -- no policies: service-role only
create index if not exists idx_deletion_status on public.deletion_requests (status, requested_at);

-- Sign in with Apple revocation (TN3194): the server exchanges the sign-in
-- authorizationCode for a refresh token and stores it here; DELETE /me revokes
-- it so the user's Apple grant is cleanly severed.
alter table public.profiles add column if not exists apple_refresh_token text;

-- ── 9. Data-quality constraints + missing FK indexes ─────────────────────────

alter table public.render_jobs
  add constraint chk_jobs_progress check (progress >= 0 and progress <= 1) not valid;
alter table public.render_jobs
  add constraint chk_jobs_cost check (cost_cents >= 0) not valid;
alter table public.renders
  add constraint chk_renders_duration check (duration_s > 0 and duration_s <= 7200) not valid;
alter table public.metering
  add constraint chk_metering_nonneg
  check (views >= 0 and watch_ms >= 0 and streamed_minutes >= 0
         and max_scroll_depth >= 0 and max_scroll_depth <= 1) not valid;
alter table public.listings
  add constraint chk_listings_coords
  check ((lat is null or (lat >= -90 and lat <= 90)) and (lng is null or (lng >= -180 and lng <= 180))) not valid;
alter table public.capture_assets
  add constraint chk_assets_bytes check (bytes is null or bytes >= 0) not valid;

create index if not exists idx_chapters_asset on public.capture_chapters (asset_id);
create index if not exists idx_leads_render   on public.leads (render_id);
create index if not exists idx_leads_listing  on public.leads (listing_id);
create index if not exists idx_renders_listing on public.renders (listing_id);
create index if not exists idx_jobs_listing    on public.render_jobs (listing_id);
create index if not exists idx_metering_org    on public.metering (org_id, day);
