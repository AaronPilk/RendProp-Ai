# Rendprop — Deployment status + remaining steps

## ✅ Already provisioned (done for you)

- **Supabase project:** dedicated **RendProp** project `ymgqpbnjpztwjsyvceld` (`https://ymgqpbnjpztwjsyvceld.supabase.co`, us-west-2, **Pro plan**). Its own project — NOT shared with anything. Schema is the standard `public` schema. Full schema + RLS + auto-provision-on-signup trigger applied.
- **Cloudflare R2 buckets created:** `rendprop-uploads`, `rendprop-renders`, `rendprop-public` (ENAM).
- **iOS app wired + FLIPPED LIVE:** `Config.swift` has the real Supabase URL + anon key, and `useLiveBackend = true` + `enableAuth = true`. The app runs offline (capture + on-device render) regardless; owner/publish calls need the steps below.

- **All 9 edge functions DEPLOYED + ACTIVE** (listings, uploads, renders, me, ai-enhance [JWT]; tours, leads, beacon, portfolio [public]). `uploads` + `renders` are at **v3** (resumable multipart + app-publish path). They return errors until secrets are set — expected. Re-run `deploy-functions.sh` only if you change function code.

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
./deploy-functions.sh                       # deploys all 10 edge functions
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

## Cost-test WITHOUT the full backend (fastest)
`cd services/pipeline && cp .env.example .env` (paste the 3 provider keys) → `python cli.py run --image room.jpg --feature restage --style modern`. Real cost per call, logged to the ledger. See `docs/AI-COST-MODEL.md`.

## Secrets reference (set via set-secrets.sh)
`CLOUDFLARE_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_UPLOADS=rendprop-uploads, R2_BUCKET_RENDERS=rendprop-renders, R2_BUCKET_PUBLIC=rendprop-public, R2_PUBLIC_BASE_URL, CLOUDFLARE_STREAM_TOKEN, CLOUDFLARE_STREAM_CUSTOMER_CODE, GEMINI_API_KEY, FAL_KEY, ANTHROPIC_API_KEY, KIE_API_KEY(optional), GHL_API_KEY(optional), GHL_LOCATION_ID(optional), QC_PASS_SCORE=85, QC_MAX_RETRIES=2, MAX_GEN_COST_PER_JOB_CENTS=2500, TOUR_PUBLIC_BASE_URL=https://rendprop.com`.
(`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are auto-injected into functions — no need to set.)
