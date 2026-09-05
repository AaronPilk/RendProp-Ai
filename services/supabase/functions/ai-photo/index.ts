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
//   style      = modern | rustic | minimalist | scandinavian   (stage only; default modern)
//   space_type = real_estate | venue | restaurant | retail | fitness | other (default real_estate)
//                Selects the industry prompt set: a restaurant is dressed for
//                service, a gym gets equipment, a store gets merchandised — not
//                a sofa and coffee table (audit F-A-07 / F-supabase-10).
//
// Two cheap text/vision helper modes. They are NOT charged against the monthly
// photo-edit allowance (they generate no image); they have their own burst
// limiter (aiphotohelp:<org>, 120 / 5 min) and the same role gate:
//
//   edit:"suggest"         { image_b64, mime?, space_type? }  ->  { suggestions: [{ edit, reason, confidence }] }
//       Looks at the photo and recommends up to 3 edits (from the 5 canned ones)
//       that would genuinely improve it — e.g. twilight only for exteriors.
//
//   edit:"improve_prompt"  { prompt, space_type? }            ->  { prompt }
//       Rewrites the user's rough custom-edit idea (≤300 chars) into a precise,
//       photorealistic edit instruction (≤400 chars). The improved prompt is
//       meant to be sent back as edit:"custom", where the architecture-lock
//       guardrails are appended server-side as usual. (The image is not needed
//       for this mode and is ignored if sent.)
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
// do not.)
//
// PROVENANCE. A successful edit records one media_provenance row (migration
// 0012) via the record_provenance RPC when `listing_id` is sent, mapping
// stage → virtual_stage, declutter → declutter, everything else → photo_edit.
// The response always carries `disclosure` (the exact sentence the public tour
// will print for this asset — CA AB 723 / NorthstarMLS) and `provenance`
// ({ id, recorded, reason? }). Recording is BEST EFFORT: a failed audit insert
// never fails an edit the caller has already paid for.
// `original_asset_id` (optional) is the untouched source uploaded via
// POST /uploads role:"original", which makes "View original" a real public link
// — the access-to-the-original half of AB 723.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, readJson, respondError } from "../_shared/http.ts";
import { adminClient, getUser, orgForUser, preferredOrg } from "../_shared/supabase.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { entitlementForCharge, quotaError } from "../_shared/entitlements.ts";
import { assertFairHousing, guardrailsFor } from "../_shared/fairhousing.ts";
import { type ProvenanceKind, recordProvenance } from "../_shared/provenance.ts";
import { APP_AI_UNIT_CENTS, recordRoutedAiCost } from "../_shared/ledger.ts";
import type { RouteStep } from "../_shared/router.ts";
import { routerEnabled } from "../_shared/router.ts";
import { adapterFor } from "../_shared/providers/index.ts";
import { resolveChain, runChain } from "../_shared/providers/chain.ts";
import {
  BUDGETS,
  ProviderError,
  awaitJob,
  inlineBase64,
  inlineImageResult,
  routedR2Key,
} from "../_shared/providers/common.ts";
import type { GenerateInput } from "../_shared/providers/types.ts";

// Denial-of-wallet guard: image edits bill Gemini per call (~3.9¢ each).
const EDIT_MAX_PER_WINDOW = 40;
const EDIT_WINDOW_SECONDS = 300; // 40 photo edits / 5 min / org
const MONTH_SECONDS = 30 * 86400;
// Helper modes are ~0.1¢ of text tokens: burst-limited only.
const HELP_MAX_PER_WINDOW = 120;
const HELP_WINDOW_SECONDS = 300; // 120 suggest/improve calls / 5 min / org

// Monthly allowances come from plan_entitlements (migration 0010) so the
// enforced number and the published number are the same number.

/** Role gate shared by both guards: marketing is read-only. */
async function requireEditorRole(userId: string, req: Request, what: string): Promise<string> {
  const orgId = await orgForUser(userId, preferredOrg(req));
  const { data: mem, error: mErr } = await adminClient()
    .from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle();
  if (mErr) throw new HttpError(500, `Role lookup failed: ${mErr.message}`);
  if (!mem?.role || mem.role === "marketing") {
    throw new HttpError(403, `Your role does not permit ${what}`);
  }
  return orgId;
}

/**
 * Charge the paid-generation quotas. MUST be called only AFTER the request body
 * and its parameters are known-good: charging first meant a caller could burn
 * an org's burst + monthly quota with `{}` bodies that never reached Gemini
 * (audit round 4).
 */
async function guardEdit(userId: string, req: Request): Promise<{ orgId: string; plan: string }> {
  const orgId = await requireEditorRole(userId, req, "AI photo edits");
  // A degraded plan lookup is a 503 here, never a 402 (audit F-E-02).
  const ent = await entitlementForCharge(orgId);
  const monthlyCap = ent.photo_edits_per_month;
  if (monthlyCap <= 0) throw quotaError("AI photo edit", 0, 0, ent.plan);

  const idem = req.headers.get("idempotency-key")?.trim();
  if (idem && idem.length <= 128) {
    if (!(await durableRateLimit(`aipidem:${orgId}:${idem}`, 1, 120))) {
      throw new HttpError(409, "Duplicate submission — this edit was already started.", "conflict");
    }
  }
  if (!(await durableRateLimit(`aiphoto:${orgId}`, EDIT_MAX_PER_WINDOW, EDIT_WINDOW_SECONDS))) {
    throw new HttpError(429, "AI photo edit limit reached for now — try again in a few minutes.", "rate_limited");
  }
  if (!(await durableRateLimit(`aiphotomo:${orgId}`, monthlyCap, MONTH_SECONDS))) {
    throw quotaError("AI photo edit", monthlyCap, monthlyCap, ent.plan);
  }
  // Return the org the quota was charged to, so the handler can attribute the
  // cost_ledger row (F-E-15) — and, once F-E-16 lands, refund the same key.
  // The effective plan rides along for the router's RouteContext: it is the
  // number entitlementForCharge() just read, not a second lookup.
  return { orgId, plan: ent.plan };
}

/** Helper modes: role gate + burst limiter only. Never touches the monthly meter. */
async function guardHelper(userId: string, req: Request): Promise<void> {
  const orgId = await requireEditorRole(userId, req, "AI photo suggestions");
  if (!(await durableRateLimit(`aiphotohelp:${orgId}`, HELP_MAX_PER_WINDOW, HELP_WINDOW_SECONDS))) {
    throw new HttpError(429, "Too many suggestion requests for now — try again in a few minutes.", "rate_limited");
  }
}

// Bound the inline base64 image so a caller can't push unbounded memory
// pressure through readJson (audit round 4). ~12 MB of base64 ≈ 9 MB binary.
const MAX_IMAGE_B64_CHARS = 12_000_000;
const ALLOWED_MIMES = ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"];

const MODEL = (Deno.env.get("GEMINI_IMAGE_MODEL")?.trim() || "gemini-2.5-flash-image");
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

const LOCK =
  "Do not change the building's architecture, structure, dimensions, walls, or " +
  "window/door placement. Photorealistic, natural, consistent perspective and shadows.";

// Staging must NEVER remodel the room — only add furnishings.
const STAGE_LOCK =
  "CRITICAL: keep the room's architecture EXACTLY as photographed — identical walls, " +
  "windows, doors, ceiling, flooring material, trim, built-ins, light fixtures, the view " +
  "through the windows, camera angle, and perspective. Only ADD furniture and decor; do not " +
  "remodel, repaint, resurface, or alter the structure or lighting direction in any way. " +
  "Photorealistic materials with shadows and reflections that match the room's existing light.";

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
    "on floors, counters, and surfaces. Keep the room, furniture, decor, and architecture " +
    "IDENTICAL — same walls, windows, doors, flooring, fixtures, camera angle, and lighting. " +
    "Seamlessly fill revealed floor/surface areas to match the surrounding material and light. " + LOCK,
};

// Real-estate staging furniture sets (verbatim from the shipped version).
const RE_STAGE_STYLES: Record<string, string> = {
  modern:
    "modern contemporary furniture: clean-lined sofa and chairs, a low-profile coffee table, " +
    "a large area rug, tasteful wall art, and designer accent lighting in a neutral palette " +
    "with warm accents",
  rustic:
    "rustic farmhouse furniture: warm natural woods, a comfortable linen-upholstered sofa, " +
    "woven and vintage accents, layered cozy textiles, and earthy tones",
  minimalist:
    "minimalist furniture: a few essential low-profile pieces, uncluttered surfaces, a " +
    "restrained monochrome palette, and plenty of intentional negative space",
  scandinavian:
    "Scandinavian furniture: light woods, soft whites with muted pastel accents, simple " +
    "functional pieces, hygge textiles like wool throws and sheepskin, and airy styling",
};

function reStagePrompt(styleDesc: string): string {
  return (
    "Virtually stage this real-estate photo: furnish the room with " + styleDesc + ". " +
    "Use realistic scale and placement appropriate to the room type, resting naturally on the " +
    "existing floor. If the room already has furniture, replace it cleanly with the new set. " +
    STAGE_LOCK
  );
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
  /** Free-text instruction for edit:"custom" (Mirino-style prompting). */
  prompt?: string;
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
 * The last-resort step: what THIS deploy runs today, hardcoded.
 *
 * resolveRoute() answers `[]` if the routing table is unreadable, and a
 * database blip must not take photo editing down. GEMINI_IMAGE_MODEL still
 * wins here, exactly as it does today.
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
const MAX_IMPROVE_INPUT = 300;  // rough idea in
const MAX_IMPROVE_OUTPUT = 400; // polished instruction out

/** Wrap a user's free-text instruction with the guardrails every edit gets. */
function customPrompt(p: Profile, userText: string): string {
  const truth = p === PROFILES.real_estate
    ? "this is a real property listing"
    : "this is a real place being marketed";
  return (
    `Edit this ${p.photo} as follows: ` + userText.trim() + ". " +
    `Stay photorealistic and true to the space — ${truth}. ` + LOCK
  );
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();
  try {
    const user = await getUser(req); // owner auth; RLS not needed (no DB touch beyond quota)
    if (req.method !== "POST") throw new HttpError(405, "POST only");
    if (!GEMINI_KEY) throw new HttpError(500, "GEMINI_API_KEY function secret is not set", "internal");

    // VALIDATE FIRST, CHARGE SECOND (audit round 4). Every quota consumption
    // below happens only once we know the request would actually reach Gemini.
    const body = await readJson<Body>(req);
    const edit = String(body.edit ?? "twilight").trim().toLowerCase();
    const mime = String(body.mime ?? "image/jpeg").split(";")[0].trim().toLowerCase();
    const space = spaceTypeOf(body.space_type);
    const profile = PROFILES[space];

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
    if (edit === "suggest") {
      assert(body.image_b64, 400, "image_b64 is required");
      await guardHelper(user.id, req);
      return json({ suggestions: await suggestEdits(body.image_b64, mime, profile), space_type: space });
    }
    if (edit === "improve_prompt") {
      const rough = (body.prompt ?? "").trim();
      assert(rough.length > 0, 400, "edit:'improve_prompt' requires a non-empty `prompt`");
      assert(rough.length <= MAX_IMPROVE_INPUT, 400,
             `prompt too long (max ${MAX_IMPROVE_INPUT} chars)`);
      // Refuse before spending tokens polishing something we would never run.
      assertFairHousing(rough, "That idea");
      await guardHelper(user.id, req);
      return json({ prompt: await improvePrompt(rough, profile), space_type: space });
    }

    assert(body.image_b64, 400, "image_b64 is required");

    let prompt: string;
    let style: string | undefined;
    if (edit === "stage") {
      style = (body.style ?? "modern").toLowerCase();
      const styleDesc = (space === "real_estate" ? RE_STAGE_STYLES : STAGE_STYLES)[style];
      assert(styleDesc, 400, `style must be ${Object.keys(STAGE_STYLES).join("|")} (got ${style})`);
      prompt = space === "real_estate" ? reStagePrompt(styleDesc) : stagePrompt(profile, styleDesc);
    } else if (edit === "custom") {
      const userText = (body.prompt ?? "").trim();
      assert(userText.length > 0, 400, "edit:'custom' requires a non-empty `prompt`");
      assert(userText.length <= MAX_CUSTOM_PROMPT, 400,
             `prompt too long (max ${MAX_CUSTOM_PROMPT} chars)`);
      // Fair-housing denylist — refuse BEFORE charging anything (see header).
      assertFairHousing(userText, "This custom edit");
      prompt = customPrompt(profile, userText);
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
    const { orgId, plan } = await guardEdit(user.id, req);

    // ── ROUTER (flag-gated, additive) ────────────────────────────────────────
    // The fair-housing gate above has already run — contract §4 puts it BEFORE
    // resolveRoute on every task that takes free text, and it is the one thing
    // no routing decision may skip.
    //
    // Flag OFF: resolveRoute returns exactly the legacy step (gemini
    // gemini-2.5-flash-image), the gemini adapter rebuilds today's payload byte
    // for byte, and this is a no-op. Flag ON: the seeded chain runs, each
    // attempt is reported for the circuit breaker, and the ledger row carries
    // the provider/model that actually ran.
    const task = `photo.${edit}`;
    const maskB64 = typeof body.mask_b64 === "string" && body.mask_b64.length > 0 ? body.mask_b64 : null;
    const maskMime = String(body.mask_mime ?? "image/png").split(";")[0].trim().toLowerCase();
    const routerOn = await routerEnabled();
    const steps = await resolveChain(
      task,
      {
        plan,
        needs: needsForPhotoEdit(edit, maskB64 !== null),
        // A photograph of somebody's home: never a vendor that trains on it.
        carries_customer_media: true,
      },
      legacyPhotoStep(task),
    );

    const genInput: GenerateInput = {
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
    const chain = routerOn ? steps : steps.map((s) =>
      s.provider === "gemini" && s.model === "gemini-2.5-flash-image" && MODEL !== s.model ? { ...s, model: MODEL } : s
    );

    const attempt = await runChain(task, chain, async (step) => {
      const adapter = adapterFor(step.provider);
      const ref = await adapter.submit(step, genInput);
      const done = await awaitJob(adapter, ref, BUDGETS.totalImageMs);
      // One download, reused for both the inline answer and the R2 copy.
      const local = await inlineImageResult(step.provider, done);
      const b64 = inlineBase64(local);
      if (!b64) throw new ProviderError(step.provider, "upstream", `${step.provider} returned no image bytes`);

      // persist(): the canonical asset is ours (contract §4).
      //
      // Only while the router is ON — with the flag off this function stores
      // nothing today, and a no-op deploy must not start writing objects (or
      // spending the latency) behind an operator's back.
      //
      // BEST EFFORT even then, and only here: unlike a video, the edited photo
      // is returned inline in this very response, so the caller already has the
      // bytes and a storage hiccup must not destroy an edit they paid for.
      let assetKey: string | null = null;
      if (routerOn) {
        try {
          const stored = await adapter.persist(local, routedR2Key(orgId, task, local.mime));
          assetKey = stored.key;
        } catch (e) {
          console.error("ai-photo: persist to R2 failed (edit still returned):", e instanceof Error ? e.message : e);
        }
      }
      return { b64, mime: local.mime, assetKey };
    });
    const step = attempt.step;
    const outB64 = attempt.value.b64;
    const outMime = attempt.value.mime;

    // COST LEDGER (F-E-15): the image edit succeeded and is billed, so record
    // ONE org-scoped cost_ledger row with job_id = NULL. This is what the owner
    // spend console and the per-org monthly COGS view read for app AI. The
    // provider/model/price come from the step that ACTUALLY ran (contract §4);
    // with the flag off that is gemini @ 3.9c/image, exactly as before.
    // Best effort — a failed insert must never fail an edit the caller has paid
    // for (see recordAppAiCost). Only reached on success, so a failure above
    // (which F-E-16 refunds) writes no row: no double-count.
    await recordRoutedAiCost(adminClient(), {
      orgId,
      feature: "photo_edit",
      step,
      images: 1,
      meta: { edit, space_type: space, ...(style ? { style } : {}) },
    });

    // COMPLIANCE: enter the edit in the org's AI audit log and hand the app the
    // exact sentence the public tour will print. Best effort — never fatal (the
    // image is already generated and already billed). See _shared/provenance.ts.
    const prov = await recordProvenance(req, {
      listingId: body.listing_id,
      kind: provenanceKind(edit),
      label: body.label ?? null,
      modelId: step.model,
      edit,
      style: style ?? null,
      // Free-text only, and only the user's own words (the canned guardrails
      // add nothing). Bounded and stripped by the RPC; never public.
      promptSummary: edit === "custom" ? (body.prompt ?? "").trim().slice(0, 300) : null,
      originalAssetId: body.original_asset_id ?? null,
    });

    return json({
      image_b64: outB64,
      mime: outMime ?? "image/png",
      edit,
      space_type: space,
      ...(style ? { style } : {}),
      // ADDITIVE, and only while the router is on: with the flag off the body
      // is byte-for-byte what shipped.
      ...(routerOn
        ? {
          route: { provider: step.provider, model: step.model, route_id: step.route_id },
          ...(attempt.value.assetKey ? { asset_key: attempt.value.assetKey } : {}),
        }
        : {}),
      // The disclosure this edit carries onto the tour (CA AB 723 / NorthstarMLS).
      disclosure: prov.disclosure,
      provenance: {
        id: prov.id,
        recorded: prov.recorded,
        ...(prov.reason ? { reason: prov.reason } : {}),
      },
    });
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
async function suggestEdits(imageB64: string, mime: string, profile: Profile): Promise<Suggestion[]> {
  const raw = await geminiText(
    [
      { text: suggestInstruction(profile) },
      { inline_data: { mime_type: mime, data: imageB64 } },
    ],
    true,
  );

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

function improveInstruction(p: Profile): string {
  return (
    `You polish rough photo-edit requests from ${p.audience} into precise instructions ` +
    `for an AI photo editor working on a real ${p.photo}.\n\n` +
    "Rewrite the user's idea as ONE clear, imperative edit instruction: concrete about what " +
    "changes and what stays, photorealistic, plausible for a real place, no camera jargon, " +
    "no markdown, no quotes, a single paragraph of at most 400 characters. Keep the user's " +
    "intent exactly — never invent extra changes they did not ask for. Do NOT add boilerplate " +
    "about preserving architecture; the system appends that separately.\n\n" +
    'Reply with STRICT JSON only: {"prompt":"<rewritten instruction>"}'
  );
}

/** edit:"improve_prompt" — rewrite a rough custom-edit idea into a precise one. */
async function improvePrompt(rough: string, profile: Profile): Promise<string> {
  const raw = await geminiText(
    [{ text: improveInstruction(profile) + "\n\nUser's idea: " + rough }],
    true,
  );

  const parsed = parseJsonLoose(raw);
  let improved = "";
  if (parsed && typeof parsed === "object" && typeof (parsed as Record<string, unknown>).prompt === "string") {
    improved = ((parsed as Record<string, unknown>).prompt as string).trim();
  } else if (typeof raw === "string") {
    // Model ignored the JSON contract — fall back to its plain text.
    improved = raw.replace(/^```(?:json)?|```$/g, "").replace(/^"|"$/g, "").trim();
  }
  if (!improved) throw new HttpError(502, "Gemini returned no improved prompt", "upstream");
  return improved.replace(/\s+/g, " ").slice(0, MAX_IMPROVE_OUTPUT);
}

/** One text/vision generateContent call on the cheap flash model → first text part. */
async function geminiText(parts: unknown[], wantJson: boolean): Promise<string> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${TEXT_MODEL}:generateContent`;
  const payload = {
    contents: [{ role: "user", parts }],
    generationConfig: {
      temperature: 0.4,
      ...(wantJson ? { responseMimeType: "application/json" } : {}),
    },
  };
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
