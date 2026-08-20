# Rendprop — Deployment status + remaining steps

## ✅ Already provisioned (done for you)

- **Supabase project:** dedicated **RendProp** project `ymgqpbnjpztwjsyvceld` (`https://ymgqpbnjpztwjsyvceld.supabase.co`, us-west-2, **Pro plan**). Its own project — NOT shared with anything. Schema is the standard `public` schema. Full schema + RLS + auto-provision-on-signup trigger applied.
- **Cloudflare R2 buckets created:** `rendprop-uploads`, `rendprop-renders`, `rendprop-public` (ENAM).
- **iOS app wired:** `Config.swift` has the real Supabase URL + anon key. `useLiveBackend` is still **false** — flip it after the steps below.

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

### 5. Enable Sign in with Apple (Supabase Auth)
Supabase dash → Authentication → Providers → **Apple** → on. Add your app's Services ID + key (Apple Developer). This is what `AuthStore.exchangeAppleIdentityToken` calls.

### 6. Deploy the public tour host (Cloudflare Worker)
```
cd ~/Rendprop\ AI/repo/services/edge/tour-host
npm install && npx wrangler deploy
```
Set its vars: `SUPABASE_FUNCTIONS_URL=https://ymgqpbnjpztwjsyvceld.supabase.co/functions/v1` and `SUPABASE_ANON_KEY=<anon>`. Map the routes `rendprop.app/f/*` and `/a/*` (needs the domain on Cloudflare) — or just use the `*.workers.dev` URL for testing.

### 7. Point the render worker at the queue (when you want server-side 4K/AI renders)
`services/worker/` — set its `.env` (Supabase service role + R2 + Stream + provider keys), then run locally (`python worker.py`) or deploy the `Dockerfile` to Modal / Cloud Run. On-device render still works without this; the worker is for the hosted/Stream/AI path.

### 8. Flip the app live
In `apps/ios/Rendprop/Config.swift` set `useLiveBackend = true` (and `enableAuth = true` once Apple auth is on). Rebuild.

## Cost-test WITHOUT the full backend (fastest)
`cd services/pipeline && cp .env.example .env` (paste the 3 provider keys) → `python cli.py run --image room.jpg --feature restage --style modern`. Real cost per call, logged to the ledger. See `docs/AI-COST-MODEL.md`.

## Secrets reference (set via set-secrets.sh)
`CLOUDFLARE_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_UPLOADS=rendprop-uploads, R2_BUCKET_RENDERS=rendprop-renders, R2_BUCKET_PUBLIC=rendprop-public, R2_PUBLIC_BASE_URL, CLOUDFLARE_STREAM_TOKEN, CLOUDFLARE_STREAM_CUSTOMER_CODE, GEMINI_API_KEY, FAL_KEY, ANTHROPIC_API_KEY, KIE_API_KEY(optional), GHL_API_KEY(optional), GHL_LOCATION_ID(optional), QC_PASS_SCORE=85, QC_MAX_RETRIES=2, MAX_GEN_COST_PER_JOB_CENTS=2500, TOUR_PUBLIC_BASE_URL=https://rendprop.app`.
(`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are auto-injected into functions — no need to set.)
