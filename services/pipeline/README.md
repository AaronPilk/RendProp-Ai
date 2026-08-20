# Rendprop Render Pipeline

Two things live here:

1. **AI Enhancement + Cost Metering** (the code in `providers/`, `router.py`,
   `cost_ledger.py`, `enhance.py`, `cli.py`) — the component that actually calls
   the AI providers for declutter / restage / hero-clip / QC, with consistency-first
   routing, a hard per-job cost cap, and a `cost_ledger` row per provider call.
2. The broader **render state machine** (stabilize → 60fps → encode → publish),
   described further down and in the Master Build Prompt.

---

## AI Enhancement + Cost Metering

### What it does

Per room/segment: **declutter → restage → QC drift-judge → (pass / regen / fall
back to original) → optional hero clip.** The paramount rule — *furniture & decor
only, architecture never changes* — is enforced two ways: masked inpaint for
declutter (architecture untouched by construction) and a Claude drift judge that
scores structural consistency 0–100 and gates every result. Every provider call
is metered **before** it runs against `MAX_GEN_COST_PER_JOB_CENTS` and logged to
`cost_ledger` after.

### Module map

| File | Role |
|---|---|
| `providers/costs.py` | **THE single unit-cost table.** Edit here when prices drop. |
| `providers/gemini.py` | Nano Banana (Gemini 2.5 Flash Image) restage — `restage(image, style_prompt) -> bytes` |
| `providers/fal_client.py` | Flux Fill declutter, Seedance hero clip, Flux Kontext restage fallback |
| `providers/anthropic_qc.py` | QC drift judge + room understanding (Haiku→Sonnet), prompt-cached rubric |
| `providers/base.py` | stdlib HTTP, base64 data-URI, download helpers, typed errors |
| `router.py` | consistency-first, cost-aware routing; **enforces the cap before every call** |
| `cost_ledger.py` | writes `cost_ledger` rows to Supabase REST + rolls up `render_jobs.cost_cents` |
| `enhance.py` | orchestrator: the per-room closed loop over router + providers + ledger |
| `cli.py` | **cost-test tool** — `estimate` (math) and `run` (one real call) |
| `config.py` | one place for env, guards, model routes, the architecture-lock prompt |

### Set keys

```bash
cp .env.example .env      # then paste values
```

Minimum to run a real call: the key for the feature you're testing —
`GEMINI_API_KEY` (restage), `FAL_KEY` (declutter/hero), `ANTHROPIC_API_KEY` (QC).
`SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` are optional — without them the
ledger runs locally (still prints every cost). No `pip install` needed (stdlib).

### Cost-test CLI (answers "what will the AI cost")

```bash
# Pure math from the unit-cost table — no keys, no API calls:
python cli.py estimate --rooms 8 --declutter --restage --hero
```

```
Rendprop AI cost estimate — 8 room(s), route='gemini'

  feature       units      ¢/unit           total
  ----------------------------------------------
  declutter         8      4.0000        $0.3200
  restage           8      3.9000        $0.3120
  hero              5      4.8000        $0.2400
  qc                8      0.9000        $0.0720
  ----------------------------------------------
  TOTAL                                  $0.9440

  Per-listing AI COGS: $0.9440 (cap is MAX_GEN_COST_PER_JOB_CENTS = $25.0000)
  vs add-on price $68.0000 → COGS is 1.4% of revenue.
```

```bash
# One REAL call → actual cost + a cost_ledger row (needs the relevant key):
python cli.py run --image room.jpg --feature restage --style modern
python cli.py run --image room.jpg --feature declutter --mask mask.png
python cli.py run --image room.jpg --feature hero --seconds 5

# Show what a single call WOULD cost, without calling:
python cli.py run --image room.jpg --feature restage --style modern --dry-run
```

### Run the full loop

```bash
python enhance.py room.jpg --declutter --style modern            # single image
python enhance.py room.jpg --declutter --mask mask.png --style modern
python enhance.py walkthrough.mp4 --style scandinavian --hero    # video (needs ffmpeg)
python enhance.py walkthrough.mp4 --declutter --chapters chapters.json \
    --job-id <render_jobs.id> --org-id <orgs.id>                 # writes ledger rows
```

Output: enhanced frames + `out/manifest.json` (per-segment status, QC scores,
`spent_cents`, and `virtually_staged` → the mandatory "Virtually staged" chip).

### Cost model (from `docs/AI-COST-MODEL.md`, editable in `providers/costs.py`)

| Feature | Model | Route | ~Unit cost |
|---|---|---|---|
| Declutter | Flux Fill masked inpaint | fal.ai | 4.0¢ / img |
| Restage | Gemini 2.5 Flash Image (Nano Banana) | Google direct | 3.9¢ / img |
| Restage fallback | Flux Kontext | fal.ai | 4.0¢ / img |
| Hero clip | Seedance 1.0 Pro Fast (1080p i2v) | fal.ai | 4.8¢ / sec ($0.24/5s) |
| QC drift judge | Claude Haiku 4.5 → Sonnet 5 | Anthropic | ~0.9¢ / ~1.7¢ per 4-img call |

**Cost governors:** deterministic-first (no AI on the base render) · masked
inpaint for declutter · Haiku-first QC with Sonnet escalation only on low
confidence · prompt-cached QC rubric · capped QC output tokens · `QC_MAX_RETRIES`
then fall back to original · **`MAX_GEN_COST_PER_JOB_CENTS` checked before every
provider call** (estimate + running total; abort if over — nothing charged).

### Provider API shapes used (verified at build)

- **Gemini restage** — `POST …/v1beta/models/{model}:generateContent`, header
  `x-goog-api-key`; body `contents[].parts[]` = `{text}` + `{inline_data:{mime_type,data}}`;
  response `candidates[].content.parts[].inlineData.data` (base64).
  Docs: `ai.google.dev/gemini-api/docs/image-generation` (+ newer `/v1beta/interactions`), `…/image-understanding`.
- **fal declutter / hero / kontext** — REST queue: `POST https://queue.fal.run/{model}`
  (`Authorization: Key $FAL_KEY`) → poll `status_url` → GET `response_url`.
  Flux Fill in `{prompt,image_url,mask_url}` / out `{images:[{url}]}`; Seedance in
  `{prompt,image_url,resolution,duration}` / out `{video:{url}}`.
  Docs: `fal.ai/models/fal-ai/flux-pro/v1/fill/api`, `…/bytedance/seedance/v1/pro/fast/image-to-video/api`, `fal.ai/docs/.../queue`.
- **Anthropic QC** — `POST https://api.anthropic.com/v1/messages`, headers
  `x-api-key` + `anthropic-version`; `system` as a list with `cache_control:{type:ephemeral}`;
  image blocks `{type:image,source:{type:base64,media_type,data}}`; cost from
  `usage.{input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens}`.
  Docs: `platform.claude.com/docs/en/build-with-claude/prompt-caching`.

### cost_ledger row (mirrors `0001_init.sql`)

`{job_id, org_id, feature, provider, model, units, unit_cost_cents, total_cents, meta}`
— `feature ∈ declutter|restage|hero|qc`, `provider ∈ gemini|fal|anthropic`.
`render_jobs.cost_cents = round(SUM(total_cents))` per job.

---

## Render state machine (broader pipeline)

Async job orchestrated as a state machine, fanned out to GPU workers (Modal
primary, RunPod batch, fal.ai offload). Every step is idempotent, checkpointed,
and writes to the cost ledger. Full spec: Master Build Prompt Parts 6, 28, 35,
Appendix A/F.

```
created → uploaded → validating → queued → ingesting → stabilizing →
interpolating → grading → [upscaling] → segmenting → [generating_hero] →
stitching → encoding → packaging → publishing → ready

Terminal: failed(step, reason) | needs_reshoot(quality) | canceled | expired | archived
```

A failed `upscaling` retries upscaling — never the whole chain. Dead-letter after
N attempts. Per-job cost ceiling pauses + alerts if exceeded.

## Steps (engine per step)

| Step | Engine | Notes |
|---|---|---|
| validate/QC | ffprobe + heuristics | blur/shake/exposure score; below threshold → needs_reshoot (cheap; refund render credit) |
| ingest | ffmpeg | normalize color, fix rotation, split audio |
| stabilize | **Gyroflow** (gyro sidecar) / vidstab fallback | the #1 handheld→drone lever; drone clips skip |
| interpolate | RIFE/FILM → 60fps | Topaz for problem footage |
| grade | ffmpeg eq + hqdn3d + LUT | brand LUT per org |
| **declutter (add-on)** | SAM-2 masks + video inpainting (ProPainter-class) | removes boxes/clutter; architecture untouched; temporal-consistent; QC per segment |
| **restage (add-on)** | structure-locked vid2vid restyle (depth/edge-conditioned; Seedance/Higgsfield i2v per room segment) | Modern/Rustic/Minimalist/Scandinavian; geometry never changes; drift QC → drop segment to original |
| upscale (tier) | Topaz self-hosted | 4K near-$0 marginal |
| segment | chapter timestamps | room rail |
| hero gen (tier) | Seedance/Veo/Kling i2v | 8–15s, seeded from REAL frame, $5 ceiling, drop if drift |
| stitch | ffmpeg | labels are player overlays, never baked |
| encode | x264 / svt-av1 | scrub proxy + playback renditions |
| package | HLS + sprite/VTT + poster + OG | |
| publish | Cloudflare Stream + R2 | flip listing to ready, fire render.ready |

## Encode recipes (Appendix A)

```bash
# Scrub proxy — instant seek, mobile/webview-safe (540–720p, all-intra-ish)
ffmpeg -i graded.mp4 -vf scale=-2:720 -c:v libx264 -profile:v high -pix_fmt yuv420p \
  -g 3 -keyint_min 3 -sc_threshold 0 -crf 28 -an -movflags +faststart proxy_720.mp4

# Playback 1080p (H.264 fallback; AV1 via svt-av1 preferred where supported)
ffmpeg -i stitched.mp4 -vf scale=-2:1080 -c:v libx264 -profile:v high -pix_fmt yuv420p \
  -g 12 -keyint_min 12 -sc_threshold 0 -crf 21 -movflags +faststart playback_1080.mp4

# Stabilize without gyro (2-pass vidstab)
ffmpeg -i in.mp4 -vf vidstabdetect=shakiness=8:accuracy=15 -f null -
ffmpeg -i in.mp4 -vf vidstabtransform=smoothing=30:input=transforms.trf,unsharp=5:5:0.8 out.mp4

# Grade/denoise starting point
-vf hqdn3d,eq=brightness=0.02:contrast=1.06:saturation=1.08:gamma=0.98
```

## Anti-patterns (Part 38)

Never full-length generative. Never a single monolithic 4K MP4. Never bake room
labels into the video. Never skip the gyro sidecar path. Never alter architecture
(walls, windows, fixtures, views) in declutter/restage — furniture and decor only.
Never ship enhanced media without the staged disclosure.
