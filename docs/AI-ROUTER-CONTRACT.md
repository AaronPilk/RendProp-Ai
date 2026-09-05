# Rendprop AI Router — the "brain" (contract v1, 2026-09-04)

Every AI task in the product goes through ONE resolver that returns an ordered chain of
provider/model steps. Callers try the chain in order; every outcome is reported back so
the router can open a circuit and the ledger can attribute spend to the step that
actually ran. Routes live in a TABLE (not code) so a model retirement, a price change,
or a plan-tier policy is a row edit, not a deploy.

Four agents build against this in parallel:
- **DB**  owns `migrations/0018_ai_routes.sql`, `_shared/router.ts`, `admin/index.ts` (additive), `tests/invariants.sql`
- **ADAPT** owns `_shared/providers/**` (new), `ai-photo/index.ts`, `ai-video/index.ts`, `_shared/ledger.ts` (additive), `set-secrets.sh`
- **CHAPTERS** owns NEW `functions/ai-chapters/**` and `apps/ios/Rendprop/Networking/**` (additive)
- **IOS** owns `apps/ios/Rendprop/Screens/**` and `Voice/**` — everything Swift outside Networking

Nobody edits another agent's files. Cross-file needs go in `HANDOFF-<agent>.md`.

---

## 1. Interface (DB implements, everyone consumes)

```ts
// _shared/router.ts
export interface RouteStep {
  route_id: string;        // ai_routes.id
  task: string;            // e.g. "video.reel_clip"
  provider: string;        // "fal" | "kie" | "higgsfield" | "gemini" | "openai" | "anthropic" | "elevenlabs" | "worldlabs" | "apple"
  model: string;           // exact upstream model id / endpoint slug
  unit: string;            // "image" | "second" | "call" | "minute" | "1k_chars" | "world"
  unit_cents: number;      // researched price, cents per unit
  capabilities: string[];  // e.g. ["i2v","1080p","9:16","6s","mask","timestamps"]
  max_latency_s: number;   // circuit opens if p95 exceeds this
  min_plan: string;        // "free" | "trial" | "starter" | "solo" | "pro" | "team"
  same_model_as: string | null; // upstream family key, e.g. "bytedance/seedance-1.0-pro-fast" — steps sharing this are NOT availability-independent
  privacy_tier: "no_retention" | "retained_30d" | "trains_by_default";
  enabled: boolean;
}

export interface RouteContext {
  plan: string;                 // effective plan of the org
  needs?: string[];             // capabilities the caller REQUIRES; steps lacking any are filtered out
  policy?: "best" | "cheapest"; // default: from plan_routing_policy (free/trial → cheapest, else best)
  carries_customer_media?: boolean; // true for anything with a photo/video of the property → prefer privacy_tier=no_retention, never "trains_by_default"
}

/** Ordered, filtered, circuit-aware chain. Never empty when a route exists: if every
 *  step is open-circuit, returns them anyway (closed-circuit first) so the caller can
 *  still try — an outage must degrade, not hard-fail. */
export async function resolveRoute(task: string, ctx: RouteContext): Promise<RouteStep[]>;

/** Report one attempt. Feeds provider_health (circuit breaker) and is what the
 *  caller uses to pick the ledger's provider/model. */
export async function reportOutcome(step: RouteStep, r: { ok: boolean; latency_ms: number; error_class?: "rate_limit" | "upstream" | "timeout" | "validation" | "nsfw" | "other" }): Promise<void>;

/** FEATURE FLAG. When `ai_router.enabled` (a row in app_config, default FALSE) is false,
 *  resolveRoute returns exactly the legacy hardcoded step for the task (today's
 *  provider/model) so behaviour is byte-for-byte unchanged. This is what makes the
 *  deploy safe mid-field-test. */
export async function routerEnabled(): Promise<boolean>;
```

## 2. Provider adapter interface (ADAPT implements)

```ts
// _shared/providers/types.ts
export interface GenerateInput {
  task: string;
  prompt?: string;
  image_url?: string;        // public https URL (already in R2)
  image_b64?: string;        // when the adapter must upload first
  video_url?: string;
  mask_url?: string;
  seconds?: number;
  aspect?: "16:9" | "9:16" | "1:1";
  resolution?: "720p" | "1080p" | "4k";
  text?: string;             // tts
  voice_id?: string;
  extra?: Record<string, unknown>;
}
export interface JobRef { provider: string; model: string; id: string; poll_url?: string; submitted_at: string }
export type JobState =
  | { status: "queued" | "running" }
  | { status: "done"; result_url: string; mime: string; duration_s?: number; width?: number; height?: number; meta?: Record<string, unknown> }
  | { status: "failed"; error_class: "rate_limit" | "upstream" | "timeout" | "validation" | "nsfw" | "other"; message: string };

export interface ProviderAdapter {
  key: string;
  submit(step: RouteStep, input: GenerateInput): Promise<JobRef>;
  poll(ref: JobRef): Promise<JobState>;
  /** Every reseller expires media (Kie 14d, Higgsfield 7d, fal configurable). The
   *  adapter copies result_url into OUR R2 and returns the R2 key. Canonical asset
   *  is always ours. */
  persist(state: Extract<JobState, { status: "done" }>, r2Key: string): Promise<{ key: string; bytes: number }>;
}
```

Adapters: `fal.ts` (exists, refactor to interface), `gemini.ts` (exists), `elevenlabs.ts` (exists), NEW `kie.ts` (two code paths: `/api/v1/jobs/createTask` market API AND `/api/v1/veo/generate` legacy; upload host `kieai.redpandaai.co`), NEW `higgsfield.ts` (`Authorization: Key ID:SECRET`; DoP needs `enhance_prompt:false` ALWAYS and `nsfw` as its own terminal state; boot-fetch `/v1/motions` → name→uuid map with hardcoded fallback; also its Seedance proxy), NEW `openai.ts` (images/edits with mask for gpt-image-2; `/v1/audio/speech` tts-1; `/v1/audio/transcriptions` whisper-1 with `timestamp_granularities[]=word`; ALWAYS `reasoning.effort:"none"` on 5.6 chat calls), NEW `anthropic.ts` (messages from edge; ALWAYS `output_config.effort:"low"` on Sonnet 5; never a Covered Model).

## 3. Seed routing table (DB seeds this; researched prices 2026-09-04, cents)

| task | needs | chain (order = "best"; "cheapest" re-sorts by unit_cents within valid steps) |
|---|---|---|
| `photo.sky` `photo.twilight` `photo.lawn` | prompt-edit | gemini `gemini-3.1-flash-lite-image` 3.36/img → gemini `gemini-3.1-flash-image` 6.7/img → fal `flux-pro/kontext` 4/img |
| `photo.declutter` | mask | fal `flux-pro/v1/fill` 5/MP (true mask) → gemini `gemini-3.1-flash-image` 6.7 (prompt) → openai `gpt-image-2` edit 4.1+ (mask-guided; carries media → retained_30d) |
| `photo.stage` `photo.custom` | prompt-edit, fidelity | gemini `gemini-3.1-flash-image` 6.7 → openai `gpt-image-2` 4.1+ → fal `flux-pro/kontext` 4 |
| `video.reel_clip` | i2v, 1080p, 5s, 16:9 & 9:16 | fal `bytedance/seedance/v1/pro/fast/image-to-video` 4.86/s → kie `bytedance/v1-pro-fast-image-to-video` 3.6/s **same_model** (disabled until commercial-rights confirmed) → fal `minimax/hailuo-02/standard/image-to-video` 4.5/s **different model, 768p, 6s max** |
| `video.aerial` | i2v, 6–8s, 1080p, 16:9 & 9:16 | fal seedance-1.0-pro-fast 6s 4.86/s → higgsfield `bytedance/seedance/v1/pro/fast/image-to-video` (same_model failover; disabled until enterprise/no-training terms) → fal `veo3.1/fast/image-to-video` 10/s (different model) · EXPERIMENTAL disabled: higgsfield `dop/turbo` 8.3/s (5s/720p only — A/B only) |
| `video.aerial_no_photo` | t2v | fal `veo3.1/fast` 10/s → kie `veo3_fast` 4.1/clip (disabled, price unverified) |
| `video.upscale_4k` | v2v | kie `topaz/video-upscale` 2× 4/s (≤50 MB input; disabled until rights confirmed) → fal `topaz/upscale/video` 8/s |
| `video.upscale_1080p60` | v2v | fal `topaz/upscale/video` 2–4/s |
| `tts.captioned` | timestamps | elevenlabs `with-timestamps` (per-char alignment) — only vendor; no fallback |
| `tts.plain` | — | openai `tts-1` 1.5/1k chars → elevenlabs |
| `stt.captions` | word timestamps | apple on-device (0) → openai `whisper-1` 0.6/min (sunsets 2027-02-26) |
| `stt.plain` | — | apple on-device → openai `gpt-transcribe` 0.45/min |
| `text.listing_copy` | vision, compliant | anthropic `claude-sonnet-5` effort:low ~2.1/call → openai `gpt-5.6-terra` effort:none ~2.0 → gemini `gemini-3.8-flash` |
| `judge.fair_housing` | classifier | regex (0, always first) → anthropic `claude-haiku-4-5` 0.045 **OR** openai `gpt-5.6-luna` 0.01 (flag if EITHER flags) |
| `judge.qc_drift` | 4-image verdict | anthropic `claude-haiku-4-5` 0.66 → anthropic `claude-sonnet-5` effort:low 1.3 (escalation) · A/B: openai `gpt-5.6-luna` 0.12 |
| `video.chapters` | video-understanding | gemini `gemini-3.6-flash` low-res 1fps ~1.4/2min → gemini `gemini-3.1-flash-lite` ~0.6/2min |
| `vision.room_label` | single frame | openai `gpt-5.6-luna` detail:low 0.012/frame → anthropic `claude-haiku-4-5` 0.06/frame |
| `3d.world` | — | worldlabs `marble-1.1` 120/world |
| `floorplan` | — | apple RoomPlan (0) |

Retirements encoded as `enabled=false` + `retire_after`: `gemini-2.5-flash-image` (2026-10-02), `gpt-image-1` (2026-10-23), `sora-2*` (2026-09-24), `claude-haiku-4-5` (watch ≥2026-10-15 — successor row `claude-sonnet-5 effort:low` present), `whisper-1` (2027-02-26).

Plan policy table `plan_routing_policy(plan, policy)`: free→cheapest, trial→cheapest, starter→cheapest, solo→best, pro→best, team→best.

## 4. Hard rules (all agents)
- Fair-housing gate runs BEFORE resolveRoute on every task that takes free text. Provider-agnostic. Unbypassable.
- Every paid step writes `cost_ledger` with the provider+model that ACTUALLY ran (`recordAppAiCost` already exists in `_shared/ledger.ts`).
- Canonical asset is always our R2. Adapters `persist()` before returning success.
- Never log/return a credential. New secret NAMES only: `KIE_API_KEY`, `HIGGSFIELD_API_KEY_ID`, `HIGGSFIELD_API_KEY_SECRET` (OPENAI_API_KEY and ANTHROPIC_API_KEY are already set).
- Flag OFF = byte-identical legacy behaviour. This is what makes it deployable today.
- No request/response shape the SHIPPED iOS build depends on may change. Additive only.
