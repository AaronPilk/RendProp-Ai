# Rendprop — AI + Infra Cost Model (grounded, late-2025/2026 pricing)

**Bottom line up front:** the unit economics are extremely favorable. The core render is **on-device (free)**. A base tour costs pennies to host and ~$0.003 per full view to deliver. A fully AI-enhanced listing (declutter + restage every room + a hero clip) costs roughly **$1.00–$1.50 in AI COGS** — against add-on prices of **+$19 declutter / +$49 restage**. Margin is not the problem; **consistency and cost *predictability*** are, and both are engineered below.

> All figures are per-unit vendor pricing as of the research pass (2025–2026). Frontier-model prices drop monthly — reconfirm at wire-up. Route choice (direct API vs aggregator) moves cost ~2×, so it's a config, not a rewrite.

---

## 1. Provider stack — consistency-first, cost-aware

Ranking logic for anything that touches a room image: **structure fidelity first, cost second.** A model that makes a pretty picture but moves a window is a listing-accuracy/legal problem, not an aesthetics one. Mask-based inpainting preserves architecture *by construction* (everything outside the mask is mathematically untouched) — that's the safe default; prompt-only editors preserve it *statistically* (usually fine, small non-zero risk) and are the one-tap fallback.

| Feature | Primary (consistency) | Fallback | Route | ~$/unit |
|---|---|---|---|---|
| **Auto-declutter** | On-device segment → **Flux Fill/Kontext inpaint on the masked region only** (walls/windows can't move) | Nano Banana prompt edit "remove clutter, keep room identical" | fal.ai (Flux) / Google (NB) | **~$0.04/img** |
| **Virtual restage** | **Nano Banana (Gemini 2.5 Flash Image)** — best geometry+lighting preservation | Flux Kontext Pro w/ locked wall mask; Seedream 4.0 at scale | Google direct / fal / KIE | **~$0.039 direct · ~$0.09 KIE / img** |
| **Photo "pro look"** | **On-device Core Image (FREE, already shipped)** | cheap Real-ESRGAN upscale only for low-res uploads (~$0.002–0.01) | — | **$0** |
| **AI hero clip (5–10s)** | **Seedance 1.0 Pro Fast (1080p, i2v from the finished still)** | Kling 2.5 Turbo Pro; Veo 3.1 Fast for flagship/audio | fal.ai / KIE | **~$0.24 / 5s clip** |
| **QC "drift judge" + room understanding** | **Claude Haiku 4.5** (cheap), escalate to **Sonnet 5** only on ambiguity | — | Anthropic (cache system prompt = −90%; batch = −50%) | **~$0.009 Haiku / ~$0.017 Sonnet per 4-image call** |

**Route rule:** direct API when one model dominates a feature (Google for Nano Banana ~$0.039 vs KIE ~$0.09 vs Replicate ~$0.15 — same model); **fal.ai** for video + Flux (cheapest, matches BFL official rates); **KIE.ai** as the one-key multi-model fallback. Make the route a config value per feature.

---

## 2. Cost-control logic (this is the "keep it from getting crazy" layer)

1. **Deterministic-first.** The base "pro look" is free on-device. AI only runs for the *paid* add-ons (declutter/restage) and the optional hero clip. No AI on the base render.
2. **Masked inpaint for declutter** — cheaper and safer than whole-image generation (model only paints the masked clutter, can't hallucinate architecture).
3. **Model tiering for QC** — Haiku by default; escalate to Sonnet only when Haiku's confidence is low. Never Opus for QC.
4. **Prompt caching** on the Claude system/instruction block → **~90% off** the repeated portion. **Batch API** for any non-realtime QC → **−50%**.
5. **Hard per-job cost cap** — `MAX_GEN_COST_PER_JOB_CENTS` (currently $25) aborts a job before it runs away. Every provider call is metered *before* it's made.
6. **Regen caps** — `QC_MAX_RETRIES=2`; below the QC threshold twice → fall back to the original (un-enhanced) segment rather than burning more calls.
7. **Cap output tokens** on Claude (structured JSON responses are 5× input cost).
8. **Streamed-minute caps per plan** — delivery is the only cost that scales with *views*; meter it and cap per tier (already in the schema's `metering` table).
9. **Feed the corrected still into i2v** — the hero clip's first frame is the already-decluttered/staged photo, so the video inherits the fixed room instead of regenerating architecture (consistency + no wasted regens).

---

## 3. Per-unit infra costs (Cloudflare + Supabase + Anthropic)

| Service | Unit | Cost |
|---|---|---|
| R2 storage | GB-month | $0.015 |
| R2 reads (Class B) | 1M ops | $0.36 |
| R2 writes (Class A) | 1M ops | $4.50 |
| **R2 egress** | GB | **$0.00** |
| Stream storage | min stored | $0.005 |
| Stream delivery | min watched | $0.001 |
| Stream egress | — | included |
| Workers/Pages requests | 1M (after 10M free) | $0.30 · static assets free · egress $0 |
| Supabase Pro base | month | $25 (incl. 100k Auth MAU, 8GB DB, 100GB storage, 250GB egress) |
| Supabase egress overage | GB | $0.09 ← **never route video through Supabase** |
| Claude Haiku 4.5 | 1M in / out | $1 / $5 |
| Claude Sonnet 5 | 1M in / out | $2 / $10 |
| Claude Opus 4.8 | 1M in / out | $5 / $25 |

**Hard rule:** video bytes live on **R2 (storage) + Stream (delivery)**, both zero-egress. Supabase stores **rows and URLs only** — never files (its $0.09/GB egress is the one trap).

---

## 4. Worked example — cost of one listing

**A) Base tour, no AI** (the default product):
- On-device render: **$0**
- R2 storage of source+proxy (~2 GB): ~**$0.03/mo**
- Stream storage (3-min tour): **$0.015/mo**
- Delivery: **$0.001/min watched** → a full view = **$0.003**; 1,000 full views = **$3.00**
- DB/Auth/API: rounding error
- **COGS ≈ $0.05 + $0.003/view.** At a $29 base render, gross margin is ~99% until it's watched thousands of times (and even then, 1,000 views = $3).

**B) Fully AI-enhanced listing** (8 rooms, declutter + restage + 1 hero clip):
- Declutter 8 × $0.04 = **$0.32**
- Restage 8 × $0.039 = **$0.31** (direct) / $0.72 (KIE)
- Hero clip 1 × $0.24 = **$0.24**
- QC 8 × $0.012 (Haiku/Sonnet, cached) = **$0.10**
- **AI COGS ≈ $0.97 (direct) / ~$1.40 (KIE).**
- Add-on price: **+$19 declutter, +$49 restage** → COGS is **~2–3%** of the add-on revenue.

**Takeaway:** price the AI add-ons for *perceived value* (they replace a $200 photographer / $16–23-per-photo staging service), not cost. Your real cost governor is Stream delivery on viral tours — which is linear, forecastable, and capped by plan.

---

## 5. Break-even vs the duration bands

Current duration-band pricing (base render): $29 / $49 / $79 / $119 by output length. Even the 6–10 min band, watched 10,000 times, is:
- Stream storage: 10 min × $0.005 = $0.05/mo
- Delivery: 10,000 × 10 min × $0.001 = **$100** at 10k *full* views (most viewers scrub partially → less)
- Still ~$0.05 to produce.

So a heavily-viewed long tour is the only scenario where COGS is material — and it's still < the render price until ~tens of thousands of full views. **Streamed-minute caps per plan** (schema `metering`) turn that from a risk into a plan-upgrade trigger.

---

## 6. What to instrument (so testing gives real numbers)

Every provider call logs to a **`cost_ledger`** row: `{job_id, provider, model, feature, units, unit_cost_cents, total_cents, ts}`. The AI-enhance edge function/worker sums the ledger per job, enforces `MAX_GEN_COST_PER_JOB_CENTS`, and exposes a per-listing + per-tenant cost rollup. That's how you'll know your true blended COGS from real usage instead of this model's estimates.

Providers to key (env): `GEMINI_API_KEY` (Nano Banana), `FAL_KEY` (Flux/Seedance), `ANTHROPIC_API_KEY` (Haiku/Sonnet QC), optional `KIE_API_KEY` (fallback), `CLOUDFLARE_*` (R2/Stream). See `BACKEND-ARCHITECTURE.md`.
