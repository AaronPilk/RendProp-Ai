# Rendprop — Upload & Publish contract (DEPLOYED) + iOS client design

Status: backend **live** on Supabase project `ymgqpbnjpztwjsyvceld` (edge functions
`uploads`, `renders`, `tours` at v2). This doc is the source of truth for the iOS
client that talks to it. #1 rule: **works perfectly for large files — no shortcuts.**
Target load: a 9-minute 4K walkthrough (2–8 GB) and 70+ photos per listing.

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

### 2.1 Start an upload — `POST /uploads`
Body: `{ listing_id, filename, bytes, sha256?, kind: "video"|"photo", content_type?, multipart? }`

- Video with `bytes > 64 MB` (or `multipart:true`) → **multipart**:
  `{ asset_id, mode:"multipart", upload_id, storage_key, part_size, part_count }`
- Otherwise → **single**:
  `{ asset_id, mode:"single", put_url, storage_key }`

`part_size` is uniform (last part smaller). `part_count = ceil(bytes/part_size)`.

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
→ the updated `capture_assets` row (has `uploaded:true`).

### 2.4 Abort — `POST /uploads/:asset_id/abort`  `{}` → `{ ok:true }`
Aborts the in-flight R2 multipart session (cleanup). Safe to call on cancel.

### 2.5 Photo batch — `POST /uploads/batch`
Body: `{ listing_id, kind:"photo", files:[{filename, bytes?, sha256?, content_type?}] }` (≤ 200)
→ `{ assets:[{ index, asset_id, put_url, storage_key }] }`
Upload each with a single PUT, then `POST /uploads/:asset_id/complete { width?, height?, bytes?, sha256? }`.

### 2.6 Render / publish — `POST /renders`, `GET /renders/:id`, `POST /renders/:id/publish`
- `POST /renders { listing_id, asset_id, tier, enhancements }` → render_job.
  **`asset_id` MUST be the SERVER `asset_id` from `/uploads`** (not a local id) and
  the upload MUST be completed first, or the server 404s ("Asset not found").
- `GET /renders/:id` → `{ status, current_step, progress, cost_cents, tour? }` where
  `tour = { slug, share_url, video_url, scrub_url, hls_url, poster, staged, duration_s, published_at }`.
  Poll this; when `status:"ready"` use `tour.share_url` / `tour.scrub_url`.
- Scrub fidelity: **`scrub_url` is the all-intra R2 mp4** (byte-range, frame-accurate
  scrubbing — the product's crown jewel). `hls_url` is Stream, an adaptive fallback
  ONLY. Prefer `scrub_url` in the player.

### 2.7 App-published tour (base path — NO Python worker) — DEPLOYED
The on-device render IS the tour. Two steps:
1. **Upload the rendered mp4 to the PUBLIC renders bucket:** `POST /uploads` with
   `{ listing_id, bytes, role:"render" }` (+ multipart if >64 MB, same lifecycle as
   §2.1–2.4). `role:"render"` routes the object to the renders bucket and tags the
   asset `bucket:"renders"`. `/complete` it with `{ duration_s, ... }`.
2. **Publish:** `POST /renders/publish-app`
   `{ listing_id, asset_id, duration_s, speed_factor?, staged?, tier?, enhancements?, poster_key?, chapters:[{label,t_ms,sort}] }`
   → creates a ready render_job (worker never touches it) + a published render row
   pointing at the uploaded mp4, stores the chapters, and returns
   `{ ...render, slug, share_url }`. Share `share_url` (the REAL server slug).

The Python render worker is only needed for server-side AI enhancement / 4K — NOT
for the base hosted tour.

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
   listing's identity for all server calls.
3. Upload the render's **scrub-master mp4** (and, if AI requested, the raw source /
   photos) via the multipart engine → server `asset_id`(s).
4. POST room chapters (from the walkthrough's local room tags).
5. Create/track the render (or publish an app-rendered tour) → server **slug**.
6. Persist the slug on the listing; share `https://rendprop.app/f/<slug>`.

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

**Mode selection.** When `Config.useLiveBackend`, force the real path (never
`.simulate`); keep `.simulate` only for offline dev. Photos → `/uploads/batch`
with bounded-concurrency single PUTs.

**Metadata.** Thread probed `{duration_s,fps,width,height,codec,is_drone,has_gyro,
bytes,sha256}` into `/complete` (fixes the metadata-not-threaded gap).

**Completion hook.** Emit a completion event carrying the server `asset_id` so the
render step can be sequenced AFTER the upload (fixes createRender racing the upload
and sending a local id).

Cellular guard, progress, pause/resume must all survive the multipart rewrite.
