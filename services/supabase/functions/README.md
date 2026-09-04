# Rendprop — Supabase Edge Functions (the API)

Deno + TypeScript Edge Functions that implement the API contract in
`docs/BACKEND-ARCHITECTURE.md §2` and `docs/UPLOAD-AND-PUBLISH-CONTRACT.md`.
Schema source of truth: `services/supabase/migrations/*.sql` (0001 → 0011, replayed
and asserted by CI — see `tests/`). Cost model: `docs/AI-COST-MODEL.md`.

**Non-negotiables baked in:** video bytes go to R2/Stream only (functions return
presigned PUTs + URLs, never file bytes) · AI keys stay server-side · RLS on
every owner route (per-request JWT client) · public routes return a published,
non-sensitive subset via the service-role client · every paid provider call is
metered against `plan_entitlements` (the same numbers rendprop.com/pricing
publishes — `tests/invariants.sql` asserts they agree) and capped by
`MAX_GEN_COST_PER_JOB_CENTS` / the per-org monthly COGS ceiling.

---

## Layout

```
functions/
  _shared/        cors · http (error envelope, RPnnn → HTTP) · supabase · r2 · ratelimit ·
                  entitlements · ledger · stream · apple · agentcard      (not deployed on its own)
  listings/       owner  · CRUD (+ DELETE unpublishes the hosted tour)
  uploads/        owner  · tickets (single/multipart/batch/poster) · part-urls · complete · abort
  renders/        owner  · publish-app (free) · POST /renders (worker) · status · chapters
  me/             owner  · user + org + EFFECTIVE plan + entitlement + usage · brand/handle · apple-code · DELETE
  leads/          public POST (end-card capture) · owner GET/PATCH (inbox)
  ai-photo/       owner  · Gemini photo edits (industry-aware) + free suggest/improve helpers
  ai-video/       owner  · fal: drone-glide (Topaz) · declutter (Bria) · aerial (Seedance i2v / Veo t2v) · reel-clip
  ai-enhance/     server · thin validate + enqueue (202) — worker path only
  tours/          public · a published tour by slug (for the tour host)
  portfolio/      public · an org's published tours by handle (/a/:handle)
  beacon/         public · view/scroll/streamed-minute metering
```

`_shared/` is underscore-prefixed so `supabase functions deploy` skips it; each
function imports it with `../_shared/...`. Always deploy from the repo with
`../deploy-functions.sh` so every function bundles the SAME `_shared` (hand
deploys once left three functions on private, older copies).

### Routing

Supabase serves each function at `/functions/v1/<name>` and passes sub-paths
through. `_shared/http.ts#pathSegments` strips the `functions/v1/<name>` prefix so
handlers see clean segments:

| Function | Auth | Paths handled |
|---|---|---|
| listings | JWT | `POST /` · `GET /?status=&space_type=` · `PATCH /:id` (validated `status`, `zillow_url`, `sold_at:null`) · `DELETE /:id` (soft + unpublish) |
| uploads | JWT | `POST /` (`role:"capture"\|"render"`, `kind:"video"\|"photo"`; render+photo = poster) · `POST /batch` (photos) · `POST /:asset_id/part-urls` · `POST /:asset_id/complete` (idempotent) · `POST /:asset_id/abort` |
| renders | JWT | `POST /publish-app` (`p_source:'app'`, `poster_asset_id?`) · `POST /` (worker job) · `GET /:job_id` · `POST /:job_id/publish` · `PATCH /:render_id/chapters` |
| me | JWT | `GET /` · `PATCH /brand` (+ `handle`, `org_name`) · `POST /apple-code` · `DELETE /` · `POST /sweep-deletions` (service role) |
| leads | public + JWT | `POST /` (public capture) · `GET /?listing_id=&since=&status=&limit=` · `PATCH /:id {status}` |
| ai-photo | JWT | `POST /` (`edit`, `space_type`, `style`, `prompt`; `suggest` / `improve_prompt` are not metered) |
| ai-video | JWT | `POST /drone` · `POST /declutter` · `POST /aerial` · `POST /reel-clip` · `GET /status?status_url=&response_url=` |
| ai-enhance | service role / JWT | `POST /` |
| tours | public | `GET /:slug` (404 for deleted listings; carries `status`, `sold_at`) |
| portfolio | public | `GET /:handle` |
| beacon | public | `POST /:slug` (or slug in body) |

### Error envelope

Every non-2xx response is `{ "error": string, "code": string, ...details }`.
`error` is human copy the app may show verbatim; `code` is what it branches on:

`validation` · `unauthorized` · `forbidden` · `not_found` · `conflict` ·
`plan_required` (402: the plan does not include the feature → upgrade prompt) ·
`quota_exceeded` (this cycle's allowance is used up; carries `feature, used, cap, plan`) ·
`rate_limited` (burst limit → "try again in a few minutes") · `payload_too_large` ·
`upstream` (provider / storage / plan-lookup failure → retry) · `internal`.

RPC exceptions raised by the SECURITY DEFINER functions are prefixed `RPnnn:` and
mapped by `_shared/http.ts#throwRpc`.

---

## 1. Prereqs

```bash
# https://supabase.com/docs/guides/cli
brew install supabase/tap/supabase
supabase login
supabase link --project-ref <your-project-ref>

# Apply the schema (RLS + tables + RPCs): every file in ../migrations, in
# LC_ALL=C sorted order (0001 … 0005b … 0008b … 0011). On the live project only
# the NEW files are applied (see ../DEPLOYMENT.md §0); CI replays all of them on
# a fresh Postgres and runs ../tests/invariants.sql.
```

## 2. Secrets

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are **injected
automatically** into every function by the platform — do not set them. Set the
rest with `../set-secrets.sh` (edit it first). Reference:

| Secret | Used by | Notes |
|---|---|---|
| `CLOUDFLARE_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | uploads, renders, tours, me, ai-video | R2 SigV4 presign / HEAD / copy / delete |
| `R2_BUCKET_UPLOADS` / `_RENDERS` / `_PUBLIC` | uploads, me | default to `rendprop-*` |
| `R2_PUBLIC_BASE_URL` | renders, tours, portfolio, ai-video | public domain for the renders bucket; if unset, R2 video/poster URLs are `null` and fal cannot fetch assets |
| `CLOUDFLARE_STREAM_CUSTOMER_CODE` | renders, tours | the `customer-<code>` subdomain for HLS manifests |
| `CLOUDFLARE_STREAM_TOKEN` (alias `CLOUDFLARE_STREAM_API_TOKEN`, `CLOUDFLARE_API_TOKEN`) | me | Stream deletion on account delete; queued when unset |
| `TOUR_PUBLIC_BASE_URL` | renders, tours, portfolio, me | base for `…/f/<slug>` and `…/a/<handle>` — **`https://rendprop.com`** (the routed domain) |
| `MAX_GEN_COST_PER_JOB_CENTS` | ledger, ai-enhance | hard per-job cap (cents), default 2500 |
| `GEMINI_API_KEY`, `GEMINI_IMAGE_MODEL`, `GEMINI_TEXT_MODEL` | ai-photo | image edits (default `gemini-2.5-flash-image`) and the suggest/improve helpers (default `gemini-2.5-flash`) |
| `FAL_KEY` | ai-video | Topaz / Bria / Veo / Seedance queue |
| `ANTHROPIC_API_KEY`, `KIE_API_KEY` | pipeline (via ai-enhance / worker) | provider keys — never shipped to the app |
| `GHL_API_KEY`, `GHL_LOCATION_ID` | leads, me | optional; leads upsert to GoHighLevel (tagged `rendprop_org:<id>`), deletion removes them |
| `TURNSTILE_SECRET_KEY` | leads | optional; when set, the end-card form must carry a valid Turnstile token |
| `APPLE_TEAM_ID`, `APPLE_CLIENT_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY_P8` | me | **all four required** for Sign in with Apple token exchange + revocation (TN3194); otherwise `/me/apple-code` answers `stored:false` |

## 3. Deploy

Public routes must be deployed with `--no-verify-jwt` (no user token; they use
the service-role client internally and restrict to published data — `leads`
validates the JWT itself on its owner routes). Owner routes keep JWT
verification on (the render worker authenticates with the service-role key,
which the gateway accepts).

```bash
cd services/supabase && ./deploy-functions.sh     # all 11, uniform _shared/, temp dir cleaned on exit
```

Equivalent per-function config if you prefer `supabase/config.toml`:

```toml
[functions.tours]
verify_jwt = false
[functions.leads]
verify_jwt = false
[functions.beacon]
verify_jwt = false
[functions.portfolio]
verify_jwt = false
```

**Order matters when a migration changes an RPC signature:** apply the migration
first, then deploy the functions that call it (0011 → `renders`, `uploads`,
`leads`, `me`, `listings`). The old function versions keep working against the
new schema (defaults on every new parameter); the new versions do NOT work
against the old schema.

## 4. Scheduled work

`POST /me/sweep-deletions` (service-role bearer) drains deletion tombstones —
R2 objects, Stream videos, CRM contacts, Apple revocations that failed or
exceeded the inline caps — until each payload is empty. Nothing calls it on its
own. Schedule it every 15 minutes with Supabase cron (`pg_cron` + `pg_net`):

```sql
-- Dashboard → Database → Extensions: enable pg_cron and pg_net, then:
select cron.schedule(
  'sweep-deletions', '*/15 * * * *',
  $$ select net.http_post(
       url     := 'https://ymgqpbnjpztwjsyvceld.supabase.co/functions/v1/me/sweep-deletions',
       headers := jsonb_build_object('Authorization', 'Bearer ' || current_setting('app.service_role_key'),
                                     'Content-Type', 'application/json'),
       body    := '{}'::jsonb) $$);
-- store the key once (superuser SQL editor): alter database postgres set app.service_role_key = '<service role key>';
```

Or, without pg_cron, a Cloudflare Worker cron trigger in `services/edge/tour-host`
that does the same POST. Either way, `deletion_requests` rows should never sit
in `pending` for more than one interval.

## 5. Local dev

```bash
supabase start
supabase functions serve --env-file services/supabase/functions/.env.local

# owner call (JWT from a signed-in session):
curl -sX POST http://localhost:54321/functions/v1/listings \
  -H "Authorization: Bearer $USER_JWT" -H "Content-Type: application/json" \
  -d '{"space_type":"real_estate","address":"1247 Hillcrest Dr","beds":4,"baths":3,"sqft":2850,"price_cents":117500000}'

# public tour read:
curl -s http://localhost:54321/functions/v1/tours/Abc123XyZ0

# typecheck everything the way CI does:
cd services/supabase/functions && echo '{"nodeModulesDir":"auto"}' > deno.json && for d in */; do [ "$d" = _shared/ ] || deno check "${d}index.ts"; done; rm deno.json
```

---

## Conventions

- `Deno.serve` entrypoints; `createClient` from `npm:@supabase/supabase-js@2`;
  R2 SigV4 via `aws4fetch` (esm.sh). Secrets via `Deno.env.get`.
- Owner routes: `getUser(req)` validates the JWT, then a **per-request** client
  (`userClient(req)`) runs queries under RLS as that user. Writes on locked-down
  tables go through SECURITY DEFINER RPCs (`create_render_job`, `publish_render`,
  `fail_render_job`, `set_render_chapters`, `set_lead_status`, `bump_rate`,
  `bump_metering`, `log_job_cost`) or the service client after an RLS-scoped
  read proved membership + role.
- Public routes: `adminClient()` (service role) with **manual** filtering to
  published/non-sensitive rows only; the agent card never publishes an email
  (`_shared/agentcard.ts`).
- Validate → charge → submit: every paid route validates its body and resolves
  its asset BEFORE touching a quota, and charges immediately before the
  provider call.
- Money in integer cents. `render_jobs.cost_cents` == `round(sum(cost_ledger.total_cents))`.
- Durable rate limits + monthly meters are Postgres rows (`bump_rate`), shared
  by every instance; the in-memory limiter is only the degraded fallback.
- Org selection: `orgForUser` picks the caller's highest-privilege membership.
  Send `X-Org-Id` to act under a specific org (membership is verified; assets
  must belong to that org).

## Known gaps

- **Lead notifications** (email/push) are not wired — the app's Leads screen
  (`GET /leads`) is the delivery channel; the copy says "email alerts coming".
- **Team seats / invitations** do not exist yet (`plan_entitlements.seats` is not
  enforced anywhere).
- **ai-enhance** enqueues onto `render_jobs.enhancements._requests`, which the
  Python worker does not consume yet; the app no longer offers declutter/restage
  on Review & Submit, so nothing calls it in the live path.
- **AI photo/video spend** is metered per kind (counters) but not written to
  `cost_ledger`, so `usage.cost_cents` only reflects worker jobs.
- The Sign in with Apple provider and the `handle_new_user` trigger are
  configured in Supabase (Auth → Providers) and `migrations/`, not here.
