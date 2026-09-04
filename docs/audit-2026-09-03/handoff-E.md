# Handoff from W1-E (backend) — things other owners must apply

## W1-F (services/worker) — F-G-01 / F-G-13 interplay with `render_jobs.source`
Migration 0011 adds `render_jobs.source text not null default 'worker' check in ('worker','app')`.
`POST /renders/publish-app` now creates jobs with `source='app'` (free, created → ready in the
same request, or `failed` via `fail_render_job`). The worker must never claim them:

- `services/worker/db.py` claim query: add `source=eq.worker` (PostgREST filter) next to the
  `status=in.(created,queued)` filter. Existing app-published jobs were backfilled to `source='app'`.
- `fail_job`: make the PATCH conditional (`status=eq.processing` / `status=in.(claimed,processing)`)
  so a worker can never overwrite a `ready` job (F-G-13).
- `fetch_asset`: select `bucket, uploaded` and refuse (requeue/skip, don't fail) anything not
  `bucket='uploads' and uploaded=true`.
- If the worker ever publishes, use the new RPC signature
  `publish_render(p_job, p_duration, p_speed, p_chapters, p_poster_asset)` — `p_poster_asset` is a
  `capture_assets.id` (renders bucket, kind photo, same listing), not a key. The 4-arg overload is gone.

## W1-C (iOS Networking/Upload) — contract details beyond DECISIONS B4
- `POST /uploads`: send `content_type` derived from the file and PUT with that exact header. Poster:
  `{ kind:"photo", role:"render", content_type:"image/jpeg", bytes }` → `asset_id` → `publish-app.poster_asset_id`.
  Responses now also carry `content_type`.
- `/complete` → 200 + row both first time and on replay. `409` with `already_complete:true` = success.
  `400` (`observed_type`/`declared_type` in the body) is terminal — do not re-ticket in a loop.
- Error envelope: `{ error, code, ...details }`; quota errors carry `feature, used, cap, plan`.
  `create_render_job` RP402 arrives as status 402 with code `quota_exceeded` (not `plan_required`).
- `POST /renders/publish-app` → `{ ...render, id (render id), job_id, slug, share_url, poster }`.
- `PATCH /renders/:render_id/chapters { chapters:[{label,t_ms,sort}] }` → `{ ok, count, chapters }`.
- `GET /me`: `plan` (effective), `plan_raw`, `trial_ends_at`, `entitlement{…}`,
  `usage.by_feature{renders,photo_edits,reels,aerials,drone}` (plain integers),
  `usage.caps{…}`, `usage.windows{…}`, `usage.renders` (month, worker-only), `usage.leads`,
  `usage.leads_new`, `portfolio_url`.
- `GET /leads?listing_id=&since=&status=&limit=` → `{ leads:[{ id, listing_id, render_id, name, phone,
  email, message, extra, source, status, synced_crm, created_at, listing_address, listing_space_type }] }`.
  `PATCH /leads/:id { status }` → `{ ok, lead }`.
- `PATCH /me/brand`: `name` must not contain `@`; new optional `handle` (slug, 409 when taken) and
  `org_name`; response `{ ok, brand_kit, org:{name,handle}, portfolio_url }`.
- `POST /ai-video/aerial` body per B4; `mime` must be image/jpeg|png|webp; response adds `grounded`,
  `space_type`, `motion`, `time_of_day`, `region`. `seconds` snaps to 4|6|8.
- `POST /ai-video/drone` response adds `upscale_factor`, `interpolated`, `source{width,height,fps,duration_s}`.
- `POST /ai-photo`: send `space_type`; response `mime` is Gemini's real type (still PNG today).
- `PATCH /listings/:id`: `status` must be in `draft|capturing|uploading|processing|ready|expired|archived`
  (sending `uploading` verbatim is fine now); a role problem is `403`, not `404`.

## W1-D / W1-F (player + tour host)
- `GET /tours/:slug` adds top-level `status`, `sold_at`, `sold`, `archived`, `published_at` (and the
  same `status`/`sold_at` inside `listing`) and returns 404 for deleted listings.
- `agent_card.name` may now be `null` (hide the card title; never render an email).
- `GET /portfolio/:handle`: `org.name` may be `null`; tours carry `published_at`.

## Parent / ops (live project, after review)
1. Apply `services/supabase/migrations/0011_app_publish_and_lifecycle.sql` (MCP `apply_migration`
   or SQL editor) — BEFORE deploying functions.
2. Deploy all 11 functions from the repo (`services/supabase/deploy-functions.sh`).
3. Decide the two early-access orgs' plan (both `free` = 1 render / 10 edits / 0 aerials):
   `update orgs set plan='trial', trial_ends_at=now()+interval '7 days' where plan='free';` or `'solo'`.
4. Schedule `POST /me/sweep-deletions` (DEPLOYMENT.md §9) and set the APPLE_* + TURNSTILE secrets.
5. `services/edge/tour-host/wrangler.toml` / pricing copy: renders are counted per CALENDAR month and
   AI meters per 30-day window from first use — the FAQ says "rolling … refills continuously"
   (F-supabase-21) — a copy decision, not fixed here.
