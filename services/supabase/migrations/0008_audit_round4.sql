-- 0008: fixes for the round-4 external audit (2026-08-29).
--
-- Addresses, in severity order:
--   P0-3  publish_render let the CALLER set `staged`, defeating the virtual-
--         staging disclosure that MLS/advertising rules require.
--   P0-3  create_render_job consumed plan entitlement for assets that were
--         never uploaded (denial-of-wallet + guaranteed worker failure).
--   P0-3  create_render_job / publish_render checked membership but never ROLE,
--         so a `marketing` member could burn paid render entitlement.
--   P0-3  the Idempotency-Key lookup ran BEFORE the advisory lock, so two
--         concurrent calls with the same key raced: the loser hit the unique
--         index and got an error instead of the original job.
--   P0-6  coordinates were coarsened only in one Swift helper; the listings
--         API and direct Data-API writes stored full precision, and the public
--         tour + its Google Maps link exposed it.
--   P0-7  a member of two orgs could re-parent a listing by updating org_id /
--         agent_id straight through PostgREST.

-- ── 1. P0-6: coarsen coordinates in the DATABASE, at every write path ───────
-- ~3 decimals ≈ 110 m. Enforced by trigger so the Edge API, the worker, and any
-- direct Data-API call all get the same treatment — the privacy manifest's
-- "coarse location" claim is now true by construction rather than by client
-- convention.

create or replace function public.coarsen_listing_coords() returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.lat is not null then new.lat := round(new.lat::numeric, 3); end if;
  if new.lng is not null then new.lng := round(new.lng::numeric, 3); end if;
  return new;
end;
$$;

drop trigger if exists trg_coarsen_listing_coords on public.listings;
create trigger trg_coarsen_listing_coords
  before insert or update of lat, lng on public.listings
  for each row execute function public.coarsen_listing_coords();

-- Remediate rows already stored at full precision.
update public.listings
   set lat = round(lat::numeric, 3)
 where lat is not null and lat <> round(lat::numeric, 3);
update public.listings
   set lng = round(lng::numeric, 3)
 where lng is not null and lng <> round(lng::numeric, 3);

-- ── 2. P0-7: ownership columns are not tenant-writable ─────────────────────
-- The Edge route strips org_id/agent_id, but that does nothing for direct
-- PostgREST calls. Re-grant UPDATE column-by-column, omitting the ownership
-- and server-controlled columns so a two-org member can't re-parent a listing.

-- NOTE: this list must stay in sync with WRITABLE in functions/listings/
-- index.ts. Omitting a legitimate product column (status/space_type/source were
-- missed on the first pass) silently breaks client writes.
revoke update on public.listings from authenticated, anon;
grant update (
  space_type, address, tagline, details, beds, baths, sqft, price_cents,
  zillow_url, main_photo_key, lat, lng, status, sold_at, source, mls_ref,
  deleted_at
) on public.listings to authenticated;

-- ── 3. P0-3: create_render_job — role, uploaded-asset, post-lock idempotency ─

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
  v_role text;
  v_plan text;
  v_cap integer;
  v_used integer;
  v_active integer;
  v_job render_jobs;
  v_idem text := case when p_idem is not null and length(p_idem) between 8 and 128 then p_idem else null end;
begin
  select l.org_id into v_org from listings l where l.id = p_listing and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  -- Role, not just membership: marketing is read-only on product data and must
  -- not be able to spend the workspace's paid render entitlement.
  v_role := org_role(v_org);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit creating renders';
  end if;

  -- The asset must exist for this listing AND actually be uploaded. Creating a
  -- job for an unuploaded asset burned entitlement and then failed in the
  -- worker (audit: denial-of-wallet).
  perform 1 from capture_assets a
    where a.id = p_asset and a.listing_id = p_listing and a.uploaded is true;
  if not found then
    raise exception 'RP409: asset not found for this listing, or its upload is not complete';
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

  perform pg_advisory_xact_lock(hashtextextended('render_jobs:' || v_org::text, 42));

  -- RE-CHECK after the lock: a concurrent caller with the same key may have
  -- inserted while we waited. Without this the loser hit the unique index and
  -- errored instead of receiving the original job (audit).
  if v_idem is not null then
    select rj.* into v_job from render_jobs rj
      where rj.listing_id = p_listing and rj.idem_key = v_idem;
    if found then return v_job; end if;
  end if;

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
  values (p_listing, p_asset, p_tier, coalesce(p_enhancements, '{}'::jsonb), 'created', 0, v_idem)
  returning * into v_job;
  return v_job;
end;
$$;

revoke execute on function public.create_render_job(uuid, uuid, text, jsonb, text) from public, anon;
grant  execute on function public.create_render_job(uuid, uuid, text, jsonb, text) to authenticated, service_role;

-- ── 4. P0-3: publish_render — staged is SERVER-DERIVED, role enforced ───────
-- p_staged is intentionally GONE from the signature. Virtual-staging
-- disclosure must never be something the client can switch off.

drop function if exists public.publish_render(uuid, numeric, numeric, boolean, jsonb);

create or replace function public.publish_render(
  p_job uuid,
  p_duration numeric default null,
  p_speed numeric default 2.0,
  p_chapters jsonb default '[]'::jsonb
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
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  v_role := org_role(v_org);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit publishing renders';
  end if;

  -- Serialize per job, then re-check: concurrent publishes previously raced the
  -- unique(job_id) index and surfaced RP500 instead of the existing render.
  perform pg_advisory_xact_lock(hashtextextended('publish_render:' || p_job::text, 42));
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

  -- SERVER-DERIVED ONLY. If any enhancement altered furniture/decor, the tour
  -- is disclosed as virtually staged — the caller gets no say.
  v_style := lower(trim(coalesce(v_job.enhancements->>'style', '')));
  v_staged := coalesce((v_job.enhancements->>'declutter')::boolean, false)
              or (v_style <> '' and v_style not in ('as_is','as-is','asis','none'));

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

revoke execute on function public.publish_render(uuid, numeric, numeric, jsonb) from public, anon;
grant  execute on function public.publish_render(uuid, numeric, numeric, jsonb) to authenticated, service_role;

-- ── 5. Validate the constraints 0006 added NOT VALID ────────────────────────
-- They guarded new writes but were never checked against existing rows.

do $$
declare c record;
begin
  for c in
    select conrelid::regclass as tbl, conname
      from pg_constraint
     where not convalidated and contype = 'c'
       and conrelid in ('public.render_jobs'::regclass, 'public.renders'::regclass,
                        'public.metering'::regclass, 'public.listings'::regclass,
                        'public.capture_assets'::regclass)
  loop
    begin
      execute format('alter table %s validate constraint %I', c.tbl, c.conname);
    exception when check_violation then
      raise warning 'constraint % on % has violating rows — remediate then re-validate', c.conname, c.tbl;
    end;
  end loop;
end $$;
