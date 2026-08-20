# Rendprop — Render Worker

The queue consumer that turns an uploaded walkthrough into a **published, hosted,
scrubbable tour**. It's the server-side twin of the on-device
`RenderEngine.swift`: same output feel (retimed, 60fps, all-intra H.264 for
buttery scrub), plus the things a phone can't do well — Cloudflare Stream
hosting, AI declutter/restage/hero, and cost metering.

The base render still runs free/instant on-device. This worker is the path for
Stream-hosted + AI-enhanced tours.

---

## Flow

```
poll rendprop.render_jobs where status in (created, queued)
  └─ claim one            → status = processing (lock-free optimistic PATCH)
     1. download capture   from R2 rendprop-uploads (S3 API)
     2. ffmpeg render      retime · 60fps · ≤1280 · all-intra H.264 · faststart · poster
                                                        → cost_ledger: render
     3. enhancements?      call services/pipeline per room/segment:
                           declutter / restage / hero   → cost_ledger: declutter|restage|hero|qc
     4. upload             mp4 + poster (+ enhanced stills) → R2 rendprop-renders
     5. Cloudflare Stream  copy-from-URL (presigned R2 GET) → stream_uid  (optional)
     6. insert             rendprop.renders (slug, duration, keys, staged)
     7. finish             job → ready, progress=1, finished_at
                                                        → cost_ledger: stream_store
  └─ any failure          → status = failed + error jsonb
```

Everything hits the **`rendprop`** Postgres schema (not `public`) — every REST
call carries `Accept-Profile: rendprop` / `Content-Profile: rendprop`.

Chapters: the app already wrote `rendprop.capture_chapters`; the tour function
reads them at serve time, so the worker only *reads* them (to segment rooms for
AI enhancement) — it never copies them.

---

## The ffmpeg command (mirrors RenderEngine)

Built in `ffmpeg_render.py`. For a handheld (non-drone) clip ≥12s (speed 2.0×):

```
ffmpeg -y -hide_banner -nostdin -i capture.mov \
  -vf "setpts=PTS/2.000000,fps=60,scale=w='min(1280,iw)':h='min(1280,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p" \
  -an \
  -c:v libx264 -preset medium -profile:v high -pix_fmt yuv420p \
  -g 1 -keyint_min 1 -bf 0 \
  -x264-params keyint=1:min-keyint=1:scenecut=0:bframes=0:ref=1 \
  -b:v 14M \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -r 60 -movflags +faststart \
  -progress pipe:1 -nostats \
  capture-tour.mp4
```

Why each piece (all from `RenderEngine.swift`):

| Piece | Purpose |
|---|---|
| `setpts=PTS/2.0` (drone `1.25`, short clips ≤`1.5`) | RETIME — the glide. Same speed rule: `min(base,1.5)` under 12s. |
| `fps=60`, `-r 60` | fluid scroll-scrub cadence |
| `scale=…:force_original_aspect_ratio=decrease:force_divisible_by=2` | ≤1280 long edge, aspect-kept, never upscaled, even dims. Single-quotes protect the commas in `min()`. |
| `-g 1 -bf 0` + `x264 keyint=1` | **ALL-INTRA** — every frame a keyframe → any scrub position decodes instantly. The whole point. |
| `-b:v 14M` | high bitrate keeps all-intra crisp (mirrors `AVVideoAverageBitRateKey`) |
| `bt709` tags | HDR/Dolby-Vision phone footage tone-maps instead of washing out |
| `-movflags +faststart` | moov atom up front → instant web start |
| `-an` | the scrubbable tour is silent, like on-device |

Poster: one exact frame pulled at ~12% in (all-intra → exact seek).

`-progress pipe:1` is parsed to drive `render_jobs.progress` smoothly during the
encode (mapped into the 0.15–0.55 band).

**HDR:** output is *tagged* Rec.709. A true HDR→SDR tonemap (for PQ/HLG sources)
is behind `TONEMAP_HDR=1` and needs an ffmpeg built with `zscale`/`tonemap`
(the Docker image qualifies). Off by default. See TODOs.

**Stabilization:** RenderEngine's Vision path-smoothing is on-device only. Server
-side we skip it (drone clips never needed it). GPU stabilization (`vidstab`
two-pass or Gyroflow-grade) is the v3 slot — see TODOs.

---

## Cloudflare Stream approach

`stream.py`, primary path = **copy-from-URL**:

1. Upload the encoded mp4 to R2 `rendprop-renders`.
2. Presign a short-lived R2 **GET** url (`r2.presigned_get_url`).
3. `POST /accounts/{acct}/stream/copy { url, meta }` → Stream pulls the bytes
   itself (no bytes route through the worker) → returns a **UID**.
4. Store `stream_uid` on `rendprop.renders`. HLS is usable immediately; by
   default we don't block on transcode (`STREAM_REQUIRE_READY=0`).

`direct_upload()` (multipart) is the fallback when the copy source isn't
reachable by Cloudflare. **No Stream token? We skip Stream entirely** and the
player serves the R2 mp4 via `renders.video_key`.

---

## Cost metering (consistent with the pipeline)

Every billable unit writes a `rendprop.cost_ledger` row; `render_jobs.cost_cents`
is the rolled-up `SUM(total_cents)`.

- **AI** (`declutter`/`restage`/`hero`/`qc`) — metered *inside* `services/pipeline`
  (its `providers/costs.py` is the single source of AI unit economics). The
  worker reuses it as-is and just reroutes its ledger writes to the `rendprop`
  schema (a contained monkeypatch in `enhance_bridge.py`).
- **Infra** (`render`, `stream_store`) — metered by the worker in `infra_costs.py`:
  - `render` = server encode compute, `RENDER_COMPUTE_CENTS_PER_MIN` × output
    minutes. **Estimate** — set it from real Modal/Cloud-Run bills.
  - `stream_store` = Cloudflare Stream storage, `$0.005/min` × minutes (logged
    once at publish; recurs monthly). Delivery (`$0.001/min` watched) is metered
    per-view by the beacon path, not here.

The pipeline enforces `MAX_GEN_COST_PER_JOB_CENTS` **before every AI call**.

---

## Run locally

Prereqs: `ffmpeg` + `ffprobe` on PATH, Python 3.11.

```bash
cd services/worker
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env      # fill in Supabase + R2 (+ Stream + provider keys)

# smoke-test just the encode (no cloud needed):
python ffmpeg_render.py /path/to/walkthrough.mov            # handheld
python ffmpeg_render.py /path/to/drone.mp4 --drone

# process exactly one queued job then exit:
python worker.py --once
# or a specific job (webhook-style):
python worker.py --job-id <render_jobs.id>
# or run the long-poller:
python worker.py
```

To enqueue a test job, insert a `rendprop.render_jobs` row (status `queued`)
pointing at a `capture_assets` row whose `storage_key` exists in
`rendprop-uploads` (the iOS `/renders` edge function does this in prod).

---

## Deploy

It's a **long-running poller** by default, but each job is independent and
idempotent enough to run **triggered/one-shot** (`--once` / `RUN_ONCE=1` /
`--job-id`), so it fits both models.

**Container (generic / Cloud Run / Fly / ECS):**
```bash
docker build -f services/worker/Dockerfile -t rendprop-worker services/
docker run --rm --env-file services/worker/.env rendprop-worker
```
- **Cloud Run:** deploy as a **Job** for one-shot drains (Cloud Scheduler → run
  `--once`), or as a **Service** with `--min-instances=1` for the poller. Bump
  CPU/memory + timeout — all-intra encodes are CPU-heavy.
- **Fly/ECS:** run the poller as one always-on machine; scale replicas to widen
  the queue (the lock-free claim makes multiple workers safe).

**Modal:** wrap `process_specific(job_id)` in a `@app.function(timeout=1800)`
(mount `services/pipeline` + `services/worker`, `apt_install("ffmpeg")`, set
secrets). Trigger from the `/renders` edge function (webhook → Modal call), or
run `process_one` on a `@app.schedule`. GPU tier only becomes worth it once
GPU-accelerated stabilization / tonemap / 4K land.

**Triggering:** today it **polls** (simple, no infra). A Supabase webhook /
`pg_notify` on `render_jobs` insert → `--job-id` would cut claim latency to ~0 —
see TODOs.

---

## TODOs / next

- **Trigger, not poll:** Supabase DB webhook or `pg_notify` on `render_jobs`
  insert → direct `--job-id` invoke (Modal/Cloud Run). Poll stays as the
  fallback + reaper for missed events.
- **GPU stabilization:** `vidstab` two-pass or a Gyroflow-grade pass to match the
  on-device Vision smoothing (skipped server-side today).
- **HDR tonemap default-on** once the encode host reliably has `zscale`/`tonemap`
  and we've tuned the curve (currently opt-in via `TONEMAP_HDR`).
- **Hero clip has no first-class home:** it's uploaded to R2 and logged, but the
  schema has no column for it. Add `renders.hero_key` (or a `media` table) so the
  tour host can play it.
- **Idempotency on retry:** re-running a failed job re-inserts a `renders` row.
  Add a unique `renders(job_id)` or an upsert so a retry replaces rather than
  duplicates.
- **4K tier:** `render_jobs.tier` (`premium4k`/`cinematic`) is read but the encode
  is fixed at ≤1280. Branch the long-edge/bitrate on tier when 4K ships.
- **Stream webhook:** subscribe to Stream's `video.ready` webhook instead of
  `poll_ready` when `STREAM_REQUIRE_READY` matters.
```
