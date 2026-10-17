import { requireLibraryWrite, libraryBillingOrg, listingLibraryScope } from "../_shared/library-access.ts";
import { fundingContext, fundedAttempt, completeFundingOperation, FundingAdmissionError, textAttemptQuote, routeCatalogQuote, ceilingVerifiedQuote, visionInputTokenBound, unlimitedSponsored, type FundingContext } from "../_shared/funded-serving.ts";
import { beginDriftCheck, finishDriftCheck } from "./drift-funding.ts";
// ai-video — server-side AI video suite on fal.ai (owner-authenticated).
//
// ASYNC SUBMIT/STATUS pattern: edge functions can't babysit multi-minute GPU
// jobs (CPU/wall limits), so every generate route SUBMITS to fal's queue and
// returns 202 with fal's own { request_id, status_url, response_url } VERBATIM.
// The app polls GET /ai-video/status with those URLs until completed/failed.
// Reflection removal uses durable jobs in erase.ts; other legacy routes retain
// the stateless transport described below.
//
//   POST /ai-video/drone      { asset_id, tier?: "1080p60"|"4k30"|"4k60", target_fps? }
//       Topaz Video AI upscale+interpolation → buttery "drone glide" master.
//       upscale_factor / target_fps are computed from the ASSET's probed
//       width/height/fps and the tier (never blindly 2× — a 4K source at "4k30"
//       used to be sent as 8K, audit F-supabase-17). The most expensive tap in
//       the product, and the one with hard COST CEILINGS — see COST SAFETY
//       below and ./dronecost.ts. The 202 carries `estimated_cost`.
//   POST /ai-video/declutter  { asset_id, listing_id, batch_id, purpose:"reflection_removal", prompt? }
//       Stable UUID Idempotency-Key required. Bria source must be <5s.
//   GET /ai-video/declutter/quote?listing_id=...
//   POST /ai-video/declutter/cancel { request_id | batch_id }
//   POST /ai-video/declutter/apply { batch_id, original_asset_id, altered_asset_id }
//       Apply records truthful linked video provenance only after user acceptance.
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
// Needs the FAL_KEY function secret + the shared private R2 signer environment.
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
// PROVENANCE. `aerial` and `reel-clip` record one media_provenance
// row (migration 0012) at SUBMIT time — the fal job is async, so the row is
// written when we know the model, the kind and the disclosure, and the app
// attaches the finished asset later via PATCH /me/compliance/:id. The 202 body
// carries `disclosure` and `provenance`. `aerial` discloses with HousingWire's
// exact wording: "Drone-style movement is simulated. No drone footage was
// captured." — the sentence the app and both tour pages must show.
// Reflection removal records a full original/edited video pair only at explicit
// acceptance, after every selected clip has completed (erase.ts + migration0055).
// `drone` (Topaz upscale + frame interpolation) is deliberately NOT recorded:
// it re-times and sharpens footage the agent actually captured, which is the
// basic-enhancement carve-out in CA AB 723, not synthesis. Revisit if Topaz
// ever gains a generative mode.
//
// ── COST SAFETY on /drone ────────────────────────────────────────────────────
//
// Estimate the output from an immutable source's checked headers before any allowance
// or paid POST. A requested 1080p tier does not downscale a 4K source: Topaz's
// minimum factor is one, so its rate must still be the above-1080p rate.
// The bounded MP4 probe supplies container geometry, duration and frame cadence;
// it does not decode sample payloads. Client-upload hints never price this route. Unknown/unsupported media and
// output above 60 fps are refused because their tariff is not verified.
// ./dronecost.ts applies the 300-second, 4096-pixel-long-edge and $48 ceilings.
// guardGenerate performs the monthly precheck, then submitReservedVideo locks
// the workspace and commits a 16c/s maximum-published-tariff hold BEFORE one provider POST.
// An accepted receipt swaps the hold for one estimated ledger row. Uncertain
// acceptance or failed settlement retain the hold; neither triggers a retry.
// These are published-rate estimates, not reconciled provider invoices or a
// complete subscription margin fence (hosting and other AI paths are separate).
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
import { adminClient, assertPaidAiIdentity, getUser, type PaidAiCaller, listingSpaceType, orgForUser, contentOrgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";
import { durableRateLimit, refundRateLimit, chargeRateReceipt, refundRateReceipt, type RateChargeReceipt } from "../_shared/ratelimit.ts";
import { requiredIdempotencyKey } from "../_shared/idempotency.ts";
import { entitlementFor, entitlementForCharge, quotaError } from "../_shared/entitlements.ts";
import { assertFairHousing, FAIR_HOUSING_LOCK, GUARDRAILS } from "../_shared/fairhousing.ts";
import { optionalUuid, recordProvenance, type ProvenanceArgs, type ProvenanceResult } from "../_shared/provenance.ts";
import {
  DRIFT_SOURCE_EXTRA_INPUT_TOKENS,
  MAX_DRIFT_FRAME_B64_CHARS,
  MAX_DRIFT_REQUEST_BODY_BYTES,
  MAX_DRIFT_SOURCE_B64_CHARS,
  validateExtendedReelSource,
} from "./drift-input.ts";
import { APP_AI_UNIT_CENTS, recordAppAiCost, recordRoutedAiCost } from "../_shared/ledger.ts";
import type { RouteStep } from "../_shared/router.ts";
import { paramsOf, resolveRoute, routerEnabled } from "../_shared/router.ts";
import { adapterFor } from "../_shared/providers/index.ts";
import type { JobState } from "../_shared/providers/types.ts";
import { asHttpError, type ChainResult, resolveChain, runChain } from "../_shared/providers/chain.ts";
import { BUDGETS, fetchBounded, ProviderError } from "../_shared/providers/common.ts";
import { type ContentBlock, anthropicMessages, imageBlock } from "../_shared/providers/anthropic.ts";
import { openaiChat } from "../_shared/providers/openai.ts";
import { falResultErrorReason, falResultReadIssue, falCompletedFailure, falLegacyReceipt, falLegacyReceiptMatchesModel } from "../_shared/providers/fal.ts";
import { persistResult, persistedUrl, putBytes, presignGet } from "../_shared/providers/common.ts";
import { R2_BUCKET_RENDERS,R2_BUCKET_UPLOADS,headObject } from "../_shared/r2.ts";
import { verifyPropertyVideoInput } from '../_shared/property-video.ts';
import { recordDirectPropertyVideoSource } from './property-source-provenance.ts';
import { createEraseHandler, extractEraseJob, readEraseConfig } from "./erase.ts";
import { renewEraseOutput } from "./erase-output.ts";
import { privateMediaUrl } from "../_shared/private-media.ts";
import { createRoutedOutput } from "./routed-output.ts";
import { createBriaAdapter } from "./bria.ts";
import { submitReservedVideo, VideoDispatchUnconfirmed } from "./cost-reservation.ts";
import { recoverVideoOperation, retainVideoSubmission } from "./operation-recovery.ts";
import { ownerQaReelStep, prepareOwnerQaReelInput } from "./owner-reel-qa.ts";
import { OWNER_RAIL_MOTION_PROFILE } from "../_shared/property-motion-profile.ts";
import {PROPERTY_VIDEO_QUALITY_PROFILE,PROPERTY_VIDEO_STEADY_PROFILE,isPropertyVideoQualityProfile,currentPropertyVideoQualityProfile,propertyVideoQualityProfile,propertyVideoQualitySteps,assertKiePropertyDispatchScope,kiePropertyExtra,kiePropertyPricedBasis,kiePropertyProviderInput,readPinnedRoute,samePinnedKieDispatch,type PropertyVideoQualityProfile} from "./property-video-quality.ts";
import {KIE_PROPERTY_IDENTITY,KIE_PROPERTY_ROUTE_ID,kiePropertyPromptPinned} from "../_shared/property-video-kie.ts";
import { buildPhotoPreservingReelPrompt, buildPropertyCanvasReelPrompt,buildSteadyPropertyReelPrompt, parseReelFraming, reelFramingSteps } from "./reel-framing.ts";
import { probeMP4Video } from "./mp4video.ts";
import type { GenerateInput, JobRef } from "../_shared/providers/types.ts";
import {
  decodeJobToken,
  extractJobToken,
  type JobTokenOwner,
  type RouterJobToken,
  routerStatusUrl,
  assertPublicSupabaseOrigin,
  assertJobTokenSigningReady,
  verifyJobTokenForRecovery,
  isExpired,
} from "../_shared/providers/jobtoken.ts";
import {
  assertDroneWithinLimits,
  assertMonthlyHeadroom,
  droneReservation,
  DRONE_TIER_CENTS,
  DRONE_TIERS,
  type DroneEstimate,
} from "./dronecost.ts";
import {
  AERIAL_MOTION_TEXT,
  AERIAL_MOTIONS,
  type AerialMotion,
  buildReelPrompt,
  buildSeedanceReelPreset,
  REEL_PRESETS,
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
// One eight-photo reel can need two bounded attempts per photo. Keep that
// legitimate batch below the denial-of-wallet burst gate even when an earlier
// monthly QC-refund cap prevents restoring a rejected attempt's burst receipt.
const REEL_MAX_PER_WINDOW = 20;
const GEN_WINDOW_SECONDS = 300;
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
  monthlyReceipt: RateChargeReceipt;
  burstReceipt: RateChargeReceipt;
}

/** New Aerial generation is private beta only. Existing receipts/status/QC
 * remain outside this entry gate. Resolve current write access and the real
 * billing authority before reading the existing sponsorship, without taking
 * an allowance, idempotency tombstone or supplier-cost hold. */
async function assertAerialLaunchAccess(user: PaidAiCaller, req: Request, listingId?: string | null): Promise<string> {
  const orgId = await contentOrgForUser(user.id, preferredOrg(req), listingId, true);
  await assertPaidAiIdentity(user, orgId);
  const admin = adminClient();
  const billingOrgId = await libraryBillingOrg(admin, orgId, user.id);
  if (!await unlimitedSponsored({ orgId: billingOrgId, rpc: (name, args) => admin.rpc(name, args) }))
    throw new HttpError(503, "Aerial intro is Coming soon.", "upstream");
  return orgId;
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
 * `projectedCents` — when the caller can reserve a conservative submission
 * cost up front (today /drone) — is checked
 * against the org's EXISTING monthly COGS ceiling BEFORE any meter is consumed,
 * so a submission that cannot fit the budget burns no allowance on its way to
 * being refused. See assertMonthlyHeadroom() in ./dronecost.ts for why this is
 * a pre-flight of log_job_cost()'s own check rather than a second ceiling.
 */
async function guardGenerate(
  user: PaidAiCaller,
  req: Request,
  kind: GenKind,
  projectedCents?: number,
  sourceOrgId?: string,
  sourceListingId?: string,
): Promise<GenerateCharge> {
  const userId = user.id;
  const orgId = await contentOrgForUser(userId, sourceOrgId ?? preferredOrg(req), sourceListingId, true);
  const admin = adminClient();

  await assertPaidAiIdentity(user, orgId);

  // A degraded plan lookup is a 503 here, never a 402 (audit F-E-02).
  const ent = await entitlementForCharge(orgId);
  const monthlyCap = capFor(kind, ent);

  // A zero allowance is a PLAN BOUNDARY, not a rate limit — 402 `plan_required`
  // so the app shows an upgrade prompt instead of "try again later". This is
  // what keeps Topaz (up to $48 reserved per tap) off the cheap plans.
  if (monthlyCap <= 0) throw quotaError(labelFor(kind), 0, 0, ent.plan);

  // PROJECTED SPEND vs the org's monthly COGS ceiling. Ordered AFTER the plan
  // boundary above (a plan that doesn't include the feature must still read as
  // `plan_required`, not as a budget problem) and BEFORE every meter below, so
  // a refusal here costs the org nothing to recover from.
  if (projectedCents != null && projectedCents > 0) {
    assertMonthlyHeadroom({
      monthSpentCents: await orgMonthSpendCents(admin, orgId, userId),
      ceilingCents: ent.cogs_ceiling_cents,
      projectedCents,
      plan: ent.plan,
      feature: labelFor(kind),
    });
  }

  // A caller-selected key is required; a duplicate submit inside 2 minutes
  // is rejected instead of double-billed.
  // NOT refunded on failure, deliberately (mirrors ai-chapters/index.ts
  // guardChapters): it is a short dedupe guard, not spend.
  const idem = requiredIdempotencyKey(req);
  if (!(await durableRateLimit(`aividem:${orgId}:${idem}`, 1, 120))) {
    throw new HttpError(409, "Duplicate submission — this job was already started.", "conflict");
  }
  const billingOrgId = await libraryBillingOrg(admin, orgId, userId);
  const burstKey = `aivideo:${billingOrgId}`;
  const monthlyKey = `${meterKeyFor(kind)}:${billingOrgId}`;
  const burstCap = kind === "reel" ? REEL_MAX_PER_WINDOW : GEN_MAX_PER_WINDOW;
  const burst = await chargeRateReceipt(burstKey, burstCap, GEN_WINDOW_SECONDS);
  if (!burst.accepted) {
    throw new HttpError(429, "AI video generation limit reached for now — try again in a few minutes.", "rate_limited");
  }
  const monthly = await chargeRateReceipt(monthlyKey, monthlyCap, MONTH_SECONDS);
  if (!monthly.accepted) {
    await refundRateReceipt(burst.receipt);
    throw quotaError(labelFor(kind), monthlyCap, monthlyCap, ent.plan);
  }
  // The effective plan rides along for the router's RouteContext — it is the
  // number entitlementForCharge() just read, not a second lookup.
  return { orgId, plan: ent.plan, monthlyKey, burstKey, monthlyReceipt: monthly.receipt, burstReceipt: burst.receipt };
}

/**
 * Hand back everything a submission that never reached the provider charged
 * (audit item 2 / F-E-16, mirrors ai-chapters/index.ts refundCharge exactly).
 *
 * Call only before dispatch or after a definitive non-allocation whose priced
 * hold release was confirmed. A thrown POST can have
 * been accepted remotely, so VideoDispatchUnconfirmed keeps BOTH its priced
 * hold and allowance. Once a receipt returns the expense is committed;
 * a later async failure never automatically refunds its original allowance.
 *
 * Best effort and never throws — see refundRateLimit().
 */
async function refundGenerateCharge(charge: GenerateCharge): Promise<void> {
  await refundRateReceipt(charge.monthlyReceipt);
  await refundRateReceipt(charge.burstReceipt);
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
// SQL app_video_refund_drift caps current-window refunds at 20.

/** Role gate + burst limiter for the check. Mirrors ai-copy's guardAssist(). */
async function guardDriftCheck(user: PaidAiCaller, req: Request, listing?: string): Promise<string> {
  const userId = user.id;
  const orgId = listing ? await contentOrgForUser(userId, preferredOrg(req), listing, true) : await orgForUser(userId, preferredOrg(req));
  await requireLibraryWrite(adminClient(), userId, orgId);
  await assertPaidAiIdentity(user, orgId);
  if (!(await durableRateLimit(`aidrift:${orgId}`, DRIFT_MAX_PER_WINDOW, DRIFT_WINDOW_SECONDS))) {
    throw new HttpError(
      429,
      "Too many quality checks for now — try again in a few minutes.",
      "rate_limited",
    );
  }
  return orgId;
}

/** Recover a recorded terminal judgement without buying another opinion.
 * Frame JPEGs can differ when a saved clip is decoded again; the immutable
 * paid provider request, source still and current listing permission bind it.
 * A plan-allowance refund is not a refund of the settled supplier payment.
 */
async function cachedDriftResponse(args: {
  actor: string; orgId: string; requestId: string; kind: GenKind; sourceB64: string;
  listingId: string | null; provenanceId: string | null; sourceAssetId: string | null;
}): Promise<Response | null> {
  const admin = adminClient();
  const recorded = await admin.from("cost_ledger")
    .select("id,org_id,feature,provider,model,total_cents,meta,created_at")
    .eq("org_id", args.orgId).eq("feature", "qc")
    .eq("meta->>kind", "video_drift").eq("meta->>request_id", args.requestId)
    .in("meta->>action", ["accept", "retry", "refuse"])
    .order("created_at", { ascending: false }).order("id", { ascending: false }).limit(3);
  assert(!recorded.error && Array.isArray(recorded.data), 503, "The saved quality check could not be read. Retry this saved clip shortly.", "upstream");
  if (recorded.data.length === 0) return null;
  assert(recorded.data.length <= 2, 409, "This saved clip has conflicting quality records.", "conflict");

  const saved = await admin.from("app_video_cost_reservations")
    .select("id,org_id,actor_id,idempotency_key,billing_org_id,feature,provider,model,provider_request_id,cost_ledger_id,settled_at,released_at,meta")
    .eq("org_id", args.orgId).eq("actor_id", args.actor)
    .eq("provider_request_id", args.requestId).limit(2);
  assert(!saved.error && Array.isArray(saved.data), 503, "This saved video payment could not be verified.", "upstream");
  assert(saved.data.length === 1, 404, "This saved clip is unavailable for this account.", "not_found");
  const payment = saved.data[0];
  const task = args.kind === "aerial" ? "video.aerial" : "video.reel_clip";
  assert(payment.org_id === args.orgId && payment.actor_id === args.actor &&
    payment.provider_request_id === args.requestId && payment.feature === args.kind && payment.meta?.task === task &&
    payment.released_at === null && payment.cost_ledger_id && payment.settled_at && Number.isFinite(Date.parse(payment.settled_at)),
    404, "This saved clip is unavailable for this account.", "not_found");
  const allowance = await admin.from("app_video_allowance_receipts")
    .select("listing_id,drift_refunded_at").eq("reservation_id", payment.id).maybeSingle();
  assert(!allowance.error, 503, "This saved video's listing could not be verified.", "upstream");
  assert(allowance.data && allowance.data.listing_id &&
    (args.listingId === null || args.listingId === allowance.data.listing_id),
    404, "This saved clip is unavailable for this listing.", "not_found");
  const listingId = allowance.data.listing_id;
  assert(await contentOrgForUser(args.actor, args.orgId, listingId, true) === args.orgId,
    404, "This saved clip is unavailable for this listing.", "not_found");
  const settled = await admin.from("cost_ledger")
    .select("id,org_id,feature,provider,model,total_cents,meta").eq("id", payment.cost_ledger_id).maybeSingle();
  assert(!settled.error, 503, "This saved video payment could not be verified.", "upstream");
  const paid = settled.data;
  assert(paid && paid.id === payment.cost_ledger_id && paid.org_id === args.orgId && paid.feature === args.kind &&
    paid.provider === payment.provider && paid.model === payment.model && Number(paid.total_cents) > 0 &&
    paid.meta?.app_video_reservation_id === payment.id && paid.meta?.request_id === args.requestId &&
    paid.meta?.billing_org_id === args.orgId && paid.meta?.request_key === payment.idempotency_key && paid.meta?.stage === args.kind,
    404, "This saved clip's paid receipt could not be verified.", "not_found");

  const sourceHash = await driftLineageKey(args.sourceB64);
  const meta = recorded.data[0].meta;
  const identity = (m: Record<string, unknown>) => JSON.stringify([
    m.clip_kind, m.request_id, m.source_sha256, m.verdict, m.scores, m.confidence,
    m.reason, m.action, m.publishable, m.attempt, m.allowance_refunded, m.provenance_id, m.source_asset_id,
  ]);
  assert(meta && recorded.data.every((row) => row.org_id === args.orgId && row.feature === "qc" &&
    Number(row.total_cents) > 0 && row.meta?.kind === "video_drift" && row.meta?.request_id === args.requestId &&
    row.meta?.clip_kind === args.kind && row.meta?.source_sha256 === sourceHash && identity(row.meta) === identity(meta)),
    409, "The saved quality check does not match this clip and source photo.", "conflict");
  assert(meta.scores && ["architecture", "contents", "additions", "artifacts", "same_room"].every((key) =>
    typeof meta.scores[key] === "number" && Number.isFinite(meta.scores[key]) && meta.scores[key] >= 0 && meta.scores[key] <= 100) &&
    typeof meta.confidence === "number" && Number.isFinite(meta.confidence) && meta.confidence >= 0 && meta.confidence <= 1 &&
    typeof meta.reason === "string" && ["pass", "regen", "fail"].includes(meta.verdict) &&
    Number.isInteger(meta.attempt) && meta.attempt >= 0 && meta.attempt <= 3 &&
    Number.isInteger(meta.frames_judged) && meta.frames_judged >= 1 && meta.frames_judged <= DRIFT_MAX_FRAMES &&
    typeof meta.allowance_refunded === "boolean" && typeof meta.publishable === "boolean",
    409, "This saved quality check is incomplete and cannot authorize publication.", "conflict");
  const verdict = parseDriftVerdict(JSON.stringify({ ...meta.scores, confidence: meta.confidence, verdict: meta.verdict, reason: meta.reason }));
  const decision = decideDriftAction({ verdict, attempt: meta.attempt, retryGranted: meta.action === "retry" && meta.attempt === 0 });
  assert(verdict.clean && decision.action === meta.action && decision.publishable === meta.publishable &&
    (!meta.allowance_refunded || (decision.action !== "accept" && allowance.data.drift_refunded_at !== null)),
    409, "This saved quality check cannot authorize a different result.", "conflict");

  // Historical clients omitted provenance_id. A same-listing row is not an
  // immutable request binding, so recovery must not stamp newly supplied IDs.
  // Validate supplied context, then return the original ledger verdict only.
  const provenanceId = args.provenanceId ?? meta.provenance_id ?? null;
  assert(!args.provenanceId || !meta.provenance_id || args.provenanceId === meta.provenance_id,
    409, "The saved quality check belongs to another provenance record.", "conflict");
  if (provenanceId) {
    const provenance = await admin.from("media_provenance")
      .select("id,org_id,listing_id,kind,model_id").eq("id", provenanceId).maybeSingle();
    assert(!provenance.error, 503, "This saved clip's provenance could not be verified.", "upstream");
    assert(provenance.data?.org_id === args.orgId && provenance.data?.listing_id === listingId &&
      provenance.data?.kind === args.kind && provenance.data?.model_id === payment.model,
      404, "This saved clip's provenance is unavailable for this listing.", "not_found");
  }
  assert(!args.sourceAssetId || !meta.source_asset_id || args.sourceAssetId === meta.source_asset_id,
    409, "The saved quality check belongs to another source asset.", "conflict");
  const sourceAssetId = args.sourceAssetId ?? meta.source_asset_id ?? null;
  if (sourceAssetId) {
    const asset = await admin.from("capture_assets").select("id,listing_id,kind,uploaded").eq("id", sourceAssetId).maybeSingle();
    assert(!asset.error, 503, "This saved clip's source could not be verified.", "upstream");
    assert(asset.data?.listing_id === listingId && asset.data?.kind === "photo" && asset.data?.uploaded === true,
      404, "This saved clip's source is unavailable for this listing.", "not_found");
  }
  const finalCall = recorded.data.find((row) => row.meta?.escalated === true) ?? recorded.data[0];
  return json({
    drift: driftBlock({ decision, verdict, provider: finalCall.provider, model: finalCall.model,
      escalated: recorded.data.some((row) => row.meta?.escalated === true), framesJudged: meta.frames_judged, attempt: meta.attempt }),
    charge: { allowance_refunded: meta.allowance_refunded,
      note: meta.allowance_refunded ? "This rejected clip's plan allowance was already returned." : "This clip's original plan charge is unchanged.",
      retry_costs_another_clip: decision.action === "retry" && !meta.allowance_refunded },
    recorded: { ledger: 0, provenance: false }, cached: true,
    ...(typeof meta.seconds === "number" ? { seconds: meta.seconds } : {}), kind: args.kind,
  });
}

/**
 * Hand back the plan allowance a clip consumed when WE rejected that clip.
 *
 * ── Why this is not refundGenerateCharge, and must not be confused with it ───
 *
 * refundGenerateCharge exists for a submission that never reached a provider:
 * its pre-dispatch charge refund. A thrown POST is not proof of no bill. This
 * policy keeps accepted spend committed even if the async job later fails. That rule is
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
 *   2. CAPPED PER ORG PER MONTH (20, enforced atomically by SQL).
 *   3. ONLY ON A REAL FAILURE. The caller runs this exclusively for a verdict a
 *      model actually delivered and that actually failed — never for `hold`,
 *      never for a check that could not run, and never on a client's say-so:
 *      the verdict comes from `judge.qc_drift`, not from the request body.
 *
 * Best effort and never throws, exactly like refundGenerateCharge: a failed
 * refund must not turn a delivered verdict into a 500.
 */
async function refundRejectedClipAllowance(orgId: string, kind: GenKind, requestId: string, actorId: string): Promise<{ refunded: boolean; reason: string }> {
  try {
    const { data, error } = await adminClient().rpc("app_video_refund_drift", {
      p_actor: actorId, p_org: orgId, p_request: requestId,
      p_feature: kind === "drone" ? "drone_render" : kind,
    });
    if (error || typeof data?.refunded !== "boolean" || typeof data?.reason !== "string") throw new Error("Unconfirmed refund");
    return { refunded: data.refunded, reason: data.reason };
  } catch { return { refunded: false, reason: "The clip refund could not be confirmed" }; }
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
  userId: string,
): Promise<number> {
  const { data, error } = await admin.rpc("org_month_spend_cents", { p_org: await libraryBillingOrg(admin, orgId, userId) });
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
const MODEL_AERIAL_T2V = "fal-ai/veo3.1/fast";
const MODEL_I2V = "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video";

// DRONE_TIERS (output target per tier) and DRONE_TIER_CENTS (the committed
// per-output-second rate card) now live in ./dronecost.ts next to the ceilings
// that read them, so the price and the cap it feeds cannot drift apart. Both
// are imported above; nothing about their values changed.

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
 * The raw provider request_id stays unchanged. Both status links carry an
 * owner-bound signed token, including submissions with the router flag off.
 */
async function assertVideoReceiptSigningReady(): Promise<void> {
  try { assertPublicSupabaseOrigin(Deno.env.get("SUPABASE_URL")); await assertJobTokenSigningReady(); }
  catch { throw new HttpError(503,"Video submission receipts could not be secured. Please retry later.","upstream"); }
}

async function submitEnvelope(
  req: Request,
  routerOn: boolean,
  task: string,
  ref: JobRef,
  owner: JobTokenOwner,
): Promise<{ request_id: string; status_url: string; response_url: string }> {
  // Every new receipt uses an owner-bound link, including router-off FAL.
  void routerOn;
  const url = await routerStatusUrl(req, "ai-video", task, ref, { ...owner, admissionKey: requiredIdempotencyKey(req) }, Deno.env.get("SUPABASE_URL"));
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
    "Keep the architecture, fixtures, materials, colors and room layout identical. Only the camera framing may change within the photographed space. " + GUARDRAILS
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
  source_asset_id?:string;
  source_provenance_id?:string|null;
  preset_version?: number;
  /** Input-photo framing, separate from the app's portrait/landscape canvas. */
  framing?: "preserve_photo";
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
  /** Optional context; recovery must match the original paid listing. */
  listing_id?: string;
  /** Client hint: how many clips this photo has already had rejected. It may
   *  only ever make the answer stricter — see the route. */
  attempt?: number;
}

const eraseHandler = createEraseHandler({
  rpc: async (name, args) => await adminClient().rpc(name, args),
  resolveAsset: async (id, req) => await resolvePublicAsset(userClient(req), id, req),
  fetch: (url, init) => fetch(url, init),
  falKey: () => Deno.env.get("FAL_KEY")?.trim() ?? "",
  config: (req, ctx) => readEraseConfig((name) => Deno.env.get(name), req, ctx),
  bria: (config) => createBriaAdapter({
    fetch: (url, init) => fetch(url, init),
    apiToken: () => Deno.env.get("BRIA_API_TOKEN")?.trim() ?? "",
    outputHosts: Array.isArray(config.output_hosts) ? config.output_hosts as string[] : [],
  }),
  persist: async (url, key, provider, config) => {
    if (provider === "bria") {
      const adapter = createBriaAdapter({
        fetch: (input, init) => fetch(input, init),
        apiToken: () => Deno.env.get("BRIA_API_TOKEN")?.trim() ?? "",
        outputHosts: Array.isArray(config?.output_hosts) ? config.output_hosts as string[] : [],
      });
      const output = await adapter.downloadOutput(url);
      await putBytes(R2_BUCKET_RENDERS, key, output.bytes, output.mime);
    } else await persistResult("fal", { status: "done", result_url: url, mime: "video/mp4" }, key);
    return `urn:rendprop:r2:renders:${key}`;
  },
  completedURL: (job) => renewEraseOutput(job, {
    sign: (key, expires) => privateMediaUrl({actor:String(job.user_id),org:String(job.org_id),listing:null,bucket:"renders",key},expires),
    read: async (args) => await adminClient().rpc("video_erase_get", args),
  }),
});

/** Trusted in-process worker scope, built only after service job/lease authority.
 * HTTP entry below never accepts this object or an actor header. No JWT stored. */
/** Current route catalog and existing paid judge bounds; no dispatch/meter.
 * This recipe quote is a precheck, not an atomic promise of future capacity. */
export async function propertyVideoRecipeQuote(actor:string,org:string,listing:string,aspect:'16:9'|'9:16',count:number,savedProfile?:PropertyVideoQualityProfile){
 const ent=await entitlementForCharge(org),task='video.reel_clip';
 const profile=savedProfile===undefined?await currentPropertyVideoQualityProfile():propertyVideoQualityProfile(savedProfile);
  const owner=profile==='legacy'?await ownerQaReelStep({actorId:actor,orgId:org,listingId:listing,seconds:5,framing:'preserve_photo',aspect}):null;
 const candidates=isPropertyVideoQualityProfile(profile)?await propertyVideoQualitySteps(ent.plan,undefined,profile):owner?[owner]:await resolveChain(task,{plan:ent.plan,needs:['i2v','1080p','5s'],carries_customer_media:true},legacyVideoStep(task,MODEL_I2V,'second',APP_AI_UNIT_CENTS.seedance_per_s,['i2v','1080p','5s','16:9','9:16']));
 const steps=reelFramingSteps(candidates,'preserve_photo');assert(steps.length>0,503,'No supported property-video quality route is currently available.');
 // Typed profile literal (compile-checked against PropertyVideoQualityProfile).
 const kie=profile==='kie-kling3-4k-steady-v1';
 const input={task,seconds:5,resolution:'1080p',aspect,framing:'preserve_photo',extra:kie?kiePropertyExtra(aspect):{...(owner?paramsOf(owner)??{}:{}),property_video_target_aspect:aspect}};
 const step=steps[0],catalog=routeCatalogQuote(step,input),verified=ceilingVerifiedQuote(step,input,catalog);assert(catalog&&verified,503,'The complete video recipe could not be priced safely.');
 const perShot=Math.max(catalog.cents,verified.cents),rubric=driftRubric({kind:'reel',sceneNoun:'property',motionText:'X'.repeat(2000)}),judgeSteps=await driftChain(ent.plan);
 if(kie)assert(perShot===kiePropertyPricedBasis(1).attempt_cents,503,'The native-4K video recipe could not be priced exactly.');
 const quotes=judgeSteps.map(s=>textAttemptQuote(s,rubric,'',DRIFT_MAX_TOKENS,true,visionInputTokenBound(4,new TextEncoder().encode(rubric).length)+DRIFT_SOURCE_EXTRA_INPUT_TOKENS));assert(quotes.length&&quotes.every(q=>q&&Number.isFinite(q.cents)&&q.cents>0),503,'The complete video quality review could not be priced safely.');
 const perQC=2*quotes.reduce((total,q)=>total+q!.cents,0),estimated=Math.ceil((perShot+perQC)*count*10000)/10000;
 return{quality_profile:profile,source_count:count,estimated_cents:estimated,reel_cents:perShot*count,qc_cents:perQC*count,planning_cents:0,narration_cents:0,provider:step.provider,model:step.model,basis:'current_catalog_and_documented_bounds',atomic_reservation:false,...(kie?{priced_basis:kiePropertyPricedBasis(count)}:{})};
}
/** kieDispatchAuthority: the worker's per-dispatch Kie supplier authority (SQL
 * property_video_kie_dispatch_authority for this job, lease and attempt). The
 * native-4K Kie profile refuses without it; no other profile ever calls it. */
export interface AiVideoWorkerScope {user:PaidAiCaller;listing:string;targetAspect?:'16:9'|'9:16';qualityProfile?:PropertyVideoQualityProfile;qualityIdentity?:unknown;accepted?:(receipt:{request_id:string;status_url:string;response_url:string;model_id:string;seconds:number})=>Promise<void>;authorize:()=>Promise<void>;kieDispatchAuthority?:()=>Promise<unknown>;provenance:(args:ProvenanceArgs)=>Promise<ProvenanceResult>}
export async function handleAiVideo(req:Request,worker?:AiVideoWorkerScope):Promise<Response> {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const user = worker?.user ?? await getUser(req); // ordinary HTTP always validates Auth
    const db = worker ? adminClient() : userClient(req);
    const seg = pathSegments(req, "ai-video");
    if(worker){await worker.authorize();assert(seg.length===1&&((req.method==='POST'&&['reel-clip','drift'].includes(seg[0]))||(req.method==='GET'&&seg[0]==='status')),403,'This worker scope is limited to its admitted photo clip.');}
    const rpc=async(name:string,args:Record<string,unknown>)=>{if(worker&&['app_video_cost_reserve_v2','serving_cost_reserve'].includes(name))await worker.authorize();return await adminClient().rpc(name,args);};
    const provenance=(args:ProvenanceArgs)=>worker?worker.provenance(args):recordProvenance(req,args);

    if (req.method === "GET" && seg.length === 1 && seg[0] === "operation") {
      return await recoverVideoOperation(req, user.id, {
        preferredOrg, contentOrg: contentOrgForUser, rpc,
        paidReceiptMatches: job => paidRoutedReceiptMatches(job, false),
        sign: (request, ref, owner) => routerStatusUrl(request, "ai-video", "video.reel_clip", ref, owner, Deno.env.get("SUPABASE_URL")),
      });
    }

    // Reflection removal has durable, caller-scoped jobs. Other video routes
    // keep their existing status transport and allowance behavior.
    const eraseAction = seg[0] === "declutter"
      ? (req.method === "POST" && seg.length === 1 ? "submit"
        : req.method === "GET" && seg[1] === "quote" && seg.length === 2 ? "quote"
        : req.method === "POST" && seg[1] === "cancel" && seg.length === 2 ? "cancel"
        : req.method === "POST" && seg[1] === "apply" && seg.length === 2 ? "apply" : null)
      : null;
    const eraseId = req.method === "GET" && seg.length === 1 && seg[0] === "status" ? extractEraseJob(req) : null;
    if (eraseAction || eraseId) {
      const orgId = await orgForUser(user.id, preferredOrg(req));
      if (eraseAction === "submit") await assertPaidAiIdentity(user, orgId);
      return await eraseHandler(req, { orgId, userId: user.id }, eraseAction ?? "status", eraseId ?? undefined);
    }

    // NOTE: quota is NOT charged up front. Each generate route validates its
    // body (and resolves its asset) FIRST, then calls guardGenerate()
    // immediately before the billable fal submit — see audit round 4.

    // ---- POST /ai-video/drone ----
    if (req.method === "POST" && seg.length === 1 && seg[0] === "drone") {
      const body = await readJson<DroneBody>(req);
      assert(body.asset_id, 400, "asset_id is required");
      const tier = body.tier ?? "4k30";
      const target = DRONE_TIERS[tier];
      assert(Object.hasOwn(DRONE_TIERS, tier), 400, `tier must be one of ${Object.keys(DRONE_TIERS).join(", ")}`);

      const asset = await resolvePublicAsset(db, body.asset_id, req);
      assert(asset.kind === "video", 400, "drone-glide needs a video asset");
      // V2 completion publishes once to a unique immutable key. Legacy final
      // keys may retain write capabilities: do not price one representation
      // and then let the provider fetch a replacement. Client metadata is only
      // a hint; the bounded MP4 probe is the source of pricing dimensions/time.
      assert(asset.transport_version === 2, 409,
        "Upload the saved clip again before enhancing it; this older upload cannot be priced safely.");
      const fps = Math.round(Number(body.target_fps ?? target.fps));
      assert(Number.isFinite(fps) && fps >= 24 && fps <= 60, 400,
        "Choose a frame rate from 24 to 60 fps. Higher frame rates are not priced yet.");
      const source = await probeMP4Video(asset.url, (url, init) => fetch(url, init));
      const srcLong = Math.max(source.width, source.height);
      // Topaz's factor is at least one. A 4K source selected as 1080p stays 4K;
      // never silently downscale it or reserve at the requested tier's rate.
      const upscale = Math.max(1, Math.min(4, Math.round((target.longEdge / srcLong) * 100) / 100));
      const outputWidth = Math.ceil(source.width * upscale);
      const outputHeight = Math.ceil(source.height * upscale);
      const interpolate = source.fps < fps - 0.5;
      const outputFps = interpolate ? fps : source.fps;
      const estimate: DroneEstimate = assertDroneWithinLimits({
        tier,
        durationS: source.billable_s,
        outputWidth,
        outputHeight,
        outputFps,
        assetId: asset.id,
      });
      // Header checks cannot establish decoded pictures for malformed avc1
      // bytes. Keep the highest published tariff reserved/booked until trusted
      // decoding or invoice reconciliation can support a cheaper cost bound.
      const reservation = droneReservation(estimate);

      // Priced — now compose with the org's existing monthly COGS ceiling
      // (inside guardGenerate, before any meter is consumed) and charge.
      await assertVideoReceiptSigningReady();
      const charge = await guardGenerate(user, req, "drone", reservation.cents, asset.org_id, asset.listing_id ?? undefined);
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
      // Reserve the exact priced attempt under the workspace lock BEFORE POST.
      // One eligible provider is attempted; lost acceptance keeps its hold.
      let attempt: ChainResult<JobRef>;
      try {
        assert(steps[0]?.provider === "fal" && /^(?:fal-ai\/)?topaz\/upscale\/video$/.test(steps[0]?.model ?? "") && steps[0]?.unit === "second",
          503, "This video route could not be priced safely. Please try again later.", "upstream");
        attempt = await submitReservedVideo({
          actorId: user.id, orgId, key: requiredIdempotencyKey(req),
          allowance: { monthlyWindowStart: charge.monthlyReceipt.windowStart, burstWindowStart: charge.burstReceipt.windowStart },
          listingId: asset.listing_id,
          feature: "drone_render", steps, input: genInput, seconds: estimate.seconds,
          // The maximum published tariff prices admission and settlement.
          unitCentsOverride: () => reservation.unit_cents,
          minHoldCents: reservation.cents,
          meta: { tier, upscale_factor: upscale, target_fps: fps, interpolated: interpolate,
            estimate_cents: reservation.cents, output_fps: outputFps },
        }, {
          rpc,
          submit: (step) => runChain(task, [step], (selected) => adapterFor(selected.provider).submit(selected, genInput)),
        });
      } catch (e) {
        if (!(e instanceof VideoDispatchUnconfirmed)) await refundGenerateCharge(charge);
        throw e;
      }
      const step = attempt.step;
      const sub = await submitEnvelope(req, routerOn, task, attempt.value, { orgId, userId: user.id, listingId: asset.listing_id });

      // submitReservedVideo atomically swaps its hold for one ledger row;
      // failed settlement retains the hold while the receipt remains usable.
      return json({
        ...sub,
        kind: "drone",
        model_id: step.model,
        tier,
        target_fps: fps,
        upscale_factor: upscale,
        interpolated: interpolate,
        source: { width: source.width, height: source.height, fps: source.fps, duration_s: source.duration_s },
        // ADDITIVE (cost safety): what this submission is expected to cost, so
        // the app can show a number instead of the user finding out on an
        // invoice. A new key on an existing object — AIVideoJobDTO decodes only
        // the fields it names and ignores the rest, so an older build is
        // unaffected. Every refusal above carries the same figures in its error
        // details, so the client has one shape to read either way.
        estimated_cost: estimate,
        reserved_cost: reservation,
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

      assert(!assetListingId || !body.listing_id || assetListingId === body.listing_id,400,"Choose a source from this listing.");
      const aerialOrgId = await assertAerialLaunchAccess(user, req, body.listing_id ?? assetListingId);
      await assertVideoReceiptSigningReady();
      const charge = await guardGenerate(user, req, "aerial", undefined, aerialOrgId, body.listing_id ?? assetListingId ?? undefined); // private beta validated — charge, then submit
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
      // Fence the priced attempt before one potentially accepted provider POST.
      let attempt: ChainResult<JobRef>;
      try {
        attempt = await submitReservedVideo({
          actorId: user.id, orgId, key: requiredIdempotencyKey(req),
          allowance: { monthlyWindowStart: charge.monthlyReceipt.windowStart, burstWindowStart: charge.burstReceipt.windowStart },
          listingId: body.listing_id ?? assetListingId,
          feature: "aerial", steps, input: genInput, seconds,
          meta: { grounded, seconds, aspect, motion: aerialMove.motion,
            ...(aerialMove.substituted ? { motion_requested: aerialMove.requested } : {}) },
        }, {
          rpc,
          submit: (step) => runChain(task, [step], (selected) => adapterFor(selected.provider).submit(selected, genInput)),
        });
      } catch (e) {
        if (!(e instanceof VideoDispatchUnconfirmed)) await refundGenerateCharge(charge);
        throw e;
      }
      const step = attempt.step;
      const modelId = step.model;
      const sub = await submitEnvelope(req, routerOn, task, attempt.value, { orgId, userId: user.id, listingId: body.listing_id ?? assetListingId });

      // Cost was settled once under the same lock that admitted its hold.

      // COMPLIANCE: an aerial is synthetic camera movement — HousingWire's
      // disclosure test names exactly this case, and WI Act 69 covers generated
      // video from 1 Jan 2027. Recorded at submit; the app attaches the finished
      // clip later via PATCH /me/compliance/:id.
      const prov = await provenance({
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
      const framing = parseReelFraming(body.framing);
      const savedQualityProfile=worker?propertyVideoQualityProfile(worker.qualityProfile):"legacy";
      // Kie profile: our vendor account cannot take this clip right now (secret
      // unset, key rejected or blocked, out of credits). HTTP 402 is what the
      // worker files as a resumable capacity pause, never a terminal source failure.
      const KIE_VENDOR_NOT_READY="The native-4K video service is not ready to accept this clip. Nothing was charged; resume this video later.";
      let secs = Math.round(Number(body.seconds ?? 5));
      if (!Number.isFinite(secs)) secs = 5;
      secs = Math.min(12, Math.max(2, secs)); // Seedance duration range 2–12 s
      // Native-4K Kie profile (typed literal): the job's frozen identity and the
      // one closed worker recipe are checked before any read, allowance or hold.
      if(savedQualityProfile==="kie-kling3-4k-steady-v1")assertKiePropertyDispatchScope(worker,{aspect:body.aspect,seconds:secs,framing,presetVersion:body.preset_version,
        customPrompt:body.prompt,assetId:body.asset_id,sourceAssetId:body.source_asset_id});

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
        validateExtendedReelSource(body.image_b64, mime);
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

      const presetVersion = body.preset_version;
      if (presetVersion !== undefined) {
        assert(presetVersion === 1, 400, "Choose a supported camera preset.");
        assert(!userMotion && (REEL_PRESETS as readonly string[]).includes(shotMotion), 400,
               "Choose Fly-through, Slow push-in, Side glide or Pull-back.");
        assert(body.aspect === "9:16" || body.aspect === "16:9", 400, "Choose portrait or landscape.");
        assert(secs === 5, 400, "These camera presets use five-second shots.");
      }
      const reelText = savedQualityProfile===PROPERTY_VIDEO_STEADY_PROFILE && worker?.targetAspect || savedQualityProfile==="kie-kling3-4k-steady-v1" && worker?.targetAspect
        ? buildSteadyPropertyReelPrompt(SCENE_NOUN[space],shotMotion as typeof REEL_PRESETS[number],worker.targetAspect)
        : presetVersion === 1
        ? framing === "preserve_photo"
          ? worker?.targetAspect ? buildPropertyCanvasReelPrompt(SCENE_NOUN[space],shotMotion as typeof REEL_PRESETS[number],worker.targetAspect) : buildPhotoPreservingReelPrompt(SCENE_NOUN[space], shotMotion as typeof REEL_PRESETS[number])
          : buildSeedanceReelPreset(SCENE_NOUN[space], shotMotion as typeof REEL_PRESETS[number])
        : userMotion
        ? guardedUserPrompt(userMotion, space, "Animate")
        : buildReelPrompt({ sceneNoun: SCENE_NOUN[space], motion: shotMotion });
      // When the caller supplied free text, the camera move came from THEIR
      // words on the unchanged guarded-user path — so the 202 and the provenance
      // row report no motion rather than one we never sent.
      const chosenMotion: ReelMotion | null = userMotion ? null : shotMotion;
      // Native-4K Kie profile: only the exact reviewed steady prompt the frozen
      // identity pins (template SHA-256 per motion, allowed scene nouns), and a
      // configured provider secret, before any storage read, allowance or hold.
      // An unset secret is our account, not this recipe: 402 (resumable pause).
      if(savedQualityProfile==="kie-kling3-4k-steady-v1"){
        assert(KIE_PROPERTY_IDENTITY.prompt_scene_nouns.includes(SCENE_NOUN[space])&&await kiePropertyPromptPinned(reelText,shotMotion),503,
          "The reviewed native-4K camera prompt is unavailable. No generation was sent.");
        if(!Deno.env.get("KIE_API_KEY")?.trim()){console.error("ai-video reel submit refused before dispatch",{provider:"kie",reason:"provider_not_configured"});throw new HttpError(402,KIE_VENDOR_NOT_READY,"upstream");}
        // Require the closed authority capability before any work. Its consuming
        // call belongs at the final prospective POST boundary after all preflight,
        // allowance and reservation checks, so a refused preparation spends none.
        if(!worker?.kieDispatchAuthority)throw new HttpError(503,"The native-4K dispatch authority is unavailable. No generation was sent.");

      }

      await assertVideoReceiptSigningReady();
      assert(!reelListingId || !body.listing_id || reelListingId === body.listing_id,400,"Choose a source from this listing.");
      let propertySource:Awaited<ReturnType<typeof verifyPropertyVideoInput>>|null=null;
      if(body.source_asset_id!==undefined){
        assert(typeof body.source_asset_id==='string'&&typeof body.listing_id==='string'&&typeof body.image_b64==='string',400,'Choose an uploaded property source and its exact prepared photo.');
        assert(optionalUuid(body.source_asset_id)===body.source_asset_id&&optionalUuid(body.listing_id)===body.listing_id,400,'Choose a valid property source.');
        const sourceProv=body.source_provenance_id??null;assert(sourceProv===null||optionalUuid(sourceProv)===sourceProv,400,'Choose a valid photo provenance record.');
        propertySource=await verifyPropertyVideoInput(user.id,body.listing_id,body.source_asset_id,body.image_b64,sourceProv,{
          rpc:(name,args)=>adminClient().rpc(name,args),
          head:(bucket,key,signal)=>headObject(bucket==='uploads'?R2_BUCKET_UPLOADS:R2_BUCKET_RENDERS,key,signal),
          sign:(bucket,key,seconds)=>presignGet(bucket==='uploads'?R2_BUCKET_UPLOADS:R2_BUCKET_RENDERS,key,seconds),fetch,
        });
      }else assert(body.source_provenance_id===undefined||body.source_provenance_id===null,400,'Photo provenance needs its uploaded source.');
      const charge = await guardGenerate(user, req, "reel", undefined, undefined, body.listing_id ?? reelListingId ?? undefined); // validated — charge, then submit
      const { orgId, plan } = charge;

      // ROUTER (flag-gated). With the flag off this resolves to the one legacy
      // step — fal Seedance — and the adapter rebuilds the payload below byte
      // for byte (asserted by providers_test.ts).
      const task = "video.reel_clip";
      const routerOn = await routerEnabled();
      const reelAspect = body.aspect === "16:9" || body.aspect === "9:16" ? body.aspect : null;
      let ownerQaStep: Awaited<ReturnType<typeof ownerQaReelStep>> = null;
      let candidateSteps:RouteStep[];
      try{ownerQaStep = savedQualityProfile==="legacy"?await ownerQaReelStep({ actorId: user.id, orgId,
        listingId: body.listing_id ?? reelListingId, seconds: secs, framing, aspect: reelAspect }):null;
      candidateSteps = isPropertyVideoQualityProfile(savedQualityProfile)?await propertyVideoQualitySteps(plan,undefined,savedQualityProfile):ownerQaStep ? [ownerQaStep] : await resolveChain(
        task,
        {
          plan,
          // 1080p is a real requirement here: it is what the shipped clip is,
          // and asking for it correctly drops the 768p Hailuo fallback.
          needs: ["i2v", "1080p", ...durationNeeds(task, secs), ...(!framing && reelAspect ? [reelAspect] : [])],
          carries_customer_media: true,
        },
        legacyVideoStep(task, MODEL_I2V, "second", APP_AI_UNIT_CENTS.seedance_per_s, ["i2v", "1080p", "5s", "16:9", "9:16"]),
      );
      }catch(error){await refundGenerateCharge(charge);throw error;}
      let steps: RouteStep[];
      try {
        steps = reelFramingSteps(candidateSteps, framing);
      } catch (error) {
        await refundGenerateCharge(charge);
        throw error;
      }
      const genInput: GenerateInput = {
        task,
        prompt: reelText,
        image_url: imageUrl,
        seconds: secs,
        resolution: "1080p",
        ...(reelAspect ? { aspect: reelAspect } : {}),
        ...(framing ? { framing } : {}),
        ...((ownerQaStep?.model === "kling-3.0/video" || ownerQaStep?.provider === "fal" && paramsOf(ownerQaStep)?.owner_motion_profile === OWNER_RAIL_MOTION_PROFILE || worker?.targetAspect) ? { extra: { ...(ownerQaStep?paramsOf(ownerQaStep)??{}:savedQualityProfile==="kie-kling3-4k-steady-v1"?paramsOf(steps[0])??{}:{}), ...(worker?.targetAspect?{property_video_target_aspect:worker.targetAspect}:{}),...(isPropertyVideoQualityProfile(savedQualityProfile)?{property_video_quality_profile:savedQualityProfile}:{}) } } : {}),
      };
      // A priced hold precedes one POST. Definitive refusal releases it;
      // transport ambiguity retains it without another provider attempt.
      let attempt: ChainResult<JobRef>;
      // Preserve a definitive local authority refusal only after the existing
      // reservation path confirms release. Unknown RPC replies remain fenced.
      let kieAuthorityRefusal: HttpError | null = null;
      try {
        attempt = await submitReservedVideo({
          actorId: user.id, orgId, key: requiredIdempotencyKey(req),
          allowance: { monthlyWindowStart: charge.monthlyReceipt.windowStart, burstWindowStart: charge.burstReceipt.windowStart },
          listingId: body.listing_id ?? reelListingId,
          feature: "reel", steps, input: genInput, seconds: secs,
          // Accounting metadata is allow-listed in SQL (app_video_cost_reserve:
          // tier, seconds, aspect, motion, ...). `preset_version` is not on that
          // list — sending it made every preset reel fail with
          // "Unsupported video accounting metadata" before any provider POST
          // (TestFlight 59, 2026-10-11). The preset is identified by `motion`.
          meta: { seconds: secs, ...(chosenMotion ? { motion: chosenMotion } : {}), ...(presetVersion === 1 && reelAspect ? { aspect: reelAspect } : {}) },
        }, {
          rpc,
          submit: (selected) => runChain(task, [selected], async (step) => {
          try {
            // Kie profile: a scope that ended (cancelled job, lost lease, account
            // switch) is a definite refusal before dispatch, so the hold is released.
            if(worker){if(savedQualityProfile==="kie-kling3-4k-steady-v1"){try{await worker.authorize();}catch{throw new ProviderError(step.provider,"validation","The admitted clip scope ended before dispatch.",0,true);}}
              else await worker.authorize();}
            if(isPropertyVideoQualityProfile(savedQualityProfile)){
              // Kie: the pinned row re-read by id must equal the reserved step and the frozen identity.
              try{if(savedQualityProfile==="kie-kling3-4k-steady-v1"){if(!samePinnedKieDispatch(await readPinnedRoute(KIE_PROPERTY_ROUTE_ID),step,worker?.qualityIdentity))throw Error("Changed Kie property identity");}
                else{const fresh=(await propertyVideoQualitySteps(plan,undefined,savedQualityProfile))[0];if(fresh.route_id!==step.route_id||fresh.model!==step.model||fresh.unit_cents!==step.unit_cents)throw Error("Changed property quality route");}}
              catch{throw new ProviderError(step.provider,"validation","The saved property quality route changed before dispatch.",0,true);}
            }
            // Kie accepts URLs only: the exact verified owned object, re-checked
            // and presigned for this one POST. Never the inline data URL.
            if(savedQualityProfile==="kie-kling3-4k-steady-v1"){
              const adapter=adapterFor(step.provider);
              const prepared=await kiePropertyProviderInput(genInput,propertySource?.location,{
                head:(bucket,key)=>headObject(bucket==='uploads'?R2_BUCKET_UPLOADS:R2_BUCKET_RENDERS,key,AbortSignal.timeout(15000)),
                sign:(bucket,key,seconds)=>presignGet(bucket==='uploads'?R2_BUCKET_UPLOADS:R2_BUCKET_RENDERS,key,seconds),
              });
              try{await worker!.kieDispatchAuthority!();}
              catch(error){
                if(error instanceof HttpError&&[400,403,409].includes(error.status)){
                  kieAuthorityRefusal=error;
                  throw new ProviderError("kie","validation","The scoped video authority refused before dispatch.",0,true);
                }
                // A lost authority reply may have committed its grant-use receipt.
                // Never send, re-authorize, or label it as provider acceptance.
                throw error;
              }
              return await adapter.submit(step,prepared);
            }
            const providerInput = ownerQaStep ? await prepareOwnerQaReelInput(
              { actorId: user.id, orgId, listingId: String(body.listing_id ?? reelListingId), provider: step.provider === "fal" ? "fal" : "kie" }, genInput, {
                authorize: async () => {
                  const liveOrg = await contentOrgForUser(user.id, orgId, body.listing_id ?? reelListingId ?? undefined, true);
                  const live = await ownerQaReelStep({ actorId: user.id, orgId: liveOrg,
                    listingId: body.listing_id ?? reelListingId, seconds: secs, framing, aspect: reelAspect });
                  return live?.provider === step.provider && live?.model === step.model &&
                    (paramsOf(step)?.owner_motion_profile === undefined || live?.route_id === step.route_id &&
                      paramsOf(live)?.owner_motion_profile === paramsOf(step)?.owner_motion_profile);
                },
                register: async (key, bytes) => {
                  const registered = await adminClient().rpc("register_private_ai_output", {
                    p_user: user.id, p_org: orgId, p_listing: body.listing_id ?? reelListingId,
                    p_bucket: "renders", p_key: key, p_bytes: bytes,
                  });
                  if (registered.error || registered.data?.ok !== true || registered.data.key !== key) throw new Error("QA source registration unavailable");
                },
                put: (key, bytes, mime) => putBytes(R2_BUCKET_RENDERS, key, bytes, mime, true),
                head: key => headObject(R2_BUCKET_RENDERS, key),
                // This vendor-only source capability is bounded by the same
                // two-hour processing window as its job receipt. It is never
                // returned to the app; app/download capabilities stay 600 s.
                sign: key => presignGet(R2_BUCKET_RENDERS, key, 7200),
              }) : genInput;
            return await adapterFor(step.provider).submit(step, providerInput);
          } catch (error) {
            // Deliberate HttpErrors are returned without logging. Preserve the
            // provider's HTTP status before runChain maps it to our 502, so
            // account authorization failures can be distinguished from an
            // outage. Never log its message/body, token or customer image URL.
            const known = error instanceof ProviderError ? error : null;
            const httpStatus = known?.status;
            console.error("ai-video reel submit failed", {
              provider: step.provider,
              model: step.model,
              error_class: known?.error_class ?? "other",
              provider_http_status: typeof httpStatus === "number" &&
                  Number.isInteger(httpStatus) && httpStatus >= 100 &&
                  httpStatus <= 599
                ? httpStatus
                : null,
              reason: known?.message === "FAL_KEY function secret is not set" || known?.message === "KIE_API_KEY function secret is not set"
                ? "provider_not_configured"
                : "submission_failed",
            });
            throw error;
          }
          }),
        });
      } catch (e) {
        if (!(e instanceof VideoDispatchUnconfirmed)) await refundGenerateCharge(charge);
        if(kieAuthorityRefusal&&!(e instanceof VideoDispatchUnconfirmed))throw kieAuthorityRefusal;
        // Kie profile: a definite createTask refusal about OUR vendor account
        // (401/403 key rejected or blocked, 402 out of credits). submitReservedVideo
        // rethrows a refusal only after the hold's release was confirmed (else
        // VideoDispatchUnconfirmed), so 402 is a resumable pause for the worker.
        // 429 and every recipe, media or ambiguous outcome keep their status.
        if(savedQualityProfile==="kie-kling3-4k-steady-v1"&&e instanceof HttpError&&e.details?.provider==="kie"&&e.details?.dispatch_rejected===true&&[401,402,403].includes(e.details?.provider_status as number))throw new HttpError(402,KIE_VENDOR_NOT_READY,"upstream",e.details);
        throw e;
      }
      const step = attempt.step;
      const savedListing = body.listing_id ?? reelListingId;
      if (!worker && step.provider === "fal" && savedListing) {
        try {
          await retainVideoSubmission({ actor: user.id, org: orgId, key: requiredIdempotencyKey(req), listing: savedListing, ref: attempt.value }, rpc);
        } catch {
          // Preserve the accepted receipt even if its recovery journal is down.
          // A lost HTTP reply remains unknown; it never authorizes another POST.
          console.error("ai-video accepted receipt recovery journal unavailable");
        }
      }
      const sub = await submitEnvelope(req, routerOn || !!worker, task, attempt.value, { orgId, userId: user.id, listingId: body.listing_id ?? reelListingId });
      if(worker?.accepted)await worker.accepted({...sub,model_id:step.model,seconds:secs});

      // submitReservedVideo settled one ledger row or retained its priced hold.

      let sourceBound=false;
      let prov:ProvenanceResult;
      if(!worker&&propertySource){
        const recorded=await recordDirectPropertyVideoSource({actor:user.id,org:orgId,key:requiredIdempotencyKey(req),
          request:sub.request_id,source:propertySource,label:body.label??null,style:chosenMotion,promptSummary:userMotion??null},rpc);
        prov=recorded.provenance;sourceBound=recorded.sourceBound;
      }else{
      prov = await provenance({
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
      if(propertySource&&prov.id){
        const bound=await adminClient().rpc('bind_property_video_source',{p_actor:user.id,p_listing:propertySource.listing,p_asset:propertySource.asset,
          p_photo_provenance:propertySource.photoProvenance,p_request:sub.request_id,p_generation_provenance:prov.id,p_sha256:propertySource.sha256,p_qc_hash:propertySource.qcHash});
        sourceBound=!bound.error&&bound.data?.bound===true;
      }
      }
      return json({
        ...sub,
        kind: "reel",
        ...(propertySource?{source_bound:sourceBound,source_asset_id:propertySource.asset}:{}),
        model_id: step.model,
        seconds: secs,
        space_type: space,
        ...(framing ? { framing } : {}),
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
    //   3. SERIALIZE checks against the owned paid clip. A terminal judgment
    //      replays; only HOLD or an abandoned worker permits a paid recheck.
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
      assert(body.listing_id == null || optionalUuid(body.listing_id) !== null,
        400, "listing_id must be a valid listing identifier.", "validation");

      const orgId = await guardDriftCheck(user, req,worker?.listing);

      const cached = await cachedDriftResponse({ actor: user.id, orgId, requestId, kind,
        sourceB64: source.b64, listingId: optionalUuid(body.listing_id), provenanceId, sourceAssetId });
      if (cached) return cached;

      // SQL verifies the owned paid generation and current listing access, then
      // serializes checks. Only a completed HOLD permits a new paid check key.
      // Old uncertain holds stay counted; changed client nonces cannot replay.
      const check = await beginDriftCheck({ actor: user.id, orgId, requestId, kind,
        sourceHash: await driftLineageKey(source.b64), listingId: optionalUuid(body.listing_id),
        req, input: body, rpc });
      if (check.replay) return json(check.replay);
      const funding = check.funding!;
      let judged: JudgeOutcome;
      try { judged = await judgeDrift({
        funding,
        plan: await driftRoutingPlan(orgId),
        subject: { kind: kind === "aerial" ? "aerial" : "reel", sceneNoun: SCENE_NOUN[space], motionText },
        source,
        frames,
      }); } catch (error) {
        // A funding refusal is availability/quota, not a model outage. It must
        // be shown truthfully and must not strand a check before any verdict.
        await finishDriftCheck(funding.rpc, user.id, orgId, check.id, "hold", null);
        throw error;
      }
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

      // ── The money (step 6) ───────────────────────────────────────────────
      //
      // Only a clip a model actually judged and actually failed. A `hold` (the
      // check could not run) refunds nothing: we do not know that the clip is
      // bad, and handing back an allowance for a clip that may be perfectly
      // good would make an outage in Anthropic's API into free reels.
      const charge = decision.action === "retry" || decision.action === "refuse"
        ? await refundRejectedClipAllowance(orgId, kind, requestId, user.id)
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
            request_key: funding.requestKey,
            stage: call.stage,
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

      const response = {
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
      };
      // A saved serving result is an independent crash-recovery proof if the
      // following QC-journal save is interrupted. It contains no source media.
      await completeFundingOperation(funding, response);
      await finishDriftCheck(funding.rpc, user.id, orgId, check.id, decision.action, response);
      return json(response);
    }

    // ---- GET /ai-video/status ----
    if (req.method === "GET" && seg.length === 1 && seg[0] === "status") {
      const params = new URL(req.url).searchParams;

      // A ROUTED job: the app is handing back the opaque token this function
      // minted at submit (it round-trips status_url/response_url verbatim, so
      // no client change is needed). Poll through the adapter and PERSIST the
      // result into our R2 the moment it completes — every reseller expires
      // media (fal 24 h by our own lifecycle header, Higgsfield 7 d, Kie 14 d),
      // so the canonical asset has to become ours here. Older unsigned FAL
      // receipts below require an exact owned admission mapping first.
      //
      // Signature, shape and actor are always required. A transport token past
      // its two-hour expiry also needs the exact durable paid receipt below;
      // current listing/library authority remains mandatory before result or
      // provider reads. Recovery never dispatches; a signed accepted admission
      // may finish its original once-only accounting settlement.
      // A `job` value that is present but fails any of those
      // checks is a 403, never a silent fall-through to the legacy path below
      // (which expects status_url/response_url, not job, and would otherwise
      // answer a confusing 400).
      const rawJobToken = extractJobToken(params);
      if (rawJobToken !== null) {
        // First establish signature and submitting actor; only an authenticated
        // token's exact admitted listing may resolve a legacy storage org.
        const signed = await decodeJobToken(rawJobToken);
        assert(signed && signed.usr === user.id,403,"This job status link does not belong to your account.");
        const routed = await verifyJobTokenForRecovery(rawJobToken,
          { orgId: signed.o, userId: user.id }, paidRoutedReceiptMatches);
        const callerOrgId = routed ? await routedContentOrg(user.id, preferredOrg(req), routed) : null;
        if (!routed || callerOrgId !== routed.o) {
          throw new HttpError(
            403,
            "This job status link is invalid, expired, or does not belong to your workspace.",
          );
        }
        if (isExpired(routed) && !await paidRoutedReceiptMatches(routed,true)) {
          throw new HttpError(403,"This saved video admission no longer matches the receipt.");
        }
        return await routedStatus(callerOrgId, routed);
      }

      const statusUrl = requireFalUrl(params.get("status_url"), "status_url");
      const responseUrl = requireFalUrl(params.get("response_url"), "response_url");
      await assertLegacyVideoReceipt(user.id, await legacyReceiptOrg(user.id, preferredOrg(req), statusUrl, responseUrl), statusUrl, responseUrl);

      const su = new URL(statusUrl);
      su.searchParams.set("logs", "1");
      const stRes = await fetchBounded("fal", su.toString(), { headers: falHeaders() }, BUDGETS.pollMs);
      const st = await stRes.json().catch(() => ({} as Record<string, unknown>));
      if (!stRes.ok) {
        console.error("ai-video fal status read failed", { provider_status: stRes.status, error_class: "upstream" });
        throw new HttpError(502, "The video status could not be checked. Please try again shortly.", "upstream", { provider_status: stRes.status, error_class: "upstream" });
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
        const terminalFailure = falCompletedFailure(st);
        if (terminalFailure) {
          console.error("ai-video fal generation failed", { provider_status: stRes.status, error_class: terminalFailure.error_class });
          return json({ status: "failed", error: terminalFailure.message, error_class: terminalFailure.error_class, provider: "fal" });
        }
        const rRes = await fetchBounded("fal", responseUrl, { headers: falHeaders() }, BUDGETS.pollMs);
        const result = await rRes.json().catch(() => ({} as Record<string, unknown>));
        if (!rRes.ok) {
          console.error("ai-video fal completed result failed", { provider_status: rRes.status, error_class: "upstream", result_reason: falResultErrorReason(result) });
          const deliveryIssue = falResultReadIssue(rRes.status, result);
          if (deliveryIssue) return json({ status: "processing", provider: "fal", delivery_issue: deliveryIssue, retry_existing_job: true });
          if (rRes.status === 408 || rRes.status === 429 || rRes.status >= 500) {
            throw new HttpError(502, "The clip finished, but its file could not be retrieved yet. Retry the saved request shortly.", "upstream",
              { provider: "fal", provider_status: rRes.status, error_class: "upstream", failure_phase: "result", retry_existing_job: true });
          }
          return json({ status: "failed", error: "The video service could not return this generation.", error_class: falResultErrorReason(result) === "content_policy" ? "nsfw" : "upstream", provider_status: rRes.status });
        }
        const resultFailure = falCompletedFailure(result);
        if (resultFailure) return json({ status: "failed", error: resultFailure.message, error_class: resultFailure.error_class, provider: "fal" });
        const videoUrl = extractVideoUrl(result);
        if (!videoUrl) {
          return json({ status: "failed", error: "The service completed without a usable video file.", error_class: "upstream", provider: "fal" });
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
      const terminalFailure = falCompletedFailure(st);
      const errorClass = terminalFailure?.error_class ?? "upstream";
      console.error("ai-video fal generation failed", { provider_status: stRes.status,
        fal_status: status === "FAILED" || status === "ERROR" ? status : "unexpected", error_class: errorClass });
      return json({ status: "failed", error: terminalFailure?.message ?? "The video service could not complete this generation.",
        error_class: errorClass, provider: "fal", provider_status: stRes.status, failure_phase: "generation" });
    }

    throw new HttpError(405, `Method ${req.method} not allowed on this path`);
  } catch (err) {
    return respondError(err);
  }
}
if(import.meta.main)Deno.serve(req=>handleAiVideo(req));

// ── routed job status (poll + persist through the adapter) ────────────────────

/** Exact accounting authority for an expired, authenticated accepted receipt.
 * Pure on the first check; a held acceptance may settle its original key only
 * after the route has freshly verified current listing/library permission. */
async function paidRoutedReceiptMatches(job: RouterJobToken, settleHeld = false): Promise<boolean> {
  const feature = job.k === "video.reel_clip" ? "reel"
    : job.k === "video.aerial" || job.k === "video.aerial_no_photo" ? "aerial"
    : job.k === "video.upscale_4k" || job.k === "video.upscale_1080p60" ? "drone_render" : null;
  if (!feature || !job.t || !Number.isFinite(Date.parse(job.t))) return false;
  const admin = adminClient();
  let query = admin.from("app_video_cost_reservations")
    .select("id,org_id,actor_id,idempotency_key,billing_org_id,input_sha256,total_cents,hold_cents,feature,provider,model,provider_request_id,cost_ledger_id,settled_at,released_at,meta")
    .eq("org_id",job.o).eq("actor_id",job.usr).eq("provider",job.p).eq("model",job.m);
  query = job.a ? query.eq("idempotency_key",job.a) : query.eq("provider_request_id",job.i);
  const saved = await query.limit(2);
  assert(!saved.error && Array.isArray(saved.data),503,"This saved video payment could not be verified.","upstream");
  if (saved.data.length !== 1) return false;
  const row = saved.data[0];
  if (row.org_id !== job.o || row.actor_id !== job.usr || (job.a && row.idempotency_key !== job.a) ||
      row.provider !== job.p || row.model !== job.m || row.feature !== feature || row.meta?.task !== job.k || row.released_at !== null) return false;
  const allowance = await admin.from("app_video_allowance_receipts")
    .select("listing_id,drift_refunded_at").eq("reservation_id",row.id).maybeSingle();
  assert(!allowance.error,503,"This saved video scope could not be verified.","upstream");
  // QC may refund the user's clip allowance; the settled supplier payment
  // below still stands. Only released/unpaid/foreign receipts deny recovery.
  if (!allowance.data ||
      (job.l !== undefined && allowance.data.listing_id !== job.l)) return false;
  // Settlement can fail after validated acceptance while both priced holds
  // remain durable. Only a newer signed receipt binds that exact admission key;
  // never infer an old unsettled request by timestamps, FIFO or provider URL.
  if (row.provider_request_id === null && row.cost_ledger_id === null && row.settled_at === null) {
    if (!job.a || allowance.data.listing_id !== (job.l ?? null) || !/^[a-f0-9]{64}$/.test(row.input_sha256 ?? "") ||
        !Number.isFinite(Number(row.total_cents)) || Number(row.total_cents) <= 0 ||
        !Number.isFinite(Number(row.hold_cents)) || Number(row.hold_cents) < Number(row.total_cents)) return false;
    const held = await admin.from("serving_cost_reservations")
      .select("org_id,actor_id,request_key,stage,provider,model,input_sha256,hold_cents,state,ledger_id,billing_org_id")
      .eq("org_id",job.o).eq("actor_id",job.usr).eq("request_key",job.a).eq("stage",feature)
      .eq("provider",job.p).eq("model",job.m).limit(2);
    assert(!held.error && Array.isArray(held.data),503,"This saved video admission could not be verified.","upstream");
    if (held.data.length !== 1) return false;
    const hold = held.data[0];
    if (hold.org_id !== job.o || hold.actor_id !== job.usr || hold.request_key !== job.a || hold.stage !== feature ||
        hold.provider !== job.p || hold.model !== job.m || hold.input_sha256 !== row.input_sha256 ||
        hold.state !== "succeeded" || hold.ledger_id !== null || !row.billing_org_id || hold.billing_org_id !== row.billing_org_id ||
        !Number.isFinite(Number(hold.hold_cents)) || Number(hold.hold_cents) < Number(row.total_cents)) return false;
    if (!settleHeld) return true;
    // Current library permission was resolved before this once-only accounting
    // repair. The existing RPC locks this key and rejects released/foreign jobs.
    let settled;
    try { settled = await admin.rpc("app_video_cost_settle",{
      p_actor:job.usr,p_org:job.o,p_key:job.a,p_provider_request_id:job.i,
    }); } catch { throw new HttpError(503,"This saved video's cost could not be recorded. Retry the saved request shortly.","upstream"); }
    assert(!settled.error && settled.data?.settled === true,503,"This saved video's cost could not be recorded. Retry the saved request shortly.","upstream");
    // A success-shaped response alone cannot waive the durable ledger proof.
    const recorded = await admin.from("app_video_cost_reservations")
      .select("provider_request_id,cost_ledger_id,settled_at").eq("id",row.id).maybeSingle();
    assert(!recorded.error,503,"This saved video payment could not be verified.","upstream");
    if (!recorded.data || recorded.data.provider_request_id !== job.i || !recorded.data.cost_ledger_id ||
        !recorded.data.settled_at || !Number.isFinite(Date.parse(recorded.data.settled_at))) return false;
    return await paidRoutedReceiptMatches(job);
  }
  // The database normally enforces all three fields together; any partial or
  // foreign tuple still fails closed rather than becoming recovery authority.
  if (row.provider_request_id !== job.i || !row.cost_ledger_id || !row.settled_at || !Number.isFinite(Date.parse(row.settled_at))) return false;
  const ledger = await admin.from("cost_ledger")
    .select("id,org_id,feature,provider,model,total_cents,meta").eq("id",row.cost_ledger_id).maybeSingle();
  assert(!ledger.error,503,"This saved video payment could not be verified.","upstream");
  const paid = ledger.data;
  return !!paid && paid.id === row.cost_ledger_id && paid.org_id === job.o &&
    paid.feature === feature && paid.provider === job.p && paid.model === job.m && Number(paid.total_cents) > 0 &&
    paid.meta?.app_video_reservation_id === row.id && paid.meta?.request_id === job.i && paid.meta?.billing_org_id === job.o &&
    (!job.a || (paid.meta?.request_key === job.a && paid.meta?.stage === feature));
}

async function routedContentOrg(actor: string, preferred: string | undefined, job: RouterJobToken): Promise<string> {
  let listing = job.l;
  if (!listing) {
    const admin = adminClient();
    const saved = await admin.from("app_video_cost_reservations").select("id")
      .eq("org_id",job.o).eq("actor_id",actor).eq("provider_request_id",job.i).eq("provider",job.p).eq("model",job.m).limit(2);
    assert(!saved.error && Array.isArray(saved.data) && saved.data.length <= 1,503,"This saved video scope could not be verified.");
    if (saved.data[0]) {
      const allowance = await admin.from("app_video_allowance_receipts").select("listing_id").eq("reservation_id",saved.data[0].id).maybeSingle();
      assert(!allowance.error,503,"This saved video scope could not be verified.");
      listing = allowance.data?.listing_id ?? undefined;
    }
  }
  return await contentOrgForUser(actor,preferred,listing);
}

/**
 * The status answer for a job the router submitted.
 *
 * Same three states the app already decodes — processing / completed / failed —
 * with `video_url` pointing at OUR R2 copy once the result has been persisted.
 * Extra fields are additive; the shipped decoder ignores them.
 *
 * `orgId` is the CALLER's own org, already verified by the signed receipt gate to
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

  let output: Awaited<ReturnType<typeof createRoutedOutput>>;
  const completed = (saved: {key:string;url:string}) => json({
    status: "completed", video_url: saved.url, provider: job.p, model: job.m,
    persisted: true, asset_key: saved.key, drift: uncheckedDriftBlock(),
  });
  try {
    const admin = adminClient();
    let listingId: string | null = job.l ?? null;
    if (!job.l) {
      const { data: reservations, error: receiptError } = await admin.from("app_video_cost_reservations")
        .select("id").eq("org_id", orgId).eq("actor_id", job.usr).eq("provider_request_id", job.i).eq("provider", job.p).eq("model", job.m).limit(1);
      if (receiptError) throw new Error("Video receipt unavailable");
      if (reservations?.[0]?.id) {
        const { data: allowance, error: allowanceError } = await admin.from("app_video_allowance_receipts")
          .select("listing_id").eq("reservation_id", reservations[0].id).maybeSingle();
        if (allowanceError) throw new Error("Video scope unavailable");
        listingId = allowance?.listing_id ?? null;
      }
    }
    output = await createRoutedOutput({orgId,userId:job.usr,listingId,provider:job.p,model:job.m,requestId:job.i,submittedAt:job.t,kind:job.k||"video"}, {
      find: async keys => {
        let query = admin.from("private_ai_outputs").select("org_id,user_id,listing_id,bucket,storage_key,bytes")
          .eq("org_id",orgId).eq("user_id",job.usr).eq("bucket","renders").in("storage_key",keys);
        query = listingId === null ? query.is("listing_id",null) : query.eq("listing_id",listingId);
        const {data,error} = await query.limit(2);
        if(error || !Array.isArray(data)) throw new Error("Saved video receipt unavailable");
        return data;
      },
      register: async (key,bytes) => {
        const {data,error} = await admin.rpc("register_private_ai_output", {p_user:job.usr,p_org:orgId,p_listing:listingId,p_bucket:"renders",p_key:key,p_bytes:bytes});
        if(error || data?.ok!==true || data.key!==key) throw new Error("Video output could not be journaled");
      },
      head: key => headObject(R2_BUCKET_RENDERS,key),
      persist: (state,key,beforeWrite) => persistResult(job.p,state,key,beforeWrite,true),
      sign: key=>privateMediaUrl({actor:job.usr,org:orgId,listing:listingId,bucket:"renders",key},600),
    });
    const saved = await output.existing();
    if(saved) return completed(saved);
  } catch {
    throw new HttpError(503, "The saved video could not be verified. Retry the saved request shortly.", "upstream",
      {provider:job.p,error_class:"upstream",failure_phase:"persistence",retry_existing_job:true});
  }

  let state: JobState;
  try { state = await adapter.poll(ref); }
  catch (error) {
    const failure = asHttpError(error);
    console.error("ai-video routed status read failed", { provider: job.p, model: job.m,
      provider_status: failure.details?.provider_status ?? null, error_class: failure.details?.error_class ?? "upstream" });
    throw failure;
  }
  if (state.status !== "done") {
    if (state.status === "failed") {
      console.error(`ai-video routed job failed (${job.p}/${job.m}):`, state.message);
      return json({ status: "failed", error: state.message, error_class: state.error_class, provider: job.p });
    }
    return json({ status: "processing", provider: job.p, model: job.m, queue_position: null, logs_tail: [], ...(state.delivery_issue ? { delivery_issue: state.delivery_issue, retry_existing_job: true } : {}) });
  }

  // COMPLETED → one immutable journaled object, including concurrent polls and
  // recovery from a lost write response. Existing output skips provider fetch.
  try {
    return completed(await output.complete(state));
  } catch (e) {
    // Kie only: a completed result that can never be retained (an image or
    // other non-video extension, or more bytes than the edge persist limit) is
    // terminal here, so the worker fails the attempt once instead of re-polling
    // the same receipt to its 24 h deadline. Kie's work is finished and its
    // result is immutable; nothing is downloaded again. Every other provider
    // keeps the retryable 503 exactly as before.
    if (job.p === "kie" && e instanceof HttpError && e.details?.result_unretainable === true) {
      console.error("ai-video routed Kie result cannot be retained", { provider: job.p, model: job.m, error_class: "upstream" });
      return json({ status: "failed", error: "The generated result cannot be retained as a video.", error_class: "upstream", provider: job.p, failure_phase: "persistence", result_unretainable: true });
    }
    console.error("ai-video result persistence failed", { provider: job.p, model: job.m, error_class: "upstream" });
    throw new HttpError(503, "The clip was generated but could not be stored yet. Retry the saved request shortly.", "upstream",
      { provider: job.p, error_class: "upstream", failure_phase: "persistence", retry_existing_job: true });
  }

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
 * Generated clip frames stay capped previews. The source retains the native
 * prepared 2048 px JPEG without a paid generation followed by a QC 413. Larger
 * sources receive complete-image/geometry validation before both dispatch
 * and judging; the judge's prospective quote also covers 4096 source tokens.
 */
const MAX_DRIFT_IMAGE_B64_CHARS = MAX_DRIFT_FRAME_B64_CHARS;
const MAX_DRIFT_BODY_BYTES = MAX_DRIFT_REQUEST_BODY_BYTES;

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
    s.length <= (field === "source_b64" ? MAX_DRIFT_SOURCE_B64_CHARS : MAX_DRIFT_IMAGE_B64_CHARS),
    413,
    field === "source_b64"
      ? "source_b64 is too large — use the prepared 2048 px source photo."
      : `${field} is too large — send the 1280 px preview frame the app makes.`,
    "payload_too_large",
  );
  const m = String(mime ?? "image/jpeg").split(";")[0].trim().toLowerCase();
  assert(ALLOWED_IMAGE_MIMES.includes(m), 400, `${field} mime must be one of ${ALLOWED_IMAGE_MIMES.join(", ")}`);
  if (field === "source_b64") validateExtendedReelSource(s, m);
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
    // The STEP, not step.model, so a row's `params` (0030) reach the request.
    // No judge.qc_drift row seeds any — the judge runs on every generation and
    // its whole job is to be cheap enough to always run — so this is
    // byte-identical today.
    return await anthropicMessages({ model: step, system: rubric, content, maxTokens: DRIFT_MAX_TOKENS });
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
    return await openaiChat(step, [{ role: "user", content }], {
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
  /** The serving-hold stage this call was admitted under; its ledger row must name it. */
  stage: string;
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
  funding: FundingContext;
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
  // Documented vision bound: one source still plus the judged frames.
  const judgeInputTokens = visionInputTokenBound(1 + args.frames.length, new TextEncoder().encode(rubric).byteLength)
    + DRIFT_SOURCE_EXTRA_INPUT_TOKENS;

  let primary: ChainResult<string>;
  try {
    primary = await runChain(DRIFT_TASK, steps, (step) => fundedAttempt(args.funding, `qc.initial:${steps.indexOf(step)}`, step, parts, textAttemptQuote(step, rubric, "", DRIFT_MAX_TOKENS, true, judgeInputTokens), () => callJudgeStep(step, rubric, parts)));
  } catch (e) {
    if (e instanceof FundingAdmissionError) throw e;
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

  const calls: JudgeCall[] = [{ step: primary.step, escalated: false, stage: `qc.initial:${steps.indexOf(primary.step)}` }];
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
        const second = await runChain(DRIFT_TASK, rest, (s) => fundedAttempt(args.funding, `qc.escalation:${steps.indexOf(s)}`, s, parts, textAttemptQuote(s, rubric, "", DRIFT_MAX_TOKENS, true, judgeInputTokens), () => callJudgeStep(s, rubric, parts)));
        calls.push({ step: second.step, escalated: true, stage: `qc.escalation:${steps.indexOf(second.step)}` });
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
async function legacyReceiptOrg(actor: string, preferred: string | undefined, status: string, response: string): Promise<string> {
  const receipt = falLegacyReceipt(status,response);
  assert(receipt,403,"This older job needs verified account recovery. No new generation was started.");
  const admin = adminClient();
  const saved = await admin.from("app_video_cost_reservations").select("id,org_id,model,provider_request_id")
    .eq("actor_id",actor).eq("provider","fal").eq("provider_request_id",receipt.requestId).limit(2);
  assert(!saved.error,503,"This saved video could not be checked.");
  assert(saved.data?.length === 1 && falLegacyReceiptMatchesModel(saved.data[0].model,saved.data[0].provider_request_id,receipt),403,"This older job needs verified account recovery. No new generation was started.");
  const allowance = await admin.from("app_video_allowance_receipts").select("listing_id").eq("reservation_id",saved.data[0].id).maybeSingle();
  assert(!allowance.error,503,"This saved video scope could not be verified.");
  const org = await contentOrgForUser(actor,preferred,allowance.data?.listing_id ?? undefined);
  assert(org === saved.data[0].org_id,403,"This saved video belongs to another listing library.");
  return org;
}

async function assertLegacyVideoReceipt(actorId: string, orgId: string, status: string, response: string): Promise<void> {
  const receipt = falLegacyReceipt(status, response);
  assert(receipt, 403, "This older job needs verified account recovery. No new generation was started.");
  const { data, error } = await adminClient().from("app_video_cost_reservations").select("id, model, provider_request_id")
    .eq("org_id", orgId).eq("actor_id", actorId).eq("provider", "fal")
    .eq("provider_request_id", receipt.requestId).limit(2);
  if (error) throw new HttpError(503, "This saved job could not be checked. Please retry its status.", "upstream");
  assert(data?.length === 1 && falLegacyReceiptMatchesModel(data[0].model, data[0].provider_request_id, receipt),
    403, "This older job needs verified account recovery. No new generation was started.");
}

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

// ── asset resolution ──────────────────────────────────────────────────────────

interface ResolvedAsset {
  org_id: string;
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
  transport_version: number;
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
    .select("id, listing_id, kind, bucket, storage_key, uploaded, duration_s, width, height, fps, transport_version, listings!inner(org_id, space_type, deleted_at)")
    .eq("id", assetId)
    .maybeSingle();
  if (error) throw new HttpError(400, `Asset lookup failed: ${error.message}`);
  if (!data) throw new HttpError(404, "Asset not found");
  assert(data.uploaded === true, 409, "Asset upload is not complete");
  assert(!String(data.storage_key).includes("/contact-"), 400, "Choose property media for this video.");
  const listing = (Array.isArray(data.listings) ? data.listings[0] : data.listings) as
    | { org_id: string; space_type: string | null; deleted_at: string | null }
    | undefined;
  if (!listing || listing.deleted_at) throw new HttpError(404, "Asset not found");

  const actor = await getUser(req);
  const scope = await listingLibraryScope(adminClient(), actor.id, String(data.listing_id), true);
  assert(scope.org_id === listing.org_id, 404, "This source belongs to another listing library.");
  const preferred = preferredOrg(req);
  if (preferred && preferred !== scope.org_id && preferred !== scope.library_org_id) {
    throw new HttpError(403, "This asset belongs to a different workspace than X-Org-Id");
  }

  if (data.bucket !== "renders") {
    throw new HttpError(
      400,
      `Asset ${assetId} is in the "${data.bucket ?? "uploads"}" bucket. Upload this provider input to ` +
        `the renders bucket first (POST /uploads with ` +
        `role:"render"), or pass image_b64 where the route supports it.`,
    );
  }
  const url = await presignGet(R2_BUCKET_RENDERS, data.storage_key as string, 600);
  if (!url) {
    throw new HttpError(
      500,
      "A private download link could not be created for this asset. Please retry.",
      "internal",
    );
  }
  const num = (v: unknown) => (v == null || !Number.isFinite(Number(v)) ? null : Number(v));
  return {
    org_id: listing.org_id,
    id: data.id as string,
    listing_id: (data.listing_id as string | null) ?? null,
    kind: data.kind as string,
    url,
    duration_s: num(data.duration_s),
    width: num(data.width),
    height: num(data.height),
    fps: num(data.fps),
    space_type: listing.space_type ?? null,
    transport_version: Number(data.transport_version),
  };
}

/** Trimmed non-empty prompt, or undefined. */
function cleanPrompt(p: string | undefined): string | undefined {
  const t = (p ?? "").trim().slice(0, 600);
  return t.length > 0 ? t : undefined;
}
