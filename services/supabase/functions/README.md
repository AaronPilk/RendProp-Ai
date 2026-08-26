# Rendprop — Supabase Edge Functions (the API)

Deno + TypeScript Edge Functions that implement the API contract in
`docs/BACKEND-ARCHITECTURE.md §2`. Schema source of truth:
`services/supabase/migrations/0001_init.sql`. Cost model: `docs/AI-COST-MODEL.md`.

**Non-negotiables baked in:** video bytes go to R2/Stream only (functions return
presigned PUTs + URLs, never file bytes) · AI keys stay server-side · RLS on
every owner route (per-request JWT client) · public routes return a published,
non-sensitive subset via the service-role client · every provider unit is
metered and capped by `MAX_GEN_COST_PER_JOB_CENTS`.

---

## Layout

```
functions/
  _shared/        cors.ts · http.ts · supabase.ts · r2.ts · ledger.ts   (not deployed)
  listings/       owner  · CRUD
  uploads/        owner  · create capture_asset + R2 presigned PUT (+ /complete)
  renders/        owner  · create render_jobs · GET status · POST /:id/publish → tours
  ai-enhance/     server · thin validate + enqueue (202); pipeline does the real calls
  leads/          public · lead capture (+ optional GoHighLevel sync)
  tours/          public · read a published tour by slug (for the tour host)
  beacon/         public · view/scroll/streamed-minute metering
  me/             owner  · user + org + plan + usage rollup
```

`_shared/` is underscore-prefixed so `supabase functions deploy` skips it; each
function imports it with `../_shared/...`.

### Routing

Supabase serves each function at `/functions/v1/<name>` and passes sub-paths
through. `_shared/http.ts#pathSegments` strips the `functions/v1/<name>` prefix so
handlers see clean segments:

| Function | Paths handled |
|---|---|
| listings | `POST /` · `GET /` · `PATCH /:id` · `DELETE /:id` |
| uploads | `POST /` · `POST /:asset_id/complete` |
| renders | `POST /` · `GET /:id` · `POST /:id/publish` |
| tours | `GET /:slug` |
| leads | `POST /` |
| beacon | `POST /:slug` (or slug in body) |
| me | `GET /` |
| ai-enhance | `POST /` |

---

## 1. Prereqs

```bash
# https://supabase.com/docs/guides/cli
brew install supabase/tap/supabase
supabase login
supabase link --project-ref <your-project-ref>

# Apply the schema first (RLS + tables) if you haven't:
supabase db push        # or paste migrations/0001_init.sql into the SQL editor
```

## 2. Secrets

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are **injected
automatically** into every function by the platform — do not set them. Set the
rest:

```bash
supabase secrets set \
  CLOUDFLARE_ACCOUNT_ID=xxxxxxxx \
  R2_ACCESS_KEY_ID=xxxxxxxx \
  R2_SECRET_ACCESS_KEY=xxxxxxxx \
  R2_BUCKET_UPLOADS=rendprop-uploads \
  R2_BUCKET_RENDERS=rendprop-renders \
  R2_BUCKET_PUBLIC=rendprop-public \
  R2_PUBLIC_BASE_URL=https://cdn.rendprop.com \
  CLOUDFLARE_STREAM_CUSTOMER_CODE=xxxxxxxx \
  CLOUDFLARE_STREAM_TOKEN=xxxxxxxx \
  TOUR_PUBLIC_BASE_URL=https://rendprop.com \
  MAX_GEN_COST_PER_JOB_CENTS=2500 \
  GEMINI_API_KEY=xxxxxxxx \
  FAL_KEY=xxxxxxxx \
  ANTHROPIC_API_KEY=xxxxxxxx \
  ANTHROPIC_MODEL_QC=claude-haiku-4-5 \
  ANTHROPIC_MODEL_ESCALATE=claude-sonnet-5 \
  KIE_API_KEY=xxxxxxxx \
  QC_PASS_SCORE=85 \
  QC_MAX_RETRIES=2 \
  GHL_API_KEY=xxxxxxxx \
  GHL_LOCATION_ID=xxxxxxxx
```

| Secret | Used by | Notes |
|---|---|---|
| `CLOUDFLARE_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | uploads, renders, tours | R2 SigV4 presign / URLs |
| `R2_BUCKET_UPLOADS` / `_RENDERS` / `_PUBLIC` | uploads, renders, tours | default to `rendprop-*` |
| `R2_PUBLIC_BASE_URL` | renders, tours | public domain for the renders/public bucket; if unset, R2 video/poster URLs are `null` (rely on Stream) |
| `CLOUDFLARE_STREAM_CUSTOMER_CODE` | renders, tours | the `customer-<code>` subdomain for HLS manifests |
| `TOUR_PUBLIC_BASE_URL` | renders, tours | base for `…/f/<slug>` (default `https://rendprop.com`) |
| `MAX_GEN_COST_PER_JOB_CENTS` | ledger, ai-enhance | hard per-job cap (cents), default 2500 |
| `GEMINI_API_KEY`, `FAL_KEY`, `ANTHROPIC_API_KEY`, `KIE_API_KEY` | pipeline (via ai-enhance) | provider keys — never shipped to the app |
| `GHL_API_KEY`, `GHL_LOCATION_ID` | leads | optional; when both set, leads upsert to GoHighLevel |

## 3. Deploy

Public routes must be deployed with `--no-verify-jwt` (no user token; they use
the service-role client internally and restrict to published data). Owner routes
and `ai-enhance` keep JWT verification on (the render worker authenticates with
the service-role key, which the gateway accepts).

```bash
# Owner (JWT verified)
supabase functions deploy listings
supabase functions deploy uploads
supabase functions deploy renders
supabase functions deploy me
supabase functions deploy ai-enhance      # worker uses service-role key; app uses user JWT

# Public (no JWT)
supabase functions deploy tours   --no-verify-jwt
supabase functions deploy leads   --no-verify-jwt
supabase functions deploy beacon  --no-verify-jwt
```

Equivalent per-function config if you prefer `supabase/config.toml`:

```toml
[functions.tours]
verify_jwt = false
[functions.leads]
verify_jwt = false
[functions.beacon]
verify_jwt = false
```

## 4. Local dev

```bash
supabase start
supabase functions serve --env-file services/supabase/functions/.env.local

# owner call (JWT from a signed-in session):
curl -sX POST http://localhost:54321/functions/v1/listings \
  -H "Authorization: Bearer $USER_JWT" -H "Content-Type: application/json" \
  -d '{"space_type":"real_estate","address":"1247 Hillcrest Dr","beds":4,"baths":3,"sqft":2850,"price_cents":117500000}'

# public tour read:
curl -s http://localhost:54321/functions/v1/tours/Abc123XyZ0
```

---

## Conventions

- `Deno.serve` entrypoints; `createClient` from `npm:@supabase/supabase-js@2`;
  R2 SigV4 via `aws4fetch` (esm.sh). Secrets via `Deno.env.get`.
- Owner routes: `getUser(req)` validates the JWT, then a **per-request** client
  (`userClient(req)`) runs queries under RLS as that user.
- Public routes: `adminClient()` (service role) with **manual** filtering to
  published/non-sensitive rows only.
- Money in integer cents. `render_jobs.cost_cents` == `round(sum(cost_ledger.total_cents))`.

## Known TODOs / assumptions

- **Rate limiting** on `/leads` and `/beacon` is best-effort in-memory (resets
  per instance). Back it with Cloudflare Turnstile + a durable store
  (Upstash/CF KV) before launch.
- **Metering + cost rollup** use read-modify-write; fine for MVP, but move the
  increments to Postgres RPCs (`ON CONFLICT DO UPDATE … +=`) for atomicity under
  concurrency.
- **ai-enhance is thin by design.** It enqueues onto `render_jobs.enhancements._requests`
  and returns 202. `services/pipeline` makes the metered provider calls and
  records spend via `_shared/ledger.logCost()`.
- **`GET /portfolio/:handle`** (contract §2) is not yet implemented — add a
  `portfolio/` function returning `{agent_card, [tour summaries]}` for a public
  org handle.
- **Org selection:** `orgForUser` picks the caller's highest-privilege membership.
  Send `X-Org-Id` to act under a specific org (membership is verified).
- **Auth provider** (Sign in with Apple) and the `handle_new_user` profile
  trigger are configured in Supabase, not here.
