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
| `providers/anthropic_qc.py` | QC drift judge + room understanding (Haiku→Sonnet); the rubric is NOT prompt-cached (too short to reach Haiku's cache minimum — audit F-G-19) |
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
confidence · capped QC output tokens · `QC_MAX_RETRIES`
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

## Roadmap: the broader render pipeline — **NOT IMPLEMENTED**

> **Read this as a design doc, not as a description of the code** (audit F-G-23).
> None of the state machine, engines, or encode recipes below exist in this repo.
> What DOES exist today is:
>
> * `services/worker/ffmpeg_render.py` — one ffmpeg pass: retime → scale ≤1280 →
>   60 fps → conditional HDR tone-map → all-intra H.264 → poster. **Stabilisation
>   is skipped** (no Gyroflow, no vidstab); there is no interpolation step (the
>   60 fps cadence is `fps=60` frame duplication, not RIFE/FILM); no grading pass;
>   no upscaler (Topaz is reachable through `providers/fal_client.drone_render`
>   but nothing calls it); no HLS packaging (Cloudflare Stream does that).
> * `services/pipeline/enhance.py` — keyframe-per-room declutter/restage with a
>   Claude QC gate, plus one optional Seedance hero clip. The **walkthrough video
>   itself is never enhanced**; the outputs are stills.
> * Declutter uses masked inpaint ONLY when a mask is supplied. The worker never
>   supplies one (`enhance_video` → `enhance_frame(mask=None)`), so in the server
>   path it is the statistical Gemini prompt-edit, gated by QC — *not* the
>   "architecture preserved by construction" story below.
>
> Everything from here to Anti-patterns is the target architecture (Master Build
> Prompt Parts 6, 28, 35, Appendix A/F). Treat each row as unbuilt until a file
> in this repo implements it.

```
created → uploaded → validating → queued → ingesting → stabilizing →
interpolating → grading → [upscaling] → segmenting → [generating_hero] →
stitching → encoding → packaging → publishing → ready

Terminal: failed(step, reason) | needs_reshoot(quality) | canceled | expired | archived
```

Intended properties: a failed `upscaling` retries upscaling — never the whole
chain; dead-letter after N attempts; a per-job cost ceiling pauses and alerts.
(The per-job ceiling IS built: `MAX_GEN_COST_PER_JOB_CENTS`, enforced in
`router._meter` before every paid call.)

### Target steps (engine per step) — planned

| Step | Engine | Status |
|---|---|---|
| validate/QC | ffprobe + heuristics | **not built** (the worker only probes duration + colour) |
| ingest | ffmpeg | partly: rotation and colour are handled inside the single encode |
| stabilize | Gyroflow / vidstab fallback | **not built** — server-side stabilisation is deliberately skipped |
| interpolate | RIFE/FILM → 60fps | **not built** — output is `fps=60` duplication |
| grade | ffmpeg eq + hqdn3d + LUT | **not built** |
| declutter (add-on) | SAM-2 masks + video inpainting | **partial**: single-frame Flux Fill with a supplied mask, else a Gemini prompt-edit. No video inpainting, and the worker supplies no masks. |
| restage (add-on) | structure-locked vid2vid | **partial**: single-frame Gemini restage + Claude drift QC. Not vid2vid. |
| upscale (tier) | Topaz | adapter exists (`fal_client.drone_render`), never invoked |
| segment | chapter timestamps | **built** (`enhance.segment_video`), but worker jobs never receive chapters — see audit F-G-10 |
| hero gen (tier) | Seedance i2v | **built** (one clip, seeded from the corrected frame) |
| stitch / encode / package | ffmpeg, HLS | encode is built (single all-intra mp4); no stitching, no HLS packaging here |
| publish | Cloudflare Stream + R2 | **built** |

### Encode recipes (Appendix A) — reference only, not what runs

The commands previously listed here (scrub proxy at `-g 3`, 1080p playback at
`-g 12`, two-pass vidstab, an `eq`/`hqdn3d` grade) are **not** the shipped recipe.
The one that runs is in `services/worker/ffmpeg_render._encode_cmd`: all-intra
(`-g 1 -bf 0`, x264 `keyint=1`), ≤1280 long edge, 60 fps, `-b:v 14M`, `-an`,
`+faststart` — chosen so every scrub position decodes instantly.

## Anti-patterns (Part 38)

Never full-length generative. Never a single monolithic 4K MP4. Never bake room
labels into the video. Never skip the gyro sidecar path. Never alter architecture
(walls, windows, fixtures, views) in declutter/restage — furniture and decor only.
Never ship enhanced media without the staged disclosure.
