-- 0046: commercial telemetry — activation, cohorts and churn become FACTS
--       (2026-09-12, commercial audit "nothing can answer the three questions
--       a subscription business is actually run on").
--
-- NUMBERING: 0045 is reserved for a parallel branch (upload explicit restart).
-- Nothing in this file references it; the two are independent and may land in
-- either order.
--
-- ── THE THREE QUESTIONS, AND WHY NOTHING COULD ANSWER THEM ──────────────────
--
-- 1. "What fraction of signups ever publish a first tour, and how long did it
--    take?"  admin_funnel() (0021 §3) counts DISTINCT DEVICES per step inside a
--    window and says so on every response (functions/admin/funnel.ts): the
--    device counted at `tour_published` need never have appeared at `signup`,
--    so it cannot be read as a cohort. And app_events is purged after 180 days
--    by the pg_cron job in 0022, so device-level history cannot answer a
--    long-window question at all. A cohort number has to live on a durable
--    ORG-level column, which is what `orgs.first_tour_published_at` is.
--
-- 2. "Of the orgs that started a free week 30 days ago, how many are paying
--    now?"  Nothing joined signup date to subscription state. admin_cohorts()
--    below does, bucket by signup date.
--
-- 3. "How many paying subscribers cancelled last month, at which plan?"
--    apple_subscriptions (0019 §1) keeps only the CURRENT status/auto_renew —
--    apply_apple_entitlement() overwrites both on every notification — and had
--    no cancelled_at at all, so a lapse left no trace of WHEN it happened. The
--    only history that exists is apple_notifications (0019 §2), which nothing
--    aggregates. `cancelled_at` / `cancel_reason` below record the transition
--    the first time it happens, and admin_churn() reports it.
--
-- ── THE ORPHAN PROBLEM (why a cohort denominator is not count(orgs)) ────────
--
-- handle_new_user() (latest body 0017 §5) creates a FRESH org on EVERY auth
-- signup, including Supabase's anonymous signup, and an Apple sign-in mints a
-- NEW user rather than linking to the anonymous one. adopt_anonymous_org()
-- (0038) then re-points the ORIGINAL org's membership row to the real user —
-- leaving the org that the Apple signup just created behind, with nothing in it.
--
-- VERIFIED against the schema rather than assumed, because it changes which
-- predicate is correct:
--   • "an org with no membership" is FALSE here. handle_new_user() inserts a
--     membership in the same statement block as the org, and adoption only
--     UPDATEs the anonymous org's membership row (0038:93) — it never deletes
--     the new org's. The leftover org therefore HAS an owner membership; it is
--     empty, not unowned. A membership predicate would exclude nothing.
--   • "no listing and no render and no upload" is TRUE and is what this file
--     uses — see org_is_real() in §6 for the exact clauses and why renders are
--     subsumed by listings.
--
-- ── IDEMPOTENCY ─────────────────────────────────────────────────────────────
--
-- `add column if not exists`, `create or replace function`, and two backfills
-- that are predicated on the column still being null, so a replay updates zero
-- rows. CI applies this file twice (tools/audit/run_database_regression.py).

-- ── 1. orgs.first_tour_published_at — the durable activation fact ───────────
--
-- ACTIVATION IS THIS COLUMN. There is deliberately no second `activated_at`:
-- one fact, one column, so two screens can never disagree about what activated
-- means. Set exactly once, by the publish functions in §3 and §4, using
-- "only if null" semantics in both the SET and the WHERE, so a second, tenth or
-- hundredth publish can never move it.

alter table public.orgs
  add column if not exists first_tour_published_at timestamptz;

comment on column public.orgs.first_tour_published_at is
  'When this workspace published its FIRST tour — the activation fact. Written '
  'once by publish_render() / publish_worker_render() and never moved; NULL '
  'means the workspace has never published. Server-controlled: not in the '
  'tenant UPDATE grant. Read by admin_cohorts().';

-- Backfill from the renders that still exist. LIMIT, stated rather than hidden:
-- unpublish_deleted_listing_renders() (0011 §12) sets renders.published_at to
-- NULL when a listing is soft-deleted, so an org whose only tour was deleted
-- before today reads as never-activated. Going forward the stamp is written at
-- publish time and is never cleared, so this gap is one-time and backwards only.
update public.orgs o
   set first_tour_published_at = f.first_published
  from (select l.org_id, min(r.published_at) as first_published
          from public.renders r
          join public.listings l on l.id = r.listing_id
         where r.published_at is not null
         group by l.org_id) f
 where f.org_id = o.id
   and o.first_tour_published_at is null;

-- Re-assert the column-scoped tenant UPDATE grant from 0005/0019 §3. Nothing
-- new is granted: this is here so the new column is unwritable by a client even
-- on a database where a bare `grant update on public.orgs` was ever run.
revoke update on public.orgs from authenticated, anon;
grant  update (name, handle, space_type, brand_kit) on public.orgs to authenticated;

-- ── 2. apple_subscriptions.cancelled_at / cancel_reason ─────────────────────
--
-- The row keeps only the CURRENT status (0019 §1), so "when did this subscriber
-- cancel" had no answer. These two columns record the FIRST transition into a
-- cancelled state and are never overwritten by a later one.
--
-- WHAT COUNTS AS CANCELLED (both arms matter to the business):
--   • status became expired | revoked | refunded — the subscription is gone; or
--   • auto_renew became false — the customer turned renewal OFF. They are still
--     entitled until expires_at, but the decision to leave has been made and
--     that is the number a retention effort needs to see EARLY.
--
-- WIN-BACK: if the row later returns to status='active' WITH auto_renew=true,
-- both columns are cleared, so they always describe the CURRENT cancellation
-- rather than an old one. The win-back TRANSITION itself is deliberately NOT
-- recorded here: apple_subscriptions holds one row per subscription with no
-- history, so recording it would need either a new history table (out of scope
-- for this migration) or a counter column that no consumer reads yet. It is not
-- guessed at either — apple_notifications (0019 §2) already stores every
-- notification that produced the win-back, which is where a later wave should
-- aggregate them. CONSEQUENCE, stated because admin_churn() depends on it: a
-- cancellation followed by a win-back inside the same window disappears from
-- the churn count, so admin_churn() reports cancellations that are STILL in
-- force, not every cancellation event that ever occurred.

alter table public.apple_subscriptions
  add column if not exists cancelled_at  timestamptz;
alter table public.apple_subscriptions
  add column if not exists cancel_reason text;

comment on column public.apple_subscriptions.cancelled_at is
  'First time this subscription went expired/revoked/refunded OR had auto_renew '
  'turned off. Written once by apply_apple_entitlement(); cleared only by a '
  'win-back (back to active with auto_renew true). NULL = not cancelled.';
comment on column public.apple_subscriptions.cancel_reason is
  'Why, in Apple''s own words where we have them: the notificationType that '
  'carried the transition (EXPIRED, REVOKE, REFUND, DID_CHANGE_RENEWAL_STATUS…), '
  'or status_<status> / auto_renew_off when the transition arrived on the '
  'device-sync path, which carries no notification type.';

create index if not exists idx_apple_subscriptions_cancelled
  on public.apple_subscriptions (cancelled_at)
  where cancelled_at is not null;

-- Backfill from the ONLY history that exists. Deliberately conservative:
--   • only rows that are cancelled RIGHT NOW (terminal status, or auto_renew
--     off) get a date, so a subscription that lapsed and came back is not
--     stamped as cancelled;
--   • the date is the EARLIEST stored notification of a terminal type for that
--     transaction — an actual recorded event, never a guess from updated_at.
-- A cancellation with no stored notification (the device-sync path before
-- today) stays NULL and is invisible to admin_churn(): unknowable is reported
-- as unknown rather than invented.
update public.apple_subscriptions s
   set cancelled_at  = n.first_terminal,
       cancel_reason = 'backfill_' || n.first_type
  from (select distinct on (a.original_transaction_id)
               a.original_transaction_id,
               a.received_at        as first_terminal,
               a.notification_type  as first_type
          from public.apple_notifications a
         where a.notification_type in ('EXPIRED','GRACE_PERIOD_EXPIRED','REFUND','REVOKE')
         order by a.original_transaction_id, a.received_at) n
 where n.original_transaction_id = s.original_transaction_id
   and s.cancelled_at is null
   and (s.status in ('expired','revoked','refunded') or s.auto_renew is false);

-- 0019 §6 posture, re-asserted: both tables stay service-role only, so the two
-- new columns are unreadable by any tenant role.
revoke all on public.apple_subscriptions from authenticated, anon;
revoke all on public.apple_notifications from authenticated, anon;

-- ── 3. publish_render(): stamp the activation fact ──────────────────────────
--
-- Reproduced VERBATIM from 0016 §3 (the LATEST definition of this function).
-- Signature, security definer, search_path, the role check, the anti-spoof
-- poster rule, the advisory lock, the idempotent replay path, the duration
-- bound, the staged-outcome derivation, chapters, slug allocation and the
-- grants are all UNCHANGED. The single edit is the `orgs` stamp marked `0046:`.
--
-- It sits after the render row exists and on the NON-replay path only: the
-- idempotent replay above returns before reaching it, so a retry of the same
-- publish cannot re-stamp anything either.

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
as $publish_render$
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

  -- 0046: the ACTIVATION fact, written exactly once. `coalesce` in the SET and
  -- `is null` in the WHERE both say the same thing on purpose — a later publish
  -- must never move the first one, and neither form alone survives a careless
  -- edit of the other.
  update orgs
     set first_tour_published_at = coalesce(first_tour_published_at, v_render.published_at)
   where id = v_org
     and first_tour_published_at is null;

  update render_jobs
     set status = 'ready', progress = 1, finished_at = now(), error = null
   where id = v_job.id;
  update listings set status = 'ready' where id = v_job.listing_id;

  return v_render;
end;
$publish_render$;

revoke execute on function public.publish_render(uuid, numeric, numeric, jsonb, uuid) from public, anon;
grant  execute on function public.publish_render(uuid, numeric, numeric, jsonb, uuid) to authenticated, service_role;

-- ── 4. publish_worker_render(): the other publish path, same stamp ──────────
--
-- Reproduced VERBATIM from 0035 (the LATEST definition), with the same single
-- `0046:` addition. Both publish paths are live — functions/renders/index.ts
-- calls publish_render for an app publish, services/worker/worker.py calls
-- publish_worker_render for a cloud render — so stamping only one of them would
-- silently under-count activation for every worker-rendered tour, and a cohort
-- number that is wrong for half the traffic is worse than none.
--
-- NOTE FOR WHOEVER RUNS THE AUDIT HARNESS: run_database_regression.py mutates
-- 0035 in a disposable database and "restores" it by re-applying that FILE, so
-- inside that one run the function reverts to the 0035 body (without this
-- stamp) after the publication fixture. Nothing downstream in that run depends
-- on the stamp, and production keeps 0046's body because migrations apply in
-- order. Do not "fix" it by moving the stamp back out.

create or replace function public.publish_worker_render(
  p_job uuid,
  p_worker text,
  p_attempt integer,
  p_render jsonb,
  p_enhancement_result jsonb,
  p_photos jsonb default '[]'::jsonb
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $publish_worker_render$
declare
  v_listing_id uuid;
  v_listing public.listings;
  v_job public.render_jobs;
  v_render public.renders;
  v_id uuid;
  v_slug text;
  v_prefix text;
  v_request jsonb;
  v_receipt jsonb;
  v_photo jsonb;
  v_duration numeric;
  v_speed numeric;
  v_staged boolean;
  v_constraint text;
  v_try integer;
begin
  -- Grants are the boundary; this explicit guard also prevents accidental future
  -- EXECUTE grants from making an ordinary member's chosen worker_id authoritative.
  if current_user <> 'service_role' then
    raise exception using errcode = '42501', message = 'worker publication requires service_role';
  end if;
  if p_worker is null or length(p_worker) not between 1 and 200
     or p_attempt is null or p_attempt < 1
     or jsonb_typeof(p_render) is distinct from 'object'
     or jsonb_typeof(p_enhancement_result) is distinct from 'object'
     or jsonb_typeof(p_photos) is distinct from 'array' then
    raise exception using errcode = 'WP003', message = 'invalid worker publication envelope';
  end if;
  if jsonb_array_length(p_photos) > 100
     or octet_length(p_render::text) + octet_length(p_enhancement_result::text)
        + octet_length(p_photos::text) > 262144 then
    raise exception using errcode = 'WP003', message = 'worker publication envelope exceeds bounds';
  end if;

  -- Listing first, then job, then render/photos: a soft-delete already locks
  -- the listing before unpublishing renders. Sharing that order prevents an
  -- inverse-lock deadlock and prevents publication from undoing a tombstone.
  select listing_id into v_listing_id from public.render_jobs where id = p_job;
  select * into v_listing from public.listings where id = v_listing_id for update;
  if not found or v_listing.deleted_at is not null then
    raise exception using errcode = 'WP001', message = 'worker publication listing is unavailable';
  end if;
  select * into v_job from public.render_jobs where id = p_job for update;
  if not found or v_job.listing_id is distinct from v_listing_id
     or v_job.source is distinct from 'worker'
     or v_job.worker_id is distinct from p_worker
     or v_job.attempts is distinct from p_attempt then
    raise exception using errcode = 'WP001', message = 'worker publication claim is no longer owned';
  end if;
  v_request := jsonb_build_object('render', p_render,
    'enhancement_result', p_enhancement_result, 'photos', p_photos);

  if v_job.status = 'ready' then
    v_receipt := v_job.worker_publish_receipt;
    select * into v_render from public.renders where job_id = p_job;
    -- A successful exact replay is read-only, even after its former lease
    -- expires. A different output from the same process/attempt is NOT a retry.
    if not found or v_receipt is null
       or v_receipt->'request' is distinct from v_request
       or v_receipt->>'worker_id' is distinct from p_worker
       or v_receipt->'attempt' is distinct from to_jsonb(p_attempt)
       or v_receipt->'render' is distinct from to_jsonb(v_render) then
      raise exception using errcode = 'WP002', message = 'worker publication conflicts with the committed output';
    end if;
    return jsonb_build_object('job_id', p_job, 'status', 'ready', 'render', to_jsonb(v_render), 'receipt', v_receipt);
  end if;
  -- clock_timestamp(), not now(): a call may have waited for either row lock.
  -- The time when its transaction BEGAN is not proof its lease is still alive.
  if v_job.status is distinct from 'processing'
     or v_job.lease_expires_at is null or v_job.lease_expires_at <= clock_timestamp() then
    raise exception using errcode = 'WP001', message = 'worker publication lease is expired or job is not processing';
  end if;
  if not exists (select 1 from public.capture_assets a
    where a.id = v_job.capture_asset_id and a.listing_id = v_listing_id
      and a.kind = 'video' and a.uploaded is true and coalesce(a.bucket, 'uploads') = 'uploads') then
    raise exception using errcode = 'WP003', message = 'worker publication requires an uploaded raw video capture';
  end if;

  begin
    v_id := (p_render->>'id')::uuid;
    v_duration := (p_render->>'duration_s')::numeric;
    v_speed := (p_render->>'speed_factor')::numeric;
    v_staged := (p_enhancement_result->>'staged')::boolean;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = 'WP003', message = 'invalid worker publication scalar';
  end;
  v_slug := p_render->>'slug';
  v_prefix := 'renders/' || v_listing_id::text || '/' || v_id::text;
  -- The persisted numeric columns have two decimal places. Reject coercion
  -- rather than commit 30.001 as 30.00 and disagree with the exact receipt.
  -- Existing chk_renders_duration already rejects 0.004 rounding to zero.
  if v_id is null or v_slug is null or v_slug !~ '^[a-zA-Z0-9_-]{6,80}$'
     or jsonb_typeof(p_render->'duration_s') is distinct from 'number'
     or jsonb_typeof(p_render->'speed_factor') is distinct from 'number'
     or v_duration is null or not (v_duration > 0 and v_duration <= 7200)
     or v_speed is null or not (v_speed >= 0.25 and v_speed <= 8)
     or round(v_duration, 2) is distinct from v_duration
     or round(v_speed, 2) is distinct from v_speed
     or jsonb_typeof(p_enhancement_result->'staged') is distinct from 'boolean'
     or jsonb_typeof(p_enhancement_result->'ran') is distinct from 'boolean'
     or p_render->>'video_key' is distinct from v_prefix || '.mp4'
     or p_render->>'poster_key' is distinct from v_prefix || '-poster.jpg'
     or (p_render->>'hero_key' is not null and p_render->>'hero_key' <> v_prefix || '-hero.mp4')
     or length(coalesce(p_render->>'stream_uid', '')) > 200 then
    raise exception using errcode = 'WP003', message = 'invalid worker publication media or outcome';
  end if;

  select * into v_render from public.renders where job_id = p_job for update;
  if found then
    -- Recovery of a pre-0035 partial publish keeps the customer's existing URL.
    -- Only the current fenced attempt can replace it; ready jobs were handled above.
    update public.renders set duration_s = v_duration, speed_factor = v_speed,
      video_key = p_render->>'video_key', poster_key = p_render->>'poster_key',
      stream_uid = p_render->>'stream_uid', hero_key = p_render->>'hero_key',
      staged = v_staged, published_at = clock_timestamp()
    where id = v_render.id returning * into v_render;
  else
    for v_try in 1..5 loop
      begin
        insert into public.renders (id, job_id, listing_id, slug, duration_s, speed_factor,
          video_key, stream_uid, poster_key, hero_key, staged, published_at)
        values (v_id, p_job, v_listing_id, v_slug, v_duration, v_speed,
          p_render->>'video_key', p_render->>'stream_uid', p_render->>'poster_key',
          p_render->>'hero_key', v_staged, clock_timestamp()) returning * into v_render;
        exit;
      exception when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint <> 'renders_slug_key' or v_try = 5 then raise; end if;
        v_slug := left(replace(gen_random_uuid()::text, '-', ''), 12);
      end;
    end loop;
  end if;

  -- 0046: the same ACTIVATION fact as publish_render(), written exactly once.
  -- A pre-0035 partial publish being recovered above is still this workspace's
  -- first tour if nothing else ever published, so the stamp covers both arms.
  update public.orgs
     set first_tour_published_at = coalesce(first_tour_published_at, v_render.published_at)
   where id = v_listing.org_id
     and first_tour_published_at is null;

  for v_photo in select value from jsonb_array_elements(p_photos) loop
    if jsonb_typeof(v_photo) is distinct from 'object'
       or v_photo->>'listing_id' is distinct from v_listing_id::text
       or v_photo->'is_staged' is distinct from 'true'::jsonb
       or v_photo->>'enhanced_key' is null
       or v_photo->>'enhanced_key' !~ ('^' || v_prefix || '-staged-[0-9]+[.]jpg$')
       or (v_photo->>'original_key' is not null and
         v_photo->>'original_key' !~ ('^' || v_prefix || '-staged-[0-9]+-orig[.]jpg$')) then
      raise exception using errcode = 'WP003', message = 'invalid worker publication photo';
    end if;
    insert into public.photos (listing_id, original_key, enhanced_key, is_staged, caption, sort)
    values (v_listing_id, v_photo->>'original_key', v_photo->>'enhanced_key', true,
      v_photo->>'caption', (v_photo->>'sort')::smallint);
  end loop;

  -- An unrelated constraint/trigger may have delayed a write. Recheck at the
  -- final state transition so expiry during that wait rolls every row back.
  if v_job.lease_expires_at <= clock_timestamp() then
    raise exception using errcode = 'WP001', message = 'worker publication lease expired during transaction';
  end if;

  v_receipt := jsonb_build_object('version', 1, 'job_id', p_job, 'worker_id', p_worker,
    'attempt', p_attempt, 'request', v_request, 'render', to_jsonb(v_render));
  update public.render_jobs set enhancement_result = p_enhancement_result,
    worker_publish_receipt = v_receipt, status = 'ready', current_step = 'ready',
    progress = 1, finished_at = clock_timestamp(), error = null
  where id = p_job;
  update public.listings set status = 'ready' where id = v_listing_id;
  -- Final-row triggers can wait too. The pre-transition check alone cannot
  -- prove these last writes completed before expiry; roll them all back if not.
  if v_job.lease_expires_at <= clock_timestamp() then
    raise exception using errcode = 'WP001', message = 'worker publication lease expired during final state writes';
  end if;
  return jsonb_build_object('job_id', p_job, 'status', 'ready', 'render', to_jsonb(v_render), 'receipt', v_receipt);
end;
$publish_worker_render$;

revoke execute on function public.publish_worker_render(uuid, text, integer, jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.publish_worker_render(uuid, text, integer, jsonb, jsonb, jsonb)
  to service_role;

-- ── 5. apply_apple_entitlement(): record the cancellation ───────────────────
--
-- Reproduced VERBATIM from 0026 (the LATEST definition — 0021's body was
-- superseded there by the sticky-org_id/post-write-recheck fix). Signature,
-- security definer, search_path, every guard, the upsert, the RP409 re-check,
-- the manual/stale/environment arms, the downgrade rule and the grants are all
-- UNCHANGED. The single edit is the `0046:` block after the upsert.
--
-- It sits AFTER the post-write RP409 re-check (so a call that loses a binding
-- race records nothing and rolls back) and BEFORE the `org_id is null` return
-- (so a notification that arrives before the app has linked the subscription
-- still records the cancellation — the fact belongs to the subscription, not to
-- the workspace).

create or replace function public.apply_apple_entitlement(
  p_org                     uuid,
  p_user                    uuid,
  p_original_transaction_id text,
  p_transaction_id          text,
  p_product_id              text,
  p_plan                    text,
  p_environment             text,
  p_status                  text,
  p_expires_at              timestamptz,
  p_auto_renew              boolean,
  p_notification_type       text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $apply_apple_entitlement$
declare
  v_existing   public.apple_subscriptions%rowtype;
  v_stale      boolean := false;
  v_status     text;
  v_expires    timestamptz;
  v_plan       text;
  v_source     text;
  v_org_source text;
  v_updated    boolean := false;
  v_reason     text := null;
  v_others     integer := 0;
  -- 0046: scratch for the cancellation stamp below. Never returned; the RPC's
  -- jsonb shape is byte-identical to 0026's.
  v_cancel_at  timestamptz;
  v_cancel_why text;
begin
  if p_original_transaction_id is null or btrim(p_original_transaction_id) = '' then
    raise exception 'RP400: original_transaction_id is required';
  end if;
  if p_status is null or p_status not in ('active','grace','expired','revoked','refunded') then
    raise exception 'RP400: status must be active, grace, expired, revoked or refunded';
  end if;

  select * into v_existing
    from apple_subscriptions
   where original_transaction_id = p_original_transaction_id
   for update;

  -- 0021 FINDING 1, sequential case: an EXISTING binding beats a disagreeing
  -- p_org. Unreachable for a brand-new original_transaction_id — `found` is
  -- false until some call has actually inserted a row — which is exactly the
  -- gap 0024 closes below.
  if found
     and v_existing.org_id is not null
     and p_org is not null
     and p_org <> v_existing.org_id
  then
    raise exception 'RP409: This subscription is already used by another account';
  end if;

  -- 0021 FINDING 3: environment is sticky. Sandbox must never move Production
  -- and Production must never be reset by a Sandbox replay, on EITHER path —
  -- functions/apple-subscriptions checked this, POST /me/entitlement did not.
  -- The arrival is recorded; nothing else changes.
  if found
     and v_existing.environment is not null
     and p_environment is not null
     and p_environment <> v_existing.environment
  then
    update apple_subscriptions
       set last_notification_type = coalesce(p_notification_type, last_notification_type),
           updated_at             = now()
     where original_transaction_id = p_original_transaction_id;

    return jsonb_build_object(
      'ok', true,
      'plan', (select o.plan from orgs o where o.id = v_existing.org_id),
      'source', 'apple',
      'expires_at', v_existing.expires_at,
      'status', v_existing.status,
      'org_updated', false,
      'reason', 'environment_mismatch');
  end if;

  -- Out-of-order delivery: an older expiry for a non-terminal status is news
  -- we already have. Record that the notification arrived; change nothing else.
  --
  -- 0021 FINDING 2: …but ONLY when the product has not changed. A crossgrade
  -- inside the subscription group is applied by Apple immediately with a
  -- prorated refund, so an UPGRADE from an annual product to a monthly one
  -- legitimately carries an earlier expiry. Treating that as stale froze the
  -- org on the old plan AND the old (much later) expiry, which then made every
  -- subsequent signal — including the final EXPIRED — stale as well, so the
  -- subscription never lapsed. A visible product change is always the newer
  -- truth; the guard is kept for the case it was written for, a duplicate or
  -- out-of-order signal about the SAME product.
  if found
     and p_status in ('active','grace','expired')
     and v_existing.expires_at is not null
     and p_expires_at is not null
     and p_expires_at < v_existing.expires_at
     and (p_product_id is null
          or v_existing.product_id is null
          or p_product_id = v_existing.product_id)
  then
    v_stale := true;
  end if;

  v_status  := case when v_stale then v_existing.status     else p_status     end;
  v_expires := case when v_stale then v_existing.expires_at else p_expires_at end;
  v_plan    := case when v_stale then v_existing.plan       else p_plan       end;

  insert into apple_subscriptions as s (
    original_transaction_id, org_id, user_id, product_id, plan, environment,
    status, expires_at, auto_renew, last_transaction_id, last_notification_type,
    created_at, updated_at
  ) values (
    p_original_transaction_id, p_org, p_user, p_product_id, v_plan, p_environment,
    v_status, v_expires, p_auto_renew, p_transaction_id, p_notification_type,
    now(), now()
  )
  on conflict (original_transaction_id) do update set
    -- 0024: STICKY, not "prefer incoming". Two calls that both saw found=false
    -- for a brand-new key (the concurrent-first-bind race — see header) both
    -- reach this upsert; whichever commits durably SECOND now keeps the FIRST
    -- committed org_id instead of overwriting it. On every non-racing path this
    -- is a no-op: a genuine first link has s.org_id = null, so the incoming
    -- value still wins via coalesce's fallback.
    org_id                 = coalesce(s.org_id, excluded.org_id),
    -- user_id is informational only (0019: the ON DELETE SET NULL target) and
    -- decides no entitlement, so it is left exactly as 0019/0021 had it.
    user_id                = coalesce(excluded.user_id, s.user_id),
    -- 0021: on a stale signal the product must not move either, or the row
    -- ends up claiming a product whose plan it is not carrying.
    product_id             = case when v_stale then s.product_id
                                  else coalesce(excluded.product_id, s.product_id) end,
    plan                   = coalesce(excluded.plan, s.plan),
    environment            = coalesce(s.environment, excluded.environment),
    status                 = excluded.status,
    expires_at             = excluded.expires_at,
    auto_renew             = coalesce(excluded.auto_renew, s.auto_renew),
    last_transaction_id    = coalesce(excluded.last_transaction_id, s.last_transaction_id),
    last_notification_type = coalesce(excluded.last_notification_type, s.last_notification_type),
    updated_at             = now()
  returning * into v_existing;

  -- 0024: the re-check the sequential guard above cannot do for a first bind —
  -- it runs on `found`, captured BEFORE this statement wrote anything. This
  -- runs on what the upsert actually persisted. Raising here rolls back this
  -- entire call (including whatever this statement itself just wrote), so a
  -- call that loses the race leaves no trace — not a wrong org_id, not a stray
  -- last_transaction_id — and its caller gets the same RP409 copy as the
  -- sequential case, never a 200 with somebody else's binding.
  if v_existing.org_id is not null and p_org is not null and v_existing.org_id <> p_org then
    raise exception 'RP409: This subscription is already used by another account';
  end if;

  -- ── 0046: THE CANCELLATION FACT ───────────────────────────────────────────
  -- Read from the row the upsert actually persisted, so it is the same state
  -- every other consumer will see. Two arms, both of which the business calls a
  -- cancellation: the subscription ended (expired/revoked/refunded), or the
  -- customer turned auto-renew OFF while still entitled. A row first SEEN in
  -- one of those states counts as the transition — Apple's first word about a
  -- subscription can already be a REFUND, and "the first time this server knew"
  -- is the only cancellation date a webhook consumer can honestly claim.
  -- `cancelled_at is null`
  -- in both the IF and the UPDATE's WHERE: the FIRST transition wins and no
  -- later signal — including a duplicate EXPIRED — can move the date.
  -- The win-back arm clears both, so the columns always describe the CURRENT
  -- cancellation; the header says what that costs admin_churn() and why the
  -- transition itself is not recorded here.
  if (v_existing.status in ('expired','revoked','refunded') or v_existing.auto_renew is false)
     and v_existing.cancelled_at is null then
    update apple_subscriptions
       set cancelled_at  = now(),
           cancel_reason = left(coalesce(
             nullif(btrim(p_notification_type), ''),
             case when v_existing.status in ('expired','revoked','refunded')
                  then 'status_' || v_existing.status
                  else 'auto_renew_off' end), 80)
     where original_transaction_id = v_existing.original_transaction_id
       and cancelled_at is null
    returning cancelled_at, cancel_reason into v_cancel_at, v_cancel_why;
    v_existing.cancelled_at  := v_cancel_at;
    v_existing.cancel_reason := v_cancel_why;
  elsif v_existing.status = 'active' and v_existing.auto_renew is true
        and v_existing.cancelled_at is not null then
    update apple_subscriptions
       set cancelled_at = null, cancel_reason = null
     where original_transaction_id = v_existing.original_transaction_id;
    v_existing.cancelled_at  := null;
    v_existing.cancel_reason := null;
  end if;

  -- No org yet (a notification that beat the device here): the row is stored
  -- and POST /me/entitlement will replay it once the app links the workspace.
  if v_existing.org_id is null then
    return jsonb_build_object(
      'ok', true, 'plan', null, 'source', null, 'expires_at', v_expires,
      'status', v_status, 'org_updated', false, 'reason', 'no_org_linked');
  end if;

  select o.plan_source into v_org_source from orgs o where o.id = v_existing.org_id for update;
  if not found then
    return jsonb_build_object(
      'ok', true, 'plan', null, 'source', null, 'expires_at', v_expires,
      'status', v_status, 'org_updated', false, 'reason', 'org_missing');
  end if;

  -- RULE 2 (0019): an owner-granted plan is Apple-proof, in both directions.
  if v_org_source = 'manual' then
    return jsonb_build_object(
      'ok', true, 'plan', (select plan from orgs where id = v_existing.org_id),
      'source', 'manual', 'expires_at', v_expires, 'status', v_status,
      'org_updated', false, 'reason', 'manual_plan');
  end if;

  if v_stale then
    return jsonb_build_object(
      'ok', true, 'plan', (select plan from orgs where id = v_existing.org_id),
      'source', 'apple', 'expires_at', v_expires, 'status', v_status,
      'org_updated', false, 'reason', 'stale_notification');
  end if;

  if v_status in ('active','grace') then
    update orgs
       set plan             = coalesce(v_plan, plan),
           plan_source      = 'apple',
           plan_expires_at  = v_expires,
           apple_product_id = coalesce(v_existing.product_id, apple_product_id)
     where id = v_existing.org_id;
    v_updated := true;
    v_source  := 'apple';
  else
    -- A lapse only downgrades when nothing else is still paying for this org.
    -- 0021: `and x.expires_at > now()` as well, so a row that is still marked
    -- active only because its own EXPIRED was never delivered cannot hold an
    -- org on a paid plan forever. Rows with no expiry at all still count, the
    -- same way they did before.
    select count(*) into v_others
      from apple_subscriptions x
     where x.org_id = v_existing.org_id
       and x.original_transaction_id <> v_existing.original_transaction_id
       and x.status in ('active','grace')
       and (x.expires_at is null or x.expires_at > now() - interval '16 days');

    if v_others > 0 then
      v_reason := 'another_subscription_active';
    else
      update orgs
         set plan             = 'free',
             plan_source      = 'apple',
             plan_expires_at  = v_expires,
             apple_product_id = coalesce(v_existing.product_id, apple_product_id)
       where id = v_existing.org_id;
      v_updated := true;
    end if;
    v_source := 'apple';
  end if;

  return jsonb_build_object(
    'ok', true,
    'plan', (select plan from orgs where id = v_existing.org_id),
    'source', coalesce(v_source, 'apple'),
    'expires_at', v_expires,
    'status', v_status,
    'org_updated', v_updated,
    'reason', v_reason
  );
end;
$apply_apple_entitlement$;

-- CREATE OR REPLACE keeps the 0019/0021/0026 privileges; re-asserted so this
-- file alone lands in the same state on a database that has only seen 0019.
revoke execute on function public.apply_apple_entitlement(
  uuid, uuid, text, text, text, text, text, text, timestamptz, boolean, text
) from public, anon, authenticated;
grant execute on function public.apply_apple_entitlement(
  uuid, uuid, text, text, text, text, text, text, timestamptz, boolean, text
) to service_role;

comment on function public.apply_apple_entitlement(
  uuid, uuid, text, text, text, text, text, text, timestamptz, boolean, text
) is
  'The ONLY path from a verified Apple JWS to orgs.plan. Upserts '
  'apple_subscriptions and sets plan/plan_source/plan_expires_at/apple_product_id '
  '— except on a manual (owner-granted) plan, which it never changes. Refuses '
  '(RP409) a p_org that disagrees with the subscription''s binding both when an '
  'existing row is read (0021) and when the write itself would move a binding '
  'another concurrent call already made (0024 — the sticky org_id upsert plus a '
  'post-write re-check), refuses to let one environment overwrite the other, and '
  'treats an earlier expiry as stale only when the product is unchanged. 0046: '
  'stamps cancelled_at/cancel_reason on the FIRST transition to '
  'expired/revoked/refunded or auto_renew=false, and clears both on a win-back. '
  'service_role only.';

-- ── 6. org_is_real() — the non-orphan predicate ─────────────────────────────
--
-- THE DEFENCE, in full, because every cohort denominator in §7 rests on it:
--
-- TRUE when the workspace has ever held a listing, an upload reservation, or an
-- App Store subscription. Each clause is there for a reason:
--
--   • listings — the first thing a real workspace creates, and the parent of
--     capture_assets, render_jobs and renders (all of them reach the org only
--     through listings.org_id), so "has a listing" subsumes "has a render".
--     Soft-deleted listings still count: deleting your work does not retroact-
--     ively make you a phantom signup.
--   • upload_reservations — org-scoped (0037) and deliberately WITHOUT a
--     cascading FK to listings, "so deleting a listing must not erase the only
--     known R2 keys". It can therefore outlive the listing that created it and
--     is the one durable trace of a workspace that uploaded and then deleted.
--   • apple_subscriptions — a workspace that paid is real even if it never
--     managed to publish anything. Leaving this out would let a paying org fall
--     out of the denominator while still being counted in `ever_paid`, which is
--     the one inconsistency a cohort table must not have.
--
-- WHAT IT DELIBERATELY DOES NOT TEST:
--   • memberships. See the header: handle_new_user() gives every org one, and
--     adopt_anonymous_org() re-points the ANONYMOUS org's membership rather
--     than removing the new org's, so the orphan this exists to exclude has a
--     membership. Testing it would exclude nothing.
--   • deleted_at. A workspace that did real work and was later deleted IS a
--     real signup that churned; hiding it would flatter both the denominator
--     and the churn number. Callers that want live workspaces only (GET
--     /admin/usage does) filter deleted_at themselves.

create or replace function public.org_is_real(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $org_is_real$
  select exists (select 1 from listings l where l.org_id = p_org)
      or exists (select 1 from upload_reservations u where u.org_id = p_org)
      or exists (select 1 from apple_subscriptions s where s.org_id = p_org);
$org_is_real$;

revoke execute on function public.org_is_real(uuid) from public, anon, authenticated;
grant  execute on function public.org_is_real(uuid) to service_role;

comment on function public.org_is_real(uuid) is
  'TRUE when a workspace has ever held a listing, an upload reservation or an '
  'App Store subscription — the non-orphan predicate. handle_new_user() creates '
  'an org on EVERY auth signup (anonymous ones included) and adopt_anonymous_org() '
  'leaves the org the Apple signup created behind, empty but still owned, so '
  'count(orgs) is inflated and a membership test would not catch it. Reads across '
  'tenants: service_role only.';

-- ── 7. admin_cohorts() — the signup cohort table ────────────────────────────
--
-- EVERY NUMBER, DEFINED. A number whose definition does not fit in one line is
-- not in this function.
--
--   bucket_start / bucket_end  the signup bucket, [start, end), UTC. Bucketing
--                              is date_trunc(p_bucket, orgs.created_at).
--   partial                    TRUE when the bucket is clipped by the window
--                              (first bucket) or is still open (last bucket).
--                              Its rates are not comparable with a whole one.
--   orgs                       REAL orgs (org_is_real) created in this bucket.
--                              The denominator for everything below it.
--   activated                  …of those, with first_tour_published_at set, AT
--                              ANY TIME — including after the window ends. This
--                              is a true cohort number, which is the whole
--                              point: admin_funnel() cannot do it.
--   activated_within_24h / _7d …and did it within 24 hours / 7 days of
--                              orgs.created_at. In a bucket younger than that
--                              age the number can only be as large as the
--                              elapsed time allows — see `partial`.
--   median_hours_to_activate   median hours from created_at to
--                              first_tour_published_at OVER THE ORGS THAT
--                              ACTIVATED (never-activated orgs are not counted
--                              as infinity and not counted as zero). NULL when
--                              nobody in the bucket activated.
--   ever_paid                  …has at least one NON-Sandbox apple_subscriptions
--                              row, whatever its status now. Derived from the
--                              subscription table, never from orgs.plan_source,
--                              which only ever shows the CURRENT source.
--   ever_paid_sandbox          the same for Sandbox rows (App Review, TestFlight).
--                              Reported apart because a tester is not revenue —
--                              the same split admin_funnel() makes.
--   paying_now                 effective_plan() is starter|solo|pro|team AND the
--                              org has a LIVE non-Sandbox subscription: status
--                              active|grace and (no expiry, or an expiry newer
--                              than 16 days ago — Apple's maximum billing-retry
--                              grace, the same constant effective_plan() and
--                              apply_apple_entitlement() already use).
--   churned                    has a non-Sandbox subscription with cancelled_at
--                              set and has NO live subscription. Since
--                              cancelled_at only exists from 0046 and its
--                              backfill only sees cancellations that left a
--                              stored notification, this UNDER-counts history.
--
--   summary                    the identical measures over the whole window
--                              (not the sum of the buckets' medians), plus:
--   summary.orphan_orgs_excluded  orgs created in the window that org_is_real()
--                              rejected — the inflation, shown rather than
--                              silently dropped.
--
-- COST: one pass over orgs created in the window with per-org EXISTS lookups on
-- apple_subscriptions (indexed on org_id). An admin console read, not a hot path.

create or replace function public.admin_cohorts(
  p_window interval default interval '90 days',
  p_bucket text default 'week'
) returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $admin_cohorts$
declare
  v_window  interval;
  v_bucket  text;
  v_from    timestamptz;
  v_now     timestamptz := now();
  v_buckets jsonb;
  v_summary jsonb;
  v_orphans bigint := 0;
begin
  -- Bound the window rather than trusting the caller, exactly as admin_funnel()
  -- does: an unbounded interval is a full-table scan and a negative one returns
  -- an empty table that reads like "nobody ever signed up".
  v_window := coalesce(p_window, interval '90 days');
  if v_window < interval '1 day'   then v_window := interval '1 day';   end if;
  if v_window > interval '365 days' then v_window := interval '365 days'; end if;
  v_from := v_now - v_window;

  -- A bucket is not clampable — there is no "nearest legal" unit — so an
  -- unknown one is refused. GET /admin/cohorts validates the same three values
  -- against its own allowlist, so this raise is the backstop, not the message
  -- a person sees.
  v_bucket := lower(btrim(coalesce(p_bucket, 'week')));
  if v_bucket not in ('day','week','month') then
    raise exception 'RP400: bucket must be day, week or month';
  end if;

  select count(*) into v_orphans
    from orgs o
   where o.created_at >= v_from and o.created_at <= v_now
     and not org_is_real(o.id);

  with cohort as (
    select o.id,
           o.created_at,
           date_trunc(v_bucket, o.created_at)      as bucket_start,
           o.first_tour_published_at               as activated_at,
           effective_plan(o.id)                    as plan
      from orgs o
     where o.created_at >= v_from
       and o.created_at <= v_now
       and org_is_real(o.id)
  ), scored as (
    select c.*,
           exists (select 1 from apple_subscriptions s
                    where s.org_id = c.id
                      and coalesce(s.environment, 'Production') <> 'Sandbox')      as ever_paid,
           exists (select 1 from apple_subscriptions s
                    where s.org_id = c.id and s.environment = 'Sandbox')           as ever_paid_sandbox,
           exists (select 1 from apple_subscriptions s
                    where s.org_id = c.id
                      and coalesce(s.environment, 'Production') <> 'Sandbox'
                      and s.status in ('active','grace')
                      and (s.expires_at is null
                           or s.expires_at > v_now - interval '16 days'))          as live,
           exists (select 1 from apple_subscriptions s
                    where s.org_id = c.id
                      and coalesce(s.environment, 'Production') <> 'Sandbox'
                      and s.cancelled_at is not null)                              as cancelled
      from cohort c
  ), grouped as (
    select grouping(s.bucket_start) = 1                                     as is_total,
           s.bucket_start,
           count(*)                                                         as orgs,
           count(s.activated_at)                                            as activated,
           count(*) filter (where s.activated_at <= s.created_at + interval '24 hours') as within_24h,
           count(*) filter (where s.activated_at <= s.created_at + interval '7 days')   as within_7d,
           round(percentile_cont(0.5) within group (
                   order by extract(epoch from (s.activated_at - s.created_at)) / 3600.0
                 )::numeric, 1)                                             as median_hours,
           count(*) filter (where s.ever_paid)                              as ever_paid,
           count(*) filter (where s.ever_paid_sandbox)                      as ever_paid_sandbox,
           count(*) filter (where s.live and s.plan in ('starter','solo','pro','team')) as paying_now,
           count(*) filter (where s.cancelled and not s.live)               as churned
      from scored s
     group by grouping sets ((s.bucket_start), ())
  ), shaped as (
    select g.is_total,
           g.bucket_start,
           jsonb_build_object(
             'bucket_start', case when g.bucket_start is null then null else
               to_char(g.bucket_start at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') end,
             'bucket_end',   case when g.bucket_start is null then null else
               to_char((g.bucket_start + ('1 ' || v_bucket)::interval) at time zone 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS"Z"') end,
             'partial',      case when g.bucket_start is null then null else
               (g.bucket_start < v_from or g.bucket_start + ('1 ' || v_bucket)::interval > v_now) end,
             'orgs',                     g.orgs,
             'activated',                g.activated,
             'activated_within_24h',     g.within_24h,
             'activated_within_7d',      g.within_7d,
             'median_hours_to_activate', g.median_hours,
             'ever_paid',                g.ever_paid,
             'ever_paid_sandbox',        g.ever_paid_sandbox,
             'paying_now',               g.paying_now,
             'churned',                  g.churned
           ) as row_json
      from grouped g
  )
  select coalesce(jsonb_agg(s.row_json order by s.bucket_start)
                    filter (where not s.is_total), '[]'::jsonb),
         coalesce((array_agg(s.row_json) filter (where s.is_total))[1], '{}'::jsonb)
    into v_buckets, v_summary
    from shaped s;

  return jsonb_build_object(
    'generated_at',   to_char(v_now  at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'from',           to_char(v_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'to',             to_char(v_now  at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'window_seconds', floor(extract(epoch from v_window))::bigint,
    'bucket',         v_bucket,
    'buckets',        v_buckets,
    -- The whole-window row carries bucket_start/bucket_end/partial as nulls by
    -- construction (it is the () grouping set); the extra key is the orphan
    -- count, which has no per-bucket meaning.
    'summary',        v_summary || jsonb_build_object('orphan_orgs_excluded', v_orphans)
  );
end;
$admin_cohorts$;

revoke execute on function public.admin_cohorts(interval, text) from public, anon, authenticated;
grant  execute on function public.admin_cohorts(interval, text) to service_role;

comment on function public.admin_cohorts(interval, text) is
  'Signup cohorts: for each day/week/month bucket inside the window, the REAL '
  'orgs created in it (org_is_real — orphan signups excluded and counted apart) '
  'with how many ever activated (first_tour_published_at), how many did so '
  'within 24h/7d, the median hours to activate among those that did, how many '
  'ever paid (from apple_subscriptions, Sandbox counted apart), how many are '
  'paying now and how many churned — plus the same measures over the whole '
  'window. Unlike admin_funnel() this IS a cohort: every number is about the '
  'orgs that signed up in the bucket, whenever they later acted. Window clamped '
  'to 1…365 days. service_role only.';

-- ── 8. admin_churn() — cancellations, by plan and by reason ─────────────────
--
-- EVERY NUMBER, DEFINED:
--   from / to                  the window, [now - p_window, now].
--   previous_from / previous_to  the window before it, the same length, so the
--                              console can show a delta instead of a lone
--                              number nobody can size.
--   cancellations              non-Sandbox apple_subscriptions rows whose
--                              cancelled_at falls in the window. Because a
--                              win-back CLEARS cancelled_at (§5), this counts
--                              cancellations that are STILL IN FORCE — a
--                              customer who cancelled and came back inside the
--                              window is deliberately not counted as churn.
--   by_plan / by_reason        the same rows grouped by the plan the
--                              subscription carried and by cancel_reason
--                              (Apple's notificationType where we have it).
--                              Unknowns show as '(unknown)', never as 0 rows.
--   in_grace                   subscriptions in status='grace' RIGHT NOW (with
--                              a live-enough expiry): Apple is retrying billing.
--                              Not churn yet, and the number that says how much
--                              of it is still in play.
--   sandbox_cancellations      the Sandbox rows the window excluded, so the
--                              exclusion is visible rather than silent.
--   delta_total                cancellations − previous.cancellations.
--
-- HISTORY LIMIT, stated on the response too: cancelled_at exists from 0046 and
-- its backfill can only see cancellations that left an apple_notifications row,
-- so a window that reaches before this migration under-reports.

create or replace function public.admin_churn(p_window interval default interval '30 days')
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $admin_churn$
declare
  v_window   interval;
  v_now      timestamptz := now();
  v_from     timestamptz;
  v_prev     timestamptz;
  v_total    bigint := 0;
  v_prev_tot bigint := 0;
  v_grace    bigint := 0;
  v_sandbox  bigint := 0;
  v_by_plan  jsonb;
  v_by_why   jsonb;
  v_prev_plan jsonb;
  v_prev_why  jsonb;
begin
  v_window := coalesce(p_window, interval '30 days');
  if v_window < interval '1 day'    then v_window := interval '1 day';    end if;
  if v_window > interval '365 days' then v_window := interval '365 days'; end if;
  v_from := v_now - v_window;
  v_prev := v_from - v_window;

  select count(*) filter (where s.cancelled_at >= v_from),
         count(*) filter (where s.cancelled_at >= v_prev and s.cancelled_at < v_from)
    into v_total, v_prev_tot
    from apple_subscriptions s
   where s.cancelled_at is not null
     and s.cancelled_at <= v_now
     and coalesce(s.environment, 'Production') <> 'Sandbox';

  select coalesce(count(*), 0) into v_sandbox
    from apple_subscriptions s
   where s.cancelled_at is not null
     and s.cancelled_at >= v_from and s.cancelled_at <= v_now
     and s.environment = 'Sandbox';

  select coalesce(count(*), 0) into v_grace
    from apple_subscriptions s
   where s.status = 'grace'
     and coalesce(s.environment, 'Production') <> 'Sandbox'
     and (s.expires_at is null or s.expires_at > v_now - interval '16 days');

  -- Four small grouped reads rather than one clever pivot: each one is legible
  -- on its own, and apple_subscriptions is a table with one row per customer
  -- subscription, not an event log.
  select coalesce(jsonb_agg(jsonb_build_object('plan', x.plan, 'count', x.n)
                            order by x.n desc, x.plan), '[]'::jsonb)
    into v_by_plan
    from (select coalesce(nullif(btrim(s.plan), ''), '(unknown)') as plan, count(*) as n
            from apple_subscriptions s
           where s.cancelled_at >= v_from and s.cancelled_at <= v_now
             and coalesce(s.environment, 'Production') <> 'Sandbox'
           group by 1) x;

  select coalesce(jsonb_agg(jsonb_build_object('reason', x.reason, 'count', x.n)
                            order by x.n desc, x.reason), '[]'::jsonb)
    into v_by_why
    from (select coalesce(nullif(btrim(s.cancel_reason), ''), '(unknown)') as reason, count(*) as n
            from apple_subscriptions s
           where s.cancelled_at >= v_from and s.cancelled_at <= v_now
             and coalesce(s.environment, 'Production') <> 'Sandbox'
           group by 1) x;

  select coalesce(jsonb_agg(jsonb_build_object('plan', x.plan, 'count', x.n)
                            order by x.n desc, x.plan), '[]'::jsonb)
    into v_prev_plan
    from (select coalesce(nullif(btrim(s.plan), ''), '(unknown)') as plan, count(*) as n
            from apple_subscriptions s
           where s.cancelled_at >= v_prev and s.cancelled_at < v_from
             and coalesce(s.environment, 'Production') <> 'Sandbox'
           group by 1) x;

  select coalesce(jsonb_agg(jsonb_build_object('reason', x.reason, 'count', x.n)
                            order by x.n desc, x.reason), '[]'::jsonb)
    into v_prev_why
    from (select coalesce(nullif(btrim(s.cancel_reason), ''), '(unknown)') as reason, count(*) as n
            from apple_subscriptions s
           where s.cancelled_at >= v_prev and s.cancelled_at < v_from
             and coalesce(s.environment, 'Production') <> 'Sandbox'
           group by 1) x;

  return jsonb_build_object(
    'generated_at',   to_char(v_now  at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'from',           to_char(v_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'to',             to_char(v_now  at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'window_seconds', floor(extract(epoch from v_window))::bigint,
    'cancellations',  v_total,
    'by_plan',        v_by_plan,
    'by_reason',      v_by_why,
    'in_grace',       v_grace,
    'sandbox_cancellations', v_sandbox,
    'previous', jsonb_build_object(
      'from',          to_char(v_prev at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'to',            to_char(v_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'cancellations', v_prev_tot,
      'by_plan',       v_prev_plan,
      'by_reason',     v_prev_why),
    'delta_total',    v_total - v_prev_tot
  );
end;
$admin_churn$;

revoke execute on function public.admin_churn(interval) from public, anon, authenticated;
grant  execute on function public.admin_churn(interval) to service_role;

comment on function public.admin_churn(interval) is
  'Cancellations in the window (apple_subscriptions.cancelled_at, Sandbox '
  'excluded and counted apart) grouped by plan and by reason, the count still in '
  'billing grace, and the same figures for the preceding window so a console can '
  'show a delta. Counts cancellations STILL IN FORCE: a win-back clears '
  'cancelled_at. Window clamped to 1…365 days. service_role only.';
