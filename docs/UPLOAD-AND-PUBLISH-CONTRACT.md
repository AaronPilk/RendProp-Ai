# Rendprop — Upload & Publish contract (DEPLOYED) + iOS client design

Status: backend **live** on Supabase project `ymgqpbnjpztwjsyvceld` (edge functions
`uploads`, `renders`, `tours`, `leads`, `me`, `listings` — fix wave 1, 2026-09-03; schema
through migration `0011_app_publish_and_lifecycle`). This doc is the source of truth for
the iOS client that talks to it. #1 rule: **works perfectly for large files — no shortcuts.**
Target load: a 9-minute 4K walkthrough (2–8 GB) and 70+ photos per listing.

---

## 0. Error envelope (every function)

Every non-2xx response is JSON:

```json
{ "error": "human copy the app may show", "code": "quota_exceeded", "feature": "AI aerial", "used": 2, "cap": 2, "plan": "starter" }
```

`code` is stable and is what the client branches on:

| code | status | client behaviour |
|---|---|---|
| `validation` | 400/405 | show `error` |
| `unauthorized` | 401 | sign-in prompt (after one token refresh + retry) |
| `forbidden` | 403 | show `error` |
| `not_found` | 404 | show `error`; for a cached `serverID` → drop it and re-create the listing once |
| `conflict` | 409 | `/complete` with `already_complete:true` = **success**; AI routes = "already started" |
| `plan_required` | 402 | "Upgrade plan" CTA → https://rendprop.com/pricing (no prices in-app) |
| `quota_exceeded` | 429 (402 from `create_render_job`) | "Upgrade plan" CTA + `used of cap` |
| `rate_limited` | 429 | "try again in a few minutes" |
| `payload_too_large` | 413 | downscale the image and retry |
| `upstream` | 502/503 | retry later (provider / storage / plan lookup) |
| `internal` | 500 | show `error` |

---

## 1. Why multipart (the thing we are NOT allowed to shortcut)

A single presigned `PUT` cannot resume: a dropped bar of signal at minute 7 of an
8 GB upload restarts from zero, and R2 caps a single-object PUT at 5 GB anyway. So
large video uploads use **S3/R2 multipart** — chunked, per-part retry, resumable
across network drops and app relaunch. Photos use a batched single-PUT path.

Bytes NEVER pass through Supabase (its egress is the cost trap). The app streams
straight to R2 via presigned URLs.

---

## 2. Deployed HTTP contract (Supabase Edge Functions, base `…/functions/v1`)

All owner routes require `Authorization: Bearer <supabase jwt>` + `apikey: <anon>`.
Optional `X-Org-Id` pins the workspace; optional `Idempotency-Key` (8–128 chars) makes
`publish-app` and the AI routes replay-safe — derive it from the operation
(`publish:<serverListing>:<asset>`), never mint a fresh UUID per request.

### 2.1 Start an upload — `POST /uploads`
Body: `{ listing_id, filename, bytes, sha256?, kind: "video"|"photo", content_type?, multipart?, role: "capture"|"render" }`

- **Always send `content_type`** — derive it from the file (`.mp4 → video/mp4`,
  `.mov → video/quicktime`, `.m4v → video/x-m4v`, `.jpg → image/jpeg`, …) and PUT with
  the **same** header. Allow-lists: video `video/mp4|video/quicktime|video/x-m4v`;
  photo `image/jpeg|png|heic|heif|webp`; poster (`role:"render"` + `kind:"photo"`)
  `image/jpeg|png|webp`, ≤ 10 MB. When the client declares the type, `/complete`
  requires the object to carry exactly that type. When it is omitted the server
  defaults it (`video/mp4` for render, `video/quicktime` for capture, `image/jpeg`
  for photos) and `/complete` accepts **any allow-listed** observed type.
- `role:"capture"` → private uploads bucket, key `uploads/<org>/<listing>/<asset>.<ext>`.
- `role:"render"` + `kind:"video"` → public renders bucket, key `renders/<org>/<listing>/<asset>.mp4`
  (the app's on-device tour mp4).
- `role:"render"` + `kind:"photo"` → the tour **poster**, public renders bucket, key
  `renders/<org>/<listing>/<asset>.<jpg|png|webp>` (first frame of the tour, ≤ 1280 px
  JPEG q0.8). Its `asset_id` goes to `publish-app` as `poster_asset_id`.
- Video with `bytes > 64 MB` (or `multipart:true`) → **multipart**:
  `{ asset_id, mode:"multipart", upload_id, storage_key, part_size, part_count, content_type }`
- Otherwise → **single**:
  `{ asset_id, mode:"single", put_url, storage_key, content_type }`

`part_size` is uniform (last part smaller). `part_count = ceil(bytes/part_size)`.
Single-PUT URLs expire in **15 min** and target a staging key; `/complete` promotes.

### 2.2 Get presigned part URLs — `POST /uploads/:asset_id/part-urls`
Body: `{ numbers: number[] }` (1-based part numbers, ≤ 256 per call).
→ `{ urls: [{ number, url }] }`. URLs expire in 1 h — request them **as you go /
on resume**, not all up front.

Upload part `n` = HTTP **PUT** the byte range
`[(n-1)*part_size, min(n*part_size, bytes))` of the source file to its `url`.
The response's **`ETag`** header is that part's etag — keep it.

### 2.3 Finish — `POST /uploads/:asset_id/complete`
- Multipart: `{ parts: [{number, etag}], duration_s?, fps?, width?, height?, codec?, is_drone?, has_gyro?, sha256?, bytes? }` — `parts` REQUIRED.
- Single: same body **without** `parts`.
→ `200` the updated `capture_assets` row (has `uploaded:true`, server-observed `bytes` and `content_type`).

**Idempotent.** A replay after a lost response returns `200` + the same row (no new
job of work is done). It is `409 conflict` only when a NEW staged object exists for an
already-completed asset — treat `409` with `already_complete:true` as success; a `400`
(size/type mismatch — the object was deleted) is terminal: fix the input and start a new
ticket, do not re-ticket in a loop. A multipart whose R2 assembly already happened
before a crash is detected and completed on retry.

The server verifies size == declared `bytes` and the content type (see 2.1); the
metadata fields are client claims used for display/pre-flight (`duration_s` is what
`publish-app` and the Bria pre-check read).

### 2.4 Abort — `POST /uploads/:asset_id/abort`  `{}` → `{ ok:true }`
Aborts the in-flight R2 multipart session (cleanup). Safe to call on cancel. Refused
(`409`) once the asset is complete, or once R2 has already assembled a multipart —
call `/complete` instead.

### 2.5 Photo batch — `POST /uploads/batch`
Body: `{ listing_id, kind:"photo", files:[{filename, bytes, sha256?, content_type?}] }` (≤ 200; `kind:"video"` is rejected — use 2.1 per video)
→ `{ assets:[{ index, asset_id, put_url, storage_key, content_type }] }`
Upload each with a single PUT (same `Content-Type`), then `POST /uploads/:asset_id/complete { width?, height?, bytes?, sha256? }`.

### 2.6 Render / publish (worker path) — `POST /renders`, `GET /renders/:job_id`, `POST /renders/:job_id/publish`
- `POST /renders { listing_id, asset_id, tier, enhancements }` → render_job (`source:"worker"`;
  counts against `renders_per_month`; max 3 in flight).
  **`asset_id` MUST be the SERVER `asset_id` from `/uploads`** (not a local id) and
  the upload MUST be completed first, or the server 409s.
- `GET /renders/:job_id` → `{ id, listing_id, status, source, tier, current_step, progress, cost_cents, error, tour? }` where
  `tour = { render_id, slug, share_url, video_url, scrub_url, hls_url, poster, staged, duration_s, published_at }`.
- Scrub fidelity: **`scrub_url` is the all-intra R2 mp4** (byte-range, frame-accurate
  scrubbing — the product's crown jewel). `hls_url` is Stream, an adaptive fallback
  ONLY. Prefer `scrub_url` in the player.

### 2.7 App-published tour (base path — NO Python worker) — DEPLOYED
The on-device render IS the tour. Three steps:
1. **Upload the rendered mp4 to the PUBLIC renders bucket:** `POST /uploads` with
   `{ listing_id, bytes, content_type:"video/mp4", kind:"video", role:"render" }` (+ multipart if
   >64 MB, same lifecycle as §2.1–2.4). `/complete` it with `{ duration_s, ... }`.
2. **Upload the poster** (optional but expected): `POST /uploads`
   `{ listing_id, bytes, content_type:"image/jpeg", kind:"photo", role:"render" }` → PUT → `/complete`.
3. **Publish:** `POST /renders/publish-app` (+ `Idempotency-Key: publish:<listing>:<asset>`)
   `{ listing_id, asset_id, duration_s, speed_factor?, tier?, enhancements?, chapters:[{label,t_ms,sort}], poster_asset_id? }`
   → `201 { ...render, id, job_id, slug, share_url, poster, poster_key, video_key, staged, duration_s, published_at }`.
   `id` is the **render** id (use it for `PATCH /renders/:id/chapters`); `job_id` is the job.

   Server behaviour: creates a `source:"app"` job — **free, never counted against
   `renders_per_month`, never claimed by the worker** (pricing: publishing is always
   free) — then publishes atomically. `staged` is derived server-side from
   `enhancements` (always send `{declutter:false, style:"as_is"}` from the app). The
   poster must be an uploaded `role:"render"` photo of the same listing; any other
   asset is `400`. If publishing fails the job is marked `failed` immediately, so a
   failed attempt never blocks a retry. Replaying with the same `Idempotency-Key`
   returns the same render (and adopts a poster the first attempt lacked).
   Share `share_url` (the REAL server slug — never fabricate one from a local UUID).

### 2.8 Chapters after publish — `PATCH /renders/:render_id/chapters`
Body: `{ chapters:[{label, t_ms, sort}] }` (≤ 60; label ≤ 80 chars; `sort` 0–999).
→ `{ ok, count, chapters }`. Replaces the room tags the hosted tour shows.

### 2.9 Listings — `POST /listings`, `PATCH /listings/:id`, `DELETE /listings/:id`
- `PATCH` accepts `space_type, address, tagline, details, beds, baths, sqft, price_cents,
  zillow_url, main_photo_key, lat, lng, status, sold_at, source, mls_ref`. `sold_at: null`
  un-sells; `zillow_url` is validated as an http(s) URL; `status` must be one of
  `draft | capturing | uploading | processing | ready | expired | archived` (the app may
  send `uploading` as-is; the DB accepts it). A `403` means the member's role cannot edit.
- `DELETE` soft-deletes AND unpublishes every render of the listing — `/f/:slug` 404s
  from that moment.

### 2.10 Leads — `GET /leads?listing_id=&since=&status=&limit=`, `PATCH /leads/:id`
→ `{ leads:[{ id, listing_id, render_id, name, phone, email, message, extra, source, status,
synced_crm, created_at, listing_address, listing_space_type }] }` (member-scoped, newest first,
≤ 500). `PATCH { status: new|contacted|won|lost }` → `{ ok, lead }`.

### 2.11 `GET /me`
`{ user, org, plan, plan_raw, trial_ends_at, entitlement:{ renders_per_month, photo_edits_per_month,
reels_per_month, aerials_per_month, topaz_per_month, seats }, usage:{ month, by_feature:{ renders,
photo_edits, reels, aerials, drone }, caps:{…same keys…}, windows:{…}, renders, leads, leads_new,
listings, cost_cents }, portfolio_url }`.
`plan` is the **effective** plan (an expired trial reads `free`), i.e. what every charge path
enforces; `plan_raw` is the stored value. Gate the render tiers on `topaz_per_month > 0`
("Team plan" label, no prices) and skip the drone upload when it is 0.

`PATCH /me/brand` accepts the card fields plus `handle` (`^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$`,
unique → `409 conflict`) and `org_name`; returns `{ ok, brand_kit, org:{name, handle}, portfolio_url }`.

### 2.12 Public tour — `GET /tours/:slug`
Adds `status`, `sold_at`, `sold`, `archived`, `published_at`; `404` for deleted listings;
`agent_card.name` is the brand-kit name, else the agent's profile name, never an email.

---

## 3. Delivery model (large 4K without shipping 40 GB)

The on-device `RenderEngine` already outputs an **all-intra "scrub master"** — that
IS the tour video. For very long 4K it must be capped to a delivery resolution
(≈1080–1440p) so the file stays a few-hundred-MB and scrubs smoothly; a 9-min 4K
all-intra file is 30–50 GB and cannot be scrubbed in a browser. The original 4K
source is only uploaded when server-side AI/4K is requested. (RenderEngine cap =
separate task; do not regress the working on-device render.)

---

## 4. Local-first + cloud-publish (the app data model when live)

The app stays **local-first** (offline capture, on-device render, local tours — all
works with no network, as today). Going online is a **Publish** step:

1. Ensure signed in (Sign in with Apple → Supabase JWT).
2. Sync the listing → `POST /listings`; adopt the returned **server id** as the
   listing's identity for all server calls. Later edits → `PATCH /listings/<serverID>`.
3. Upload the render's **scrub-master mp4** (and the first-frame poster) via the
   multipart engine → server `asset_id`(s). Persist a pending-publish record so a
   relaunch or a failed attempt can resume without re-rendering.
4. `POST /renders/publish-app` with the chapters (from the walkthrough's local room
   tags) → server **slug**. Room tags edited later → `PATCH /renders/:id/chapters`.
5. Persist the slug on the listing; share `https://rendprop.com/f/<slug>`.

Never fabricate a slug from a local UUID. The share link must be the server slug.

---

## 5. iOS client design (build to this — no shortcuts)

**Resumability (mandatory).** Persist per-part state `{number, status, etag}` in
`UploadStore` so a relaunch or network drop resumes only the MISSING parts. Part
URLs expire (1 h) → re-request `/part-urls` for missing parts on resume.

**Background URLSession.** Each part is an `uploadTask(fromFile:)` streaming from a
**temp slice file** (write the byte range to a temp file with `FileHandle`; never
load the whole file into memory). Tag each task `taskDescription = "part:<assetId>:<n>"`.
On `didCompleteWithError` success, read the part ETag from
`(task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Etag")`, delete the
temp slice, persist. When every part has an etag → `POST …/complete`.

**Bounded concurrency.** ≤ 3 parts in flight; only materialize temp slices for
in-flight parts so an 8 GB upload uses ≤ ~3×part_size of temp disk. Clean up temp
slices on success, failure, and cancel.

**Retry.** Per-part exponential backoff (≤ 5 tries), then mark the upload `failed`
but resumable (state preserved). Whole-upload cancel → `POST …/abort` + delete temps.
`/complete` is idempotent — retry it on a lost response; a `409 already_complete`
is success.

**Mode selection.** When `Config.useLiveBackend`, force the real path (never
`.simulate`); keep `.simulate` only for offline dev. Photos → `/uploads/batch`
with bounded-concurrency single PUTs.

**Content type.** Derive it from the file, send it on the ticket, use the same value
on every PUT (single and multipart parts inherit the ticket type on the server side).

**Metadata.** Thread probed `{duration_s,fps,width,height,codec,is_drone,has_gyro,
bytes,sha256}` into `/complete` (fixes the metadata-not-threaded gap).

**Completion hook.** Emit a completion event carrying the server `asset_id` so the
publish step can be sequenced AFTER the upload (fixes publish racing the upload
and sending a local id).

Cellular guard, progress, pause/resume must all survive the multipart rewrite.
