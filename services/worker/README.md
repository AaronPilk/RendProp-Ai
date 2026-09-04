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
poll render_jobs where status in (created, queued) AND the capture asset is an uploaded video in the uploads bucket
  └─ claim one            → status = processing (lock-free optimistic PATCH)
     1. download capture   from R2 rendprop-uploads (S3 API)
     2. ffmpeg render      retime · 60fps · ≤1280 · all-intra H.264 · faststart · poster
                                                        → cost_ledger: render
     3. enhancements?      call services/pipeline per room/segment:
                           declutter / restage / hero   → cost_ledger: declutter|restage|hero|qc
     4. upload             mp4 + poster (+ enhanced stills) → R2 rendprop-renders
     5. Cloudflare Stream  copy-from-URL (presigned R2 GET) → stream_uid  (optional)
     6. insert             renders (slug, duration, keys, staged)
     7. finish             job → ready, progress=1, finished_at
                                                        → cost_ledger: stream_store
  └─ any failure          → status = failed + error jsonb
```

Everything hits the **`public`** Postgres schema on the dedicated RendProp
project `ymgqpbnjpztwjsyvceld` — matching the edge functions and
`migrations/0001_init.sql`. `SUPABASE_DB_SCHEMA` defaults to `public`; only set
it if you deliberately isolate the tables into a named schema.

Chapters: the worker only *reads* `capture_chapters` (to segment rooms for AI
enhancement) — it never writes them. Today the only writer of that table is
`publish_render` (the on-device publish path), so a worker-path job normally has
**no** chapters and the pipeline falls back to blind 8-second slices; the tour
function reads whatever rows exist at serve time. Wiring `POST /renders` to
accept `chapters` is an open backend item (audit F-G-10). Chapter times are
SOURCE time for capture assets (the app only rescales for tours it publishes
itself).

Which jobs the worker takes: only `render_jobs` whose capture asset is a finished
upload (`uploaded = true`) of `kind = 'video'` in the private **uploads** bucket.
App-published tours (asset `bucket = 'renders'`, published by
`/renders/publish-app`) are excluded by the claim query itself and skipped —
released back to `queued`, never failed — if one reaches `--job-id`.

Enhancements: `enhancements.style` is normalised before anything runs.
`as_is` / `as-is` / `asis` / `none` / `""` (what the app sends on every plain
job) mean **no restage**; an unknown style is skipped with a reason; only
`modern | rustic | minimalist | scandinavian` reach the pipeline.

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
| `fps=60` | fluid scroll-scrub cadence (scale runs FIRST, so frames `fps` will drop aren't scaled for nothing) |
| `scale=…:force_original_aspect_ratio=decrease:force_divisible_by=2` | ≤1280 long edge, aspect-kept, never upscaled, even dims. Single-quotes protect the commas in `min()`. |
| `-g 1 -bf 0` + `x264 keyint=1` | **ALL-INTRA** — every frame a keyframe → any scrub position decodes instantly. The whole point. |
| `-b:v 14M` | high bitrate keeps all-intra crisp (mirrors `AVVideoAverageBitRateKey`) |
| `bt709` tags | the output really is Rec.709 SDR: HDR sources are tone-mapped first (below) |
| `-movflags +faststart` | moov atom up front → instant web start |
| `-an` | the scrubbable tour is silent, like on-device |

Poster: one exact frame pulled at ~12% in — but at least 1 s in (skips the
hand/floor at record start) and never past the last half-second (all-intra →
exact seek).

`-progress pipe:1` is parsed to drive `render_jobs.progress` smoothly during the
encode (mapped into the 0.15–0.55 band).

**HDR:** every source is probed (`ffprobe` colour metadata). PQ (`smpte2084`)
and HLG (`arib-std-b67`) sources — the iPhone default — get a real tone-map
(`zscale → linear → hable → bt709`) inserted after the scale step; SDR and
untagged sources are passed through untouched (the chain degrades SDR and
errors on untagged input). Output is tagged bt709 either way. Needs an ffmpeg
built with `zscale`/`tonemap` (the Docker image qualifies); on a build without
them the worker warns and re-tags only. `TONEMAP_HDR=0` disables it;
`TONEMAP_CURVE` (default `mobius`) and `TONEMAP_NPL` (default 100) tune it.

Measured with `tests/test_hdr_tonemap.py` (ffmpeg 6.1.1, SMPTE bars, signalstats
averaged over every output frame, 0–255) — an SDR reference reads
YAVG 103.7 / YMAX 254 / SATAVG 39.4:

| source | chain | YAVG | YMAX | SATAVG |
|---|---|---|---|---|
| bt709 SDR | none (correct) | 103.7 | 254 | 39.4 |
| untagged SDR | none (correct) | 103.7 | 254 | 39.4 |
| PQ BT.2020 | `TONEMAP_HDR=0` — re-tag only | 79.7 | 134 | **9.6** |
| PQ BT.2020 | `hable` | 73.4 | 162 | 24.6 |
| PQ BT.2020 | **`mobius` (default)** | 99.9 | 207 | **36.1** |
| HLG BT.2020 | **`mobius` (default)** | 98.8 | 207 | 37.6 |

The `TONEMAP_HDR=0` row is the washed-out, mislabelled output the audit found;
`mobius` was chosen over `hable` because `hable` crushes in-gamut content (a room
interior is mostly in gamut) and, on a genuinely bright PQ source, clipped YMAX to
255 where `mobius` held 240.
The AI pipeline extracts its keyframes with the same conditional chain, so
Gemini/Claude never judge a washed-out HLG frame.

**Timeouts:** two independent ceilings. `FFMPEG_TIMEOUT_S` (default 90 min) is
the TOTAL wall clock, enforced by a `threading.Timer` that kills the process group
when it fires. `FFMPEG_STALL_TIMEOUT_S` (default 5 min) is the NO-PROGRESS
ceiling — the one that actually catches a wedged demuxer, since a silently hung
ffmpeg would otherwise sit inside the total budget for 90 minutes. Stall
monitoring stops at `progress=end` so a long `+faststart` moov relocation is never
mistaken for a hang. ffprobe and poster extraction have their own bounds, and a
shutdown signal aborts the encode and re-queues the job.

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
4. Store `stream_uid` on `renders`. HLS is usable immediately; by
   default we don't block on transcode (`STREAM_REQUIRE_READY=0`).

`direct_upload()` (multipart) **is** the automatic fallback: if Cloudflare can't
reach the presigned R2 url, the worker pushes the bytes itself; if that fails too,
the tour publishes with the R2 mp4. If only the readiness poll
(`STREAM_REQUIRE_READY=1`) times out, the UID is kept (Stream keeps transcoding).
A Stream asset registered by a job that then FAILS is deleted during rollback, so
it can't transcode and bill forever unreferenced. **No Stream token? We skip
Stream entirely** and the player serves the R2 mp4 via `renders.video_key`.
The `stream_store` cost line is only written when a UID actually exists.

---

## Cost metering (consistent with the pipeline)

Every billable unit writes a `cost_ledger` row; `render_jobs.cost_cents`
is the rolled-up `SUM(total_cents)`.

- **AI** (`declutter`/`restage`/`hero`/`qc`) — metered *inside* `services/pipeline`
  (its `providers/costs.py` is the single source of AI unit economics). The
  worker reuses it as-is and just reroutes its ledger writes to the worker's
  schema (`SUPABASE_DB_SCHEMA`; a contained monkeypatch in `enhance_bridge.py`).
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

To enqueue a test job, insert a `render_jobs` row (status `queued`)
pointing at a `capture_assets` row (`bucket = 'uploads'`, `uploaded = true`,
`kind = 'video'`) whose `storage_key` exists in `rendprop-uploads` (the
`/renders` edge function does this in prod).

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

**Modal:** wrap `process_specific(job_id)` in a `@app.function(timeout=...)` — set the
function timeout **above** `FFMPEG_TIMEOUT_S` (default 5400 s) or lower the ffmpeg ceiling
to match; a platform kill leaves the job stuck in `processing`
(mount `services/pipeline` + `services/worker`, `apt_install("ffmpeg")`, set
secrets). Trigger from the `/renders` edge function (webhook → Modal call), or
run `process_one` on a `@app.schedule`. GPU tier only becomes worth it once
GPU-accelerated stabilization / tonemap / 4K land.

**Triggering:** today it **polls** (simple, no infra). A Supabase webhook /
`pg_notify` on `render_jobs` insert → `--job-id` would cut claim latency to ~0 —
see TODOs.

---

## Tests

Stdlib-only scripts (the repo has no Python test runner installed):

```bash
cd services/worker
python3 tests/test_job_lease.py     # claim / lease / heartbeat / reclaim / reaper,
                                    # the pre-migration degradation path, and the
                                    # F-G-13 guards. Uses a fake PostgREST.
python3 tests/test_hdr_tonemap.py   # synthesises SDR / untagged / PQ / HLG clips,
                                    # runs the REAL encode command, measures the
                                    # result. Skips if ffmpeg lacks libzimg.
```

## Cost-ledger policy

Two ledgers with deliberately opposite failure modes:

* **Worker infra ESTIMATES** (`render` compute, `stream_store`) are best-effort.
  Bounded retries, then the row is written to a durable spool and the render
  publishes. An estimate must never destroy a finished tour.
* **Real provider spend** (`services/pipeline/cost_ledger.py`) fails closed. It
  retries, spools the row, and then LATCHES: the router refuses every further paid
  call for that job. Money we cannot record is money we do not spend. The base
  tour still ships; the remaining segments ship as originals.

The spool (`COST_LEDGER_SPOOL`) defaults to the system temp dir, which is tmpfs on
Cloud Run and Modal. Point it at a persistent volume — the worker prints which of
the two it has at startup.

## TODOs / next

- **Trigger, not poll:** Supabase DB webhook or `pg_notify` on `render_jobs`
  insert → direct `--job-id` invoke (Modal/Cloud Run). Poll stays as the
  fallback + reaper for missed events.
- **GPU stabilization:** `vidstab` two-pass or a Gyroflow-grade pass to match the
  on-device Vision smoothing (skipped server-side today).
- **HDR curve tuning:** the tone-map is on by default for HDR sources; the
  `npl=100` + `hable` curve is usable but still compresses in-gamut content —
  tune against real iPhone HLG clips.
- **Hero clip has no first-class home:** it's uploaded to R2 and logged, but the
  schema has no column for it. Add `renders.hero_key` (or a `media` table) so the
  tour host can play it.
- **Heartbeat / lease:** *implemented* in the worker (claim stamps
  `lease_expires_at`/`worker_id`/`attempts`, a heartbeat thread renews it, the
  claim query reclaims expired leases, and a reaper fails attempts-exhausted
  orphans as `poison`). It needs **migration 0015** — see `HANDOFF.md`. Until that
  lands the worker detects the missing columns, warns at startup, and behaves as
  before.
- **4K tier:** `render_jobs.tier` (`premium4k`/`cinematic`) is read but the encode
  is fixed at ≤1280. Branch the long-edge/bitrate on tier when 4K ships.
- **Stream webhook:** subscribe to Stream's `video.ready` webhook instead of
  `poll_ready` when `STREAM_REQUIRE_READY` matters.
```
