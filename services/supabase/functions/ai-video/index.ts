// ai-video — server-side AI video suite on fal.ai (owner-authenticated).
//
// ASYNC SUBMIT/STATUS pattern: edge functions can't babysit multi-minute GPU
// jobs (CPU/wall limits), so every generate route SUBMITS to fal's queue and
// returns 202 with fal's own { request_id, status_url, response_url } VERBATIM.
// The app polls GET /ai-video/status with those URLs until completed/failed.
// Stateless v1: nothing is persisted server-side; the app holds the ids.
//
//   POST /ai-video/drone      { asset_id, tier?: "1080p60"|"4k30"|"4k60", target_fps? }
//       Topaz Video AI upscale+interpolation → buttery "drone glide" master.
//       upscale_factor / target_fps are computed from the ASSET's probed
//       width/height/fps and the tier (never blindly 2× — a 4K source at "4k30"
//       used to be sent as 8K, audit F-supabase-17). The most expensive tap in
//       the product, and the one with hard COST CEILINGS — see COST SAFETY
//       below and ./dronecost.ts. The 202 carries `estimated_cost`.
//   POST /ai-video/declutter  { asset_id, prompt?, space_type? }
//       Bria video eraser (prompt-based object removal). Source must be < 5 s.
//   POST /ai-video/aerial     { image_b64?, mime?, asset_id?, space_type, region?, time_of_day?, motion?,
//                               style?, seconds?=6, aspect?: "16:9"|"9:16" }
//       Establishing shot. GROUNDED when a photo is given: Seedance image-to-
//       video starts on the exact photographed building and flies out.
//       UNGROUNDED otherwise: Veo 3.1 Fast text-to-video invents a generic
//       building of the right kind for the space type. SYNTHETIC either way —
//       the 202 carries { synthetic:true, grounded:boolean } so the app discloses.
//       Prompts are built SERVER-SIDE from space_type / motion / time_of_day /
//       region with anti-hallucination guardrails; the user's `style` hint is
//       appended (≤200 chars), never a replacement (audit F-A-01 / F-supabase-09).
//   POST /ai-video/reel-clip  { asset_id? | image_b64? (+mime?), prompt?, seconds?=5, space_type?,
//                               room?, motion?, shot_index?, shot_count? }
//       Seedance i2v: animate a listing photo into a motion clip. The camera
//       move is SERVER-CHOSEN per shot from ./motion.ts: a `room` hint and a
//       `shot_index` pick a move that suits the room AND vary it across the
//       reel, so six photos stop being six identical push-ins. `motion` names
//       one explicitly and must be in the enum (400 otherwise) — that is the
//       field a client-side shot list drives. ALL FOUR ABSENT reproduces the
//       old fixed push-in prompt byte for byte, which is what the shipped app
//       (build 5) sends. The 202 carries `motion` + `motion_label` so the clip
//       can be labelled and the provenance row records the move asked for.
//   GET  /ai-video/status?status_url=...&response_url=...
//       → { status: "processing", queue_position?, logs_tail? }
//       → { status: "completed", video_url, drift: { status:"unchecked", publishable:false, … } }
//       → { status: "failed", error }
//       The `drift` block is ADDITIVE and always says "not checked yet" here:
//       this route is stateless and holds no verdict. See QUALITY GATE below.
//   POST /ai-video/drift      { request_id, kind:"reel"|"aerial", source_b64, source_mime?,
//                               frames:[{ at:"first"|"middle"|"last", b64, mime? }],
//                               seconds?, motion?, room?, space_type?, listing_id?,
//                               provenance_id?, asset_id?, attempt? }
//       → { drift: { status:"pass"|"fail"|"unavailable", publishable, action, message,
//                    scores{…}, confidence, reason, model, … }, charge?, recorded? }
//       THE QUALITY GATE. Judges the finished clip's frames against the source
//       still on `judge.qc_drift` and decides whether it may be published.
//

// Every submit response: { request_id, status_url, response_url, kind, model_id, ... }.
// Every error: { error, code } (see _shared/http.ts).
//
// Model ids verified against fal (2026-09-03):
//   fal-ai/topaz/upscale/video                       model enum incl. "Proteus"; upscale_factor float; target_fps int
//   bria/video/erase/prompt                          https://fal.ai/models/bria/video/erase/prompt/api
//   fal-ai/veo3.1/fast                               https://fal.ai/models/fal-ai/veo3.1/fast
//   fal-ai/bytedance/seedance/v1/pro/fast/image-to-video
//       duration enum "2".."12" (string), aspect_ratio 21:9|16:9|4:3|1:1|3:4|9:16|auto, resolution 480p|720p|1080p
//
// Needs the FAL_KEY function secret + the shared R2 env (R2_PUBLIC_BASE_URL).
//
// ── COMPLIANCE (wave 2, W2-B3) ───────────────────────────────────────────────
//
// FAIR HOUSING. Every prompt this function sends — the built ones AND the
// free-text `prompt` / `style` a caller may supply — carries the fair-housing
// lock from _shared/fairhousing.ts ("Do not add or alter people, pets,
// religious or cultural objects, flags, or signage." + the permanence clause),
// and every free-text field is checked against the DENYLIST documented in full
// in _shared/fairhousing.ts. A hit is a 400 with code `unsupported_edit`.
// Before this, `reel-clip { prompt }` and `declutter { prompt }` REPLACED the
// guarded prompt outright, so a user string reached the model with no
// guardrails at all — that hole is closed.
// The `room` hint on reel-clip is NOT free text and never reaches a model: it is
// resolved to a closed enum by motion.ts normalizeRoom(), which answers null for
// anything it does not recognise, and it is the ENUM VALUE that selects a camera
// move. So there is nothing for the denylist to gate there — an unrecognised or
// hostile hint degrades to the neutral rotation instead of being refused, since
// unlike a chapter label (ai-chapters/postprocess.ts, where the same string is
// PRINTED on a public tour) this one is dropped after it has picked a move.
// The denylist is scoped by the LISTING's `space_type` (industry review P1-1):
// the asset's listing row when the route loads one, else the `listing_id` in
// the body, else the body's `space_type`, else housing. A venue, bar, store or
// gym keeps the general safety layer but not the housing-steering rules or the
// HUD wording — see _shared/fairhousing.ts, SCOPE. The PROMPT still uses the
// same `space` it always did.
//
// PROVENANCE. `aerial`, `reel-clip` and `declutter` record one media_provenance
// row (migration 0012) at SUBMIT time — the fal job is async, so the row is
// written when we know the model, the kind and the disclosure, and the app
// attaches the finished asset later via PATCH /me/compliance/:id. The 202 body
// carries `disclosure` and `provenance`. `aerial` discloses with HousingWire's
// exact wording: "Drone-style movement is simulated. No drone footage was
// captured." — the sentence the app and both tour pages must show.
// `drone` (Topaz upscale + frame interpolation) is deliberately NOT recorded:
// it re-times and sharpens footage the agent actually captured, which is the
// basic-enhancement carve-out in CA AB 723, not synthesis. Revisit if Topaz
// ever gains a generative mode.
//
// ── COST SAFETY on /drone ────────────────────────────────────────────────────
//
// The 4,000 sq ft field test: a 410 s 4K60 tour billed ~$48 from one tap, and
// the route took it without comment — no ceiling, no confirmation, no estimate.
// Topaz bills per OUTPUT second and the output runs the source's wall-clock, so
// spend on this route is linear in a number the user picks by walking around a
// house, on a plan whose whole monthly AI budget is $82.00.
//
// The per-generation cap this repo commits to elsewhere ($25.00,
// MAX_GEN_COST_PER_JOB_CENTS) lives inside log_job_cost(), which raises RP404
// without a render_job row to lock — and the in-app AI routes have none, so it
// never applied here and never can. ./dronecost.ts is the pre-flight of the
// checks that RPC would have made, with a per-submission ceiling DERIVED from
// the duration cap at the top tier (300 s × 16.0¢ = $48.00) rather than
// borrowed from a cap that cannot reach this route:
//
//   1. a submission with no usable duration_s is REFUSED (409 `conflict`, the
//      same shape /declutter already uses) — Topaz cannot be priced per second
//      without one, and a spend we cannot price is a spend we cannot cap;
//   2. a source longer than DRONE_MAX_SOURCE_SECONDS is refused (400) with the
//      length said in minutes, so an agent can act on it;
//   3. the projected cost (duration × tier × output frame rate) over
//      DRONE_MAX_SUBMISSION_CENTS is refused (400) naming the price and the
//      length that would fit — in practice this catches a submission whose
//      PRICE is out of line with its LENGTH (a `4k30` tap asking for 120 fps),
//      since a full-length tour at the top tier is exactly at the ceiling;
//   4. the projected cost is then composed with the org's EXISTING per-org
//      monthly COGS ceiling — org_month_spend_cents() vs the plan's
//      cogs_ceiling_cents, the same pair log_job_cost() compares — inside
//      guardGenerate(), BEFORE any meter is consumed (402 `quota_exceeded`).
//
// All four run before a meter is charged and before fal is called, so a refused
// submission costs the org nothing and leaves no state to unwind. Nothing here
// writes to cost_ledger, so the ceiling is checked, never double-counted: the
// one row for an accepted submission is still written after fal accepts it.
//
// ── QUALITY GATE — POST /ai-video/drift (2026-09-07) ─────────────────────────
//
// THE INCIDENT. The owner sent a screenshot of a generated aerial: smeared,
// warped roof tiles over invented geometry. "the photo to reel generator is
// changing how the house looks and that's false advertising — it has AI slop
// left over." It was not his house. On a real estate listing that is a CA AB
// 723 / MLS / HUD problem before it is an aesthetic one.
//
// WHY THE PROMPT WAS NEVER GOING TO FIX IT. buildReelPrompt() already orders
// "Do not add, remove, or move any objects; no scene changes, style shifts,
// warping, or flicker", and AERIAL_GUARDRAILS already orders "no morphing or
// warping structures". These are image-to-video models animating ONE still: a
// move that shows a surface the photograph never contained is a REQUEST to
// invent it, and no sentence outranks the shot you just ordered. So this
// function now does the thing that actually helps — it judges the output and
// refuses the bad ones. Three changes, in the order they bite:
//
//   1. RESTRICT THE MOVE. A grounded aerial no longer runs `rise_reveal` at
//      all: motion.ts groundedAerialMotion() substitutes `push_in` and the 202
//      reports both moves. The grounded aerial prompt also gains a hard clause
//      naming the exact failure (no roof plane, no unseen elevation, no
//      invented lot). The UNGROUNDED path is untouched — Veo invents a generic
//      building by design and there is no real property to contradict.
//   2. JUDGE THE RESULT. POST /ai-video/drift runs `judge.qc_drift` — seeded in
//      migration 0018 as a "4-image verdict" and, until now, with ZERO callers
//      — over the SOURCE still plus the first, middle and last frames of the
//      finished clip. Five axes (architecture, contents, additions, artifacts,
//      same_room), thresholds, parser and policy all live in _shared/drift.ts,
//      which carries the cost arithmetic and the fail-closed reasoning.
//   3. ACT ON THE VERDICT. pass → publishable. First failure → ONE retry with
//      the safest move, and the rejected clip's plan allowance is handed BACK
//      so the retry costs the user nothing (see refundRejectedClipAllowance —
//      it is deliberately NOT refundGenerateCharge, and says why). Second
//      failure → refuse, and tell the agent to use the still. A check that
//      could not run → hold: never a pass, never a paid retry.
//
// WHERE THE FRAMES COME FROM, AND THE TRUST BOUNDARY. An edge function cannot
// decode an mp4 — the repo's two frame-grabbers are ffmpeg in the worker
// (ffmpeg_render.py _extract_poster) and AVAssetImageGenerator on the device
// (RendpropApp.swift PosterMaker, which already pulls a poster frame at 0.25 s
// for every tour). So the client sends the pixels and the SERVER owns
// everything else: the rubric, the model, the thresholds, the verdict, the
// retry accounting and the audit row. A client can decline to run the check —
// and then `publishable` is false and stays false, because the status route
// reports every unchecked clip as unchecked rather than silently as fine. A
// client could also send frames that are not from its own clip, which would
// forge its own compliance evidence; the audit row records the source hash and
// the frame count so that is visible after the fact.
//
// The two ways to close that boundary properly, neither of which is invented
// here: run the check where ffmpeg already lives (the worker owns the render
// pipeline and could pull frames from the R2 copy the routed status path
// already persists), or transform the frames at the CDN edge. Both are real
// pieces of work in somebody else's file, and both would make the gate
// server-enforced rather than server-adjudicated. Until then this is the
// honest shape: the client supplies pixels, the server supplies the verdict,
// and an unchecked clip is reported as unchecked.
//
// THE AUDIT TRAIL (item 4). Every judged clip writes a cost_ledger row with
// `feature: "qc"` — the vocabulary 0001 already comments and the admin console
// already labels "QC drift judge" — whose meta carries the verdict, all five
// scores, the confidence, the model, the frames judged and the provenance id.
// When the caller passes `provenance_id`, migration 0029's record_media_qc()
// also stamps the verdict onto the media_provenance row itself, which is the
// broker-exportable AI audit log behind AB 723 / NorthstarMLS. That RPC is
// service-role only, on purpose: a tenant must not be able to write a passing
// verdict about their own listing media.

import { handleOptions } from "../_shared/cors.ts";
import {
  HttpError,
  assert,
  json,
  pathSegments,
  readJson,
  readJsonLimited,
  respondError,
} from "../_shared/http.ts";
import { adminClient, getUser, listingSpaceType, orgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";
import { durableRateLimit, refundRateLimit } from "../_shared/ratelimit.ts";
import { entitlementFor, entitlementForCharge, quotaError } from "../_shared/entitlements.ts";
import { publicR2Url } from "../_shared/r2.ts";
import { assertFairHousing, FAIR_HOUSING_LOCK, GUARDRAILS } from "../_shared/fairhousing.ts";
import { optionalUuid, recordProvenance } from "../_shared/provenance.ts";
import { APP_AI_UNIT_CENTS, recordAppAiCost, recordRoutedAiCost } from "../_shared/ledger.ts";
import type { RouteStep } from "../_shared/router.ts";
import { resolveRoute, routerEnabled } from "../_shared/router.ts";
import { adapterFor } from "../_shared/providers/index.ts";
import { type ChainResult, resolveChain, runChain } from "../_shared/providers/chain.ts";
import { ProviderError } from "../_shared/providers/common.ts";
import { type ContentBlock, anthropicMessages, imageBlock } from "../_shared/providers/anthropic.ts";
import { openaiChat } from "../_shared/providers/openai.ts";
import { falSubmitEcho } from "../_shared/providers/fal.ts";
import { persistedUrl, routedR2Key } from "../_shared/providers/common.ts";
import type { GenerateInput, JobRef } from "../_shared/providers/types.ts";
import {
  extractJobToken,
  type JobTokenOwner,
  type RouterJobToken,
  routerStatusUrl,
  verifyJobToken,
} from "../_shared/providers/jobtoken.ts";
import {
  assertDroneWithinLimits,
  assertMonthlyHeadroom,
  DRONE_TIER_CENTS,
  DRONE_TIERS,
  type DroneEstimate,
} from "./dronecost.ts";
import {
  AERIAL_MOTION_TEXT,
  AERIAL_MOTIONS,
  type AerialMotion,
  buildReelPrompt,
  chooseReelMotion,
  groundedAerialMotion,
  normalizeRoom,
  parseReelMotion,
  REEL_MOTION_LABEL,
  REEL_MOTION_TEXT,
  REEL_MOTIONS,
  type ReelMotion,
} from "./motion.ts";
import {
  DRIFT_FALLBACK_CENTS,
  DRIFT_FRAME_POSITIONS,
  DRIFT_MAX_FRAMES,
  DRIFT_PASS_SCORES,
  DRIFT_SOURCE_LABEL,
  DRIFT_TASK,
  type DriftFramePosition,
  type DriftVerdict,
  decideDriftAction,
  driftBlock,
  driftFramesLabel,
  driftLineageKey,
  driftPasses,
  driftRubric,
  ESCALATE_BELOW_CONFIDENCE,
  failedCategories,
  parseDriftVerdict,
  unavailableVerdict,
  uncheckedDriftBlock,
} from "../_shared/drift.ts";

// Denial-of-wallet guards (audit P1-3): every generate route hits a paid GPU
// queue, so cap submissions per burst window AND per rolling month per org,
// and soft-dedupe retried submits via the Idempotency-Key header.
const GEN_MAX_PER_WINDOW = 12;
const GEN_WINDOW_SECONDS = 300; // 12 video jobs / 5 min / org
const MONTH_SECONDS = 30 * 86400;

// These are NOT one pool. Measured costs differ by an order of magnitude, so
// each kind gets its own meter (allowances from plan_entitlements, 0010):
//   reel  — Seedance 1.0 Pro Fast 5s ......... $0.24
//   aerial— Veo 3.1 Fast 8s 1080p no audio ... $0.80   (3x a reel)
//   drone — Topaz 90s @1080p60 ............... $3.60   (15x a reel)
//           Topaz 90s @4K30 / @4K60 .......... $7.20 / $14.40
// Topaz is an ADD-ON, not bundled: a single 4K60 tap costs more than a third of
// a Starter subscription. declutter (Bria) rides the reel meter.
// The meters bound how MANY drone taps an org gets; they never bounded how much
// ONE of them could cost — that is ./dronecost.ts (see COST SAFETY above).
type GenKind = "reel" | "aerial" | "drone" | "declutter";

function capFor(kind: GenKind, ent: { reels_per_month: number; aerials_per_month: number; topaz_per_month: number }): number {
  switch (kind) {
    case "aerial": return ent.aerials_per_month;
    case "drone": return ent.topaz_per_month;
    default: return ent.reels_per_month; // reel + declutter share the clip pool
  }
}

function meterKeyFor(kind: GenKind): string {
  return kind === "aerial" ? "aerialmo" : kind === "drone" ? "dronemo" : "reelmo";
}

function labelFor(kind: GenKind): string {
  return kind === "aerial"
    ? "AI aerial"
    : kind === "drone"
    ? "drone-glide render"
    : "AI video clip";
}

// Bound inline base64 so a caller can't push unbounded memory pressure through
// readJson (audit round 4). ~12 MB of base64 ≈ 9 MB binary.
const MAX_IMAGE_B64_CHARS = 12_000_000;
const ALLOWED_IMAGE_MIMES = ["image/jpeg", "image/png", "image/webp"];

/**
 * What guardGenerate() actually charged, so a submission that never reaches
 * the provider can hand it all back (see refundGenerateCharge, audit item 2 /
 * F-E-16).
 */
interface GenerateCharge {
  orgId: string;
  plan: string;
  monthlyKey: string;
  burstKey: string;
}

/**
 * Charge the paid-generation quotas + enforce the role gate.
 *
 * MUST be called only AFTER the request body and its referenced asset are
 * known-good. Charging up front meant `POST /ai-video/drone {}` burned an org's
 * burst and monthly quota before failing on the missing asset_id, with no
 * provider call ever made (audit round 4).
 *
 * The org is resolved with the X-Org-Id header when present: orgForUser()
 * otherwise picks the caller's highest-privilege membership, so a user in two
 * workspaces could have quota charged to the wrong one.
 *
 * `projectedCents` — when the caller can price the submission up front (today
 * only /drone, whose per-output-second rate card makes that exact) — is checked
 * against the org's EXISTING monthly COGS ceiling BEFORE any meter is consumed,
 * so a submission that cannot fit the budget burns no allowance on its way to
 * being refused. See assertMonthlyHeadroom() in ./dronecost.ts for why this is
 * a pre-flight of log_job_cost()'s own check rather than a second ceiling.
 */
async function guardGenerate(
  userId: string,
  req: Request,
  kind: GenKind,
  projectedCents?: number,
): Promise<GenerateCharge> {
  const orgId = await orgForUser(userId, preferredOrg(req));
  const admin = adminClient();

  const { data: mem, error: mErr } = await admin
    .from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle();
  if (mErr) throw new HttpError(500, `Role lookup failed: ${mErr.message}`);
  if (!mem?.role || mem.role === "marketing") {
    throw new HttpError(403, "Your role does not permit AI video generation");
  }

  // A degraded plan lookup is a 503 here, never a 402 (audit F-E-02).
  const ent = await entitlementForCharge(orgId);
  const monthlyCap = capFor(kind, ent);

  // A zero allowance is a PLAN BOUNDARY, not a rate limit — 402 `plan_required`
  // so the app shows an upgrade prompt instead of "try again later". This is
  // what keeps Topaz (up to $14.40 a tap) off the cheap plans.
  if (monthlyCap <= 0) throw quotaError(labelFor(kind), 0, 0, ent.plan);

  // PROJECTED SPEND vs the org's monthly COGS ceiling. Ordered AFTER the plan
  // boundary above (a plan that doesn't include the feature must still read as
  // `plan_required`, not as a budget problem) and BEFORE every meter below, so
  // a refusal here costs the org nothing to recover from.
  if (projectedCents != null && projectedCents > 0) {
    assertMonthlyHeadroom({
      monthSpentCents: await orgMonthSpendCents(admin, orgId),
      ceilingCents: ent.cogs_ceiling_cents,
      projectedCents,
      plan: ent.plan,
      feature: labelFor(kind),
    });
  }

  // Idempotency soft-dedupe: when the client sends an Idempotency-Key, a
  // duplicate submit inside 2 minutes is rejected instead of double-billed.
  // NOT refunded on failure, deliberately (mirrors ai-chapters/index.ts
  // guardChapters): it is a short dedupe guard, not spend.
  const idem = req.headers.get("idempotency-key")?.trim();
  if (idem && idem.length <= 128) {
    if (!(await durableRateLimit(`aividem:${orgId}:${idem}`, 1, 120))) {
      throw new HttpError(409, "Duplicate submission — this job was already started.", "conflict");
    }
  }
  const burstKey = `aivideo:${orgId}`;
  const monthlyKey = `${meterKeyFor(kind)}:${orgId}`;
  if (!(await durableRateLimit(burstKey, GEN_MAX_PER_WINDOW, GEN_WINDOW_SECONDS))) {
    throw new HttpError(429, "AI video generation limit reached for now — try again in a few minutes.", "rate_limited");
  }
  if (!(await durableRateLimit(monthlyKey, monthlyCap, MONTH_SECONDS))) {
    throw quotaError(labelFor(kind), monthlyCap, monthlyCap, ent.plan);
  }
  // The effective plan rides along for the router's RouteContext — it is the
  // number entitlementForCharge() just read, not a second lookup.
  return { orgId, plan: ent.plan, monthlyKey, burstKey };
}

/**
 * Hand back everything a submission that never reached the provider charged
 * (audit item 2 / F-E-16, mirrors ai-chapters/index.ts refundCharge exactly).
 *
 * Call ONLY when the provider submit itself threw — a fal/router submit that
 * THROWS never billed us, so nothing was produced for the quota it consumed.
 * Once a submit call RETURNS, the provider has ACCEPTED the job and the spend
 * is committed (see the COST LEDGER comments below); nothing past that point
 * is ever refunded, even if the async job later fails — that failure surfaces
 * from GET /ai-video/status, which never charged anything to begin with.
 *
 * Best effort and never throws — see refundRateLimit().
 */
async function refundGenerateCharge(charge: GenerateCharge): Promise<void> {
  await refundRateLimit(charge.monthlyKey, MONTH_SECONDS, 1);
  await refundRateLimit(charge.burstKey, GEN_WINDOW_SECONDS, 1);
}

// ── The quality gate's own guards (POST /ai-video/drift) ─────────────────────

/**
 * Burst ceiling on the check itself.
 *
 * Shaped like ai-copy's guardAssist() and ai-photo's guardHelper() rather than
 * like guardGenerate(): a role check and ONE burst key, no monthly meter and
 * nothing refundable. The check is a 0.66¢ classifier call that PROTECTS a
 * generation the org has already paid for, so putting it behind a monthly
 * allowance would mean an org could run out of the ability to verify its own
 * clips — which is the one thing that must never be rationed.
 *
 * 30 per 5 minutes against generation's own 12 per 5 minutes: a clip can cost
 * at most two checks (the original and its one retry), so 24 is the true
 * ceiling a legitimate client can reach, and 30 leaves room for a re-check
 * after a `hold` without inventing a second budget to reason about.
 */
const DRIFT_MAX_PER_WINDOW = 30;
const DRIFT_WINDOW_SECONDS = 300;

/**
 * How long a source still's ONE retry grant lives (6 hours).
 *
 * Long enough that the retry generation, its poll and its own check all happen
 * inside it — a Seedance clip is minutes, not hours. Short enough that an agent
 * who reshoots the same room tomorrow, or comes back to a listing next week,
 * gets a fresh grant instead of inheriting yesterday's refusal. The counter is
 * keyed on a hash of the source photograph (drift.ts driftLineageKey), so it
 * follows the PHOTO rather than any id a client controls.
 */
const DRIFT_LINEAGE_WINDOW_SECONDS = 6 * 3600;

/**
 * The most rejected-clip allowance refunds one org can be given in a month.
 *
 * Refunding is the right product answer (see refundRejectedClipAllowance) but
 * it is unbounded generosity if it is not capped: reel generations do not
 * pre-check the org's monthly COGS ceiling the way /drone does, so every
 * refunded allowance is another 24¢ of real Seedance spend the meters would
 * otherwise have stopped. 20 × 24¢ = $4.80 of extra exposure per org per month,
 * against a plan whose whole monthly AI budget is $82.00 — visible in the
 * ledger, small next to the budget, and far cheaper than the alternative, which
 * is billing an agent twice for our model's failure. Past the cap the clip is
 * still refused; only the goodwill refund stops, and the response says so.
 */
const DRIFT_MAX_REFUNDS_PER_MONTH = 20;

/** Role gate + burst limiter for the check. Mirrors ai-copy's guardAssist(). */
async function guardDriftCheck(userId: string, req: Request): Promise<string> {
  const orgId = await orgForUser(userId, preferredOrg(req));
  const { data: mem, error: mErr } = await adminClient()
    .from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle();
  if (mErr) throw new HttpError(500, `Role lookup failed: ${mErr.message}`);
  if (!mem?.role || mem.role === "marketing") {
    throw new HttpError(403, "Your role does not permit AI video generation");
  }
  if (!(await durableRateLimit(`aidrift:${orgId}`, DRIFT_MAX_PER_WINDOW, DRIFT_WINDOW_SECONDS))) {
    throw new HttpError(
      429,
      "Too many quality checks for now — try again in a few minutes.",
      "rate_limited",
    );
  }
  return orgId;
}

/**
 * Hand back the plan allowance a clip consumed when WE rejected that clip.
 *
 * ── Why this is not refundGenerateCharge, and must not be confused with it ───
 *
 * refundGenerateCharge exists for a submission that never reached a provider:
 * "a fal/router submit that THROWS never billed us". Its own comment is
 * explicit that once a submit RETURNS, the spend is committed and "nothing past
 * that point is ever refunded, even if the async job later fails". That rule is
 * about VENDOR MONEY and it still holds here: the rejected clip was generated,
 * Seedance billed us for it, and its cost_ledger row stands untouched. So does
 * the retry's. COGS stays honest and GET /admin/spend still sees every cent.
 *
 * What this refunds is the ORG'S OWN PLAN ALLOWANCE — the `reelmo:`/`aerialmo:`
 * counters guardGenerate() charged. Those are our product's promise ("N clips a
 * month"), not a vendor's invoice, and charging two of them for one usable clip
 * bills the agent twice for our model's failure. The brief's rule was "never
 * charge twice for the retry without saying so"; handing the allowance back is
 * the version of that which does not require an apology, and `charge` in the
 * response says exactly what happened either way.
 *
 * THREE GUARDS, because a refund is money:
 *   1. IDEMPOTENT PER CLIP. Keyed on the request id, so re-posting the same
 *      frames cannot mint allowance. Same shape as guardGenerate()'s
 *      Idempotency-Key dedupe.
 *   2. CAPPED PER ORG PER MONTH (DRIFT_MAX_REFUNDS_PER_MONTH).
 *   3. ONLY ON A REAL FAILURE. The caller runs this exclusively for a verdict a
 *      model actually delivered and that actually failed — never for `hold`,
 *      never for a check that could not run, and never on a client's say-so:
 *      the verdict comes from `judge.qc_drift`, not from the request body.
 *
 * Best effort and never throws, exactly like refundGenerateCharge: a failed
 * refund must not turn a delivered verdict into a 500.
 */
async function refundRejectedClipAllowance(
  orgId: string,
  kind: GenKind,
  requestId: string,
): Promise<{ refunded: boolean; reason: string }> {
  try {
    if (!(await durableRateLimit(`aidriftref:${orgId}:${requestId}`, 1, MONTH_SECONDS))) {
      return { refunded: false, reason: "already refunded for this clip" };
    }
    if (!(await durableRateLimit(`aidriftrefmo:${orgId}`, DRIFT_MAX_REFUNDS_PER_MONTH, MONTH_SECONDS))) {
      return {
        refunded: false,
        reason:
          `this workspace has already had ${DRIFT_MAX_REFUNDS_PER_MONTH} clips refunded this month`,
      };
    }
    const monthly = await refundRateLimit(`${meterKeyFor(kind)}:${orgId}`, MONTH_SECONDS, 1);
    await refundRateLimit(`aivideo:${orgId}`, GEN_WINDOW_SECONDS, 1);
    return monthly
      ? { refunded: true, reason: "the clip we rejected was not charged to your plan" }
      : { refunded: false, reason: "the allowance counter had already rolled over" };
  } catch (e) {
    // Key names are org ids and feature slugs — no secrets, no user content.
    console.error("ai-video: rejected-clip refund failed:", e instanceof Error ? e.message : e);
    return { refunded: false, reason: "the refund could not be applied" };
  }
}

/**
 * What this org has already spent this calendar month, in cents.
 *
 * The SAME number log_job_cost() measures its ceiling against — literally the
 * same function, org_month_spend_cents() from migration 0010 §4, called here
 * instead of re-implementing the sum, so the pre-flight and the enforcement can
 * never disagree about what "spent this month" means. It counts the app-AI rows
 * this function writes (org-scoped, job_id IS NULL) as well as every worker
 * pipeline row, because it sums cost_ledger by org and date, not by job.
 *
 * FAILS CLOSED. A spend read we cannot make is a budget we cannot check, and
 * the whole point of this guard is that the most expensive tap in the product
 * never runs unpriced — so a lookup failure is a 503 "try again", exactly the
 * shape entitlementForCharge() already uses for a degraded plan lookup
 * (F-E-02 / F-supabase-34), never a silent pass.
 */
async function orgMonthSpendCents(
  admin: ReturnType<typeof adminClient>,
  orgId: string,
): Promise<number> {
  const { data, error } = await admin.rpc("org_month_spend_cents", { p_org: orgId });
  if (error) {
    console.error("ai-video: org_month_spend_cents lookup failed:", error.message);
    throw new HttpError(
      503,
      "Spend budget lookup is temporarily unavailable — try again in a moment.",
      "upstream",
    );
  }
  const cents = Number(data ?? 0);
  return Number.isFinite(cents) ? Math.max(0, cents) : 0;
}

const FAL_QUEUE_BASE = "https://queue.fal.run";
const FAL_KEY = Deno.env.get("FAL_KEY");

const MODEL_DRONE = "fal-ai/topaz/upscale/video";
const MODEL_DECLUTTER = "bria/video/erase/prompt";
const MODEL_AERIAL_T2V = "fal-ai/veo3.1/fast";
const MODEL_I2V = "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video";

// DRONE_TIERS (output target per tier) and DRONE_TIER_CENTS (the committed
// per-output-second rate card) now live in ./dronecost.ts next to the ceilings
// that read them, so the price and the cap it feeds cannot drift apart. Both
// are imported above; nothing about their values changed.

// Bria hard limit: "duration must be less than 5s" (input schema). We disable
// auto_trim (never silently cut the user's clip) and pre-flight the duration.
const BRIA_MAX_SECONDS = 5;

// ── AI router glue (docs/AI-ROUTER-CONTRACT.md) ──────────────────────────────
//
// This function is ASYNC by design: it submits and returns 202, and the app
// polls GET /ai-video/status. The chain therefore covers the SUBMIT — the only
// point where failing over to another vendor is free. Once a job is accepted it
// has been paid for, so poll and persist happen in the status route below,
// through the same adapter.
//
// THE 202 SHAPE NEVER CHANGES. With the flag OFF a fal step echoes fal's own
// { request_id, status_url, response_url } verbatim, exactly as it does today.
// With the flag ON — where the provider may not be fal at all — those three
// fields carry an OPAQUE token addressed to our own status route. The shipped
// app round-trips them without looking inside (LiveAPIClient percent-encodes
// them and hands them straight back), so one code path serves both.

/**
 * Durations each task's rows actually advertise.
 *
 * `needs` is a filter: requiring "11s" when no step advertises it empties the
 * chain and 503s a request the shipped function serves today. So the duration
 * is required only when it is a duration the table can satisfy — everything
 * else falls back to the chain order, which is still 1080p i2v.
 */
const ADVERTISED_SECONDS: Record<string, number[]> = {
  "video.reel_clip": [5, 6],
  "video.aerial": [6, 8],
  "video.aerial_no_photo": [4, 6, 8],
};

function durationNeeds(task: string, seconds: number): string[] {
  return (ADVERTISED_SECONDS[task] ?? []).includes(seconds) ? [`${seconds}s`] : [];
}

/**
 * The last-resort step: what THIS deploy runs today, hardcoded.
 * resolveRoute() answers `[]` when the routing table is unreadable, and a
 * database blip must not take video generation down.
 */
function legacyVideoStep(
  task: string,
  model: string,
  unit: string,
  unitCents: number,
  capabilities: string[],
): RouteStep {
  return {
    route_id: "legacy-local",
    task,
    provider: "fal",
    model,
    unit,
    unit_cents: unitCents,
    capabilities,
    max_latency_s: 900,
    min_plan: "free",
    same_model_as: null,
    privacy_tier: "retained_30d",
    enabled: true,
  };
}

/**
 * The three fields every 202 carries.
 *
 * Flag OFF + fal → fal's own ids, verbatim (today's contract, unchanged).
 * Otherwise      → our opaque, SIGNED token (audit item 4) in all three
 * fields, bound to `owner` — the org + user that submitted the job.
 */
async function submitEnvelope(
  req: Request,
  routerOn: boolean,
  task: string,
  ref: JobRef,
  owner: JobTokenOwner,
): Promise<{ request_id: string; status_url: string; response_url: string }> {
  if (!routerOn && ref.provider === "fal") {
    const echo = falSubmitEcho(ref.id);
    if (echo) return echo;
  }
  const url = await routerStatusUrl(req, "ai-video", task, ref, owner);
  return { request_id: ref.id, status_url: url, response_url: url };
}

// ── Space-type vocabulary (mirrors SpaceType in Models/Listing.swift) ─────────

const SPACE_TYPES = ["real_estate", "venue", "restaurant", "retail", "fitness", "other"] as const;
type SpaceType = typeof SPACE_TYPES[number];

function spaceTypeOf(raw: unknown): SpaceType {
  const s = String(raw ?? "").trim().toLowerCase().replace(/-/g, "_");
  return (SPACE_TYPES as readonly string[]).includes(s) ? (s as SpaceType) : "real_estate";
}

/** What the building IS, for the aerial prompt (exterior subject noun). */
const AERIAL_SUBJECT: Record<SpaceType, string> = {
  real_estate: "residential home",
  venue: "event venue building",
  restaurant: "restaurant building with its entrance and signage",
  retail: "retail storefront",
  fitness: "fitness studio / gym building",
  other: "commercial building",
};

/** What the photographed scene IS, for i2v continuation prompts. */
const SCENE_NOUN: Record<SpaceType, string> = {
  real_estate: "home",
  venue: "event venue",
  restaurant: "restaurant",
  retail: "store",
  fitness: "fitness studio",
  other: "space",
};

/** What "clutter" means per industry, for the Bria eraser default prompt. */
const DECLUTTER_PROMPT: Record<SpaceType, string> = {
  real_estate:
    "remove clutter, shoes, bags, boxes, cords, laundry, dishes, and personal items " +
    "from the floor and surfaces; keep the room, furniture, and architecture unchanged",
  venue:
    "remove stray chairs, cables, cases, trash, cleaning equipment and clutter from the floor " +
    "and surfaces; keep the space, its fixtures, and architecture unchanged",
  restaurant:
    "remove clutter from tables and floors: stray napkins, bus tubs, condiment bottles, receipts, " +
    "cords and trash; keep the tables, chairs, decor, and architecture unchanged",
  retail:
    "remove boxes, stock carts, packaging, cords, signage clutter and trash from the floor and " +
    "surfaces; keep the fixtures, displays, products, and architecture unchanged",
  fitness:
    "remove stray towels, water bottles, bags, loose weight plates, cords and clutter from the " +
    "floor; keep the equipment, mats, mirrors, and architecture unchanged",
  other:
    "remove clutter, boxes, cords, trash, and personal items from the floor and surfaces; " +
    "keep the space, furniture, and architecture unchanged",
};

// The reel prompt — its anti-hallucination scaffolding, its per-shot camera
// clause and its GUARDRAILS composition — is ./motion.ts buildReelPrompt(),
// which this route calls with SCENE_NOUN[space]. It lived here as a single
// fixed push-in sentence until the shot-motion work; it moved so the vocabulary
// and the choice could be unit-tested (index.ts calls Deno.serve at module load
// and can never be imported by a test — same reason dronecost.ts lives apart).
// buildReelPrompt({ motion: "push_in" }) reproduces the old sentence byte for
// byte, which is what the shipped app still gets when it sends no hints.

/**
 * Wrap a caller-supplied free-text video prompt so it can never REPLACE the
 * guardrails (it used to: `cleanPrompt(body.prompt) ?? builtPrompt` sent the raw
 * user string straight to the model). The denylist has already run on `userText`
 * by the time this is called.
 */
function guardedUserPrompt(userText: string, space: SpaceType, verb: string): string {
  return (
    `${verb} this exact photographed ${SCENE_NOUN[space]} as follows: ${userText.trim()}. ` +
    "Stay photorealistic and true to the space — it is a real place being marketed. " +
    "Keep the architecture, fixtures, materials and camera perspective identical. " + GUARDRAILS
  );
}

// ── Aerial prompt builder ─────────────────────────────────────────────────────

// AERIAL_MOTIONS / AERIAL_MOTION_TEXT now live in ./motion.ts, shared with the
// reel's own vocabulary. The four original ids keep their exact original text
// and `rise_reveal` is still the default, so an aerial submitted today is the
// aerial that was submitted yesterday; the module adds directional orbits.
const AERIAL_TIMES = ["golden_hour", "midday", "twilight", "overcast"] as const;
type AerialTime = typeof AERIAL_TIMES[number];

const TIME_TEXT: Record<AerialTime, string> = {
  golden_hour: "warm golden-hour sunlight with long soft shadows",
  midday: "bright, clear midday daylight with crisp shadows",
  twilight: "blue-hour twilight with a deep blue sky and warm light glowing from the windows",
  overcast: "soft, even overcast light under a pale grey sky",
};

const AERIAL_GUARDRAILS =
  "Smooth, stabilized gimbal drone motion with gentle parallax and coherent, stable geometry " +
  "throughout — no morphing or warping structures, no added or removed buildings, no scene cuts. " +
  "Realistic scale and proportions. No people, no text, no watermarks, no logos. " +
  FAIR_HOUSING_LOCK;

/** Never a street address: drop anything that starts like a house number. */
function cleanRegion(raw: unknown): string | null {
  const s = String(raw ?? "").replace(/[\r\n]+/g, " ").replace(/[^A-Za-z0-9 ,.'\-]/g, "").trim().slice(0, 80);
  if (!s) return null;
  if (/^\d{1,6}\s+\S/.test(s)) return null; // "1247 Hillcrest Dr…" — a street, not a region
  return s;
}

function cleanStyle(raw: unknown): string | null {
  const s = String(raw ?? "").replace(/[\r\n]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 200);
  return s.length > 0 ? s : null;
}

function buildAerialPrompt(args: {
  grounded: boolean;
  space: SpaceType;
  motion: AerialMotion;
  time: AerialTime;
  region: string | null;
  style: string | null;
}): string {
  const subject = AERIAL_SUBJECT[args.space];
  const parts: string[] = [];
  if (args.grounded) {
    parts.push(
      `Photorealistic cinematic aerial drone establishing shot of THIS EXACT ${subject} as shown in the reference image. ` +
        "Preserve its architecture, roofline, facade colors, materials, windows, doors, signage and landscaping exactly as photographed — " +
        "it is the same building for the entire shot.",
    );
    // THE HARD GROUNDED CLAUSE (2026-09-07). The rest of this prompt says what
    // to preserve; this says what NOT TO DRAW, which is the failure the owner
    // photographed. A model asked for an aerial over a kerbside photo will
    // supply a roof plane because an aerial has one — so the shot is told, in
    // as many words, that running out of photograph is a reason to stop moving
    // rather than a reason to invent. It sits immediately after the subject
    // sentence, before the camera clause, so the constraint is read before the
    // move it constrains. It is grounded-only: the ungrounded path has no real
    // building to be unfaithful to, and its prompt is unchanged.
    parts.push(
      "Never render any surface the reference photograph does not contain: no roof plane, no " +
        "upper storey, no rear or side elevation, no neighbouring building or lot, and no interior " +
        "through any window that is not already visible. If the camera move would travel past what " +
        "the photograph shows, slow and settle instead of inventing what lies beyond it. Roof " +
        "tiles, shingles, render, brick, siding and every other material keep the exact texture, " +
        "colour and pattern of the photograph — no painterly, melted, smeared or repeating " +
        "surfaces.",
    );
  } else {
    parts.push(
      `Cinematic aerial drone establishing shot of a single, believable ${subject}. ` +
        "One consistent building for the entire shot — the same structure, roofline, lot and street throughout.",
    );
  }
  parts.push(`Camera: ${AERIAL_MOTION_TEXT[args.motion]}.`);
  parts.push(`Light: ${TIME_TEXT[args.time]}.`);
  if (args.region) {
    parts.push(`Setting: ${args.region} — regional architecture, vegetation and climate consistent with that area.`);
  }
  parts.push(AERIAL_GUARDRAILS);
  if (args.style) parts.push(`Look and feel: ${args.style}.`);
  return parts.join(" ");
}

interface DroneBody {
  asset_id?: string;
  tier?: string;
  target_fps?: number;
}
interface DeclutterBody {
  asset_id?: string;
  prompt?: string;
  space_type?: string;
  /** Compliance (W2-B3). Defaults to the asset's own listing. */
  listing_id?: string;
  label?: string;
}
interface AerialBody {
  image_b64?: string;
  mime?: string;
  asset_id?: string;
  space_type?: string;
  region?: string;
  time_of_day?: string;
  motion?: string;
  /** Optional look-and-feel hint ("modern glass house with a pool"), APPENDED to
   *  the guarded prompt. ≤ 200 chars. */
  style?: string;
  /** Legacy alias of `style` from older clients; never a replacement prompt. */
  prompt?: string;
  /** Accepted for back-compat and ignored: Veo's safety filter rejects real
   *  residential addresses, and the model has never seen the property anyway.
   *  Send `region` ("Charlotte, NC") instead. */
  address?: string;
  seconds?: number;
  aspect?: string;
  /** Compliance (W2-B3). Defaults to the grounding asset's listing. */
  listing_id?: string;
  label?: string;
}
interface ReelBody {
  asset_id?: string;
  image_b64?: string;
  mime?: string;
  prompt?: string;
  seconds?: number;
  space_type?: string;
  /** ADDITIVE (router): "16:9" | "9:16". The shipped app does not send one, and
   *  without it the clip keeps the source photo's framing exactly as today. */
  aspect?: string;
  /** ADDITIVE (per-shot motion). What room this photo shows — a RoomPlan tag or
   *  the agent's own chapter label. Resolved against a CLOSED set (motion.ts);
   *  anything unrecognised is treated as absent, never passed on. */
  room?: string;
  /** ADDITIVE. One of REEL_MOTIONS, naming the camera move explicitly — a 400
   *  outside the enum, because a shot list that silently degrades to a push-in
   *  is exactly the bug this exists to fix. Absent = server-chosen. */
  motion?: string;
  /** ADDITIVE. 0-based position of this clip in the reel; what makes the move
   *  VARY shot to shot. Absent = 0 = the first shot's move. */
  shot_index?: number;
  /** ADDITIVE. How many clips the reel has. Bounds-checked and echoed for the
   *  provenance record; it does NOT steer the choice, and deliberately so — the
   *  four-family cycle already gives a 2- or 3-shot reel two or three different
   *  families, so there is nothing about a short reel left for it to fix. */
  shot_count?: number;
  /** Compliance (W2-B3). Defaults to the source asset's listing. */
  listing_id?: string;
  label?: string;
}

/**
 * POST /ai-video/drift — the quality gate's request.
 *
 * `source_b64` and `frames[]` are the only two REQUIRED fields, because they
 * are the only two the check cannot do without: the photograph that is the
 * truth, and the frames that are on trial. Everything else sharpens the rubric
 * or the audit row, and every one of them is resolved through a closed
 * vocabulary before it is used.
 */
interface DriftBody {
  /** The completed clip's `request_id` from the 202. The audit key, and what
   *  makes the judgement and the allowance refund idempotent per clip. */
  request_id?: string;
  /** "reel" | "aerial" — anything else reads as "reel", the cheaper default. */
  kind?: string;
  /** The SOURCE STILL the clip was generated from, base64, no data: prefix. */
  source_b64?: string;
  source_mime?: string;
  /** Frames pulled from the finished clip: first / middle / last. 1-3 of them. */
  frames?: unknown;
  /** Clip length, echoed for the audit row only. */
  seconds?: number;
  /** The camera move that was asked for, so the judge knows what motion is
   *  legitimate in these frames. Resolved against the same enums the generate
   *  routes use; an unknown value is simply dropped. */
  motion?: string;
  /** Space type, for the scene noun in the rubric ("home", "restaurant"). */
  space_type?: string;
  /** The media_provenance row this clip's 202 returned. When present, the
   *  verdict is stamped onto it (migration 0029) — the compliance evidence. */
  provenance_id?: string;
  /** The source photo's capture_asset, when the clip was generated from one.
   *  Recorded for the audit trail; the PIXELS always come from source_b64. */
  asset_id?: string;
  /** Client hint: how many clips this photo has already had rejected. It may
   *  only ever make the answer stricter — see the route. */
  attempt?: number;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const user = await getUser(req); // auth required on every route (also guards the FAL key)
    const db = userClient(req); // RLS: the caller only sees their own org's assets
    const seg = pathSegments(req, "ai-video");

    // NOTE: quota is NOT charged up front. Each generate route validates its
    // body (and resolves its asset) FIRST, then calls guardGenerate()
    // immediately before the billable fal submit — see audit round 4.

    // ---- POST /ai-video/drone ----
    if (req.method === "POST" && seg.length === 1 && seg[0] === "drone") {
      const body = await readJson<DroneBody>(req);
      assert(body.asset_id, 400, "asset_id is required");
      const tier = body.tier ?? "4k30";
      const target = DRONE_TIERS[tier];
      assert(target, 400, `tier must be one of ${Object.keys(DRONE_TIERS).join(", ")}`);

      const asset = await resolvePublicAsset(db, body.asset_id, req);
      assert(asset.kind === "video", 400, "drone-glide needs a video asset");

      // Upscale factor from the SOURCE: reach the tier's long edge, never exceed
      // it, never exceed 4K. Unknown dimensions fall back to the old defaults.
      const srcLong = asset.width && asset.height ? Math.max(asset.width, asset.height) : null;
      let upscale: number;
      if (srcLong) {
        upscale = Math.max(1, Math.min(4, Math.round((target.longEdge / srcLong) * 100) / 100));
      } else {
        upscale = tier === "1080p60" ? 1 : 2;
      }
      const outLong = srcLong ? Math.round(srcLong * upscale) : null;
      assert(outLong == null || outLong <= 4096, 400, "This source is already above 4K; drone-glide would exceed the 4K ceiling");

      // Target fps from the tier (client override bounded 24–120). No
      // interpolation request when the source already runs at/above it.
      let fps = Math.round(Number(body.target_fps ?? target.fps));
      if (!Number.isFinite(fps)) throw new HttpError(400, "target_fps must be a number");
      fps = Math.min(120, Math.max(24, fps));
      const interpolate = asset.fps == null || asset.fps < fps - 0.5;

      // COST SAFETY (the 4,000 sq ft field test: a 410 s 4K60 tour billed ~$48
      // from one tap). Everything above this line is free; everything below it
      // spends money. So the duration ceiling, the missing-duration refusal and
      // the per-submission cost ceiling all run HERE — before guardGenerate()
      // charges a meter and long before fal is called — and the estimate they
      // return is the single place this submission's price is computed. Sizing,
      // arithmetic and the fail-closed reasoning are all in ./dronecost.ts.
      //
      // Topaz preserves duration, so the OUTPUT runs at the source's
      // wall-clock; the output FRAME RATE is the interpolation target when we
      // ask for one, and otherwise the source's own rate (Topaz does not
      // re-time what it is not asked to). That distinction is what the estimate
      // is priced on, so a `4k30` tap that quietly emits 120 fps is costed as
      // the 120 fps job it is rather than at the 30 fps tier price.
      const outputFps = interpolate ? fps : (asset.fps ?? fps);
      const estimate: DroneEstimate = assertDroneWithinLimits({
        tier,
        durationS: asset.duration_s,
        outputFps,
        assetId: asset.id,
      });

      // Priced — now compose with the org's existing monthly COGS ceiling
      // (inside guardGenerate, before any meter is consumed) and charge.
      const charge = await guardGenerate(user.id, req, "drone", estimate.cents);
      const { orgId, plan } = charge;

      // ROUTER (flag-gated): 4K tiers and the 1080p60 tier are separate tasks
      // because they are separately priced. Topaz is v2v; nothing else in the
      // table can do it, so the chain is short by nature.
      const task = tier === "1080p60" ? "video.upscale_1080p60" : "video.upscale_4k";
      const routerOn = await routerEnabled();
      const steps = await resolveChain(
        task,
        { plan, needs: ["v2v"], carries_customer_media: true },
        legacyVideoStep(task, MODEL_DRONE, "second", DRONE_TIER_CENTS[tier], ["v2v"]),
      );
      const genInput: GenerateInput = {
        task,
        video_url: asset.url,
        extra: {
          upscale_factor: upscale,
          ...(interpolate ? { target_fps: fps } : {}),
        },
      };
      // The submit itself failing means no provider ever accepted the job —
      // hand the charge back (audit item 2). See refundGenerateCharge.
      let attempt: ChainResult<JobRef>;
      try {
        attempt = await runChain(task, steps, (step) => adapterFor(step.provider).submit(step, genInput));
      } catch (e) {
        await refundGenerateCharge(charge);
        throw e;
      }
      const step = attempt.step;
      const sub = await submitEnvelope(req, routerOn, task, attempt.value, { orgId, userId: user.id });

      // COST LEDGER (F-E-15): Topaz bills per OUTPUT second, and the output runs
      // the same wall-clock as the source, so units = the source duration. One
      // org-scoped row, job_id = NULL, best effort. Written only after fal ACCEPTED
      // the submit — the spend is committed at that point (E-network.md §1), and a
      // retried Idempotency-Key was already 409'd above, so one render → one row.
      //
      // The row is now UNCONDITIONAL: assertDroneWithinLimits() above refuses a
      // submission with no usable duration_s, so anything that reaches this
      // point has one. That closes the F-E-15 residual gap the old branch
      // documented (submit anyway, warn, record nothing) — a spend we could not
      // price is a spend we now never make, rather than one the ledger, the
      // per-org monthly ceiling and GET /admin/spend all miss.
      await recordRoutedAiCost(adminClient(), {
        orgId,
        feature: "drone_render",
        step,
        seconds: estimate.seconds,
        // ONE route row cannot price Topaz: it bills per OUTPUT pixel-frame,
        // so 4K60 is twice 4K30 while `video.upscale_4k` is a single row. The
        // tier price in _shared/ledger.ts stays authoritative for Topaz; any
        // other provider is billed at its own row price. NOTE this is the TIER
        // price, deliberately unscaled by the frame-rate multiplier the
        // pre-flight estimate applies — the estimate errs high on purpose so a
        // 120 fps tap cannot slip past the ceiling, but the accounting stays on
        // the number the three-way rate-card lockstep owns (see dronecost.ts).
        unitCentsOverride: /topaz/i.test(step.model) ? DRONE_TIER_CENTS[tier] : undefined,
        meta: {
          tier,
          request_id: attempt.value.id,
          upscale_factor: upscale,
          target_fps: fps,
          interpolated: interpolate,
          estimate_cents: estimate.cents,
        },
      });
      return json({
        ...sub,
        kind: "drone",
        model_id: step.model,
        tier,
        target_fps: fps,
        upscale_factor: upscale,
        interpolated: interpolate,
        source: { width: asset.width, height: asset.height, fps: asset.fps, duration_s: asset.duration_s },
        // ADDITIVE (cost safety): what this submission is expected to cost, so
        // the app can show a number instead of the user finding out on an
        // invoice. A new key on an existing object — AIVideoJobDTO decodes only
        // the fields it names and ignores the rest, so an older build is
        // unaffected. Every refusal above carries the same figures in its error
        // details, so the client has one shape to read either way.
        estimated_cost: estimate,
      }, 202);
    }

    // ---- POST /ai-video/declutter ----
    if (req.method === "POST" && seg.length === 1 && seg[0] === "declutter") {
      const body = await readJson<DeclutterBody>(req);
      assert(body.asset_id, 400, "asset_id is required");

      const asset = await resolvePublicAsset(db, body.asset_id, req);
      // Bria rejects ≥5 s clips AFTER we would have charged the meter: without
      // probed metadata we cannot pre-flight, so require it (audit F-supabase-29).
      if (asset.duration_s == null) {
        throw new HttpError(409, "This asset has no probed duration — re-upload it with duration_s so the clip can be pre-checked", "conflict");
      }
      if (asset.duration_s >= BRIA_MAX_SECONDS) {
        throw new HttpError(
          400,
          `Bria's video eraser only accepts clips under ${BRIA_MAX_SECONDS}s and auto-trim is ` +
            `disabled so your full clip is processed — this asset is ${asset.duration_s}s. ` +
            `Trim the clip to under ${BRIA_MAX_SECONDS}s and try again.`,
        );
      }
      const space = spaceTypeOf(body.space_type ?? asset.space_type);

      // A free-text erase instruction is checked, then WRAPPED — it can no
      // longer replace the guardrails (see header). The gate is scoped by the
      // asset's LISTING type (header, FAIR HOUSING).
      const userErase = cleanPrompt(body.prompt);
      if (userErase) assertFairHousing(userErase, "This erase instruction", asset.space_type ?? space);
      const erasePrompt = userErase
        ? guardedUserPrompt(userErase, space, "Erase objects from")
        : `${DECLUTTER_PROMPT[space]}. ${GUARDRAILS}`;

      // NOT ROUTED, deliberately: §3 defines no video-declutter task, so a route
      // row would invent a chain the router's contract doesn't actually seed.
      // This path stays hardcoded to Bria — see the COST LEDGER note below for
      // pricing (audit item 3 changed that half of the "stays as shipped" story;
      // the ROUTING half is unchanged).
      const charge = await guardGenerate(user.id, req, "declutter"); // validated — charge, then submit
      let sub: Awaited<ReturnType<typeof falSubmit>>;
      try {
        sub = await falSubmit(MODEL_DECLUTTER, {
          video_url: asset.url,
          prompt: erasePrompt,
          auto_trim: false, // never silently cut the video — process the full clip
          preserve_audio: true,
          output_container_and_codec: "mp4_h264",
        });
      } catch (e) {
        // The submit itself failed — fal never accepted the job, so hand the
        // reel-allowance charge back (audit item 2). See refundGenerateCharge.
        await refundGenerateCharge(charge);
        throw e;
      }

      // COST LEDGER (audit item 3): this route consumed the shared reel quota
      // and called a real provider, then wrote NOTHING to cost_ledger — so a
      // heavy user of this route could spend real Bria money that never showed
      // up in the org's monthly COGS total or GET /admin/spend. No unit price
      // for Bria is committed ANYWHERE in this repo (confirmed against
      // admin/index.ts's own bria row, unit_cost_cents: null, and
      // HANDOFF-DB.md's "Known gap: bria/video/erase/prompt" — §3 of the router
      // contract never defined a video-declutter task either). Rather than
      // inventing a number, this reuses APP_AI_UNIT_CENTS
      // .bria_declutter_per_clip_estimated — itself a pointer to the existing,
      // already-committed ESTIMATED_UNIT_COST_CENTS.declutter figure (Flux
      // Fill/Kontext masked inpaint, ~$0.04/image) — as an explicitly-marked
      // placeholder so the row exists and is auditable instead of silently
      // absent. meta.price_estimated flags it for every consumer of this table.
      // Replace with Bria's real per-clip price the moment one is obtained, and
      // mirror the change into admin/index.ts's bria row + HANDOFF-DB.md in the
      // same commit (see docs/handoff/audit-fixes.md).
      await recordAppAiCost(adminClient(), {
        orgId: charge.orgId,
        provider: "fal",
        feature: "video_declutter",
        model: MODEL_DECLUTTER,
        units: 1,
        unitCents: APP_AI_UNIT_CENTS.bria_declutter_per_clip_estimated,
        meta: {
          space_type: space,
          request_id: sub.request_id,
          price_estimated: true,
          price_basis:
            "No committed Bria price exists in the repo; reusing ESTIMATED_UNIT_COST_CENTS.declutter " +
            "as an order-of-magnitude stand-in — see HANDOFF-DB.md 'Known gap: bria/video/erase/prompt'.",
        },
      });

      const prov = await recordProvenance(req, {
        listingId: body.listing_id ?? asset.listing_id,
        kind: "declutter",
        label: body.label ?? null,
        modelId: MODEL_DECLUTTER,
        edit: "declutter",
        promptSummary: userErase ?? null,
      });
      return json({
        ...sub,
        kind: "declutter",
        model_id: MODEL_DECLUTTER,
        space_type: space,
        disclosure: prov.disclosure,
        provenance: { id: prov.id, recorded: prov.recorded, ...(prov.reason ? { reason: prov.reason } : {}) },
      }, 202);
    }

    // ---- POST /ai-video/aerial ----
    if (req.method === "POST" && seg.length === 1 && seg[0] === "aerial") {
      const body = await readJson<AerialBody>(req);
      const aspect = body.aspect ?? "16:9";
      assert(aspect === "16:9" || aspect === "9:16", 400, `aspect must be "16:9" or "9:16"`);
      // 4 | 6 | 8 s (Veo's enum; Seedance accepts any 2–12 s string).
      const wanted = Number(body.seconds ?? 6);
      const seconds = !Number.isFinite(wanted) || wanted <= 4 ? 4 : wanted <= 6 ? 6 : 8;

      const space = spaceTypeOf(body.space_type);
      const motionRaw = String(body.motion ?? "rise_reveal").trim().toLowerCase();
      assert((AERIAL_MOTIONS as readonly string[]).includes(motionRaw), 400,
        `motion must be one of ${AERIAL_MOTIONS.join(", ")}`);
      const motion = motionRaw as AerialMotion;
      const timeRaw = String(body.time_of_day ?? "golden_hour").trim().toLowerCase();
      assert((AERIAL_TIMES as readonly string[]).includes(timeRaw), 400,
        `time_of_day must be one of ${AERIAL_TIMES.join(", ")}`);
      const time = timeRaw as AerialTime;
      const region = cleanRegion(body.region);
      const style = cleanStyle(body.style) ?? cleanStyle(body.prompt);
      // The look-and-feel hint is appended to the guarded prompt, so it is a
      // free-text field and gets the fair-housing denylist (see header). The
      // `region` field is already sanitized to a place name by cleanRegion(),
      // but a region is exactly where steering language shows up, so it is
      // checked too ("a good school district" would otherwise pass as a place).
      // Scoped by the listing's type when a listing_id is sent (header).
      const aerialGateSpace = (await listingSpaceType(db, body.listing_id)) ?? space;
      if (style) assertFairHousing(style, "This look-and-feel hint", aerialGateSpace);
      if (region) assertFairHousing(region, "This setting", aerialGateSpace);

      // Grounding image: inline base64 (preferred — the app downsizes to ≤1280 px)
      // or a renders-bucket photo asset of the org's listing.
      let imageUrl: string | null = null;
      let assetListingId: string | null = null;
      if (typeof body.image_b64 === "string" && body.image_b64.length > 0) {
        assert(body.image_b64.length <= MAX_IMAGE_B64_CHARS, 413, "image is too large — resize it before sending", "payload_too_large");
        const mime = String(body.mime ?? "image/jpeg").split(";")[0].trim().toLowerCase();
        assert(ALLOWED_IMAGE_MIMES.includes(mime), 400, `mime must be one of ${ALLOWED_IMAGE_MIMES.join(", ")}`);
        imageUrl = `data:${mime};base64,${body.image_b64}`;
      } else if (body.asset_id) {
        const asset = await resolvePublicAsset(db, body.asset_id, req);
        assert(asset.kind === "photo", 400, "aerial asset_id must be a photo (the exterior shot)");
        imageUrl = asset.url;
        assetListingId = asset.listing_id;
      }
      const grounded = imageUrl !== null;

      // ── The move a real photograph can hold (2026-09-07 incident) ─────────
      // A GROUNDED `rise_reveal` is the screenshot: the shot's whole purpose is
      // to reveal a roofline the photograph does not contain, so the model
      // paints one, and it stops being the customer's house. motion.ts
      // groundedAerialMotion() substitutes the one move that can only ever show
      // LESS of the photograph. The UNGROUNDED path is returned unchanged, so
      // text-to-video aerials are byte-identical to what they were.
      //
      // A substitution rather than a 400 because the SHIPPED app hardcodes
      // `motion: "rise_reveal"` as its aerial default (iOS APIClient.swift): a
      // 400 would delete the feature from every installed copy to fix a defect
      // the server can fix by itself. Both moves are reported in the 202 and
      // the substituted one is what the provenance row records, so nothing
      // about the swap is silent.
      const aerialMove = groundedAerialMotion(motion, grounded);
      const prompt = buildAerialPrompt({
        grounded,
        space,
        motion: aerialMove.motion,
        time,
        region,
        style,
      });

      const charge = await guardGenerate(user.id, req, "aerial"); // validated — charge, then submit
      const { orgId, plan } = charge;

      // ROUTER (flag-gated). GROUNDED is an image-to-video task carrying the
      // customer's own photo; UNGROUNDED is text-to-video and carries none —
      // two different tasks, exactly as §3 seeds them.
      const task = grounded ? "video.aerial" : "video.aerial_no_photo";
      const routerOn = await routerEnabled();
      const steps = await resolveChain(
        task,
        {
          plan,
          needs: grounded
            ? ["i2v", "1080p", ...durationNeeds(task, seconds), aspect]
            : ["t2v"],
          carries_customer_media: grounded,
        },
        grounded
          ? legacyVideoStep(task, MODEL_I2V, "second", APP_AI_UNIT_CENTS.seedance_per_s, ["i2v", "1080p", "6s", "8s", "16:9", "9:16"])
          : legacyVideoStep(task, MODEL_AERIAL_T2V, "call", APP_AI_UNIT_CENTS.veo_aerial_clip, ["t2v"]),
      );
      const genInput: GenerateInput = {
        task,
        prompt,
        ...(grounded && imageUrl ? { image_url: imageUrl } : {}),
        seconds,
        aspect,
        resolution: "1080p",
      };
      // The submit itself failing means no provider ever accepted the job —
      // hand the charge back (audit item 2). See refundGenerateCharge.
      let attempt: ChainResult<JobRef>;
      try {
        attempt = await runChain(task, steps, (step) => adapterFor(step.provider).submit(step, genInput));
      } catch (e) {
        await refundGenerateCharge(charge);
        throw e;
      }
      const step = attempt.step;
      const modelId = step.model;
      const sub = await submitEnvelope(req, routerOn, task, attempt.value, { orgId, userId: user.id });

      // COST LEDGER (F-E-15): a GROUNDED aerial is Seedance i2v (billed per output
      // second); an UNGROUNDED one is Veo 3.1 Fast (a flat per-clip price — the
      // repo has no per-second Veo rate). One org-scoped row, job_id = NULL, best
      // effort, only after fal ACCEPTED the submit (spend committed; see §1).
      // The step's own unit decides the maths: "second" bills per output second
      // (grounded Seedance), "call" bills flat per clip (ungrounded Veo).
      await recordRoutedAiCost(adminClient(), {
        orgId,
        feature: "aerial",
        step,
        seconds,
        meta: {
          grounded,
          seconds,
          aspect,
          request_id: attempt.value.id,
          motion: aerialMove.motion,
          ...(aerialMove.substituted ? { motion_requested: aerialMove.requested } : {}),
        },
      });

      // COMPLIANCE: an aerial is synthetic camera movement — HousingWire's
      // disclosure test names exactly this case, and WI Act 69 covers generated
      // video from 1 Jan 2027. Recorded at submit; the app attaches the finished
      // clip later via PATCH /me/compliance/:id.
      const prov = await recordProvenance(req, {
        listingId: body.listing_id ?? assetListingId,
        kind: "aerial",
        label: body.label ?? "Aerial intro",
        modelId,
        edit: "aerial",
        style: grounded ? "grounded" : "ungrounded",
        promptSummary: style ?? null,
      });

      return json(
        {
          ...sub,
          kind: "aerial",
          synthetic: true, // AI-generated footage — the app must disclose this
          grounded,        // true = starts on the user's photo; false = generic scenery
          model_id: modelId,
          seconds,
          aspect,
          space_type: space,
          // The move the clip was ACTUALLY built with. When the grounded path
          // substituted one, `motion_requested` carries what the caller asked
          // for and `motion_substitution` says why in plain language — additive
          // keys the shipped decoder ignores, so an installed build reads
          // `motion` exactly as it always did and simply gets a safer shot.
          motion: aerialMove.motion,
          ...(aerialMove.substituted
            ? {
              motion_requested: aerialMove.requested,
              motion_substituted: true,
              motion_substitution: aerialMove.reason,
            }
            : {}),
          time_of_day: time,
          region,
          // "Drone-style movement is simulated. No drone footage was captured."
          // — show this verbatim in the app AND in the share text (W2-C4).
          disclosure: prov.disclosure,
          provenance: { id: prov.id, recorded: prov.recorded, ...(prov.reason ? { reason: prov.reason } : {}) },
        },
        202,
      );
    }

    // ---- POST /ai-video/reel-clip ----
    if (req.method === "POST" && seg.length === 1 && seg[0] === "reel-clip") {
      const body = await readJson<ReelBody>(req);
      let secs = Math.round(Number(body.seconds ?? 5));
      if (!Number.isFinite(secs)) secs = 5;
      secs = Math.min(12, Math.max(2, secs)); // Seedance duration range 2–12 s

      let imageUrl: string;
      let assetSpace: string | null = null;
      let reelListingId: string | null = null;
      if (body.asset_id) {
        const asset = await resolvePublicAsset(db, body.asset_id, req);
        imageUrl = asset.url;
        assetSpace = asset.space_type;
        reelListingId = asset.listing_id;
      } else {
        assert(body.image_b64, 400, "asset_id or image_b64 is required");
        assert(typeof body.image_b64 === "string", 400, "image_b64 must be a string");
        assert(body.image_b64.length <= MAX_IMAGE_B64_CHARS, 413,
               "image is too large — resize it before sending", "payload_too_large");
        const mime = String(body.mime ?? "image/jpeg").split(";")[0].trim().toLowerCase();
        assert(ALLOWED_IMAGE_MIMES.includes(mime), 400, `mime must be one of ${ALLOWED_IMAGE_MIMES.join(", ")}`);
        imageUrl = `data:${mime};base64,${body.image_b64}`;
      }
      const space = spaceTypeOf(body.space_type ?? assetSpace);

      // Checked, then WRAPPED — a free-text reel prompt can no longer replace
      // the anti-hallucination + fair-housing guardrails (see header). The gate
      // is scoped by the listing's type: the asset's listing, else the body's
      // listing_id (the shipped app sends the photo inline, with listing_id).
      const userMotion = cleanPrompt(body.prompt);
      if (userMotion) {
        const reelGateSpace = assetSpace ?? (await listingSpaceType(db, body.listing_id)) ?? space;
        assertFairHousing(userMotion, "This clip prompt", reelGateSpace);
      }

      // ── Per-shot camera motion (./motion.ts) ──────────────────────────────
      // ADDITIVE, and the compatibility line is exact: with `room`, `motion`,
      // `shot_index` and `shot_count` all absent — which is every request the
      // shipped app makes — this resolves to `push_in` and buildReelPrompt()
      // rebuilds the prompt the route has always sent, byte for byte
      // (motion_test.ts freezes that string). Nothing below is reachable
      // without a client that opts in.
      //
      // The chosen text is SERVER-CHOSEN, so it composes with GUARDRAILS the
      // same way the old fixed sentence did — a clause inside the built prompt,
      // never a replacement for it. The room hint cannot inject: normalizeRoom
      // answers a member of a closed enum or null, and it is that value, not
      // the caller's string, that picks the move.
      const room = normalizeRoom(body.room);
      let shotIndex: number | null = null;
      if (body.shot_index !== undefined && body.shot_index !== null) {
        const n = Number(body.shot_index);
        assert(Number.isInteger(n) && n >= 0 && n <= 999, 400,
               "shot_index must be a whole number between 0 and 999");
        shotIndex = n;
      }
      let shotCount: number | null = null;
      if (body.shot_count !== undefined && body.shot_count !== null) {
        const n = Number(body.shot_count);
        assert(Number.isInteger(n) && n >= 1 && n <= 999, 400,
               "shot_count must be a whole number between 1 and 999");
        shotCount = n;
      }
      // A shot index past the planned count is NOT an error: a retry that
      // appends a clip is a legitimate thing for a client to do, and refusing it
      // would cost the agent a shot over an off-by-one.
      let shotMotion: ReelMotion;
      if (body.motion !== undefined && body.motion !== null) {
        const named = parseReelMotion(body.motion);
        assert(named !== null, 400, `motion must be one of ${REEL_MOTIONS.join(", ")}`);
        shotMotion = named;
      } else {
        shotMotion = chooseReelMotion({ room, shotIndex });
      }

      const reelText = userMotion
        ? guardedUserPrompt(userMotion, space, "Animate")
        : buildReelPrompt({ sceneNoun: SCENE_NOUN[space], motion: shotMotion });
      // When the caller supplied free text, the camera move came from THEIR
      // words on the unchanged guarded-user path — so the 202 and the provenance
      // row report no motion rather than one we never sent.
      const chosenMotion: ReelMotion | null = userMotion ? null : shotMotion;

      const charge = await guardGenerate(user.id, req, "reel"); // validated — charge, then submit
      const { orgId, plan } = charge;

      // ROUTER (flag-gated). With the flag off this resolves to the one legacy
      // step — fal Seedance — and the adapter rebuilds the payload below byte
      // for byte (asserted by providers_test.ts).
      const task = "video.reel_clip";
      const routerOn = await routerEnabled();
      const reelAspect = body.aspect === "16:9" || body.aspect === "9:16" ? body.aspect : null;
      const steps = await resolveChain(
        task,
        {
          plan,
          // 1080p is a real requirement here: it is what the shipped clip is,
          // and asking for it correctly drops the 768p Hailuo fallback.
          needs: ["i2v", "1080p", ...durationNeeds(task, secs), ...(reelAspect ? [reelAspect] : [])],
          carries_customer_media: true,
        },
        legacyVideoStep(task, MODEL_I2V, "second", APP_AI_UNIT_CENTS.seedance_per_s, ["i2v", "1080p", "5s", "16:9", "9:16"]),
      );
      const genInput: GenerateInput = {
        task,
        prompt: reelText,
        image_url: imageUrl,
        seconds: secs,
        resolution: "1080p",
        ...(reelAspect ? { aspect: reelAspect } : {}),
      };
      // The submit itself failing means no provider ever accepted the job —
      // hand the charge back (audit item 2). See refundGenerateCharge.
      let attempt: ChainResult<JobRef>;
      try {
        attempt = await runChain(task, steps, (step) => adapterFor(step.provider).submit(step, genInput));
      } catch (e) {
        await refundGenerateCharge(charge);
        throw e;
      }
      const step = attempt.step;
      const sub = await submitEnvelope(req, routerOn, task, attempt.value, { orgId, userId: user.id });

      // COST LEDGER (F-E-15): i2v bills per output second. One org-scoped row,
      // job_id = NULL, best effort, only after the provider ACCEPTED the submit,
      // and attributed to the provider/model that actually ran (contract §4).
      await recordRoutedAiCost(adminClient(), {
        orgId,
        feature: "reel",
        step,
        seconds: secs,
        meta: {
          seconds: secs,
          space_type: space,
          request_id: attempt.value.id,
          ...(chosenMotion ? { motion: chosenMotion } : {}),
          ...(room ? { room } : {}),
        },
      });

      const prov = await recordProvenance(req, {
        listingId: body.listing_id ?? reelListingId,
        kind: "reel",
        label: body.label ?? null,
        modelId: step.model,
        edit: "reel",
        // What was actually asked of the model: the move we chose, or nothing
        // when the agent's own words drove the clip instead.
        style: chosenMotion,
        promptSummary: userMotion ?? null,
      });
      return json({
        ...sub,
        kind: "reel",
        model_id: step.model,
        seconds: secs,
        space_type: space,
        // The move this clip was actually asked for, so the client can label it
        // in a shot list without shipping its own copy of the enum. null when a
        // free-text prompt drove the clip instead.
        motion: chosenMotion,
        motion_label: chosenMotion ? REEL_MOTION_LABEL[chosenMotion] : null,
        room,
        ...(shotIndex !== null ? { shot_index: shotIndex } : {}),
        ...(shotCount !== null ? { shot_count: shotCount } : {}),
        disclosure: prov.disclosure,
        provenance: { id: prov.id, recorded: prov.recorded, ...(prov.reason ? { reason: prov.reason } : {}) },
      }, 202);
    }

    // ---- POST /ai-video/drift ----
    //
    // THE QUALITY GATE. Everything about why this exists is in the header and
    // in _shared/drift.ts; what follows is the order of operations, which is
    // the part that has to be right:
    //
    //   1. VALIDATE the body (free) — audit round 4's rule, same as every
    //      generate route: nothing is charged for a request that was never
    //      going to work.
    //   2. ROLE + BURST (guardDriftCheck). No monthly meter: an org must never
    //      run out of the ability to verify clips it has already paid for.
    //   3. ONE JUDGEMENT PER CLIP, so a retried POST cannot buy a second
    //      opinion or a second refund.
    //   4. JUDGE on `judge.qc_drift`, escalating once on low confidence.
    //   5. DECIDE — pure, in drift.ts. The retry grant is durable and keyed on
    //      the SOURCE PHOTOGRAPH, so "exactly once" survives restarts and lies.
    //   6. REFUND the rejected clip's plan allowance (never the vendor spend).
    //   7. RECORD: one cost_ledger row per judge call, plus the verdict on the
    //      media_provenance row when the caller names one.
    if (req.method === "POST" && seg.length === 1 && seg[0] === "drift") {
      const body = await readJsonLimited<DriftBody>(req, MAX_DRIFT_BODY_BYTES);

      const requestId = cleanRequestId(body.request_id);
      const kind: GenKind = body.kind === "aerial" ? "aerial" : "reel";
      const source = requireDriftImage(body.source_b64, body.source_mime, "source_b64");
      const frames = cleanDriftFrames(body.frames);
      const seconds = Number.isFinite(Number(body.seconds))
        ? Math.min(60, Math.max(1, Math.round(Number(body.seconds))))
        : null;

      // Context that sharpens the rubric. Every piece of it is resolved through
      // the SAME closed vocabularies the generate routes use — spaceTypeOf()
      // and the two motion enums — so nothing a caller types reaches the model
      // through this route either: what is sent is our own frozen text, chosen
      // by an enum value. That is why this route runs no fair-housing denylist,
      // exactly as motion.ts argues for the reel's `room` hint.
      const space = spaceTypeOf(body.space_type);
      const motionText = driftMotionText(kind, body.motion);
      const provenanceId = optionalUuid(body.provenance_id);
      const sourceAssetId = optionalUuid(body.asset_id);

      const orgId = await guardDriftCheck(user.id, req);

      // ONE JUDGEMENT PER CLIP (step 3). Same 409 shape guardGenerate() uses
      // for a duplicate Idempotency-Key. Without it, re-posting the frames of a
      // failed clip would spend the lineage's retry grant twice and could ask
      // for a second allowance refund; with it, a client that lost the response
      // is told plainly that a verdict already exists.
      if (!(await durableRateLimit(`aidriftjob:${orgId}:${requestId}`, 1, DRIFT_LINEAGE_WINDOW_SECONDS))) {
        throw new HttpError(
          409,
          "This clip has already been checked — use the verdict you were given.",
          "conflict",
        );
      }

      const judged = await judgeDrift({
        plan: await driftRoutingPlan(orgId),
        subject: { kind: kind === "aerial" ? "aerial" : "reel", sceneNoun: SCENE_NOUN[space], motionText },
        source,
        frames,
      });
      const verdict = judged.verdict;
      const passed = driftPasses(verdict);

      // ── The retry grant (step 5) ─────────────────────────────────────────
      //
      // A retry is a NEW generation with a new request id and a new provenance
      // row, so nothing in the job ids ties attempt 2 to attempt 1. The one
      // thing both attempts share is the PHOTOGRAPH, so the counter is keyed on
      // a hash of its bytes: a client cannot dodge the limit by renaming
      // anything, and two agents animating two different photos never collide.
      //
      // The client's own `attempt` hint may only ever make this STRICTER. A
      // caller saying "this is already the retry" is believed (it refuses); a
      // caller saying "this is the first attempt" is not (the durable counter
      // decides). Fail closed in the direction that stops publishing.
      let attempt = 0;
      let retryGranted = false;
      if (!passed && !verdict.unavailable && verdict.judgement !== "unknown") {
        const claimed = Math.max(0, Math.round(Number(body.attempt ?? 0)) || 0);
        if (claimed >= 1) {
          attempt = claimed;
        } else {
          const lineage = await driftLineageKey(source.b64);
          retryGranted = await durableRateLimit(
            `aidriftlin:${orgId}:${lineage}`,
            1,
            DRIFT_LINEAGE_WINDOW_SECONDS,
          );
          attempt = retryGranted ? 0 : 1;
        }
      }

      const decision = decideDriftAction({ verdict, attempt, retryGranted });

      // A HOLD means no verdict was delivered, so this clip has NOT been judged
      // and the once-per-clip token above must not go on holding the door shut
      // for six hours — the message we are about to return literally says "try
      // the check again in a moment". Handing the token back is what makes that
      // sentence true. Same primitive, same best-effort contract, as every
      // other refund in this function.
      if (decision.action === "hold") {
        await refundRateLimit(`aidriftjob:${orgId}:${requestId}`, DRIFT_LINEAGE_WINDOW_SECONDS, 1);
      }

      // ── The money (step 6) ───────────────────────────────────────────────
      //
      // Only a clip a model actually judged and actually failed. A `hold` (the
      // check could not run) refunds nothing: we do not know that the clip is
      // bad, and handing back an allowance for a clip that may be perfectly
      // good would make an outage in Anthropic's API into free reels.
      const charge = decision.action === "retry" || decision.action === "refuse"
        ? await refundRejectedClipAllowance(orgId, kind, requestId)
        : { refunded: false, reason: "this clip was charged to your plan as usual" };

      // ── The audit trail (step 7) ─────────────────────────────────────────
      //
      // ONE cost_ledger row PER JUDGE CALL, so an escalated verdict costs two
      // rows and reads as two calls — the same shape services/pipeline/
      // router.py `_record_qc` writes, and the honest alternative to ai-copy's
      // documented "the retry is invisible in the ledger" under-report. feature
      // is `qc`: 0001 comments that vocabulary on cost_ledger.feature and
      // admin/index.ts already labels it "QC drift judge", so this shows up in
      // the spend console with no admin change at all.
      //
      // meta carries the WHOLE verdict. It is a durable, org-scoped row that
      // every member of the org can read under the ledger RLS policy, so it
      // holds no photograph, no frame, no prompt and no free text of the
      // caller's — only bounded numbers, a closed-vocabulary verdict, the
      // judge's own sentence, and ids. That is the compliance evidence: what
      // was judged, by which model, and what it scored.
      let ledgerRows = 0;
      for (const call of judged.calls) {
        const res = await recordRoutedAiCost(adminClient(), {
          orgId,
          feature: "qc",
          step: call.step,
          meta: {
            kind: "video_drift",
            clip_kind: kind,
            request_id: requestId,
            provenance_id: provenanceId,
            source_asset_id: sourceAssetId,
            escalated: call.escalated,
            frames_judged: frames.length,
            ...(seconds !== null ? { seconds } : {}),
            source_sha256: judged.sourceHash,
            verdict: verdict.judgement,
            scores: verdict.scores,
            failed: failedCategories(verdict),
            confidence: verdict.confidence,
            reason: verdict.reason,
            action: decision.action,
            publishable: decision.publishable,
            attempt,
            allowance_refunded: charge.refunded,
          },
        });
        if (res.recorded) ledgerRows++;
      }

      // The compliance spine (migration 0029). Service-role RPC on purpose: a
      // tenant must not be able to write a passing verdict about their own
      // listing media. Best effort — the verdict is already in the ledger and
      // already in the response, and losing an audit stamp must not lose the
      // answer the agent is waiting for.
      const stamped = provenanceId
        ? await stampProvenanceQc(orgId, provenanceId, {
          verdict: verdict.judgement,
          action: decision.action,
          publishable: decision.publishable,
          score: verdict.score,
          scores: verdict.scores,
          thresholds: DRIFT_PASS_SCORES,
          failed: failedCategories(verdict),
          confidence: verdict.confidence,
          reason: verdict.reason,
          model: judged.step?.model ?? null,
          provider: judged.step?.provider ?? null,
          task: DRIFT_TASK,
          escalated: judged.escalated,
          frames_judged: frames.length,
          request_id: requestId,
          source_sha256: judged.sourceHash,
          attempt,
        })
        : false;

      return json({
        drift: driftBlock({
          decision,
          verdict,
          provider: judged.step?.provider ?? "none",
          model: judged.step?.model ?? "none",
          escalated: judged.escalated,
          framesJudged: frames.length,
          attempt,
        }),
        // What this cost the agent, said out loud rather than left to an
        // invoice — the same reason /drone carries `estimated_cost`.
        charge: {
          allowance_refunded: charge.refunded,
          note: charge.reason,
          retry_costs_another_clip: decision.action === "retry" ? !charge.refunded : false,
        },
        recorded: { ledger: ledgerRows, provenance: stamped },
        ...(seconds !== null ? { seconds } : {}),
        kind,
      });
    }

    // ---- GET /ai-video/status ----
    if (req.method === "GET" && seg.length === 1 && seg[0] === "status") {
      const params = new URL(req.url).searchParams;

      // A ROUTED job: the app is handing back the opaque token this function
      // minted at submit (it round-trips status_url/response_url verbatim, so
      // no client change is needed). Poll through the adapter and PERSIST the
      // result into our R2 the moment it completes — every reseller expires
      // media (fal 24 h by our own lifecycle header, Higgsfield 7 d, Kie 14 d),
      // so the canonical asset has to become ours here. The legacy fal path
      // below is untouched and still runs for every flag-off submit.
      //
      // SECURITY (audit item 4): verifyJobToken() checks signature, shape,
      // expiry AND that the token's org+user match the CALLER's own JWT —
      // never the reverse — BEFORE anything here polls a vendor with our
      // credentials. A `job` value that is present but fails any of those
      // checks is a 403, never a silent fall-through to the legacy path below
      // (which expects status_url/response_url, not job, and would otherwise
      // answer a confusing 400).
      const rawJobToken = extractJobToken(params);
      if (rawJobToken !== null) {
        const callerOrgId = await orgForUser(user.id, preferredOrg(req));
        const routed = await verifyJobToken(rawJobToken, { orgId: callerOrgId, userId: user.id });
        if (!routed) {
          throw new HttpError(
            403,
            "This job status link is invalid, expired, or does not belong to your workspace.",
          );
        }
        return await routedStatus(callerOrgId, routed);
      }

      const statusUrl = requireFalUrl(params.get("status_url"), "status_url");
      const responseUrl = requireFalUrl(params.get("response_url"), "response_url");

      const su = new URL(statusUrl);
      su.searchParams.set("logs", "1");
      const stRes = await fetch(su.toString(), { headers: falHeaders() });
      const st = await stRes.json().catch(() => ({} as Record<string, unknown>));
      if (!stRes.ok) {
        throw new HttpError(502, `fal status ${stRes.status}: ${JSON.stringify(st).slice(0, 300)}`, "upstream");
      }

      const status = String(st.status ?? "");
      if (status === "IN_QUEUE" || status === "IN_PROGRESS") {
        return json({
          status: "processing",
          fal_status: status,
          queue_position: typeof st.queue_position === "number" ? st.queue_position : null,
          logs_tail: logsTail(st),
        });
      }

      if (status === "COMPLETED") {
        const rRes = await fetch(responseUrl, { headers: falHeaders() });
        const result = await rRes.json().catch(() => ({} as Record<string, unknown>));
        if (!rRes.ok) {
          throw new HttpError(502, `fal result ${rRes.status}: ${JSON.stringify(result).slice(0, 300)}`, "upstream");
        }
        const videoUrl = extractVideoUrl(result);
        if (!videoUrl) {
          throw new HttpError(502, `fal result had no video url: ${JSON.stringify(result).slice(0, 300)}`, "upstream");
        }
        // ADDITIVE (quality gate). A completed clip is not an APPROVED clip.
        // This route is stateless — it holds no verdict and cannot fetch one
        // without a per-poll database read on every 2-second poll — so what it
        // reports is the honest thing it knows: nobody has checked this clip
        // against the source photo yet, and therefore `publishable` is false.
        // The block is emitted rather than omitted precisely BECAUSE silence
        // reads as approval; POST /ai-video/drift answers with the same shape
        // once a verdict exists. A shipped build decodes the fields it names
        // and ignores this one entirely.
        return json({ status: "completed", video_url: videoUrl, drift: uncheckedDriftBlock() });
      }

      // FAILED / ERROR / anything unexpected. Log the provider's reason so
      // failures are diagnosable from the function logs (audit follow-up).
      const failMsg = await failureError(st, responseUrl);
      console.error("ai-video job failed:", failMsg);
      return json({ status: "failed", error: failMsg });
    }

    throw new HttpError(405, `Method ${req.method} not allowed on this path`);
  } catch (err) {
    return respondError(err);
  }
});

// ── routed job status (poll + persist through the adapter) ────────────────────

/**
 * The status answer for a job the router submitted.
 *
 * Same three states the app already decodes — processing / completed / failed —
 * with `video_url` pointing at OUR R2 copy once the result has been persisted.
 * Extra fields are additive; the shipped decoder ignores them.
 *
 * `orgId` is the CALLER's own org, already verified by verifyJobToken() to
 * match the token's owner before this function is ever reached (audit item 4)
 * — it is what the finished asset is persisted under, never re-derived from
 * the token itself.
 */
async function routedStatus(orgId: string, job: RouterJobToken): Promise<Response> {
  const adapter = adapterFor(job.p);
  const ref: JobRef = {
    provider: job.p,
    model: job.m,
    id: job.i,
    // The adapter re-validates this against its own host allowlist before it
    // ever fetches with our key — the token round-trips through the client.
    poll_url: job.u,
    submitted_at: job.t,
  };

  const state = await adapter.poll(ref);
  if (state.status !== "done") {
    if (state.status === "failed") {
      console.error(`ai-video routed job failed (${job.p}/${job.m}):`, state.message);
      return json({ status: "failed", error: state.message, error_class: state.error_class, provider: job.p });
    }
    return json({ status: "processing", provider: job.p, model: job.m, queue_position: null, logs_tail: [] });
  }

  // COMPLETED → persist before we call it a success (contract §4).
  let assetKey: string | null = null;
  let videoUrl: string | null = null;
  try {
    const stored = await adapter.persist(state, routedR2Key(orgId, job.k || "video", state.mime));
    assetKey = stored.key;
    videoUrl = persistedUrl(stored.key);
  } catch (e) {
    console.error(`ai-video: persisting ${job.p} result to R2 failed:`, e instanceof Error ? e.message : e);
  }

  if (!videoUrl) {
    // No R2 copy (storage failed, or R2_PUBLIC_BASE_URL is unset). Handing back
    // the vendor's own URL is honest degradation — UNLESS it carries a
    // signature, which must never leave this function.
    const looksSigned = /[?&](x-amz-|token=|signature=|sig=|expires=)/i.test(state.result_url);
    if (looksSigned) {
      return json({
        status: "failed",
        error: "The clip was generated but could not be stored — try again.",
        error_class: "upstream",
      });
    }
    videoUrl = state.result_url;
  }

  return json({
    status: "completed",
    video_url: videoUrl,
    provider: job.p,
    model: job.m,
    persisted: assetKey !== null,
    ...(assetKey ? { asset_key: assetKey } : {}),
    // Same additive quality-gate block as the legacy path above, for the same
    // reason: persisted is not the same as approved.
    drift: uncheckedDriftBlock(),
  });
}

// ── The quality gate: validation, routing, and the judge call ────────────────
//
// The pure half of this feature — the rubric, the thresholds, the parser, the
// decision and the response shape — is _shared/drift.ts, which is where the
// reasoning and the cost arithmetic live and where the tests point. What is
// below is the part that touches the network, the router and the database, and
// therefore cannot be unit-tested in this repo's no-network house style.

/**
 * Per-image and per-body ceilings.
 *
 * The generate routes allow 12,000,000 base64 characters for ONE image because
 * that image is the product. A judge frame is not: it exists to be looked at by
 * a vision model that down-samples it anyway, and the app already produces
 * exactly the right thing — PosterMaker writes a 1280 px JPEG at quality 0.8,
 * which is around 250 KB, i.e. ~340,000 base64 characters. 2,000,000 characters
 * is six times that headroom per image and still bounds a four-image body at
 * roughly 8 MB, which is what MAX_DRIFT_BODY_BYTES leaves room for. Sending
 * bigger frames buys no better verdict and costs input tokens on every call.
 */
const MAX_DRIFT_IMAGE_B64_CHARS = 2_000_000;
const MAX_DRIFT_BODY_BYTES = 12_000_000;

/** The judge answers one small JSON object. 400 tokens is what the Python
 *  gate caps its own structured verdict at (QC_MAX_OUTPUT_TOKENS), and output
 *  tokens on a vision call cost roughly 5× input. */
const DRIFT_MAX_TOKENS = 400;

/** The clip's provider request id: bounded, printable, and never interpolated
 *  into anything but a rate-limit key and an audit field. */
function cleanRequestId(raw: unknown): string {
  const s = String(raw ?? "").trim();
  assert(s.length > 0, 400, "request_id is required — send the id the clip's 202 returned");
  assert(s.length <= 200, 400, "request_id is too long");
  assert(/^[A-Za-z0-9._:-]+$/.test(s), 400, "request_id has characters that are not part of a job id");
  return s;
}

interface DriftImage {
  b64: string;
  mime: string;
}

/** One image out of the body, bounded and MIME-checked exactly as the generate
 *  routes check their inline photo. */
function requireDriftImage(b64: unknown, mime: unknown, field: string): DriftImage {
  assert(typeof b64 === "string" && b64.length > 0, 400, `${field} is required`);
  const s = b64 as string;
  assert(
    s.length <= MAX_DRIFT_IMAGE_B64_CHARS,
    413,
    `${field} is too large — send the 1280 px frame the app already makes, not the full-size image`,
    "payload_too_large",
  );
  const m = String(mime ?? "image/jpeg").split(";")[0].trim().toLowerCase();
  assert(ALLOWED_IMAGE_MIMES.includes(m), 400, `${field} mime must be one of ${ALLOWED_IMAGE_MIMES.join(", ")}`);
  return { b64: s, mime: m };
}

interface DriftFrame extends DriftImage {
  at: DriftFramePosition;
}

/**
 * The frames to judge, in clip order, de-duplicated by position.
 *
 * ORDER IS MEANING here: the judge is told these are the first, middle and last
 * of the clip, and drift is cumulative, so a shuffled list would tell it the
 * wrong story about when the invention started. The array is therefore sorted
 * into DRIFT_FRAME_POSITIONS order rather than trusted as sent.
 *
 * A body with none of them is a 400. A body with more than one frame at the
 * same position keeps the first: it is a client bug, and silently paying for a
 * fourth and fifth image would be the wrong way to discover it.
 */
function cleanDriftFrames(raw: unknown): DriftFrame[] {
  assert(
    Array.isArray(raw),
    400,
    "frames is required — send the finished clip's " +
      `${DRIFT_FRAME_POSITIONS.join(", ")} frames as an array of { at, b64 }`,
  );
  const rows = raw as Array<Record<string, unknown>>;
  assert(
    rows.length > 0 && rows.length <= DRIFT_MAX_FRAMES + 2,
    400,
    `frames must hold between 1 and ${DRIFT_MAX_FRAMES} entries (${DRIFT_FRAME_POSITIONS.join(", ")})`,
  );
  const byPosition = new Map<DriftFramePosition, DriftFrame>();
  for (const row of rows) {
    if (!row || typeof row !== "object") continue;
    const at = String(row.at ?? "").trim().toLowerCase();
    if (!(DRIFT_FRAME_POSITIONS as readonly string[]).includes(at)) continue;
    const position = at as DriftFramePosition;
    if (byPosition.has(position)) continue;
    const img = requireDriftImage(row.b64, row.mime, `frames[${position}].b64`);
    byPosition.set(position, { at: position, ...img });
  }
  const ordered = DRIFT_FRAME_POSITIONS.map((p) => byPosition.get(p)).filter((f): f is DriftFrame => !!f);
  assert(
    ordered.length > 0,
    400,
    `frames needs at least one entry whose \`at\` is one of ${DRIFT_FRAME_POSITIONS.join(", ")}`,
  );
  return ordered;
}

/**
 * The camera-move sentence for the rubric, resolved through the SAME enums the
 * generate routes use — so what reaches the model is our own frozen text, never
 * the caller's string. An unrecognised move answers null and the rubric simply
 * omits the clause, exactly as normalizeRoom() degrades rather than refusing.
 */
function driftMotionText(kind: GenKind, raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const s = raw.trim().toLowerCase();
  if (kind === "aerial" && (AERIAL_MOTIONS as readonly string[]).includes(s)) {
    return AERIAL_MOTION_TEXT[s as AerialMotion];
  }
  const reel = parseReelMotion(s);
  return reel ? REEL_MOTION_TEXT[reel] : null;
}

/**
 * The org's plan, for the router's RouteContext ONLY — never for access.
 *
 * `entitlementFor()` and not `entitlementForCharge()`, for ai-copy's reason
 * exactly: the -ForCharge variant turns a degraded plan lookup into a 503 to
 * protect a charge, and there is no charge here worth protecting — the clip is
 * already generated and already billed. A plan-table blip must not be the
 * reason a clip goes out unverified. Every judge.qc_drift row is min_plan
 * 'free', so the plan can only ever pick a POLICY, never access.
 */
async function driftRoutingPlan(orgId: string): Promise<string> {
  try {
    return (await entitlementFor(orgId)).plan;
  } catch (e) {
    console.error("ai-video: plan lookup failed; routing the drift check as free:", e instanceof Error ? e.message : e);
    return "free";
  }
}

/**
 * The in-code chain, mirroring rows 1 and 2 of `judge.qc_drift` in migration
 * 0018 verbatim (claude-haiku-4-5 at 0.66¢, claude-sonnet-5 at 1.3¢). Same
 * shape and same purpose as ai-copy's fallbackStep(): with the router flag off,
 * resolveRoute() looks for a `note='legacy'` row, this task deliberately has
 * none (0028's argument — a new task has no prior behaviour to preserve), so
 * the answer is `[]` and this is what runs.
 */
function driftFallbackStep(position: 1 | 2): RouteStep {
  const primary = position === 1;
  return {
    route_id: `qc-drift-fallback-${primary ? "haiku" : "sonnet"}`,
    task: DRIFT_TASK,
    provider: "anthropic",
    model: primary ? "claude-haiku-4-5" : "claude-sonnet-5",
    unit: "call",
    unit_cents: primary ? DRIFT_FALLBACK_CENTS.primary : DRIFT_FALLBACK_CENTS.escalation,
    capabilities: ["classifier", "vision", "multi_image"],
    max_latency_s: 60,
    min_plan: "free",
    same_model_as: null,
    privacy_tier: "retained_30d",
    enabled: true,
  };
}

/** Today's chain for the drift judge. Used AS RETURNED (contract §4, rule 2). */
async function driftChain(plan: string): Promise<RouteStep[]> {
  try {
    const steps = await resolveRoute(DRIFT_TASK, {
      plan,
      // The three capabilities 0018 actually seeds on every judge.qc_drift row.
      // ctx.needs is a hard AND, so asking for more than the rows advertise
      // would empty the chain; asking for less would let a text-only step
      // through and it would fail on the first image block.
      needs: ["classifier", "vision", "multi_image"],
      // These are photographs of somebody's home. The router drops
      // trains_by_default steps outright for media that carries them.
      carries_customer_media: true,
    });
    if (steps.length > 0) return steps;
  } catch (e) {
    console.error("ai-video: resolveRoute(judge.qc_drift) threw; using the in-code chain:", e instanceof Error ? e.message : e);
  }
  return [driftFallbackStep(1), driftFallbackStep(2)];
}

/** A text block or an image block, in the order the judge should read them. */
type DriftPart = { text: string } | { image: DriftImage };

/**
 * ONE judge call against ONE routing step.
 *
 * An unknown provider is error_class "other", NOT "validation", so runChain()
 * fails over to the next vendor instead of hard-failing the whole check over an
 * admin-added row this deploy cannot speak — the same choice ai-copy's
 * callStep() makes and for the same reason. gemini is deliberately not handled:
 * 0018 seeds no gemini step on this task, and _shared/providers/gemini.ts is an
 * image-GENERATION adapter, so pretending otherwise would produce a confusing
 * failure at the first image block rather than a clean failover.
 */
async function callJudgeStep(step: RouteStep, rubric: string, parts: DriftPart[]): Promise<string> {
  if (step.provider === "anthropic") {
    const content: ContentBlock[] = parts.map((p) =>
      "text" in p ? { type: "text" as const, text: p.text } : imageBlock(p.image.b64, p.image.mime)
    );
    // assertNotCoveredModel() runs inside anthropicMessages: a Covered Model
    // must never receive a photograph of a customer's home, and these are four
    // of them.
    return await anthropicMessages({ model: step.model, system: rubric, content, maxTokens: DRIFT_MAX_TOKENS });
  }
  if (step.provider === "openai") {
    const content = [
      { type: "input_text", text: rubric },
      ...parts.map((p) =>
        "text" in p
          ? { type: "input_text", text: p.text }
          : { type: "input_image", image_url: `data:${p.image.mime};base64,${p.image.b64}` }
      ),
    ];
    return await openaiChat(step.model, [{ role: "user", content }], {
      json: true,
      maxOutputTokens: DRIFT_MAX_TOKENS,
    });
  }
  throw new ProviderError(
    step.provider,
    "other",
    `${DRIFT_TASK}: no vision adapter for provider "${step.provider}" in this deploy`,
  );
}

interface JudgeCall {
  step: RouteStep;
  escalated: boolean;
}

interface JudgeOutcome {
  verdict: DriftVerdict;
  /** Every call actually made — one cost_ledger row each. */
  calls: JudgeCall[];
  /** The step whose verdict is being returned, or null when none answered. */
  step: RouteStep | null;
  escalated: boolean;
  /** SHA-256 of the source still, for the audit row. */
  sourceHash: string;
}

/**
 * Run the check.
 *
 * TWO TIERS, NOT A FAILOVER CHAIN — the same distinction 0018 draws for
 * judge.fair_housing ("resolveRoute() still returns them in order; the caller
 * decides"). runChain() drives each tier, so a vendor outage still fails over
 * and every attempt is still reported to the circuit breaker; but the SECOND
 * tier is entered on LOW CONFIDENCE, not on failure, which is what 0018's own
 * note on row 2 ("escalation, and the standing successor") describes and what
 * services/pipeline/router.py has done for photos since it shipped. The
 * arithmetic for why escalating beats treating "not sure" as a failure is in
 * _shared/drift.ts.
 *
 * FAILS CLOSED. If the whole chain throws — every provider down, no API key, a
 * Covered Model refusal, a timeout — this returns unavailableVerdict(), which
 * routes to "hold": not published, not regenerated, re-checkable. It never
 * throws, because the caller must always be able to answer the client with a
 * drift block, and an error the app surfaces as "network problem" is exactly
 * how an unchecked clip gets published anyway.
 */
async function judgeDrift(args: {
  plan: string;
  subject: { kind: "reel" | "aerial"; sceneNoun: string; motionText: string | null };
  source: DriftImage;
  frames: DriftFrame[];
}): Promise<JudgeOutcome> {
  const sourceHash = await driftLineageKey(args.source.b64);
  const rubric = driftRubric(args.subject);
  const parts: DriftPart[] = [
    { text: DRIFT_SOURCE_LABEL },
    { image: args.source },
    { text: driftFramesLabel(args.frames.map((f) => f.at)) },
    ...args.frames.map((f) => ({ image: { b64: f.b64, mime: f.mime } })),
  ];

  const steps = await driftChain(args.plan);

  let primary: ChainResult<string>;
  try {
    primary = await runChain(DRIFT_TASK, steps, (step) => callJudgeStep(step, rubric, parts));
  } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    console.error("ai-video: the drift judge could not be reached:", why);
    return {
      verdict: unavailableVerdict(
        "The quality check could not reach its model, so this clip has not been verified.",
      ),
      calls: [],
      step: null,
      escalated: false,
      sourceHash,
    };
  }

  const calls: JudgeCall[] = [{ step: primary.step, escalated: false }];
  let verdict = parseDriftVerdict(primary.value);
  let step = primary.step;
  let escalated = false;

  // The escalation tier: the steps AFTER the one that just answered. An empty
  // remainder (the cheap judge was already the last step) simply means the
  // low-confidence verdict stands, which is the pipeline's own behaviour when
  // it cannot afford to escalate.
  if (verdict.confidence < ESCALATE_BELOW_CONFIDENCE) {
    const at = steps.indexOf(primary.step);
    const rest = at >= 0 ? steps.slice(at + 1) : [];
    if (rest.length > 0) {
      try {
        const second = await runChain(DRIFT_TASK, rest, (s) => callJudgeStep(s, rubric, parts));
        calls.push({ step: second.step, escalated: true });
        verdict = parseDriftVerdict(second.value);
        step = second.step;
        escalated = true;
      } catch (e) {
        // Keep the cheap judge's answer. It is a real verdict from a real
        // model; the escalation was an upgrade we could not buy, not a reason
        // to throw away what we already paid for.
        console.error("ai-video: drift escalation failed; keeping the first verdict:", e instanceof Error ? e.message : e);
      }
    }
  }

  return { verdict, calls, step, escalated, sourceHash };
}

/**
 * Stamp the verdict onto the media_provenance row (migration 0029).
 *
 * SERVICE ROLE, deliberately. record_provenance() is called as the CALLER
 * because the agent is the one asserting "I generated this"; a QC verdict is
 * the opposite — it is evidence ABOUT the agent's media, and a tenant who can
 * write their own passing score has evidence worth nothing. So 0029 grants
 * record_media_qc() to service_role only and takes the org id explicitly, and
 * this passes the org the caller's JWT resolved to, never one from the body.
 *
 * Best effort and never throws, exactly like recordProvenance(): the verdict is
 * already in the response and already in cost_ledger.
 */
async function stampProvenanceQc(
  orgId: string,
  provenanceId: string,
  qc: Record<string, unknown>,
): Promise<boolean> {
  try {
    const { error } = await adminClient().rpc("record_media_qc", {
      p_id: provenanceId,
      p_org: orgId,
      p_qc: qc,
    });
    if (error) {
      console.error("ai-video: record_media_qc failed:", error.message);
      return false;
    }
    return true;
  } catch (e) {
    console.error("ai-video: record_media_qc threw:", e instanceof Error ? e.message : e);
    return false;
  }
}

// ── fal queue helpers ─────────────────────────────────────────────────────────

function falHeaders(): Record<string, string> {
  if (!FAL_KEY) throw new HttpError(500, "FAL_KEY function secret is not set", "internal");
  return { "Authorization": `Key ${FAL_KEY}`, "Content-Type": "application/json" };
}

/** Submit to the fal queue; return fal's own ids/URLs verbatim. */
async function falSubmit(
  modelId: string,
  input: Record<string, unknown>,
): Promise<{ request_id: string; status_url: string; response_url: string }> {
  const res = await fetch(`${FAL_QUEUE_BASE}/${modelId}`, {
    method: "POST",
    headers: falHeaders(),
    body: JSON.stringify(input),
  });
  const data = await res.json().catch(() => ({} as Record<string, unknown>));
  if (!res.ok) {
    throw new HttpError(502, `fal submit failed (${modelId}, HTTP ${res.status}): ${JSON.stringify(data).slice(0, 400)}`, "upstream");
  }
  const { request_id, status_url, response_url } = data as Record<string, unknown>;
  if (!request_id || !status_url || !response_url) {
    throw new HttpError(502, `Unexpected fal submit response (${modelId}): ${JSON.stringify(data).slice(0, 400)}`, "upstream");
  }
  return {
    request_id: String(request_id),
    status_url: String(status_url),
    response_url: String(response_url),
  };
}

/**
 * SSRF guard: the status route fetches caller-supplied URLs with OUR fal key,
 * so only https URLs on fal's own queue hosts are allowed.
 */
function requireFalUrl(raw: string | null, name: string): string {
  assert(raw, 400, `${name} query param is required`);
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new HttpError(400, `${name} is not a valid URL`);
  }
  const host = url.hostname.toLowerCase();
  const allowed = url.protocol === "https:" &&
    (host === "queue.fal.run" || host.endsWith(".fal.run"));
  if (!allowed) {
    throw new HttpError(400, `${name} must be an https URL on queue.fal.run / *.fal.run`);
  }
  return url.toString();
}

/** Pull the output video URL out of the known fal result shapes. */
// deno-lint-ignore no-explicit-any
function extractVideoUrl(result: any): string | null {
  const v = result?.video; // Topaz / Bria / Veo / Seedance: { video: { url } }
  if (typeof v === "string") return v;
  if (v && typeof v.url === "string") return v.url;
  const vids = result?.videos;
  if (Array.isArray(vids) && vids.length > 0) {
    const first = vids[0];
    if (typeof first === "string") return first;
    if (first && typeof first.url === "string") return first.url;
  }
  if (typeof result?.video_url === "string") return result.video_url;
  return null;
}

/** Last few log lines from a fal status body (?logs=1). */
function logsTail(st: Record<string, unknown>): string[] {
  const logs = Array.isArray(st.logs) ? st.logs : [];
  return logs
    .slice(-5)
    .map((l) => String((l as Record<string, unknown>)?.message ?? ""))
    .filter((m) => m.length > 0);
}

/** Best-effort human-readable error for a FAILED fal job. */
async function failureError(st: Record<string, unknown>, responseUrl: string): Promise<string> {
  try {
    const res = await fetch(responseUrl, { headers: falHeaders() });
    const body = await res.json().catch(() => null);
    if (body && typeof body === "object") {
      // deno-lint-ignore no-explicit-any
      const detail = (body as any).detail ?? (body as any).error ?? (body as any).message;
      if (detail) {
        return (typeof detail === "string" ? detail : JSON.stringify(detail)).slice(0, 500);
      }
    }
  } catch {
    // fall through to logs
  }
  const tail = logsTail(st);
  if (tail.length > 0) return tail.join(" | ").slice(0, 500);
  return `fal reported status ${String(st.status ?? "FAILED")}`;
}

// ── asset resolution ──────────────────────────────────────────────────────────

interface ResolvedAsset {
  id: string;
  /** The listing the asset belongs to — the provenance row's anchor (W2-B3). */
  listing_id: string | null;
  kind: string;
  url: string;
  duration_s: number | null;
  width: number | null;
  height: number | null;
  fps: number | null;
  space_type: string | null;
}

/**
 * Load a capture_assets row (RLS applies via the user client) and require a
 * fal-fetchable PUBLIC URL: uploaded + bucket "renders" + configured public base.
 * The asset must belong to the org the quota is charged to (X-Org-Id / default):
 * a two-org user must not spend org A's allowance on org B's asset (F-supabase-35).
 */
// deno-lint-ignore no-explicit-any
async function resolvePublicAsset(db: any, assetId: string, req: Request): Promise<ResolvedAsset> {
  const { data, error } = await db
    .from("capture_assets")
    .select("id, listing_id, kind, bucket, storage_key, uploaded, duration_s, width, height, fps, listings!inner(org_id, space_type, deleted_at)")
    .eq("id", assetId)
    .maybeSingle();
  if (error) throw new HttpError(400, `Asset lookup failed: ${error.message}`);
  if (!data) throw new HttpError(404, "Asset not found");
  assert(data.uploaded === true, 409, "Asset upload is not complete");
  const listing = (Array.isArray(data.listings) ? data.listings[0] : data.listings) as
    | { org_id: string; space_type: string | null; deleted_at: string | null }
    | undefined;
  if (!listing || listing.deleted_at) throw new HttpError(404, "Asset not found");

  const preferred = preferredOrg(req);
  if (preferred && preferred !== listing.org_id) {
    throw new HttpError(403, "This asset belongs to a different workspace than X-Org-Id");
  }

  if (data.bucket !== "renders") {
    throw new HttpError(
      400,
      `Asset ${assetId} is in the private "${data.bucket ?? "uploads"}" bucket, so fal cannot ` +
        `fetch it. Upload it to the public renders bucket first (POST /uploads with ` +
        `role:"render"), or pass image_b64 where the route supports it.`,
    );
  }
  const url = publicR2Url(data.storage_key as string);
  if (!url) {
    throw new HttpError(
      500,
      "R2_PUBLIC_BASE_URL is not configured on the server, so no public URL can be built " +
        "for this asset. Set the R2_PUBLIC_BASE_URL function secret to the renders bucket's public base.",
      "internal",
    );
  }
  const num = (v: unknown) => (v == null || !Number.isFinite(Number(v)) ? null : Number(v));
  return {
    id: data.id as string,
    listing_id: (data.listing_id as string | null) ?? null,
    kind: data.kind as string,
    url,
    duration_s: num(data.duration_s),
    width: num(data.width),
    height: num(data.height),
    fps: num(data.fps),
    space_type: listing.space_type ?? null,
  };
}

/** Trimmed non-empty prompt, or undefined. */
function cleanPrompt(p: string | undefined): string | undefined {
  const t = (p ?? "").trim().slice(0, 600);
  return t.length > 0 ? t : undefined;
}
