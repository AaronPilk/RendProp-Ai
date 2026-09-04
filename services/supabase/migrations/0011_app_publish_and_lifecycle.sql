-- 0011: app publishing is free + listing lifecycle + leads + poster (fix wave 1, 2026-09-03).
--
-- Addresses (audit findings F-supabase-04/05/06/07/08/13, F-E-05, F-G-13, decisions A3/A6/A13/A14/A15):
--   A15  App publishes must not consume "AI tour renders" (pricing says publishing
--        is free): render_jobs.source ('worker'|'app'); create_render_job(p_source)
--        stores it, uses effective_plan(), and counts ONLY source='worker' jobs
--        against the monthly cap and the 3-in-flight guard.
--   F-05 A failed publish-app left `created` jobs that locked the workspace:
--        fail_render_job() lets publish-app mark its own job failed; stale
--        app-source jobs self-heal after an hour.
--   F-08 App-published tours never got a poster: publish_render(p_poster_asset)
--        accepts an uploaded renders-bucket PHOTO asset of the same listing and
--        stores its key (server-derived — the anti-spoof intent of 0008 is kept).
--   F-13 listings.status accepts `uploading` (the iOS state) as well as `capturing`.
--   A14/F-06 Org names were the sign-in EMAIL and leaked onto public tours:
--        handle_new_user() names the org from user metadata or 'My business';
--        existing email-named orgs are renamed.
--   A13/F-02 Leads get a status (new|contacted|won|lost) + set_lead_status().
--   A3/F-07 Soft-deleting a listing unpublishes its renders (trigger), so /f/:slug
--        404s the moment the listing is deleted.
--   F-E-01 capture_assets.content_type_declared records whether the CLIENT declared
--        the ticket's content type (uploads relaxes the /complete equality check for
--        videos only when the type was server-defaulted).
--   PATCH /renders/:id/chapters → set_render_chapters() (room tags edited after publish).
--
-- Idempotent: every statement guards itself, so this file is safe to replay on
-- a database where it already ran and on a fresh database built from 0001.
-- Function signatures that CHANGE drop only their OLD signature first (a second
-- overload would make PostgREST RPC calls ambiguous).

-- ── 1. render_jobs.source ────────────────────────────────────────────────────

alter table public.render_jobs
  add column if not exists source text not null default 'worker';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.render_jobs'::regclass and conname = 'render_jobs_source_check'
  ) then
    alter table public.render_jobs
      add constraint render_jobs_source_check check (source in ('worker','app'));
  end if;
end $$;

comment on column public.render_jobs.source is
  'worker = queued for the Python render worker (counts against renders_per_month); app = the app published its own on-device render (free, never claimed by the worker).';

-- Backfill: a job whose asset lives in the public renders bucket can only have
-- come from POST /renders/publish-app. Marking it `app` stops it counting.
update public.render_jobs rj
   set source = 'app'
  from public.capture_assets a
 where a.id = rj.capture_asset_id
   and a.bucket = 'renders'
   and rj.source = 'worker';

create index if not exists idx_jobs_source_status on public.render_jobs (source, status);

-- ── 2. capture_assets.content_type_declared ─────────────────────────────────

alter table public.capture_assets
  add column if not exists content_type_declared boolean not null default false;

comment on column public.capture_assets.content_type_declared is
  'true when the client declared content_type at ticket time; false when the server defaulted it. /complete only requires observed == declared for videos when this is true (F-E-01).';

-- ── 3. leads.status ─────────────────────────────────────────────────────────

alter table public.leads
  add column if not exists status text not null default 'new';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.leads'::regclass and conname = 'leads_status_check'
  ) then
    alter table public.leads
      add constraint leads_status_check check (status in ('new','contacted','won','lost'));
  end if;
end $$;

create index if not exists idx_leads_org_status on public.leads (org_id, status, created_at);

-- ── 4. listings.status accepts the app's `uploading` state ──────────────────
-- iOS: draft|uploading|processing|ready|expired ; server: + capturing|archived.
-- Both vocabularies are accepted; the listings function validates against
-- this exact set and returns the accepted values in its 400.

do $$
declare v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
    from pg_constraint
   where conrelid = 'public.listings'::regclass and conname = 'listings_status_check';
  if v_def is null or v_def not like '%uploading%' then
    execute 'alter table public.listings drop constraint if exists listings_status_check';
    execute $c$alter table public.listings add constraint listings_status_check
              check (status in ('draft','capturing','uploading','processing','ready','expired','archived'))$c$;
  end if;
end $$;

-- ── 5. create_render_job(p_source): app publishes are free ──────────────────
-- Drop the OLD 5-argument signature first: keeping both overloads would make
-- PostgREST unable to choose a candidate for the 5-key RPC call.

drop function if exists public.create_render_job(uuid, uuid, text, jsonb, text);

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
        and rj.status in ('created','queued','claimed','processing');
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

-- ── 6. fail_render_job(): publish-app marks its own job failed ──────────────
-- Never overwrites a published job (F-G-13): a job with a renders row stays
-- `ready`. Idempotent: a job that is already failed is returned as-is.

create or replace function public.fail_render_job(
  p_job uuid,
  p_error text default null
) returns public.render_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job render_jobs;
  v_org uuid;
  v_role text;
begin
  select rj.* into v_job from render_jobs rj where rj.id = p_job for update;
  if not found then raise exception 'RP404: render job not found'; end if;

  select l.org_id into v_org from listings l where l.id = v_job.listing_id;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  v_role := org_role(v_org);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit updating renders';
  end if;

  if v_job.status = 'failed' then return v_job; end if;
  if v_job.status = 'ready' or exists (select 1 from renders r where r.job_id = p_job) then
    raise exception 'RP409: this job already published a tour and cannot be marked failed';
  end if;

  update render_jobs
     set status = 'failed',
         finished_at = now(),
         error = coalesce(error, '{}'::jsonb)
                 || jsonb_build_object(
                      'message', left(coalesce(nullif(trim(p_error), ''), 'publish failed'), 500),
                      'at', now(),
                      'by', 'fail_render_job')
   where id = p_job
   returning * into v_job;
  return v_job;
end;
$$;

revoke execute on function public.fail_render_job(uuid, text) from public, anon;
grant  execute on function public.fail_render_job(uuid, text) to authenticated, service_role;

-- ── 7. Chapters helper (shared by publish_render and set_render_chapters) ───
-- Bounded (≤60 rows, label ≤80, t_ms 0…86400000, sort 0…999 — `sort` is a
-- smallint and an unclamped value failed the whole publish, F-supabase-35) and
-- tolerant of "1234.5"/junk numerics so one bad chapter can't sink a publish.
-- Internal: callable only by the owner (the definer functions run as it).

create or replace function public.replace_asset_chapters(
  p_asset uuid,
  p_chapters jsonb
) returns integer
language plpgsql
set search_path = public
as $$
declare
  c jsonb;
  v_label text;
  v_n integer := 0;
  v_t numeric;
  v_sort numeric;
  v_list jsonb := case when jsonb_typeof(p_chapters) = 'array' then p_chapters else '[]'::jsonb end;
begin
  delete from capture_chapters where asset_id = p_asset;
  for c in select value from jsonb_array_elements(v_list) limit 60 loop
    v_label := left(trim(coalesce(c->>'label', c->>'name', '')), 80);
    if v_label <> '' then
      begin
        v_t := coalesce((c->>'t_ms')::numeric, (c->>'tMs')::numeric, 0);
      exception when others then
        v_t := 0;
      end;
      begin
        v_sort := coalesce((c->>'sort')::numeric, v_n);
      exception when others then
        v_sort := v_n;
      end;
      insert into capture_chapters (asset_id, label, t_ms, sort)
      values (
        p_asset,
        v_label,
        greatest(0, least(86400000, round(v_t)))::integer,
        greatest(0, least(999, round(v_sort)))::smallint
      );
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;

revoke execute on function public.replace_asset_chapters(uuid, jsonb) from public, anon, authenticated, service_role;

-- ── 8. publish_render(p_poster_asset): server-verified poster ───────────────
-- Drop the OLD 4-argument signature (see §5 for why).

drop function if exists public.publish_render(uuid, numeric, numeric, jsonb);

create or replace function public.publish_render(
  p_job uuid,
  p_duration numeric default null,
  p_speed numeric default 2.0,
  p_chapters jsonb default '[]'::jsonb,
  p_poster_asset uuid default null
) returns public.renders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job render_jobs;
  v_org uuid;
  v_role text;
  v_asset capture_assets;
  v_poster capture_assets;
  v_poster_key text := null;
  v_render renders;
  v_slug text;
  v_dur numeric;
  v_staged boolean;
  v_style text;
  attempt integer;
begin
  select rj.* into v_job from render_jobs rj where rj.id = p_job;
  if not found then raise exception 'RP404: render job not found'; end if;
  select l.org_id into v_org from listings l where l.id = v_job.listing_id and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  v_role := org_role(v_org);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit publishing renders';
  end if;

  -- Poster: SERVER-DERIVED key from an asset the caller could only have created
  -- through /uploads {role:"render", kind:"photo"} for this same listing. A free
  -- string here would let a caller point og:image at anything in the bucket.
  if p_poster_asset is not null then
    select a.* into v_poster from capture_assets a where a.id = p_poster_asset;
    if not found
       or v_poster.listing_id <> v_job.listing_id
       or coalesce(v_poster.bucket, 'uploads') <> 'renders'
       or v_poster.uploaded is not true
       or v_poster.kind <> 'photo' then
      raise exception 'RP400: poster_asset_id must be an uploaded photo in the renders bucket for this listing';
    end if;
    v_poster_key := v_poster.storage_key;
  end if;

  -- Serialize per job, then re-check: concurrent publishes previously raced the
  -- unique(job_id) index and surfaced RP500 instead of the existing render.
  perform pg_advisory_xact_lock(hashtextextended('publish_render:' || p_job::text, 42));
  select r.* into v_render from renders r where r.job_id = p_job;
  if found then
    -- Idempotent replay. A retry that now carries a poster completes the earlier
    -- poster-less publish instead of being ignored.
    if v_poster_key is not null and v_render.poster_key is null then
      update renders set poster_key = v_poster_key where id = v_render.id returning * into v_render;
    end if;
    return v_render;
  end if;

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

  -- SERVER-DERIVED ONLY. If any enhancement altered furniture/decor, the tour
  -- is disclosed as virtually staged — the caller gets no say (0008).
  v_style := lower(trim(coalesce(v_job.enhancements->>'style', '')));
  v_staged := coalesce((v_job.enhancements->>'declutter')::boolean, false)
              or (v_style <> '' and v_style not in ('as_is','as-is','asis','none'));

  perform replace_asset_chapters(v_asset.id, p_chapters);

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
              v_asset.storage_key, null, v_poster_key, v_staged, now())
      returning * into v_render;
      exit;
    exception when unique_violation then
      if attempt = 6 then raise exception 'RP500: could not allocate a unique slug'; end if;
    end;
  end loop;

  update render_jobs
     set status = 'ready', progress = 1, finished_at = now(), error = null
   where id = v_job.id;
  update listings set status = 'ready' where id = v_job.listing_id;

  return v_render;
end;
$$;

revoke execute on function public.publish_render(uuid, numeric, numeric, jsonb, uuid) from public, anon;
grant  execute on function public.publish_render(uuid, numeric, numeric, jsonb, uuid) to authenticated, service_role;

-- ── 9. set_render_chapters(): PATCH /renders/:id/chapters ───────────────────

create or replace function public.set_render_chapters(
  p_render uuid,
  p_chapters jsonb
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_render renders;
  v_job render_jobs;
  v_org uuid;
  v_role text;
begin
  select r.* into v_render from renders r where r.id = p_render;
  if not found then raise exception 'RP404: render not found'; end if;
  select l.org_id into v_org from listings l where l.id = v_render.listing_id and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  v_role := org_role(v_org);
  if v_role is null then raise exception 'RP404: render not found'; end if;  -- don't reveal existence
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit editing chapters';
  end if;

  select rj.* into v_job from render_jobs rj where rj.id = v_render.job_id;
  if not found or v_job.capture_asset_id is null then
    raise exception 'RP409: this render has no capture asset to attach chapters to';
  end if;

  return replace_asset_chapters(v_job.capture_asset_id, p_chapters);
end;
$$;

revoke execute on function public.set_render_chapters(uuid, jsonb) from public, anon;
grant  execute on function public.set_render_chapters(uuid, jsonb) to authenticated, service_role;

-- ── 10. set_lead_status(): PATCH /leads/:id ─────────────────────────────────
-- leads writes are revoked for tenants (0007); status changes go through here.

create or replace function public.set_lead_status(
  p_lead uuid,
  p_status text
) returns public.leads
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead leads;
  v_role text;
begin
  if p_status is null or p_status not in ('new','contacted','won','lost') then
    raise exception 'RP400: status must be new, contacted, won, or lost';
  end if;
  select l.* into v_lead from leads l where l.id = p_lead;
  if not found or v_lead.org_id is null then raise exception 'RP404: lead not found'; end if;

  v_role := org_role(v_lead.org_id);
  if v_role is null then raise exception 'RP404: lead not found'; end if;  -- don't reveal existence
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit updating leads';
  end if;

  update leads set status = p_status where id = p_lead returning * into v_lead;
  return v_lead;
end;
$$;

revoke execute on function public.set_lead_status(uuid, text) from public, anon;
grant  execute on function public.set_lead_status(uuid, text) to authenticated, service_role;

-- ── 11. handle_new_user(): the org is never named after the email ───────────
-- Sign in with Apple can pass `name`/`full_name` in raw_user_meta_data (the app
-- sends the formatted full name on first sign-in); otherwise 'My business'.
-- The email is PII the privacy manifest declares as app-functionality-only —
-- it must never become the public agent card (F-supabase-06, F-E-10).

create or replace function public.handle_new_user() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  new_org uuid;
  v_name text := left(trim(coalesce(
    nullif(trim(new.raw_user_meta_data->>'name'), ''),
    nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
    ''
  )), 120);
begin
  insert into public.profiles (id, email, name)
  values (new.id, new.email, v_name)
  on conflict (id) do nothing;
  insert into public.orgs (name, plan, trial_ends_at)
  values (
    case when v_name <> '' and v_name not like '%@%' then v_name else 'My business' end,
    'trial',
    now() + interval '7 days'
  )
  returning id into new_org;
  insert into public.memberships (user_id, org_id, role) values (new.id, new_org, 'owner');
  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- One-off remediation: orgs created by the old trigger carry the user's email.
update public.orgs set name = 'My business' where name like '%@%';

-- ── 12. Deleting a listing takes its public tour down ───────────────────────
-- SECURITY DEFINER because the UPDATE that fires it runs as the tenant, whose
-- direct writes on renders are revoked (0007); trigger firing itself is not
-- EXECUTE-checked, so the function is unreachable for clients.

create or replace function public.unpublish_deleted_listing_renders() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    update renders set published_at = null
     where listing_id = new.id and published_at is not null;
  end if;
  return new;
end;
$$;

revoke execute on function public.unpublish_deleted_listing_renders() from public, anon, authenticated;

drop trigger if exists trg_unpublish_deleted_listing on public.listings;
create trigger trg_unpublish_deleted_listing
  after update of deleted_at on public.listings
  for each row
  when (old.deleted_at is null and new.deleted_at is not null)
  execute function public.unpublish_deleted_listing_renders();

-- One-off remediation: tours of already-deleted listings.
update public.renders r
   set published_at = null
  from public.listings l
 where l.id = r.listing_id
   and l.deleted_at is not null
   and r.published_at is not null;
