-- 0016: record what the AI pipeline actually DID, and disclose from that
--       (2026-09-04, audit F-G-01 #2 / F-G-09).
--
-- Two problems, one root cause: nothing in the database recorded the OUTCOME of
-- an enhancement run, so the only thing publish_render could read was the
-- user's REQUEST.
--
-- 1. DISCLOSURE (the serious one). `renders.staged` is derived from the toggles
--    the caller picked (0008 §4, carried forward by 0011 §8), so a tour is
--    stamped "✦ Virtually staged" plus the MLS disclosure sheet even when no
--    pixel was ever altered — because the pipeline skipped the segment, QC
--    rejected the edit, the spend ceiling stopped it, or (F-G-01) no worker was
--    reachable at all. That is the compliance failure in reverse: a legal
--    disclosure attached to media that does not need one, and false advertising
--    of a paid add-on that did not run.
--
-- 2. OPERABILITY. When enhancement is skipped or partly fails, the reason is
--    printed to the worker's stdout and nowhere else. Ops cannot tell from the
--    database whether a paid add-on ran, and RenderStatusView cannot tell the
--    customer WHY it did not.
--
-- The worker already writes `enhancement_result` and `hero_key` best-effort
-- (services/worker/db.py: a missing column produces ONE warning and the tour
-- still publishes), so applying this migration is all that is needed to light
-- them up. Nothing here is required for the worker to run.
--
-- Idempotent: `add column if not exists` + `create or replace function`.

-- ── 1. render_jobs.enhancement_result ───────────────────────────────────────

alter table public.render_jobs
  add column if not exists enhancement_result jsonb;

comment on column public.render_jobs.enhancement_result is
  'Written ONLY by the render worker: {ran, staged, reason, spent_cents, stills, '
  'hero_key, segments, ts}. `staged` is an OUTCOME (a segment passed QC and '
  'shipped an edit), never an intent derived from the request toggles.';

-- ── 2. renders.hero_key ─────────────────────────────────────────────────────

alter table public.renders
  add column if not exists hero_key text;

comment on column public.renders.hero_key is
  'R2 key of the optional Seedance hero clip (renders/{listing}/{render}-hero.mp4). '
  'Until this existed the worker uploaded the clip and had nowhere to reference it.';

-- Both columns inherit the existing TABLE-level grants (anon/authenticated
-- SELECT, service_role write) — deliberately no new grant is issued here, and
-- row visibility stays governed by the unchanged RLS policies.

-- ── 3. publish_render(): staged is an OUTCOME, not an intent ────────────────
-- Reproduced verbatim from 0011 §8 (the LATEST definition of this function).
-- Signature, security definer, search_path, the role check, the anti-spoof
-- poster rule, the advisory lock, the idempotent replay path, the duration
-- bound, chapters, slug allocation and the grants are all UNCHANGED. The single
-- edit is the `v_staged` derivation, argued in full at that line.

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

  -- ── VIRTUAL-STAGING DISCLOSURE — SERVER-DERIVED, the caller gets no say ────
  -- `renders.staged` is a LEGAL DISCLOSURE, not a feature flag: it drives the
  -- "✦ Virtually staged" chip and the disclosure sheet on the public tour
  -- (services/edge/tour-host/src/player.ts). Under MLS virtual-media rules and
  -- California AB 723, getting it wrong is a compliance failure in BOTH
  -- directions — stamping a tour whose pixels were never altered is false
  -- advertising of an add-on that did not run; failing to stamp one that WAS
  -- altered is a disclosure violation. So the flag follows the OUTCOME the
  -- pipeline reports, and where no outcome exists it follows whichever answer
  -- cannot under-disclose:
  --
  --   1. enhancement_result carries `staged` → the worker MEASURED what it
  --      shipped (a segment passed QC and an edit landed). Trust it in both
  --      directions. This is the F-G-01 #2 / F-G-09 fix: before 0016 a tour was
  --      stamped because the user ticked a box, even when the pipeline skipped,
  --      QC denied the edit, the spend ceiling stopped it, or no worker was
  --      reachable at all.
  --   2. source='app' with no outcome → FALSE. An app publish is the phone's
  --      own on-device render, uploaded through /uploads role=render; no AI
  --      pipeline exists on that path (iOS decision A5 — Enhancements always
  --      ships `declutter:false, style:.asIs`), so nothing was altered and
  --      stamping it is exactly the false-advertising failure above. Photo-level
  --      edits made through /ai-enhance are disclosed separately and per-asset
  --      through media_provenance (0012); they are not this tour-level flag.
  --   3. source='worker' with no outcome → the pre-0016 intent-derived rule,
  --      byte-for-byte unchanged. A worker that died before writing its result,
  --      or one too old to write the column at all, must not silently turn a
  --      REAL virtual staging into an undisclosed one. Falling back to the
  --      requested toggles can only over-disclose, which is the survivable
  --      direction — and it is what this function does today, so the worker
  --      path does not regress.
  v_style := lower(trim(coalesce(v_job.enhancements->>'style', '')));
  if v_job.enhancement_result is not null and v_job.enhancement_result ? 'staged' then
    v_staged := coalesce((v_job.enhancement_result->>'staged')::boolean, false);
  elsif coalesce(v_job.source, 'worker') = 'app' then
    v_staged := false;
  else
    v_staged := coalesce((v_job.enhancements->>'declutter')::boolean, false)
                or (v_style <> '' and v_style not in ('as_is','as-is','asis','none'));
  end if;

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
