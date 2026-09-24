# Python enhancement pipeline

This package implements per-image/per-room enhancement and cost accounting for
[the optional server render worker](../worker/README.md), plus standalone CLI
experiments. It is separate from the [Studio editor](../../apps/studio/README.md)
and [Supabase AI endpoints](../supabase/functions/README.md).

## Implemented behavior

`enhance.py` extracts room/chapter keyframes, applies requested declutter/restage,
runs a structural-consistency judge, retries within configured limits, and falls
back to the original when necessary. It can also create a short hero clip.
Enhanced stills and a manifest are produced; the full walkthrough is not replaced
with a generated video by this package.

Declutter uses masked inpainting when a mask is supplied. Without a mask it uses
a prompt-based edit; the worker's video path does not supply masks. Prompts and
QC scores reduce risk but do not guarantee unchanged architecture or listing
facts. Inspect output against the originals and retain staging disclosures.

| File | Role |
| --- | --- |
| [config.py](config.py) | Environment parsing, model configuration, limits and prompts |
| [router.py](router.py) | Feature routing, pre-call estimated-cost checks and ledger latch |
| [cost_ledger.py](cost_ledger.py) | Ledger writes, retries, durable-spool fallback and paid-call latch |
| [providers/costs.py](providers/costs.py) | This Python package's unit-cost assumptions and token-rate calculations |
| [providers/gemini.py](providers/gemini.py) | Image restaging/edit adapter |
| [providers/fal_client.py](providers/fal_client.py) | Masked declutter, fallback restage, hero and drone-render adapters |
| [providers/anthropic_qc.py](providers/anthropic_qc.py) | Structured image QC and usage-based cost calculation |
| [enhance.py](enhance.py) | Image/video orchestration and result manifest |
| [cli.py](cli.py) | Offline estimates, dry runs and explicit paid single-feature runs |

Adapter availability is not proof of a configured account, live route, commercial
processing agreement, current vendor price or accepted output quality. The Python
cost table is not the source of truth for all Supabase `ai_routes` pricing.

## Local use

From the repository root:

```sh
cd services/pipeline
cp .env.example .env
# Configure only the credentials needed for the intended authorized experiment.
python3 cli.py estimate --rooms 8 --declutter --restage --hero
python3 cli.py run --image room.jpg --feature restage --style modern --dry-run
```

The CLI and providers use the Python standard library. Video frame extraction
also requires FFmpeg/FFprobe. Protect `.env` and never commit credentials.
`GEMINI_API_KEY`, `FAL_KEY` and `ANTHROPIC_API_KEY` serve their respective adapters.
Without Supabase URL/service-role configuration, ledger output is local rather
than a production database record.

The following commands make real provider calls when configured:

```sh
python3 cli.py run --image room.jpg --feature restage --style modern
python3 cli.py run --image room.jpg --feature declutter --mask mask.png
python3 cli.py run --image room.jpg --feature hero --seconds 5
python3 enhance.py walkthrough.mp4 --style scandinavian --hero
```

For the full option list use `python3 cli.py --help` and
`python3 enhance.py --help`. Read the resulting manifest for per-segment status,
QC, spend records and `virtually_staged`; successful execution alone does not
certify the generated content.

## Cost and QC configuration

`MAX_GEN_COST_PER_JOB_CENTS` defaults to 2500 in this package. The router compares
its running total plus a call estimate before dispatch. This is an estimate-based
per-job guard, not a provider invoice guarantee or a shared experiment budget.
The owner's separate spatial ceiling and Presenter authorization are unrelated.

The current code defaults both `ANTHROPIC_MODEL_QC` and
`ANTHROPIC_MODEL_ESCALATE` to `claude-sonnet-5`; do not assume the historical
Haiku-first arrangement is active. `QC_PASS_SCORE` defaults to 85,
`QC_MAX_RETRIES` to 2, and the confidence threshold to 0.75. Actual environment
configuration can override these defaults.

Returned token usage is priced with the checked-in token-rate table; other calls
use adapter/unit-cost records. Validate those assumptions against the account's
current rate and final billing before treating them as actual charges or customer
pricing. The short QC rubric deliberately has no `cache_control` marker.

A failed paid-ledger write is retried, spooled and latched: later paid calls for
that job are refused. Keep `COST_LEDGER_SPOOL` on persistent storage for a deployed
worker; temporary container storage is not a durable billing archive. The worker's
infrastructure estimates have a different best-effort policy, documented in its
README.

## Current limits and design history

[The master build prompt](../../docs/MASTER-BUILD-PROMPT.md) describes a larger
stabilize/interpolate/grade/upscale/stitch state machine. This Python package does
not implement that whole design. The worker's actual encoder is one FFmpeg pass:
retime, scale, 60 fps cadence, conditional HDR tone-map, all-intra H.264 and poster.
It has no server stabilization or RIFE/FILM interpolation stage. A callable Topaz
adapter is not evidence that the worker invokes it.

This package's image edits are also separate from the reflection-removal and
other video tools implemented in Supabase. Do not infer product-wide capability
or release status from this package alone. The [current Studio release](../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
records what was actually deployed and which new generation features remain off.
