# Report — W1-E (backend: services/supabase/**, docs/UPLOAD-AND-PUBLISH-CONTRACT.md, .github/workflows/ci.yml)

Generated 2026-09-03. Nothing was deployed; the live project was only READ (list_migrations, execute_sql SELECTs on pg_proc/pg_constraint/information_schema/plan_entitlements).

## Verification performed here
- Local Postgres 16 cluster (`/tmp/rp-pg`, postgres user): `tests/ci-bootstrap.sql` → all 13 migrations in LC_ALL=C order, each in one transaction → `tests/invariants.sql` (**56/56 pass**) → re-apply 0005b/0008b/0009/0010/0011 → invariants again (56/56, exactly one overload per RPC). Same sequence the new CI job runs.
- `deno check` (Deno 2.9.6 via npx) on all 11 function entrypoints and every `_shared/*.ts`: **all OK**. `deno lint` on touched files: only the pre-existing `no-import-prefix` (esm.sh aws4fetch import).
- Two local experiments that changed the plan: (1) revoking EXECUTE on `is_org_member` from PUBLIC (F-supabase-30 "corrected block") breaks every RLS policy for `authenticated` ("permission denied for function is_org_member") — NOT applied; (2) trigger functions fire without EXECUTE on the invoking role — so `handle_new_user`/`rls_auto_enable` CAN lose PUBLIC (applied).

## Files changed
 M .github/workflows/ci.yml
 M .gitignore
 M docs/UPLOAD-AND-PUBLISH-CONTRACT.md
 M services/supabase/DEPLOYMENT.md
 M services/supabase/deploy-functions.sh
 M services/supabase/functions/README.md
 M services/supabase/functions/_shared/entitlements.ts
 M services/supabase/functions/_shared/http.ts
 M services/supabase/functions/_shared/r2.ts
 M services/supabase/functions/ai-photo/index.ts
 M services/supabase/functions/ai-video/index.ts
 M services/supabase/functions/leads/index.ts
 M services/supabase/functions/listings/index.ts
 M services/supabase/functions/me/index.ts
 M services/supabase/functions/portfolio/index.ts
 M services/supabase/functions/renders/index.ts
 M services/supabase/functions/tours/index.ts
 M services/supabase/functions/uploads/index.ts
 M services/supabase/set-secrets.sh
 M services/supabase/tests/invariants.sql
?? services/supabase/functions/_shared/agentcard.ts
?? services/supabase/migrations/0005b_lock_down_rpc_definer_functions.sql
?? services/supabase/migrations/0008b_audit_round4_grant_fix.sql
?? services/supabase/migrations/0009_plan_coherence.sql
?? services/supabase/migrations/0010_pricing_entitlements_and_spend_ceiling.sql
?? services/supabase/migrations/0011_app_publish_and_lifecycle.sql
?? services/supabase/tests/ci-bootstrap.sql
- D  services/supabase/.deploy/** (19 stale files removed; path gitignored, deploy script now `trap rm EXIT`)

## Migration naming decision
Kept **0005b / 0008b / 0009 / 0010** (+ new **0011_app_publish_and_lifecycle.sql**) rather than renumbering to 0009–0012:
DECISIONS A15/A16 and the code comments (`_shared/entitlements.ts`, ai-photo, ai-video) already call the
entitlements migration "0010" and the new one "0011"; the names sort correctly under `LC_ALL=C`
(`0005_` < `0005b_` < `0006_`), which is exactly production's apply order; and no repo tooling consumes
the directory (CI iterates `ls | LC_ALL=C sort`). Each re-committed file is idempotent AND guarded so a
stray re-apply on prod is a no-op (0009 skips its constraint/function bodies when 0010/0011 are present;
0010 skips `handle_new_user` when 0011's body is present). 0001–0008 are frozen history and are NOT
replay-safe (0001 `create policy`, 0006 `add constraint`) — CI replays only 0005b, 0008b and ≥0009.

## What each piece does
### Migrations
- `0005b` — prod-verbatim revokes; `handle_new_user`/`rls_auto_enable` also revoked from PUBLIC (safe, tested); `is_org_member` deliberately keeps PUBLIC (RLS runs with the caller's privileges — documented in the file + an invariant guards it).
- `0008b` — the column-scoped listings grant (no-op vs repo 0008, in prod history).
- `0009` — guarded history file (constraint swap only if still the 0001 set; hardcoded `plan_render_cap` only if absent; 5-arg `create_render_job` only if the 6-arg one is absent).
- `0010` — verbatim prod text (plan_entitlements + seeds via upsert, effective_plan/plan_entitlement/plan_render_cap/org_month_spend_cents, log_job_cost with the monthly COGS ceiling, trial_ends_at, six-plan check); `handle_new_user` guarded.
- `0011` — see the SQL below.

### Edge functions
- `_shared/http.ts` — `HttpError(status, message, code?, details?)` with `codeForStatus` defaults; envelope `{ error, code, ...details }`; shared `throwRpc` (RP402 "limit reached" → `quota_exceeded`, else `plan_required`).
- `_shared/entitlements.ts` — `quotaError` → 402 `plan_required` (cap 0) / 429 `quota_exceeded` with `{feature, used, cap, plan}`; `entitlementForCharge` turns a degraded plan lookup into 503 `upstream` (never a fake 402); `degraded` flag surfaced on `/me`.
- `_shared/r2.ts` — `NoSuchUpload` surfaced distinctly (`isNoSuchUpload`); presign `contentType` documented as advisory.
- `_shared/agentcard.ts` (new) — the one public-name rule (brand → agent profile → null; never an email/org name).
- `uploads` — `content_type` allow-listed on every ticket + `content_type_declared` stored; `/complete` requires declared==observed only when the client declared (videos AND photos — server defaults are guesses); poster tickets (`role:"render"`+`kind:"photo"`, ≤10 MB, jpeg/png/webp, key `renders/<org>/<listing>/<asset>.<ext>`); precise mismatch messages with `observed_type/declared_type`; idempotent `/complete` (replay → 200 + row unless a NEW staged object exists → 409 `already_complete:true`; multipart: HEAD final first, NoSuchUpload → verify assembled object); `/abort` refuses an already-assembled multipart; batch rejects `kind:"video"`; tickets 404 on deleted listings.
- `renders` — `publish-app`: `p_source:'app'`, `poster_asset_id`, `fail_render_job` on publish failure, returns `id`+`job_id`+`share_url`+`poster`; `POST /renders` passes `p_source:'worker'`; both call `assertNotDeleting`; NEW `PATCH /renders/:render_id/chapters` (RPC `set_render_chapters`, ≤60, label ≤80, sort 0–999); `GET /renders/:job_id` adds `id, listing_id, source, tier, tour.render_id`.
- `ai-video` — `/aerial` per B4 (grounded Seedance i2v with `aspect_ratio`, `duration` "4|6|8"; ungrounded Veo t2v); prompts built server-side from space_type/motion/time_of_day/region + guardrails, `style` appended ≤200 chars (legacy `prompt` treated as a style hint, never a replacement), `region` rejected when it looks like a street address; returns `grounded`. `/reel-clip` + `/declutter` space-aware defaults (space_type from body or the asset's listing). `/drone`: `upscale_factor` from the asset's max(width,height) vs the tier target (never >4K, never blind 2×), fps from the tier (bounded client override), no `target_fps` when the source already meets it; declutter requires probed `duration_s` (Bria pre-flight before charging). Asset must belong to the X-Org-Id org. Validate → charge → submit kept.
- `ai-photo` — `space_type` → industry profiles (restaurant/venue/fitness/retail/other) for twilight/sky/lawn/declutter/stage/custom + suggest/improve instructions; **real-estate strings verbatim**; `suggest`/`improve_prompt` on their own burst limiter `aiphotohelp:<org>` 120/5 min, never the monthly meter; explicit 402 when the plan's photo cap is 0; returns Gemini's actual mime.
- `listings` — PATCH validates `status` (DB set incl. `uploading`), `zillow_url` (http(s)), `sold_at` (ISO or null), `details` ≤16 KB, `main_photo_key` prefix; role problems are 403; DELETE also unpublishes via service role (plus the DB trigger).
- `tours` — 404 for deleted listings; adds `status`, `sold_at`, `sold`, `archived`, `published_at`; agent name via `agentcard.ts`.
- `portfolio` — same name rule; `org.name` email-guarded; `main_photo_key` used only when it is a `renders/` key; `published_at` per tour.
- `me` — GET: effective `plan`, `plan_raw`, `trial_ends_at`, `entitlement{…}`, `usage.by_feature` (from `rate_limits` rows, clamped, expired windows = 0) + month-scoped worker-only `usage.renders` (joined via listings, admin client), `usage.caps/windows/leads_new`, `portfolio_url`. PATCH /me/brand: `handle` (slug regex + reserved list, 23505 → 409), `org_name`, `name` never an email, heals a placeholder/email org name from the card name, 403 when RLS filters (non owner/admin).
- `leads` — NEW auth'd `GET /leads?listing_id=&since=&status=&limit=` (RLS user client, embeds `listings(address, space_type)`, `message` lifted from `extra`) and `PATCH /leads/:id {status}` (RPC `set_lead_status`); public POST unchanged except: phone-or-email required, 10-minute dedupe per tour+contact, 404 for deleted listings, GHL contacts tagged `rendprop_org/listing/slug` for attribution.

### CI / docs / ops
- `.github/workflows/ci.yml` — new `db-migrations` job: `postgres:16` service → `tests/ci-bootstrap.sql` → every migration (`LC_ALL=C`, `psql -1` each) → `tests/invariants.sql` → replay 0005b, 0008b and everything ≥0009 → invariants again.
- `tests/ci-bootstrap.sql` (new) — roles, `auth` schema + minimal `auth.users`, Supabase-identical `auth.uid()/role()/jwt()`, Supabase default privileges (so the REVOKE assertions are load-bearing).
- `tests/invariants.sql` — 56 assertions incl. pricing-page numbers (8/25/80; 150/300/600 edits; 8/20/40 clips; 2/6/15 aerials; 2 Topaz + 3 seats on Team; trial/free 1/10/1/0), one overload per RPC, grants on the new RPCs, RLS helper still executable, lifecycle schema, and a mutating fixture (two signups through the real trigger → app publishes free / worker jobs capped → poster → fail_render_job → chapters → lead status → cross-org 404 → soft-delete unpublish; cleans up).
- `docs/UPLOAD-AND-PUBLISH-CONTRACT.md` — error envelope table, content_type rule, poster flow, idempotent `/complete`, publish-app body/response, chapters, listings/leads/me/tours contracts.
- `functions/README.md` — routing table for all 11 functions, error codes, full secrets table (APPLE_*, TURNSTILE, GEMINI_* models, Stream aliases), deploy order rule, sweep cron SQL, honest known-gaps list.
- `DEPLOYMENT.md` — §0 migrations + wave-1 order, §9 sweeper cron, 11 functions, secrets incl. APPLE_*.
- `set-secrets.sh` — APPLE_TEAM_ID/CLIENT_ID/KEY_ID/PRIVATE_KEY_P8 (from `$APPLE_P8_PATH`), TURNSTILE_SECRET_KEY, GEMINI_IMAGE_MODEL/TEXT_MODEL, `TOUR_PUBLIC_BASE_URL=https://rendprop.com` (was rendprop.app — an unrouted host).
- `deploy-functions.sh` — `trap 'rm -rf "$STAGE"' EXIT`; `.deploy/` deleted + gitignored (also `functions/deno.json|deno.lock`).

## Deploy order (parent)
1. **Migration first:** apply `services/supabase/migrations/0011_app_publish_and_lifecycle.sql` to `ymgqpbnjpztwjsyvceld` (MCP `apply_migration` or SQL editor; single transaction; idempotent). Do NOT re-apply 0006–0008. Re-applying 0005b/0008b/0009/0010 is harmless (verified no-ops) but unnecessary — they are already in prod history.
   - Live functions keep working during the gap: every new RPC parameter has a default, and the 5-arg `create_render_job` / 4-arg `publish_render` calls resolve to the new signatures.
2. **Then deploy functions** (`./deploy-functions.sh` deploys all 11; the ones that changed: `renders`, `uploads`, `leads`, `me`, `listings`, `tours`, `portfolio`, `ai-video`, `ai-photo` + every function re-bundles the new `_shared`). The NEW `uploads`/`me`/`leads`/`renders` do not work against the OLD schema (`content_type_declared`, `render_jobs.source`, `leads.status`, `set_render_chapters`).
3. Run `tests/invariants.sql` against a branch/copy (its fixture inserts+deletes two `auth.users` rows) — or at least the read-only sections.
4. Ops decisions: plan for the two early-access `free` orgs; schedule `POST /me/sweep-deletions`; set APPLE_*/TURNSTILE secrets; `R2_PUBLIC_BASE_URL` must be set for posters/fal.

## Must be applied elsewhere (see /home/claude/audit/handoff-E.md)
- W1-F worker: claim filter `source=eq.worker`, conditional `fail_job`, `bucket/uploaded` in `fetch_asset`, new `publish_render` signature.
- W1-C iOS: content_type on tickets/PUTs, poster upload, `code` handling, new `/me`, `/leads`, chapters route, `space_type` on AI routes, aerial body.
- W1-D/W1-F player/tour-host: `status/sold_at/sold/archived` on `/tours`, nullable `agent_card.name` and `org.name`.
- Pricing copy (tour-host): window semantics (calendar-month renders vs 30-day AI meters) still differ from "rolling … refills continuously".

## Deliberately NOT done (and why)
- `is_org_member` NOT revoked from PUBLIC (would break all RLS — see experiment). Advisor warning on it is a false positive.
- 0001–0008 not made idempotent (frozen, already applied; changing them changes history without changing prod).
- `ai-enhance`, `beacon` untouched (not in scope; ai-enhance is dead in the live path per A5/F-G-01).
- No refund of a meter unit when the provider submit fails after charging (F-supabase-29) — needs a `refund_rate` RPC; noted as a risk.
- `usage.cost_cents` (internal COGS) still returned for back-compat; the app should stop displaying it (F-24).
- Team seats/invites, lead email notifications, per-tenant GHL locations — out of wave-1 scope (documented in README known gaps).

## Risks / things to watch
- **Deploy-order coupling**: functions before migration → `uploads`/`me`/`leads`/`renders` 400/500 on missing columns/RPCs. Migration before functions is safe.
- `create_render_job` now skips the monthly cap for app jobs entirely and rate-limits them at 60/hour/org; existing app-published jobs were backfilled to `source='app'` (prod: 1 job).
- `handle_new_user` reads `raw_user_meta_data->>'name' / 'full_name'`; GoTrue's Apple id_token grant does not carry the name unless the app passes it (W1-C/W1-B: PATCH /me/brand `name` on first sign-in).
- `/me` reads `rate_limits` rows with the admin client; `bump_rate` still counts past the cap, so `by_feature` is clamped to `caps`.
- `PATCH /me/brand` now returns 403 (was silent 200) for agent/marketing members — the app should only offer the card editor to owners/admins.
- Poster `content_type` allow-list excludes HEIC (browsers); iOS must send JPEG.
- `/ai-video/declutter` now 409s without probed `duration_s` (was: charged, then Bria rejected).
- The invariants fixture requires a DB where the signup trigger exists and inserts into `auth.users` — run on a branch, never prod.

## Exact SQL of the new migration (`services/supabase/migrations/0011_app_publish_and_lifecycle.sql`)

```sql
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
```
