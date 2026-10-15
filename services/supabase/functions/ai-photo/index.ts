import { libraryBillingOrg } from "../_shared/library-access.ts";
// ai-photo — single-image AI edits (twilight | sky | lawn | declutter | stage |
// custom) via Gemini image edit ("Nano Banana"). Owner-authenticated.
// Mirrors services/pipeline providers/gemini.py + router.PHOTO_EDIT_PROMPTS.
//
//   POST /ai-photo  { image_b64, mime?, edit, style?, prompt?, space_type?,
//                     listing_id?, label?, original_asset_id? }
//              ->  { image_b64, mime, edit, style?, space_type,
//                     disclosure, provenance: { id, recorded, reason? } }
//
//   edit       = twilight | sky | lawn | declutter | stage | custom
//   style      = modern | rustic | minimalist | contemporary (legacy scandinavian accepted)   (stage only; default modern)
//   space_type = real_estate | venue | restaurant | retail | fitness | other (default real_estate)
//                Selects the industry prompt set: a restaurant is dressed for
//                service, a gym gets equipment, a store gets merchandised — not
//                a sofa and coffee table (audit F-A-07 / F-supabase-10).
//
// Text/vision helper modes use separately priced shared-wallet holds on paid
// accounts and preserve private QA sponsorship. They do not use a photo credit,
// are excluded from the bounded trial, and have their own burst limiter:
//
//   edit:"suggest"         { image_b64, mime?, space_type? }  ->  { suggestions: [{ edit, reason, confidence }] }
//       Looks at the photo and recommends up to 3 edits (from the 5 canned ones)
//       that would genuinely improve it — e.g. twilight only for exteriors.
//
//   edit:"improve_prompt"  { prompt, space_type? }            ->  { prompt }
//       Rewrites the user's rough custom-edit idea (≤600 chars) into a precise,
//       photorealistic edit instruction (≤400 chars). The improved prompt is
//       meant to be sent back as edit:"custom", where the architecture-lock
//       guardrails are appended server-side as usual. (The image is not needed
//       for this mode and is ignored if sent.)
//
//       SUPERSEDED BY `POST /ai-copy/edit-prompt` (2026-09-07), which does the
//       same job with an org burst limiter, a cost_ledger row and the LISTING's
//       space_type. This mode is kept because SHIPPED APP BUILDS STILL CALL IT
//       and nothing the client sees may change — but it is now a thin forward:
//       the words come from the one shared polisher, ai-copy/prompt.ts
//       `editPromptInstruction()`, so the two cannot drift. New clients should
//       call /ai-copy/edit-prompt. See docs/COPY-ASSIST-CONTRACT.md.
//
// Needs the GEMINI_API_KEY function secret. Returns the edited image inline
// (base64, with Gemini's ACTUAL mime type) so the app can show a before/after.
// Errors carry { error, code } — 402 plan_required / 429 quota_exceeded carry
// {feature, used, cap, plan} so the app can prompt an upgrade.
//
// ── COMPLIANCE (wave 2, W2-B3) ───────────────────────────────────────────────
//
// FAIR HOUSING. Every prompt this function builds — canned and free-text — gets
// the guardrails from _shared/fairhousing.ts appended server-side:
//   "Do not add or alter people, pets, religious or cultural objects, flags, or
//    signage." + "Do not change the exterior, the view out of windows, or any
//    permanent feature."
// The exterior edits (twilight | sky | lawn) get the same fair-housing sentence
// plus a SCOPED permanence clause instead of the blanket one — those three
// edits exist to change the sky, the light and the landscaping, so "do not
// change the exterior" would fight the instruction. See fairhousing.ts.
// Free-text prompts (edit:"custom" and edit:"improve_prompt") are additionally
// checked against the DENYLIST documented in full in _shared/fairhousing.ts —
// people / pets / religious + cultural objects only when the prompt is ADDING
// them, and neighborhood / school-district / demographic claims always. A hit
// is a 400 with code `unsupported_edit` naming the term and how to rephrase.
// ("remove the personal items" and "brighten the flag stone patio" pass; "add a
// family in the living room" and "make it look like a good school district"
// do not.) The denylist is scoped by the LISTING's `space_type` (the row wins,
// the request's `space_type` is the fallback, nothing = housing): a venue, bar,
// store or gym keeps the general safety layer (no people / pets / cultural
// objects added, nothing that singles people out) but not the housing-steering
// rules or the HUD wording — see _shared/fairhousing.ts, SCOPE.
//
// PROVENANCE. Prospective edits retain exact private source/candidate evidence.
// A separate funded fixed-feature photo review must atomically record matching
// paid receipts, QC and provenance before ordinary delivery is allowed. Pending
// or uncertain checks return their saved IDs without image bytes or an asset key.
// Historical photo_output replays preserve their original disclosure receipt.
// `original_asset_id` (optional) is the untouched source uploaded via
// POST /uploads role:"original", which makes "View original" a real public link
// — the access-to-the-original half of AB 723.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, readJson, readJsonLimited, respondError } from "../_shared/http.ts";
import { adminClient, assertPaidAiIdentity, getUser, type PaidAiCaller, listingSpaceType, orgForUser, contentOrgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";
import { chargeRateReceipt, refundRateReceipt, type RateChargeReceipt } from "../_shared/ratelimit.ts";
import { requiredIdempotencyKey } from "../_shared/idempotency.ts";
import { entitlementForCharge, quotaError } from "../_shared/entitlements.ts";
import { assertFairHousing, guardrailsFor } from "../_shared/fairhousing.ts";
import { CUSTOM_PHOTO_FIXED_FEATURES } from "../_shared/custom-photo-prompt.ts";
import { buildRealEstateStagePrompt } from "../_shared/photo-stage-prompt.ts";
import { assertCustomPhotoPrompt, assertCustomPhotoOutput } from "../ai-copy/guard.ts";
import { type ProvenanceKind, disclosureFallback } from "../_shared/provenance.ts";
import { APP_AI_UNIT_CENTS, recordRoutedAiCost } from "../_shared/ledger.ts";
import type { RouteStep } from "../_shared/router.ts";
import { routerEnabled } from "../_shared/router.ts";
import { adapterFor } from "../_shared/providers/index.ts";
import { fundingContext, fundedAttempt, mediaAttemptQuote, SavedFundingResponse, completeFundingOperation, abortFundingOperationBeforeDispatch, boundedPhotoChain, assertPhotoHelperSponsorship, inputHash, type FundingContext } from "../_shared/funded-serving.ts";
import { type ChainResult, resolveChain, runChain } from "../_shared/providers/chain.ts";
import { ownerQaPhotoStep, prepareOwnerQaPhotoInput, assertOwnerQaPhotoOutput } from "./owner-photo-qa.ts";
import { preparePhoto4KInput, photo4KChain, assertPhoto4KGeometry } from "./photo-quality.ts";
import { priceMaskedPhotoChain, isMaskedFillStep } from "./masked-photo-pricing.ts";
import { supportsStagingReference } from "../_shared/providers/gemini.ts";
import {
  BUDGETS,
  ProviderError,
  awaitJob,
  inlineBase64,
  inlineImageResult,
} from "../_shared/providers/common.ts";
import type { DoneState, GenerateInput } from "../_shared/providers/types.ts";
// THE SHARED PROMPT POLISHER. Yes, this reaches into a sibling function's
// folder — the same mechanism `../_shared/…` uses (both live under functions/
// and both are followed by the bundler at deploy). ai-copy/prompt.ts imports
// NOTHING, precisely so it can be pulled in here without dragging ai-copy's
// handler, its router glue or its Supabase clients into this function's bundle.
// See ai-copy/prompt.ts's header and improvePrompt() below.
import { MAX_PROMPT_INPUT, MAX_PROMPT_OUTPUT, editPromptInstruction } from "../ai-copy/prompt.ts";
import { restorePhotoResult, type PhotoResultPointer } from "./photo-result.ts";
import { photoJsonResponse } from "./photo-response.ts";
import { validatePhotoInputs, validatePhotoPrompt, decodePhotoOutput } from "./input-policy.ts";
import { photoHelperPayload, photoHelperQuote, type PhotoHelperPayload } from "./helper-policy.ts";
import {lookupPhotoQuality,statusPhotoQuality,photoQualityScope,beginPhotoQuality,retainPhotoCandidate,failPhotoQuality,photoQualityResponse,type PhotoQualityEnvelope} from "./photo-qc-store.ts";
import {waitForPhotoQuality} from "./photo-qc-wait.ts";
import {calibrationRequest,beginPhotoCalibration} from "./photo-qc-calibration.ts";

// Money admission uses the actual conservative payload hold independently of
// these burst/monthly feature counters.
const EDIT_MAX_PER_WINDOW = 40;
const EDIT_WINDOW_SECONDS = 300; // 40 photo edits / 5 min / org
const MONTH_SECONDS = 30 * 86400;
// Paid helpers spend the shared funded wallet separately from photo credits.
// Trial helper stages are fenced so their five image admissions retain cash.
const HELP_MAX_PER_WINDOW = 120;
const HELP_WINDOW_SECONDS = 300; // 120 suggest/improve calls / 5 min / org

// Monthly allowances come from plan_entitlements (migration 0010) so the
// enforced number and the published number are the same number.

/** Role gate shared by both guards: marketing is read-only. */
async function requireEditorRole(user: PaidAiCaller, req: Request, what: string, listingId?: string): Promise<string> {
  const userId = user.id;
  const orgId = await contentOrgForUser(userId, preferredOrg(req), listingId, true);

  await assertPaidAiIdentity(user, orgId);
  return orgId;
}

/** What guardEdit() actually charged (audit item 2 / F-E-16: refundEditCharge
 *  hands it all back when the edit that follows produces no output). */
interface EditCharge {
  orgId: string;
  plan: string;
  monthlyKey: string;
  burstKey: string;
  monthlyReceipt: RateChargeReceipt;
  burstReceipt: RateChargeReceipt;
}

/**
 * Charge the paid-generation quotas. MUST be called only AFTER the request body
 * and its parameters are known-good: charging first meant a caller could burn
 * an org's burst + monthly quota with `{}` bodies that never reached Gemini
 * (audit round 4).
 */
async function guardEdit(user: PaidAiCaller, req: Request, listingId?: string): Promise<EditCharge> {
  const orgId = await requireEditorRole(user, req, "AI photo edits", listingId);
  // A degraded plan lookup is a 503 here, never a 402 (audit F-E-02).
  const ent = await entitlementForCharge(orgId);
  const monthlyCap = ent.photo_edits_per_month;
  if (monthlyCap <= 0) throw quotaError("AI photo edit", 0, 0, ent.plan);

  // Permanent serving-operation admission now owns replay. A time-window
  // counter must not prevent recovery or renew an admitted paid operation.
  requiredIdempotencyKey(req);
  const billingOrgId = await libraryBillingOrg(adminClient(), orgId, user.id);
  const burstKey = `aiphoto:${billingOrgId}`;
  const monthlyKey = `aiphotomo:${billingOrgId}`;
  const burst = await chargeRateReceipt(burstKey, EDIT_MAX_PER_WINDOW, EDIT_WINDOW_SECONDS);
  if (!burst.accepted) {
    throw new HttpError(429, "AI photo edit limit reached for now — try again in a few minutes.", "rate_limited");
  }
  const monthly = await chargeRateReceipt(monthlyKey, monthlyCap, MONTH_SECONDS);
  if (!monthly.accepted) {
    await refundRateReceipt(burst.receipt);
    throw quotaError("AI photo edit", monthlyCap, monthlyCap, ent.plan);
  }
  // Return the org the quota was charged to, so the handler can attribute the
  // cost_ledger row (F-E-15) and refund the same keys on failure (F-E-16).
  // The effective plan rides along for the router's RouteContext: it is the
  // number entitlementForCharge() just read, not a second lookup.
  return { orgId, plan: ent.plan, monthlyKey, burstKey, monthlyReceipt: monthly.receipt, burstReceipt: burst.receipt };
}

/**
 * Hand back everything a FAILED edit charged (audit item 2 / F-E-16, mirrors
 * ai-chapters/index.ts refundCharge exactly). Call ONLY when route resolution or the provider
 * chain threw — once runChain returns a value the provider ran and billed,
 * and the ledger write right after it is what records that; nothing past that
 * point is ever refunded. Each receipt names the original SQL charge window.
 */
async function refundEditCharge(charge: EditCharge): Promise<void> {
  await refundRateReceipt(charge.monthlyReceipt);
  await refundRateReceipt(charge.burstReceipt);
}

/** What guardHelper() charged — burst only, never the monthly meter. */
interface HelperCharge {
  orgId: string;
  burstKey: string;
  burstReceipt: RateChargeReceipt;
}

/** Helper modes: role gate + burst limiter only. Never touches the monthly meter. */
async function guardHelper(user: PaidAiCaller, req: Request, listingId?: string): Promise<HelperCharge> {
  const orgId = await requireEditorRole(user, req, "AI photo suggestions", listingId);
  const burstKey = `aiphotohelp:${orgId}`;
  const burst = await chargeRateReceipt(burstKey, HELP_MAX_PER_WINDOW, HELP_WINDOW_SECONDS);
  if (!burst.accepted) {
    throw new HttpError(429, "Too many suggestion requests for now — try again in a few minutes.", "rate_limited");
  }
  return { orgId, burstKey, burstReceipt: burst.receipt };
}

/** Hand back a helper-mode burst charge on failure (audit item 2). Never throws. */
async function refundHelperCharge(charge: HelperCharge): Promise<void> {
  await refundRateReceipt(charge.burstReceipt);
}

// Bound the inline base64 image so a caller can't push unbounded memory
// pressure through readJson (audit round 4). ~12 MB of base64 ≈ 9 MB binary.
const MAX_IMAGE_B64_CHARS = 12_000_000;
const ALLOWED_MIMES = ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"];

const MODEL = (Deno.env.get("GEMINI_IMAGE_MODEL")?.trim() || "gemini-3.1-flash-image");
// Text+vision model for the suggest / improve_prompt helper modes (NOT the
// image model — these are plain generateContent calls returning JSON).
// Text/vision helper model (suggest + improve_prompt). `gemini-2.5-flash` was
// RETIRED — Google returns 404 "no longer available to new users" — which made
// both helper buttons in the app return 502 (found in live verification
// 2026-09-04). Keep this default on a current model and re-check it whenever
// Google publishes a deprecation; the secret GEMINI_TEXT_MODEL overrides it.
const TEXT_MODEL = (Deno.env.get("GEMINI_TEXT_MODEL")?.trim() || "gemini-3.6-flash");
const GEMINI_KEY = Deno.env.get("GEMINI_API_KEY");

// ── Industry profiles (mirrors SpaceType in Models/Listing.swift) ─────────────
// real_estate is UNCHANGED from the proven prompt set; the others swap the
// nouns and the "what to add / what to remove" so the model dresses the right
// kind of space.

const SPACE_TYPES = ["real_estate", "venue", "restaurant", "retail", "fitness", "other"] as const;
type SpaceType = typeof SPACE_TYPES[number];

function spaceTypeOf(raw: unknown): SpaceType {
  const s = String(raw ?? "").trim().toLowerCase().replace(/-/g, "_");
  return (SPACE_TYPES as readonly string[]).includes(s) ? (s as SpaceType) : "real_estate";
}

interface Profile {
  /** "real-estate photo", "restaurant photo", … */
  photo: string;
  /** exterior subject for twilight/sky/lawn */
  exterior: string;
  /** what "lawn" means (grass vs planters) */
  greenery: string;
  /** the clutter list for declutter */
  clutter: string;
  /** what stays identical in declutter */
  keep: string;
  /** what staging ADDS (style aesthetics come from STAGE_STYLES) */
  stageSet: string;
  /** one-line version of stageSet for the suggest instruction */
  stageShort: string;
  /** who the agent is, for the helper instructions */
  audience: string;
}

const PROFILES: Record<SpaceType, Profile> = {
  real_estate: {
    photo: "real-estate photo",
    exterior: "house",
    greenery: "the lawn: lush, healthy, vibrant green grass; remove brown/dead patches, dirt, and weeds",
    clutter: "shoes, bags, boxes, cords, laundry, dishes, papers, toys, toiletries, fridge magnets, and stray items on floors, counters, and surfaces",
    keep: "the room, furniture, decor, and architecture",
    stageSet: "furnish the room with",
    stageShort: "virtually furnish an empty or sparsely furnished room",
    audience: "a real-estate agent",
  },
  venue: {
    photo: "event-venue photo",
    exterior: "venue building",
    greenery: "the grounds and landscaping: lush green lawns, healthy hedges and planters; remove brown patches, dirt, and weeds",
    clutter: "stacked chairs, cables, equipment cases, cleaning supplies, trash, stray signage and personal items on floors and surfaces",
    keep: "the space, its fixtures, lighting rig, and architecture",
    stageSet: "dress the space for an event: round tables with linens and chairs, elegant place settings, floral centerpieces and tasteful uplighting, leaving a clear dance floor where the room allows, all in",
    stageShort: "dress an empty hall for an event (tables, linens, centerpieces, uplighting)",
    audience: "an event-venue manager",
  },
  restaurant: {
    photo: "restaurant photo",
    exterior: "restaurant building",
    greenery: "the outdoor greenery: healthy planters, patio plants and any lawn or hedges; remove dead foliage, dirt, and weeds",
    clutter: "stray napkins, condiment bottles, bus tubs, receipts, cords, trash, and personal items on tables, counters, and floors",
    keep: "the tables, chairs, bar, decor, and architecture",
    stageSet: "dress the dining room for service: tables set with linens, place settings, glassware and small centerpieces, warm ambient candle light, bar seating where present, all in",
    stageShort: "set an empty dining room for service (linens, place settings, glassware)",
    audience: "a restaurant owner",
  },
  retail: {
    photo: "retail-store photo",
    exterior: "storefront",
    greenery: "the outdoor greenery: healthy planters, street trees and any lawn or hedges by the storefront; remove dead foliage, dirt, and weeds",
    clutter: "boxes, stock carts, packaging, cords, handwritten signs, trash, and personal items on floors, counters, and shelves",
    keep: "the fixtures, displays, products, and architecture",
    stageSet: "merchandise the store: fill the existing fixtures, shelves and racks with neatly arranged, brand-free generic products and tasteful displays, keeping walkways clear, all in",
    stageShort: "merchandise empty fixtures and shelves with generic products",
    audience: "a retail store owner",
  },
  fitness: {
    photo: "fitness-studio photo",
    exterior: "gym building",
    greenery: "the outdoor greenery: healthy planters and any lawn or hedges by the entrance; remove dead foliage, dirt, and weeds",
    clutter: "stray towels, water bottles, bags, loose weight plates, cords, trash, and personal items on the floor and benches",
    keep: "the equipment, mats, mirrors, flooring, and architecture",
    stageSet: "equip the studio with modern fitness equipment appropriate to the space (racks, benches, mats, cardio machines) neatly arranged with clear walkways, all in",
    stageShort: "equip an empty studio with fitness equipment",
    audience: "a gym or studio owner",
  },
  other: {
    photo: "commercial-space photo",
    exterior: "building",
    greenery: "the outdoor greenery: healthy planters and any lawn or hedges; remove dead foliage, dirt, and weeds",
    clutter: "boxes, cords, trash, papers, and personal items on floors, counters, and surfaces",
    keep: "the space, furniture, fixtures, and architecture",
    stageSet: "furnish the space with",
    stageShort: "virtually furnish an empty or sparse space",
    audience: "a business owner",
  },
};

/**
 * THE MATERIAL-FACT LINE.
 *
 * Every prompt above instructs the model to preserve ARCHITECTURE — walls,
 * dimensions, window and door placement. That instruction is not verified
 * geometry or a quality guarantee. The CONDITION instruction covers a different
 * thing: an inpainting model asked to tidy a room will happily smooth a cracked
 * wall or a water stain on the way past, because a clean wall is what "tidy"
 * looks like in its training data. Nothing in this file told it not to.
 *
 * The rule comes from a licensed agent — the owner's mother, on the 17 Sep call,
 * describing what she is and is not allowed to do: "You can do things for like
 * maybe design of the house, but you cannot remove things that are there... If
 * there's a huge crack in the wall, you're not supposed to fix that. That should
 * be in the picture." Her other example is the power pole in the backyard that
 * agents were editing out by hand long before any of this existed. The owner's
 * answer on the same call: "No, we will never do that."
 *
 * That is not only an ethics position. A defect removed from a listing photo is
 * a misrepresentation of a material fact, which is the thing that ends licences
 * — and it is the one edit no disclosure sentence makes acceptable, because the
 * buyer's complaint is not "this was AI", it is "the house is not what you
 * showed me". The instruction is included on every route; the output must
 * still be compared with the original before publication.
 */
const CONDITION_LOCK =
  "CRITICAL — MATERIAL FACTS: never repair, patch, hide, clean away, smooth over or " +
  "remove any DEFECT or PERMANENT FEATURE of the property. Cracks, holes, dents, " +
  "stains, water marks, damp, mould, rust, peeling or chipped paint, damaged, worn or " +
  "missing flooring, cracked or broken glass, dated or damaged fixtures and finishes, " +
  "and any sign of wear or disrepair must remain EXACTLY as photographed. The same " +
  "applies to permanent surroundings: power poles and lines, utility boxes and meters, " +
  "antennas and satellite dishes, air-conditioning units, pool cages, fences, sheds, " +
  "driveways, neighbouring buildings and whatever is visible through a window or a " +
  "doorway all stay. If you cannot make the requested change without altering one of " +
  "these, make the smaller change and leave the feature alone. " +
  "The ONE exception, and only when it is what was asked for: grass, planting and the " +
  "sky may be improved. Nothing about the building, the hardscape or the surroundings may. ";

const LOCK =
  "Do not change the building's architecture, structure, dimensions, walls, or " +
  "window/door placement. Never add or remove a window, doorway, wall or opening. " +
  CUSTOM_PHOTO_FIXED_FEATURES + " " +
  "Keep fixed appliances, including refrigerators, ovens, sinks and their connections, in their exact original positions. " + CONDITION_LOCK +
  "Photorealistic, natural, consistent perspective and shadows.";

// Staging instruction; generated results still require original-image review.
const STAGE_LOCK =
  "CRITICAL: keep the room's architecture EXACTLY as photographed — identical walls, " +
  "windows, doors, ceiling, flooring material, trim, built-ins, light fixtures, the view " +
  "through the windows, camera angle, and perspective. Only ADD furniture and decor; do not " +
  "remodel, repaint, resurface, or alter the structure or lighting direction in any way. " +
  "Never invent a window or opening. Do not move, replace or remove refrigerators, ovens, sinks, " +
  "cabinets, counters or other fixed appliances and built-ins. Keep doors, door swings, exits and " +
  "walking routes unobstructed; never put furniture across an opening or into a wall. " +
  CUSTOM_PHOTO_FIXED_FEATURES + " " +
  CONDITION_LOCK +
  "Photorealistic materials with shadows and reflections that match the room's existing light.";

/**
 * The photographer, reflected.
 *
 * Reported by the same agent on the same call: "There's a lot of images where
 * you can see my entire body and face in the glare of a window or a mirror."
 * An agent shooting her own listing is in every mirrored surface in the house,
 * and a person in a listing photo is both unprofessional and, under the HUD
 * guidance this product already follows, something AI media should not be
 * rendering at all.
 *
 * It rides declutter rather than becoming its own mode ON PURPOSE: a new edit
 * mode is a new billable route, a new ledger row, a new provenance kind and a
 * new disclosure sentence, and "a person who is not part of the property" is
 * already what declutter means. No new cost, no new surface.
 */
const REFLECTION_CLAUSE =
  "Also remove any person visible in the photo, including the photographer or a " +
  "phone or camera reflected in mirrors, windows, glass, screens, tiles, appliances " +
  "or any other glossy surface — rebuild the reflection as the empty surface would " +
  "look, reflecting only the room itself. ";

// The proven real-estate prompt set — VERBATIM from the shipped version (the
// industry templates below are for the other space types only).
const RE_PROMPTS: Record<string, string> = {
  twilight:
    "Convert this daytime exterior real-estate photo into a stunning twilight/dusk shot: " +
    "deep blue-to-warm-orange gradient sky, warm glowing interior window lights, subtle " +
    "landscape/path lighting, professional dusk real-estate photography. Keep the house, " +
    "landscaping, driveway, and composition exactly the same — only change the sky and lighting. " + LOCK,
  sky:
    "Replace the dull, grey, or overcast sky in this real-estate photo with a bright, clear " +
    "blue sky with soft natural clouds. Keep the house, trees, and ground exactly the same and " +
    "match the lighting, shadows, and reflections naturally. " + LOCK,
  lawn:
    "Repair and green the lawn in this real-estate photo: lush, healthy, vibrant green grass; " +
    "remove brown/dead patches, dirt, and weeds. Keep the house, hardscape, driveway, plants, " +
    "and everything else identical. " + LOCK,
  declutter:
    "Remove all clutter, mess, and personal items from this real-estate photo: shoes, bags, " +
    "boxes, cords, laundry, dishes, papers, toys, toiletries, fridge magnets, and stray items " +
    "on floors, counters, and surfaces. " + REFLECTION_CLAUSE +
    "Keep the room, furniture, decor, and architecture " +
    "IDENTICAL — same walls, windows, doors, flooring, fixtures, camera angle, and lighting. " +
    "Seamlessly fill revealed floor/surface areas to match the surrounding material and light. " + LOCK,
};

// Real-estate staging furniture sets (verbatim from the shipped version).
const RE_STAGE_STYLES: Record<string, string> = {
  modern:
    "modern contemporary furniture: clean-lined sofa and chairs, a low-profile coffee table, " +
    "a large area rug, tasteful freestanding decor, and movable floor or table lamps in a neutral palette " +
    "with warm accents",
  rustic:
    "rustic farmhouse furniture: warm natural woods, a comfortable linen-upholstered sofa, " +
    "woven and vintage accents, layered cozy textiles, and earthy tones",
  minimalist:
    "minimalist furniture: a few essential low-profile pieces, uncluttered surfaces, a " +
    "restrained monochrome palette, and plenty of intentional negative space",
  contemporary:
    "contemporary furniture: softly curved seating, sculptural movable coffee and side tables, " +
    "layered linen and textured upholstery, a warm neutral palette with restrained deep accents, " +
    "and a few refined freestanding decorative pieces; style only movable furnishings, not " +
    "the photographed building or its fixed finishes",
  scandinavian:
    "Scandinavian furniture: light woods, soft whites with muted pastel accents, simple " +
    "functional pieces, hygge textiles like wool throws and sheepskin, and airy styling",
};

function reStagePrompt(styleDesc: string): string {
  // Style describes movable furnishings; it does not restyle the photographed
  // building. This remains a prompt instruction, subject to manual review.
  return buildRealEstateStagePrompt(styleDesc);
}

function prompts(p: Profile): Record<string, string> {
  return {
    twilight:
      `Convert this daytime exterior ${p.photo} into a stunning twilight/dusk shot: ` +
      "deep blue-to-warm-orange gradient sky, warm glowing interior window lights, subtle " +
      `landscape/path lighting, professional dusk photography. Keep the ${p.exterior}, ` +
      "landscaping, driveway, signage, and composition exactly the same — only change the sky and lighting. " + LOCK,
    sky:
      `Replace the dull, grey, or overcast sky in this ${p.photo} with a bright, clear ` +
      `blue sky with soft natural clouds. Keep the ${p.exterior}, trees, and ground exactly the same and ` +
      "match the lighting, shadows, and reflections naturally. " + LOCK,
    lawn:
      `Repair and green ${p.greenery} in this ${p.photo}. Keep the ${p.exterior}, hardscape, driveway, plants, ` +
      "and everything else identical. " + LOCK,
    declutter:
      `Remove all clutter, mess, and personal items from this ${p.photo}: ${p.clutter}. ` +
      REFLECTION_CLAUSE +
      `Keep ${p.keep} IDENTICAL — same walls, windows, doors, flooring, fixtures, camera angle, and lighting. ` +
      "Seamlessly fill revealed floor/surface areas to match the surrounding material and light. " + LOCK,
  };
}

// Per-style furnishing direction for edit:"stage" (aesthetics; the profile says WHAT to add).
const STAGE_STYLES: Record<string, string> = {
  modern:
    "a modern contemporary style: clean-lined pieces, low-profile tables, tasteful wall art, " +
    "designer accent lighting, and a neutral palette with warm accents",
  rustic:
    "a rustic farmhouse style: warm natural woods, linen upholstery, woven and vintage accents, " +
    "layered cozy textiles, and earthy tones",
  minimalist:
    "a minimalist style: a few essential low-profile pieces, uncluttered surfaces, a restrained " +
    "monochrome palette, and plenty of intentional negative space",
  contemporary:
    "a contemporary style: softly curved seating, sculptural movable tables, layered linen " +
    "and textured upholstery, warm neutrals with restrained deep accents, and refined " +
    "freestanding decor; apply this aesthetic only to movable furnishings, not fixed finishes",
  scandinavian:
    "a Scandinavian style: light woods, soft whites with muted pastel accents, simple functional " +
    "pieces, hygge textiles like wool throws and sheepskin, and airy styling",
};

function stagePrompt(p: Profile, styleDesc: string): string {
  return (
    `Virtually stage this ${p.photo}: ${p.stageSet} ${styleDesc}. ` +
    "Use realistic scale and placement appropriate to the space, resting naturally on the " +
    "existing floor. If the space already has furnishings, replace them cleanly with the new set. " +
    STAGE_LOCK
  );
}

interface Body {
  image_b64?: string;
  mime?: string;
  edit?: string;
  style?: string;
  /** Custom instruction or a staging furnishing brief. */
  prompt?: string;
  staging_reference_b64?: string;
  staging_reference_mime?: string;
  space_type?: string;
  /** Compliance (W2-B3): the listing this photo belongs to. Without it the edit
   *  still runs, but it cannot be entered in the org's AI audit log. */
  listing_id?: string;
  /** "Living room", "Front exterior" — shown next to the public disclosure. */
  label?: string;
  /** capture_asset of the UNTOUCHED source, uploaded via POST /uploads
   *  role:"original". Makes "View original" a real link (CA AB 723). */
  original_asset_id?: string;
  /** ADDITIVE (router): a real inpaint mask for edit:"declutter". White = edit.
   *  The shipped app does not send one; when it is absent the declutter route
   *  asks for a prompt edit instead of a mask edit — see needsForPhotoEdit(). */
  mask_b64?: string;
  mask_mime?: string;
}

// ── AI router glue (docs/AI-ROUTER-CONTRACT.md) ──────────────────────────────

/**
 * The capabilities an edit genuinely REQUIRES, per contract §3.
 *
 * `needs` is a filter, so asking for more than you need costs you your
 * fallbacks. declutter therefore requires "mask" ONLY when the caller actually
 * sent one: the mask steps (flux-fill, gpt-image-2) cannot run without it, and
 * requiring the capability with no mask to send would skip the prompt-edit step
 * that serves every shipped client today and then fail on the mask step.
 */
export function needsForPhotoEdit(edit: string, hasMask: boolean): string[] {
  if (edit === "declutter") return hasMask ? ["mask"] : ["prompt-edit"];
  if (edit === "stage" || edit === "custom") return ["prompt-edit", "fidelity"];
  return ["prompt-edit"];
}

/**
 * Retained descriptor for the shared resolver API. Photo tasks now require
 * an enabled database route; resolveChain never executes these constants
 * when photo authorization is absent (0056).
 */
export function legacyPhotoStep(task: string): RouteStep {
  return {
    route_id: "legacy-local",
    task,
    provider: "gemini",
    model: MODEL,
    unit: "image",
    unit_cents: APP_AI_UNIT_CENTS.gemini_image,
    capabilities: ["prompt-edit"],
    max_latency_s: 60,
    min_plan: "free",
    same_model_as: null,
    privacy_tier: "retained_30d",
    enabled: true,
  };
}

/** edit id → the provenance `kind` the audit log and the tour disclose. */
function provenanceKind(edit: string): ProvenanceKind {
  if (edit === "stage") return "virtual_stage";
  if (edit === "declutter") return "declutter";
  return "photo_edit";
}

const MAX_CUSTOM_PROMPT = 600;
// The improve_prompt caps now come from the SHARED polisher module so this
// function and POST /ai-copy/edit-prompt cannot disagree about them. Same
// 600 characters in / 400 out; generation never truncates the user's request.
const MAX_IMPROVE_INPUT = MAX_PROMPT_INPUT;   // rough idea in
const MAX_IMPROVE_OUTPUT = MAX_PROMPT_OUTPUT; // polished instruction out

/** Wrap a user's free-text instruction with the guardrails every edit gets. */
function customPrompt(p: Profile, preparedInstruction: string): string {
  const truth = p === PROFILES.real_estate
    ? "this is a real property listing"
    : "this is a real place being marketed";
  return (
    `Edit this ${p.photo} as follows: ` + preparedInstruction + " " +
    `Stay photorealistic and true to the space — ${truth}. ` + LOCK
  );
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();
  try {
    const user = await getUser(req); // owner auth; RLS not needed (no DB touch beyond quota)
    if(req.method==="GET"&&new URL(req.url).pathname.endsWith("/ai-photo/status")){
      const row=await statusPhotoQuality(adminClient(),user.id,new URL(req.url).searchParams.get("check_id")??"",preferredOrg(req)??null);
      return await photoQualityResponse(adminClient(),row,user.id,preferredOrg(req)??null);
    }
    if (req.method !== "POST") throw new HttpError(405, "POST only");
    if(new URL(req.url).pathname.endsWith("/ai-photo/check-existing")){
      const body=calibrationRequest(await readJsonLimited(req,12_100_000));
      const org=await requireEditorRole(user,req,"Photo quality checks",body.generation_request_body.listing_id);
      const row=await beginPhotoCalibration(adminClient(),{actor:user.id,org,selected:preferredOrg(req)??null,body});
      const checked=await waitForPhotoQuality(adminClient(),row,{actor:user.id,selected:preferredOrg(req)??null,request:req,instruction:body.generation_request_body.prompt});
      return await photoQualityResponse(adminClient(),checked,user.id,preferredOrg(req)??null);
    }
    if (!GEMINI_KEY) throw new HttpError(500, "GEMINI_API_KEY function secret is not set", "internal");

    // VALIDATE FIRST, CHARGE SECOND (audit round 4). Every quota consumption
    // below happens only once we know the request would actually reach Gemini.
    const body = await readJson<Body>(req);
    const edit = String(body.edit ?? "twilight").trim().toLowerCase();
    // Plain-object prompt lookup must not accept inherited keys as edit modes.
    assert(["twilight", "sky", "lawn", "declutter", "stage", "custom", "suggest", "improve_prompt"].includes(edit),
      400, "Choose a supported photo editing tool.");
    const mime = String(body.mime ?? "image/jpeg").split(";")[0].trim().toLowerCase();
    const space = spaceTypeOf(body.space_type);
    const profile = PROFILES[space];

    // The fair-housing gate scopes itself on the LISTING's business type — a
    // bar's custom edit is not housing advertising (industry review P1-1). The
    // listing row wins, the request's space_type is the fallback, and nothing
    // at all means the stricter housing rules (see _shared/fairhousing.ts).
    // Resolved only on the two free-text paths that are gated.
    const gateSpace = async (): Promise<string> =>
      (await listingSpaceType(userClient(req), body.listing_id)) ?? space;

    if (body.image_b64 !== undefined) {
      assert(typeof body.image_b64 === "string", 400, "image_b64 must be a string");
      assert(body.image_b64.length <= MAX_IMAGE_B64_CHARS, 413,
             "image is too large — resize it before sending", "payload_too_large");
      assert(ALLOWED_MIMES.includes(mime), 400, `mime must be one of ${ALLOWED_MIMES.join(", ")}`);
    }
    // Same bound on the optional router mask: an unbounded second image would
    // reopen the memory-pressure hole the image_b64 cap closed (audit round 4).
    if (body.mask_b64 !== undefined) {
      assert(typeof body.mask_b64 === "string", 400, "mask_b64 must be a string");
      assert(body.mask_b64.length <= MAX_IMAGE_B64_CHARS, 413,
             "mask is too large — resize it before sending", "payload_too_large");
      const mm = String(body.mask_mime ?? "image/png").split(";")[0].trim().toLowerCase();
      assert(ALLOWED_MIMES.includes(mm), 400, `mask_mime must be one of ${ALLOWED_MIMES.join(", ")}`);
    }

    // Helper modes: text/vision analysis only — no image generation, no monthly charge.
    const referenceB64 = body.staging_reference_b64;
    const referenceMime = String(body.staging_reference_mime ?? "image/jpeg").split(";")[0].trim().toLowerCase();
    if (referenceB64 !== undefined) {
      assert(edit === "stage" && typeof referenceB64 === "string" && referenceB64.length > 0, 400,
        "A furniture reference is supported only for staging.");
      assert(referenceB64.length <= 6_000_000 && (body.image_b64?.length ?? 0) + referenceB64.length <= MAX_IMAGE_B64_CHARS,
        413, "The staging images are too large — resize them before sending.", "payload_too_large");
      assert(["image/jpeg", "image/png", "image/webp"].includes(referenceMime), 400,
        "The furniture reference must be JPEG, PNG or WebP.");
      // The route's per-output-image price does not cover input tokens. A
      // second image cannot dispatch until an approved conservative cost
      // preflight covers both inputs. Refuse before any quota is consumed.
      throw new HttpError(503, "Same-room furniture references are coming soon. No edit was sent or charged. Stage without a reference for now.", "upstream");
    }
    if (edit === "suggest") {
      assert(body.image_b64, 400, "image_b64 is required");
      const helperCharge = await guardHelper(user, req, body.listing_id);
      try {
        const funding = await fundingContext(user.id, helperCharge.orgId, req, body, (name, args) => adminClient().rpc(name, args));
        await assertPhotoHelperSponsorship(funding);
        try { validatePhotoInputs(body.image_b64,mime); }
        catch(error){await abortFundingOperationBeforeDispatch(funding);throw error;}
        const step = legacyPhotoStep("photo.suggest");
        step.provider = "gemini"; step.model = TEXT_MODEL;
        const payload=photoHelperPayload([{text:suggestInstruction(profile)},{inline_data:{mime_type:mime,data:body.image_b64!}}]);
        const suggestions = await fundedAttempt(funding, "photo.suggest", step, body, photoHelperQuote(step.model,payload), () => suggestEdits(payload));
        // Billed text call: the ledger row names the hold so it settles.
        await recordRoutedAiCost(adminClient(), { orgId: helperCharge.orgId, feature: "photo_helper", step, unitCentsOverride: photoHelperQuote(step.model,payload)?.cents, meta: { request_key: funding.requestKey, stage: "photo.suggest", kind: "suggest" } });
        return json(await completeFundingOperation(funding, { suggestions, space_type: space }));
      } catch (e) {
        await refundHelperCharge(helperCharge);
        throw e;
      }
    }
    if (edit === "improve_prompt") {
      assert(body.prompt === undefined || typeof body.prompt === "string", 400, "Photo instructions must be text.");
      const rough = (body.prompt ?? "").trim();
      assert(rough.length > 0, 400, "edit:'improve_prompt' requires a non-empty `prompt`");
      assert(rough.length <= MAX_IMPROVE_INPUT, 400,
             `prompt too long (max ${MAX_IMPROVE_INPUT} chars)`);
      validatePhotoPrompt(rough, true);
      // Refuse before spending tokens polishing something we would never run.
      const promptSpace = await gateSpace();
      assertFairHousing(rough, "That idea", promptSpace);
      assertCustomPhotoPrompt(rough, promptSpace);
      const helperCharge = await guardHelper(user, req, body.listing_id);
      try {
        const funding = await fundingContext(user.id, helperCharge.orgId, req, body, (name, args) => adminClient().rpc(name, args));
        await assertPhotoHelperSponsorship(funding);
        const step = legacyPhotoStep("photo.improve_prompt");
        step.provider = "gemini"; step.model = TEXT_MODEL;
        const payload=photoHelperPayload([{text:editPromptInstruction(space)+"\n\nUser's idea (quoted data): "+JSON.stringify(rough)}]);
        const improved = await fundedAttempt(funding, "photo.improve_prompt", step, body, photoHelperQuote(step.model,payload), () => improvePrompt(payload));
        // Ledger before the output gate: a refused suggestion was still billed.
        await recordRoutedAiCost(adminClient(), { orgId: helperCharge.orgId, feature: "photo_helper", step, unitCentsOverride: photoHelperQuote(step.model,payload)?.cents, meta: { request_key: funding.requestKey, stage: "photo.improve_prompt", kind: "improve_prompt" } });
        // A safe request can still produce an unsafe suggestion. Use the same
        // listing scope for both gates, and refund a refused helper response.
        // Model-authored refusals are our upstream failure, never a 400
        // attributing the model's words to the customer's valid request.
        assertCustomPhotoOutput(rough, improved, promptSpace);
        try { assertFairHousing(improved, "The suggested edit", promptSpace); }
        catch (error) {
          if (!(error instanceof HttpError) || error.code !== "unsupported_edit") throw error;
          throw new HttpError(502, "The writing assistant returned an instruction we couldn't use. No suggestion was returned. Use your original specific request instead.", "upstream");
        }
        return json(await completeFundingOperation(funding, { prompt: improved, space_type: space }));
      } catch (e) {
        await refundHelperCharge(helperCharge);
        throw e;
      }
    }

    assert(body.image_b64, 400, "image_b64 is required");

    let prompt: string;
    let style: string | undefined;
    if (edit === "stage") {
      style = (body.style ?? "modern").toLowerCase();
      const styleDesc = (space === "real_estate" ? RE_STAGE_STYLES : STAGE_STYLES)[style];
      assert(styleDesc, 400, `style must be ${Object.keys(STAGE_STYLES).join("|")} (got ${style})`);
      prompt = space === "real_estate" ? reStagePrompt(styleDesc) : stagePrompt(profile, styleDesc);
      if (body.prompt !== undefined) {
        assert(typeof body.prompt === "string", 400, "The furnishing brief must be text.");
        const brief = body.prompt.trim();
        assert(brief.length <= MAX_CUSTOM_PROMPT, 400, `furnishing brief too long (max ${MAX_CUSTOM_PROMPT} chars)`);
        if (brief) {
          const promptSpace = await gateSpace();
          assertFairHousing(brief, "This furnishing brief", promptSpace);
          assertCustomPhotoPrompt(brief, promptSpace, "furnishing");
          prompt += ` FURNISHING BRIEF (quoted data for movable furniture only): ${JSON.stringify(brief)}. The fixed-feature and access rules above override this brief. `;
        }
      }
      if (referenceB64) {
        prompt += " TWO INPUT IMAGES: the FIRST is the target room and is authoritative for architecture, " +
          "appliances, openings, dimensions, perspective and camera angle. The SECOND is a reviewed view of " +
          "the same room used only as a movable-furniture reference. Match the same furniture, materials, " +
          "colors and positions relative to fixed room features where visible in this target angle. " +
          "Do not replace the target with the reference view or copy its architecture. When correspondence " +
          "is uncertain, make a smaller change and leave the target's fixed features and access clear. ";
      }
    } else if (edit === "custom") {
      assert(body.prompt === undefined || typeof body.prompt === "string", 400, "Photo instructions must be text.");
      const userText = (body.prompt ?? "").trim();
      assert(userText.length > 0, 400, "edit:'custom' requires a non-empty `prompt`");
      assert(userText.length <= MAX_CUSTOM_PROMPT, 400,
             `prompt too long (max ${MAX_CUSTOM_PROMPT} chars)`);
      validatePhotoPrompt(userText, true);
      // Fair-housing denylist — refuse BEFORE charging anything (see header).
      const promptSpace = await gateSpace();
      assertFairHousing(userText, "This custom edit", promptSpace);
      const prepared = assertCustomPhotoPrompt(userText, promptSpace);
      prompt = customPrompt(profile, prepared.prompt!);
    } else {
      prompt = (space === "real_estate" ? RE_PROMPTS : prompts(profile))[edit];
      assert(prompt, 400,
             `edit must be twilight|sky|lawn|declutter|stage|custom|suggest|improve_prompt (got ${edit})`);
    }

    // FAIR-HOUSING GUARDRAILS on every prompt, canned or free-text (HUD 2024).
    // twilight|sky|lawn get the scoped permanence clause — see fairhousing.ts.
    prompt = `${prompt} ${guardrailsFor(edit)}`;

    // Everything validated — NOW charge the quota, immediately before the
    // billable provider call. Keep the org it charged for the cost_ledger row,
    // and the plan for the router's RouteContext.
    const orgId = await requireEditorRole(user, req, "AI photo edits", body.listing_id);
    const requestKey = requiredIdempotencyKey(req).trim();
    const resultIdentity = { actorId: user.id, orgId, requestKey, listingId: body.listing_id ?? null };
    let funding: FundingContext = {actorId:user.id,orgId,requestKey,rpc:(name,args)=>adminClient().rpc(name,args)};
    try {
      funding = await fundingContext(user.id, orgId, req, body, funding.rpc);
    } catch (error) {
      if (error instanceof SavedFundingResponse || (error instanceof HttpError && error.details?.funding_operation_replay === true)) {
        // The serving-operation begin above checks the complete request hash.
        // Resolve prospective policy FIRST, even when its pointer ACK was lost.
        const quality=await lookupPhotoQuality(adminClient(),resultIdentity);
        if(quality){
          assert(quality.evidence.request_sha256===await inputHash(body),409,"This request identifier belongs to different photo instructions.","conflict");
          await photoQualityScope(adminClient(),quality,user.id,preferredOrg(req)??null);
          const continued=await waitForPhotoQuality(adminClient(),quality,{actor:user.id,selected:preferredOrg(req)??null,request:req,instruction:body.prompt});
          return await photoQualityResponse(adminClient(),continued,user.id,preferredOrg(req)??null,{space_type:space});
        }
        const stored=error instanceof SavedFundingResponse?error.saved_response:undefined;
        assert(stored?.kind!=="photo_quality",503,"The saved photo quality journal is temporarily unavailable. No new edit was started.","upstream");
        const pointer = stored as unknown as PhotoResultPointer|undefined;
        const saved = await restorePhotoResult(adminClient(), resultIdentity, pointer);
        if (!saved) throw new HttpError(409, "This edit is already underway, but its saved image is not available yet. Retry the same request shortly.", "conflict");
        const metadata = pointer?.metadata ?? {
          edit, space_type: space, ...(style ? {style} : {}),
          disclosure: disclosureFallback(provenanceKind(edit), edit),
          provenance: { id: null, recorded: false, reason: "The image was recovered before its disclosure receipt was saved. Review the original before publishing." },
        };
        if (!pointer) await completeFundingOperation(funding, {kind:"photo_output",bucket:"renders",key:saved.key,mime:saved.mime,metadata});
        return photoJsonResponse(metadata,saved.image_b64,saved.mime,saved.key);
      }
      throw error;
    }
    // Saved results above retain their original request/history. The new
    // still-image and UTF-8 policy governs prospective dispatch only.
    try {
      validatePhotoInputs(body.image_b64,mime,body.mask_b64,
        String(body.mask_mime??"image/png").split(";")[0].trim().toLowerCase());
      if(edit==="custom" || edit==="stage")validatePhotoPrompt(String(body.prompt??"").trim(),true);
      validatePhotoPrompt(prompt);
    }catch(error){await abortFundingOperationBeforeDispatch(funding);throw error;}
    let charge: EditCharge;
    try { charge = await guardEdit(user, req, body.listing_id); }
    catch (error) { await abortFundingOperationBeforeDispatch(funding); throw error; }
    const { plan } = charge;
    if (charge.orgId !== orgId) { await refundEditCharge(charge); await abortFundingOperationBeforeDispatch(funding); throw new HttpError(409,"The generation workspace changed. Please retry.","conflict"); }

    // ── ROUTER (flag-gated, additive) ────────────────────────────────────────
    // The fair-housing gate above has already run — contract §4 puts it BEFORE
    // resolveRoute on every task that takes free text, and it is the one thing
    // no routing decision may skip.
    //
    // Flag OFF: resolveRoute requires the enabled, eligible photo fallback
    // (0056). Flag ON: the seeded chain runs, each
    // attempt is reported for the circuit breaker, and the ledger row carries
    // the provider/model that actually ran.
    const task = `photo.${edit}`;
    const maskB64 = typeof body.mask_b64 === "string" && body.mask_b64.length > 0 ? body.mask_b64 : null;
    const maskMime = String(body.mask_mime ?? "image/png").split(";")[0].trim().toLowerCase();
    const routerOn = await routerEnabled();
    let steps: RouteStep[];
    try {
      steps = await resolveChain(
        task,
        {
          plan,
          needs: needsForPhotoEdit(edit, maskB64 !== null),
          // A photograph of somebody's home: never a vendor that trains on it.
          carries_customer_media: true,
        },
        legacyPhotoStep(task),
      );
    } catch (e) {
      // No authorized route means no provider ran; return both quota charges.
      await refundEditCharge(charge);
      await abortFundingOperationBeforeDispatch(funding);
      throw e;
    }

    let genInput: GenerateInput = {
      task,
      prompt,
      image_b64: body.image_b64,
      // fal/OpenAI take a URL; a data URI is what this function already hands
      // fal today, so the bytes still never leave our process except to the
      // provider that runs the edit.
      image_url: `data:${mime};base64,${body.image_b64}`,
      ...(maskB64 ? { mask_url: `data:${maskMime};base64,${maskB64}` } : {}),
      extra: { image_mime: mime, ...(maskB64 ? { mask_mime: maskMime } : {}) },
    };

    // GEMINI_IMAGE_MODEL is an operator override that predates the routing
    // table. While the router is OFF it still wins for the legacy gemini step,
    // so the flag-off path stays exactly what THIS deploy runs today even if
    // the secret and the seeded legacy row ever disagree.
    let chain = routerOn ? steps : steps.map((s) =>
      s.provider === "gemini" && s.model === "gemini-2.5-flash-image" && MODEL !== s.model ? { ...s, model: MODEL } : s
    );
    if (referenceB64) {
      // Preserve route retirement, privacy, plan and operator eligibility. Never
      // silently drop a reference or send it to a single-image adapter.
      chain = chain.filter((step) => step.provider === "gemini" && supportsStagingReference(step.model));
      if (chain.length === 0) {
        await refundEditCharge(charge);
        await abortFundingOperationBeforeDispatch(funding);
        throw new HttpError(503, "Same-room furniture references are unavailable on the active photo route. No edit was sent. Try staging without a reference or wait until the route supports it.", "upstream");
      }
      genInput.extra = { ...genInput.extra, staging_reference_b64: referenceB64, staging_reference_mime: referenceMime };
    }

    const ownerPhotoStep = await ownerQaPhotoStep({actorId:user.id,orgId,listingId:body.listing_id,task});
    if (ownerPhotoStep) {
      try { genInput = prepareOwnerQaPhotoInput(genInput); }
      catch(error) { await refundEditCharge(charge); await abortFundingOperationBeforeDispatch(funding); throw error; }
      // Explicit comparison is one full Flash2K step, never a quiet 1K fallback.
      chain = [ownerPhotoStep];
    }
    const normalPhoto4K = !ownerPhotoStep && !maskB64;
    if (normalPhoto4K) {
      try { genInput = preparePhoto4KInput(genInput); chain = photo4KChain(chain, genInput); }
      catch(error) { await refundEditCharge(charge); await abortFundingOperationBeforeDispatch(funding); throw error; }
    }
    // Masked Fill keeps its legacy resolution, but its per-megapixel quote
    // and the successful ledger entry must use the same complete source bound.
    try {
      if (maskB64) chain = priceMaskedPhotoChain(chain, genInput);
      chain = await boundedPhotoChain(funding, chain, genInput);
    }
    catch(error) {
      await refundEditCharge(charge);
      await abortFundingOperationBeforeDispatch(funding);
      throw error;
    }

    // This is the sole new-generation owner. While policy is disabled begin
    // fails before supplier dispatch; historical saved results above still work.
    let quality:PhotoQualityEnvelope;
    try{
      quality=await beginPhotoQuality(adminClient(),resultIdentity,{edit,style,instruction:body.prompt,originalAsset:body.original_asset_id,imageB64:body.image_b64,mime});
      if(quality.created!==true){
        await refundEditCharge(charge);
        return await photoQualityResponse(adminClient(),quality,user.id,preferredOrg(req)??null,{space_type:space});
      }
    }catch(error){await refundEditCharge(charge);await abortFundingOperationBeforeDispatch(funding);throw error;}

    // The chain throwing means every step failed (or a validation/nsfw refusal
    // fired) — no image was produced, so hand the quota back (audit item 2 /
    // F-E-16). Once runChain RETURNS, a provider ran and produced bytes; the
    // ledger write just below is what records that, and nothing past this
    // point is ever refunded.
    let attempt: ChainResult<{ b64: string; mime: string; local: DoneState }>;
    try {
      attempt = await runChain(task, chain, async (step) => {
        if (ownerPhotoStep) {
          const currentOrg = await requireEditorRole(user, req, "AI photo edits", body.listing_id);
          if (currentOrg !== orgId || !(await ownerQaPhotoStep({actorId:user.id,orgId,listingId:body.listing_id,task})))
            throw new HttpError(403,"The temporary 2K comparison authorization ended. No new edit was sent.","forbidden");
        }
        const adapter = adapterFor(step.provider);
        const ref = await fundedAttempt(funding, `${task}:${chain.indexOf(step)}`, step, genInput, mediaAttemptQuote(step, genInput), () => adapter.submit(step, genInput));
        const done = await awaitJob(adapter, ref, BUDGETS.totalImageMs);
        // One download, reused for both the inline answer and the R2 copy.
        const local = await inlineImageResult(step.provider, done);
        const b64 = inlineBase64(local);
        if (!b64) throw new ProviderError(step.provider, "upstream", `${step.provider} returned no image bytes`);

        return { b64, mime: local.mime, local };
      });
    } catch (e) {
      const retainCharge=e instanceof HttpError&&e.details?.retain_feature_charge===true;
      if(!retainCharge)await refundEditCharge(charge);
      try{
        quality=await failPhotoQuality(adminClient(),quality,retainCharge?"photo_provider_wire_size":"generation",{provider_cost_incurred:"possible",retained_output:false,...(retainCharge?{max_response_bytes:e.details?.max_response_bytes}:{}),message:"The generation did not return a confirmed image. No repeat generation was started."});
        return await photoQualityResponse(adminClient(),quality,user.id,preferredOrg(req)??null);
      }catch(statusError){if(statusError instanceof HttpError&&statusError.code.startsWith("photo_quality_"))throw statusError;}
      throw e;
    }
    const step = attempt.step;
    let outB64 = attempt.value.b64;
    const outMime = attempt.value.mime;
    await completeFundingOperation(funding,{kind:"photo_quality",evidence_id:quality.evidence.id});

    // COST LEDGER (F-E-15): the image edit succeeded and is billed, so record
    // ONE org-scoped cost_ledger row with job_id = NULL. This is what the owner
    // spend console and the per-org monthly COGS view read for app AI. The
    // provider/model/price come from the step that ACTUALLY ran (contract §4);
    // Normal unmasked edits price the complete requested4K bound on that route.
    // Best effort — a failed insert must never fail an edit the caller has paid
    // for (see recordAppAiCost). Only reached on success, so a failure above
    // (which F-E-16 refunds) writes no row: no double-count.
    await recordRoutedAiCost(adminClient(), {
      orgId,
      feature: "photo_edit",
      step,
      images: 1,
      meta: { edit, space_type: space, ...((ownerPhotoStep || normalPhoto4K) ? {image_size:normalPhoto4K?"4K":"2K",owner_quality_comparison:!!ownerPhotoStep,cost_basis:normalPhoto4K?"complete_input_4096_text_2520_image_bound":"complete_input_4096_text_1680_image_bound",input_token_allowance:genInput.extra?.photo_input_allowance ?? 8192} : {}), ...(maskB64&&isMaskedFillStep(step)?{cost_basis:"source_megapixels_rounded_up_5_cents_bound",priced_megapixels:step.unit_cents/5}:{}), request_key: funding.requestKey, stage: `${task}:${chain.indexOf(step)}`, ...(style ? { style } : {}),
        ...(referenceB64 ? { input_images: 2, staging_furniture_reference: true,
          ...(normalPhoto4K ? {} : {cost_basis: "route_output_image_estimate_input_tokens_unmodeled"}) } : {}) },
    });

    // Ledger liability above survives every later quality/storage refusal.
    // Decode once within the measured9MB envelope, retain exact quarantine
    // bytes, then evaluate requested geometry. Even a wrong-size valid photo
    // remains private evidence rather than being silently discarded.
    let phase="photo_output_validation";
    try{
      const decoded=decodePhotoOutput(outB64,outMime);
      phase="evidence_persistence";
      quality=await retainPhotoCandidate(adminClient(),quality,decoded,{stage:`${task}:${chain.indexOf(step)}`,provider:step.provider,model:step.model});
      phase="photo_output_geometry";
      if(ownerPhotoStep)assertOwnerQaPhotoOutput(outB64,outMime);
      else if(normalPhoto4K)assertPhoto4KGeometry(decoded);
    }catch(error){
      const over=error instanceof HttpError&&error.details?.failure_phase==="photo_output_size";
      quality=await failPhotoQuality(adminClient(),quality,over?"photo_output_size":phase,{provider_cost_incurred:true,retained_output:!!quality.evidence.output_etag,encoded_characters:outB64.length,mime:outMime,provider:step.provider,model:step.model,message:over?"The paid image exceeded the safe9MB output bound and could not be retained.":"The generated edit could not be confirmed as a usable high-resolution photo. No new generation was started."});
      return await photoQualityResponse(adminClient(),quality,user.id,preferredOrg(req)??null);
    }
    // The heavy judge runs in its separate service function. Retain this exact
    // already-validated base64 for the eventual accepted reply, avoiding another
    //9MB download/decode/encode in the generation isolate.
    const inlineCandidate={imageB64:outB64,key:quality.evidence.output!.key,mime:outMime,sha256:quality.evidence.output!.sha256,bytes:quality.evidence.output!.bytes};
    attempt.value.b64="";attempt.value.local={status:"done",mime:outMime,result_url:""};
    quality=await waitForPhotoQuality(adminClient(),quality,{actor:user.id,selected:preferredOrg(req)??null,request:req,instruction:body.prompt});
    return await photoQualityResponse(adminClient(),quality,user.id,preferredOrg(req)??null,{space_type:space,...(routerOn?{route:{provider:step.provider,model:step.model,route_id:step.route_id}}:{})},undefined,inlineCandidate);
  } catch (err) {
    return respondError(err);
  }
});

// ── helper modes: suggest / improve_prompt (text+vision, JSON out) ────────────

interface Suggestion {
  edit: string;
  reason: string;
  confidence: number;
}

const SUGGESTABLE_EDITS = ["twilight", "sky", "lawn", "declutter", "stage"];

function suggestInstruction(p: Profile): string {
  return (
    `You are reviewing ONE ${p.photo} for ${p.audience}. These are the available ` +
    "one-tap AI edits:\n" +
    "- twilight: turn a daytime EXTERIOR into a dusk shot with glowing windows (exteriors only)\n" +
    "- sky: replace a dull/grey/overcast sky with a clear blue one (only when sky is visible " +
    "and actually dull)\n" +
    `- lawn: green up unhealthy outdoor greenery (only when ${p.greenery.split(":")[0]} is visible and looks unhealthy)\n` +
    `- declutter: remove mess and personal items (${p.clutter.split(",").slice(0, 3).join(",")}, …) from floors and surfaces (only when visible ` +
    "clutter hurts the shot)\n" +
    `- stage: ${p.stageShort} (empty/sparse interiors only)\n\n` +
    "Recommend ONLY edits that would genuinely improve THIS specific photo — an interior must " +
    "never get twilight/sky/lawn, an already furnished/dressed space must never get stage, a clean space must " +
    "never get declutter. Zero suggestions is a valid answer.\n\n" +
    'Reply with STRICT JSON only, shaped exactly like {"suggestions":[{"edit":"sky",' +
    '"reason":"...","confidence":0.9}]} — at most 3 entries, best first. "reason" is a plain-' +
    "language sentence of at most 80 characters written for the owner (e.g. \"Grey sky makes " +
    "the building look gloomy\"). \"confidence\" is 0 to 1."
  );
}

/** edit:"suggest" — analyze the photo and pick up to 3 genuinely useful edits. */
async function suggestEdits(payload:PhotoHelperPayload): Promise<Suggestion[]> {
  const raw = await geminiText(payload);

  const parsed = parseJsonLoose(raw);
  const list = Array.isArray((parsed as Record<string, unknown>)?.suggestions)
    ? (parsed as { suggestions: unknown[] }).suggestions
    : Array.isArray(parsed)
    ? (parsed as unknown[])
    : [];

  const out: Suggestion[] = [];
  const seen = new Set<string>();
  for (const item of list) {
    if (out.length >= 3) break;
    if (!item || typeof item !== "object") continue;
    const o = item as Record<string, unknown>;
    const edit = String(o.edit ?? "").toLowerCase().trim();
    if (!SUGGESTABLE_EDITS.includes(edit) || seen.has(edit)) continue;
    const reason = String(o.reason ?? "").trim().slice(0, 80);
    let confidence = Number(o.confidence);
    if (!Number.isFinite(confidence)) confidence = 0.5;
    confidence = Math.min(1, Math.max(0, Math.round(confidence * 100) / 100));
    out.push({ edit, reason, confidence });
    seen.add(edit);
  }
  return out;
}

/**
 * edit:"improve_prompt" — rewrite a rough custom-edit idea into a precise one.
 *
 * THIN FORWARD TO THE SHARED POLISHER (2026-09-07). The instruction this used
 * to build locally now lives in ai-copy/prompt.ts `editPromptInstruction()`,
 * which POST /ai-copy/edit-prompt builds from as well, so there is ONE
 * prompt-polisher rather than two that drift apart the first time either is
 * improved. The shared version is also STRONGER: it asks for the same density
 * of direction a preset carries (what changes / what stays IDENTICAL /
 * materials, shadows and reflections that match the existing light), which is
 * the asymmetry this whole feature exists to close — a preset edit got ~60
 * words of engineered direction while a custom edit got one sentence.
 *
 * NOTHING THE CLIENT SEES MOVES. Shipped app builds still call
 * `edit:"improve_prompt"` on THIS function; the request body, the response
 * shape ({ prompt, space_type }), the caps (300 in / 400 out), the gate order,
 * the model (TEXT_MODEL) and helper limiter remain unchanged. Paid helpers use
 * their separately priced shared wallet; bounded trial helpers are excluded.
 */
async function improvePrompt(payload:PhotoHelperPayload): Promise<string> {
  const raw = await geminiText(payload);

  const parsed = parseJsonLoose(raw);
  let improved = "";
  if (parsed && typeof parsed === "object" && typeof (parsed as Record<string, unknown>).prompt === "string") {
    improved = ((parsed as Record<string, unknown>).prompt as string).trim();
  } else if (typeof raw === "string") {
    // Model ignored the JSON contract — fall back to its plain text.
    improved = raw.replace(/^```(?:json)?|```$/g, "").replace(/^"|"$/g, "").trim();
  }
  if (!improved) throw new HttpError(502, "Gemini returned no improved prompt", "upstream");
  improved = improved.replace(/\s+/g, " ");
  if (improved.length > MAX_IMPROVE_OUTPUT) throw new HttpError(502, "The writing assistant returned an instruction that was too long. No suggestion was returned.", "upstream");
  return improved;
}

/** One text/vision generateContent call on the cheap flash model → first text part. */
async function geminiText(payload:PhotoHelperPayload): Promise<string> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${TEXT_MODEL}:generateContent`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_KEY! },
    body: JSON.stringify(payload),
  });
  const data = await res.json().catch(() => ({} as Record<string, unknown>));
  if (!res.ok) {
    throw new HttpError(502, `Gemini ${res.status}: ${JSON.stringify(data).slice(0, 300)}`, "upstream");
  }
  // deno-lint-ignore no-explicit-any
  for (const cand of ((data as any).candidates ?? [])) {
    for (const part of ((cand.content?.parts) ?? [])) {
      if (typeof part.text === "string" && part.text.trim()) return part.text as string;
    }
  }
  throw new HttpError(502, `Gemini returned no text. ${JSON.stringify(data).slice(0, 200)}`, "upstream");
}

/** Defensive JSON parse: strip code fences, else grab the first {...} block. */
function parseJsonLoose(raw: string): unknown {
  const cleaned = raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  try {
    return JSON.parse(cleaned);
  } catch {
    const start = cleaned.indexOf("{");
    const end = cleaned.lastIndexOf("}");
    if (start >= 0 && end > start) {
      try {
        return JSON.parse(cleaned.slice(start, end + 1));
      } catch {
        return null;
      }
    }
    return null;
  }
}
