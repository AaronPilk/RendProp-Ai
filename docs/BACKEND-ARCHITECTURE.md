# Rendprop — Backend Architecture + API Contract + Runbook

Stack decision (locked): **Supabase** (Postgres + Auth + Edge Functions) + **Cloudflare** (R2 storage · Stream delivery · Pages/Workers for the public tour host). See `AI-COST-MODEL.md` for why (zero-egress video, never route bytes through Supabase).

This doc is the **contract** every backend component builds against. Directory layout for the new code:

```
services/
  supabase/
    migrations/        SQL migrations (source of truth for the DB; RLS included)
    functions/         Deno/TypeScript Edge Functions (the API)
      _shared/         auth, cors, supabase client, cost-ledger helper
      listings/        CRUD for listings (+ details jsonb, space_type)
      uploads/         create capture_asset + return R2 presigned PUT
      renders/         create/advance render_jobs; publish → tours
      ai-enhance/      AI proxy: declutter/restage/hero + cost metering + caps
      leads/           public lead capture (from the tour end-card) → DB (+GHL)
      tours/           public read of a published tour by slug (for the host)
  edge/
    tour-host/         Cloudflare Worker/Pages: serves /f/:slug (the player) + /a/:handle (portfolio)
    r2-sign/           (optional) Worker for R2 presign if not done in Supabase fn
  pipeline/            existing render/AI pipeline (Python) — enhance.py etc.
apps/ios/Rendprop/Networking/  LiveAPIClient wired to the above (Config.apiBaseURL)
```

---

## 1. Data flow (end to end)

1. **Auth** — iOS: Sign in with Apple → Supabase Auth (apple provider) → JWT. `users` row is the app profile; `auth.users.id` == `users.id`.
2. **Create listing** — `POST /listings` (space_type, address, details jsonb, tagline, coords).
3. **Upload** — `POST /uploads` returns an **R2 presigned PUT** + a `capture_assets` row; iOS `DirectUploader` PUTs the video straight to R2 (background URLSession). No bytes touch Supabase.
4. **Render** — `POST /renders` creates a `render_jobs` row (tier + enhancements). A worker (Modal/Cloudflare Container/self-host) runs the pipeline: stabilize → 60fps → (AI enhance if purchased) → encode. **On-device render still works** as the free/instant path; the server path is for 4K/AI/Stream hosting. Output uploaded to R2; registered to **Cloudflare Stream** for delivery.
5. **Publish** — job → `ready` creates a `tours` row with a public `slug`. Public URL = `https://rendprop.app/f/{slug}` served by the **tour-host Worker** (pulls tour JSON from `GET /tours/{slug}`, renders `player/index.html` with the Stream/R2 video + chapters + agent card + per-industry CTA).
6. **View** — viewer scrolls the tour (Stream HLS). A beacon posts view/scroll-depth/streamed-minutes to `metering`.
7. **Lead** — end-card form → `POST /leads` (public) → `leads` row → optional push to GoHighLevel CRM (user has GHL connected) + notify the agent (email/push).
8. **Cost** — every AI/GPU/stream unit writes a `cost_ledger` row; `render_jobs.cost_cents` is the rollup; `MAX_GEN_COST_PER_JOB_CENTS` aborts runaways.

---

## 2. API contract (Supabase Edge Functions; base = `https://<project>.supabase.co/functions/v1`)

Auth: `Authorization: Bearer <supabase_jwt>` for owner routes; public routes (`/tours/:slug` GET, `/leads` POST) use the anon key + RLS + a captcha/rate-limit.

| Method | Path | Auth | Body / params | Returns |
|---|---|---|---|---|
| POST | `/listings` | owner | `{space_type, address, tagline?, details?, price_cents?, beds?, baths?, sqft?, lat?, lng?}` | `listing` |
| GET | `/listings` | owner | `?status=&space_type=` | `[listing]` |
| PATCH | `/listings/:id` | owner | partial listing (incl. `sold_at`, `main_photo_key`, `details`) | `listing` |
| DELETE | `/listings/:id` | owner | — | `{ok}` |
| POST | `/uploads` | owner | `{listing_id, filename, bytes, sha256, kind:"video"|"photo"}` | `{asset_id, put_url, storage_key}` (R2 presigned PUT) |
| POST | `/uploads/:asset_id/complete` | owner | `{duration_s,fps,width,height,codec,is_drone,has_gyro}` | `asset` |
| POST | `/renders` | owner | `{listing_id, asset_id, tier, enhancements:{declutter,style}}` | `render_job` |
| GET | `/renders/:id` | owner | — | `{status,current_step,progress,cost_cents,tour?}` |
| POST | `/ai-enhance` | server/worker | `{job_id, feature:"declutter"|"restage"|"hero", image_key|frames, style?, mask_key?}` | `{output_key, cost_cents, qc_score}` |
| GET | `/tours/:slug` | public | — | `{listing(public subset), video_url(Stream/R2), poster, chapters, agent_card, cta, staged_disclosure}` |
| POST | `/leads` | public | `{slug, name, phone, email?, extra:{party_size?,event_date?,guest_count?,...}}` | `{ok}` |
| POST | `/beacon/:slug` | public | `{watch_ms, scroll_depth, streamed_minutes}` | `{ok}` (metering) |
| GET | `/me` | owner | — | `{user, org, plan, usage}` |
| GET | `/portfolio/:handle` | public | — | `{agent_card, [tour summaries]}` (whole-app link) |

CTA logic on `/tours/:slug`: from `space_type.actionURLKey` → deep-link (reservations/booking/online store/website) OR the lead form; per-industry `extra` fields come from the spec in `INDUSTRY-LOGIC.md`.

---

## 3. Storage (Cloudflare)

- **R2 buckets:** `rendprop-uploads` (raw captures + photos, presigned PUT), `rendprop-renders` (encoded proxies, poster frames), `rendprop-public` (published tour HTML + portfolio pages if not Worker-rendered). Zero egress.
- **Stream:** each published render is registered to Cloudflare Stream → HLS/DASH + adaptive bitrate + player. Store the Stream UID on `renders.stream_uid`. Delivery billed per watched minute (§AI-COST-MODEL). 4K = 1080p cost.
- Keys: `uploads/{org}/{listing}/{asset}.mov`, `renders/{listing}/{render}.mp4`, `renders/{listing}/{render}-poster.jpg`.

---

## 4. Auth & security

- **Supabase Auth** with the **Apple** provider (Sign in with Apple on iOS). JWT carries `sub` = user id.
- **RLS on every table:** a row is readable/writable only by members of its `org` (via `memberships`); public tour/lead routes read a *published, non-sensitive* subset via a `SECURITY DEFINER` function, never raw table access.
- **Rate-limit + captcha** on `/leads` and `/beacon` (public, abusable).
- **Service role key** only inside Edge Functions / the render worker — never shipped to the app.
- **AI provider keys** (`GEMINI_API_KEY`, `FAL_KEY`, `ANTHROPIC_API_KEY`, `KIE_API_KEY`, `CLOUDFLARE_*`) live in Supabase Function secrets / the worker env — never in the iOS app. The app calls our `/ai-enhance`, which proxies the providers and meters cost.

---

## 5. Env / secrets (set in Supabase → Edge Function secrets, and the render worker)

```
SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY
CLOUDFLARE_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_UPLOADS, R2_BUCKET_RENDERS
CLOUDFLARE_STREAM_TOKEN
GEMINI_API_KEY            # Nano Banana (restage) — cheapest direct
FAL_KEY                   # Flux Fill/Kontext (declutter inpaint) + Seedance (hero clip)
ANTHROPIC_API_KEY, ANTHROPIC_MODEL_QC=claude-haiku-4-5, ANTHROPIC_MODEL_ESCALATE=claude-sonnet-5
KIE_API_KEY               # optional one-key fallback
QC_PASS_SCORE=85, QC_MAX_RETRIES=2, MAX_GEN_COST_PER_JOB_CENTS=2500
GHL_API_KEY, GHL_LOCATION_ID   # optional: push leads to GoHighLevel
```

---

## 6. Provisioning runbook (do this in order)

1. **Supabase:** create project (Pro, $25/mo; spend cap ON). Get URL + anon + service-role keys.
2. Run `services/supabase/migrations/*.sql` (via Supabase SQL editor or `supabase db push`). Enables RLS + tables.
3. Enable **Apple** auth provider in Supabase (add the app's Services ID + key).
4. **Cloudflare:** create the 3 R2 buckets; create R2 API token (access key/secret); enable **Stream** and mint a Stream token.
5. Set all secrets (§5) in Supabase Edge Function secrets + the render worker env.
6. `supabase functions deploy` for each function in `services/supabase/functions/`.
7. Deploy the **tour-host** Worker/Pages (`services/edge/tour-host/`); map `rendprop.app/f/*` and `/a/*` to it.
8. In iOS `Config.swift`, set `apiBaseURL` to the Supabase functions URL; set `uploadMode = .direct`; flip `enableAuth = true`. Wire `LiveAPIClient` (see the iOS task).
9. Add AI provider keys, run one real `/ai-enhance` on a test image, confirm a `cost_ledger` row + the `MAX_GEN_COST_PER_JOB_CENTS` guard. **Now you have real cost numbers.**
10. Point the render worker (Modal or Cloudflare Container) at the queue; process one job end-to-end → published tour on Stream → open `/f/{slug}`.

**MVP shortcut to start cost-testing fast:** you don't need the whole render worker to measure AI cost. Deploy Supabase + `ai-enhance` + `cost_ledger` + keys, and call `/ai-enhance` on sample photos. That alone answers "what will the AI cost."

---

## 7. Non-negotiables (unchanged)

Video bytes → R2/Stream only (never Supabase). AI keys server-side only. RLS on everything. "Virtually staged" disclosure MUST render on any tour with enhancements (MLS/legal). Meter every provider call. Cost cap before every job.
