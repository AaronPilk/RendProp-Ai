# Rendprop — Deployment status + remaining steps

## ✅ Already provisioned (done for you)

- **Supabase project:** dedicated **RendProp** project `ymgqpbnjpztwjsyvceld` (`https://ymgqpbnjpztwjsyvceld.supabase.co`, us-west-2, **Pro plan**). Its own project — NOT shared with anything. Schema is the standard `public` schema. Full schema + RLS + auto-provision-on-signup trigger applied.
- **Cloudflare R2 buckets created:** `rendprop-uploads`, `rendprop-renders`, `rendprop-public` (ENAM).
- **iOS app wired + FLIPPED LIVE:** `Config.swift` has the real Supabase URL + anon key, and `useLiveBackend = true` + `enableAuth = true`. The app runs offline (capture + on-device render) regardless; owner/publish calls need the steps below.

- **All 11 edge functions DEPLOYED + ACTIVE** (listings, uploads, renders, me, ai-enhance, ai-photo, ai-video [JWT]; tours, leads, beacon, portfolio [public]). They return errors until secrets are set — expected. Re-run `deploy-functions.sh` whenever function code changes (it deploys all 11 from the repo with a uniform `_shared/`).

## 0. Schema: migrations (apply BEFORE the functions that need them)

`migrations/` is the source of truth and replays on a fresh Postgres in CI
(`.github/workflows/ci.yml` → `db-migrations`, then `tests/invariants.sql`). Production
history already contains 0001–0010 (the four that were missing from the repo —
`0005b`, `0008b`, `0009`, `0010` — were re-committed 2026-09-03 and are safe no-ops if
re-applied). To ship a new migration:

```
# Supabase dashboard → SQL editor: paste the file, run. Or the MCP apply_migration tool.
# Each file is idempotent from 0005b onward; apply in LC_ALL=C sorted order.
```

**Fix wave 1 order (2026-09-03):**
1. Apply `migrations/0011_app_publish_and_lifecycle.sql` (render_jobs.source, poster,
   fail_render_job, chapters/lead RPCs, listings.status `uploading`, org-name trigger,
   soft-delete → unpublish). The live function versions keep working during the gap
   (every new RPC parameter has a default).
2. `./deploy-functions.sh` — `renders`, `uploads`, `leads`, `me`, `listings`, `tours`,
   `portfolio`, `ai-video`, `ai-photo` all changed; the script deploys everything.
3. Verify: `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/invariants.sql` against a
   **branch/copy** (the fixture creates and deletes two throwaway auth users).
4. Schedule the deletion sweeper (§9) and, if the two early-access orgs should keep
   publishing AI features, move them off `free`: `update orgs set plan='trial',
   trial_ends_at=now()+interval '7 days' where plan='free';` (or `'solo'`).

### How the live tour works now (base path — no Python worker)
The on-device render IS the tour. On publish the app uploads its rendered mp4 to the
**public renders bucket** (`/uploads role=render`) and calls `/renders/publish-app` to
mint the slug. So the base hosted tour needs only: R2 secrets + a **public URL on the
`rendprop-renders` bucket** (→ `R2_PUBLIC_BASE_URL`) + Apple auth + the tour-host worker.
The Python render worker and the AI provider keys are needed ONLY for AI enhancement /
server-side 4K — not for the base tour.

## Remaining (need YOUR keys — ~15–20 min)

### 1. Create a Cloudflare R2 API token
Cloudflare dash → R2 → **Manage R2 API Tokens** → Create (Object Read & Write). Save the **Access Key ID** and **Secret Access Key**, and note your **Account ID** (R2 overview page).

### 2. (Optional now) Enable Cloudflare Stream
Cloudflare dash → Stream → subscribe (pre-pay $5 block). Mint an API token with Stream edit. Skip for now if you want — tours will play straight from the R2 mp4 until Stream is on.

### 3. Get AI provider keys
- **Google AI Studio** → `GEMINI_API_KEY` (restage).
- **fal.ai** → `FAL_KEY` (declutter + hero clips).
- **Anthropic** → `ANTHROPIC_API_KEY` (QC drift judge).

### 4. Set the function secrets + deploy the functions
```
brew install supabase/tap/supabase        # if you don't have the CLI
cd ~/Rendprop\ AI/repo/services/supabase
supabase login
./set-secrets.sh                            # edit it first — paste your keys
./deploy-functions.sh                       # deploys all 11 edge functions
```

### 5. Enable Sign in with Apple (3 parts)
1. **Apple Developer:** enable the **Sign in with Apple** capability on App ID `com.rendprop.app`.
2. **Xcode entitlement:** add to `apps/ios/Rendprop/Rendprop.entitlements` (currently empty):
   ```xml
   <key>com.apple.developer.applesignin</key>
   <array><string>Default</string></array>
   ```
   With automatic signing + Team ID `5F5C5G25Y6`, Xcode provisions it on the next build.
3. **Supabase:** dash → Authentication → Providers → **Apple** → on; add the Services ID + key. This is what `AuthStore.exchangeAppleIdentityToken` calls.

Until all three are done, the app runs and renders locally, but the publish step's
Sign-in-with-Apple button errors (so no shareable link yet).

### 6. Deploy the public tour host (Cloudflare Worker)
```
cd ~/Rendprop\ AI/repo/services/edge/tour-host
npm install && npx wrangler deploy
```
Set its vars: `SUPABASE_FUNCTIONS_URL=https://ymgqpbnjpztwjsyvceld.supabase.co/functions/v1` and `SUPABASE_ANON_KEY=<anon>`. Map the routes `rendprop.com/f/*` and `/a/*` (needs the domain on Cloudflare) — or just use the `*.workers.dev` URL for testing.

### 7. (OPTIONAL — AI/4K only) Point the render worker at the queue
`services/worker/` — set its `.env` (Supabase service role + R2 + Stream + provider keys),
then run locally (`python worker.py`) or deploy the `Dockerfile` to Modal / Cloud Run.
**Not needed for the base hosted tour** (that's the app-publish path). Only required for
server-side AI enhancement (declutter/restage/hero) or 4K server renders.

### 8. Build on device
`Config.swift` is already `useLiveBackend = true` + `enableAuth = true`. Just rebuild the
app (steps 1, 2-as-needed, 5, 6 must be done for publish + playback to work end to end).
No `xcodegen` needed — no new source files were added to the target this round.

### 9. Schedule the deletion sweeper (required for honest account deletion)
`POST /me/sweep-deletions` (service-role bearer) drains `deletion_requests` tombstones —
R2 objects, Stream videos, CRM contacts, Apple revocations, the analytics-forget update and
the profile row, any of which failed or exceeded the inline caps. Nothing calls it by itself.
Enable `pg_cron` + `pg_net` (Dashboard → Database → Extensions) and run once in the SQL editor:
```sql
alter database postgres set app.service_role_key = '<service role key>';
select cron.schedule('sweep-deletions', '*/15 * * * *', $$
  select net.http_post(
    url     := 'https://ymgqpbnjpztwjsyvceld.supabase.co/functions/v1/me/sweep-deletions',
    headers := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.service_role_key'),
                                  'Content-Type', 'application/json'),
    body    := '{}'::jsonb) $$);
```
(Alternative: a Cloudflare Worker cron trigger in `services/edge/tour-host` doing the same
POST.) Check: `select * from deletion_requests where status <> 'completed';` should be empty
within one interval of any deletion.

### 10. Scheduling the app_events purge (pg_cron is a manual gate)
`app_events` (0020) is only kept honest by `purge_app_events(interval)`, which
deletes rows older than the retention window (default 180 days). That function
is created **unconditionally** — it always exists and can be called by hand or
from an external scheduler — but migration `0022_app_events_purge_schedule.sql`
can only put **pg_cron** in charge of calling it nightly (04:17 UTC), and
pg_cron is a `shared_preload_libraries` extension that is NOT enabled on a
fresh Supabase project (or a plain Postgres) by default.

0022 detects this and degrades on purpose: if `pg_cron` isn't available (or is
available but fails to actually schedule for any other reason — e.g. pg_cron
pins its objects to a single `cron.database_name` cluster-wide, so it can be
"available" yet still refuse to install in the wrong database) it logs a loud
`raise notice` naming what happened and skips the schedule, rather than
erroring out or silently doing nothing. **This means scheduling the purge is a
manual step in production, separate from applying the migration:**
1. Dashboard → Database → Extensions → enable **pg_cron**.
2. Re-run `migrations/0022_app_events_purge_schedule.sql` (safe — idempotent).
3. Confirm: `select * from cron.job where jobname = 'purge-app-events';` returns
   one row scheduled `17 4 * * *`.
4. If step 2's log instead shows `0022: pg_cron setup did not finish (...)`,
   read the `SQLSTATE`/message it prints — that's the actual blocker (e.g. a
   `cron.database_name` mismatch) on THIS server, not a missing extension.

Until that is done, `app_events` grows without bound — check the migration's
own log output for the `0022:` notice to see which state you're in. (This is
the same shape as the deletion-sweeper gate in §9, and can be combined with it
in one pg_cron enablement pass.)

## Cost-test WITHOUT the full backend (fastest)
`cd services/pipeline && cp .env.example .env` (paste the 3 provider keys) → `python cli.py run --image room.jpg --feature restage --style modern`. Real cost per call, logged to the ledger. See `docs/AI-COST-MODEL.md`.

## Secrets reference (set via set-secrets.sh)
`CLOUDFLARE_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_UPLOADS=rendprop-uploads, R2_BUCKET_RENDERS=rendprop-renders, R2_BUCKET_PUBLIC=rendprop-public, R2_PUBLIC_BASE_URL, CLOUDFLARE_STREAM_TOKEN, CLOUDFLARE_STREAM_CUSTOMER_CODE, GEMINI_API_KEY, GEMINI_IMAGE_MODEL, GEMINI_TEXT_MODEL, FAL_KEY, JOB_TOKEN_SIGNING_SECRET (signs the ai-video async-job status token — audit item 4, a dedicated secret, never reuse a vendor key), ANTHROPIC_API_KEY, KIE_API_KEY(optional), GHL_API_KEY(optional), GHL_LOCATION_ID(optional), TURNSTILE_SECRET_KEY (required — leads/index.ts now FAILS CLOSED on POST /leads when this is unset; set TURNSTILE_OPTIONAL=1 instead if you are knowingly launching without bot protection), APPLE_TEAM_ID, APPLE_CLIENT_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY_P8 (all four required for Sign in with Apple revocation), QC_PASS_SCORE=85, QC_MAX_RETRIES=2, MAX_GEN_COST_PER_JOB_CENTS=2500, TOUR_PUBLIC_BASE_URL=https://rendprop.com` (the routed domain — never rendprop.app).
(`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are auto-injected into functions — no need to set.)

**`TURNSTILE_SECRET_KEY` changed behavior (2026-09-07 audit fix):** it used to
be optional — unset meant "not configured yet, don't block." `POST /leads` now
FAILS CLOSED instead: with the secret unset, every public lead submission is
rejected (and a warning naming the var is logged). Set the secret before
driving real traffic to the tour end-card, or set `TURNSTILE_OPTIONAL=1` if
you are knowingly deploying without bot protection (a warning is still logged
either way). See `services/supabase/functions/leads/README.md`.
