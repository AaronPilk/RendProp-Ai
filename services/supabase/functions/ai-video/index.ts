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
//       used to be sent as 8K, audit F-supabase-17).
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
//   POST /ai-video/reel-clip  { asset_id? | image_b64? (+mime?), prompt?, seconds?=5, space_type? }
//       Seedance i2v: animate a listing photo into a motion clip.
//   GET  /ai-video/status?status_url=...&response_url=...
//       → { status: "processing", queue_position?, logs_tail? }
//       → { status: "completed", video_url }
//       → { status: "failed", error }
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

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { adminClient, getUser, orgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { entitlementForCharge, quotaError } from "../_shared/entitlements.ts";
import { publicR2Url } from "../_shared/r2.ts";
import { assertFairHousing, FAIR_HOUSING_LOCK, GUARDRAILS } from "../_shared/fairhousing.ts";
import { recordProvenance } from "../_shared/provenance.ts";
import { APP_AI_UNIT_CENTS, recordAppAiCost } from "../_shared/ledger.ts";

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
 */
async function guardGenerate(userId: string, req: Request, kind: GenKind): Promise<string> {
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

  // Idempotency soft-dedupe: when the client sends an Idempotency-Key, a
  // duplicate submit inside 2 minutes is rejected instead of double-billed.
  const idem = req.headers.get("idempotency-key")?.trim();
  if (idem && idem.length <= 128) {
    if (!(await durableRateLimit(`aividem:${orgId}:${idem}`, 1, 120))) {
      throw new HttpError(409, "Duplicate submission — this job was already started.", "conflict");
    }
  }
  if (!(await durableRateLimit(`aivideo:${orgId}`, GEN_MAX_PER_WINDOW, GEN_WINDOW_SECONDS))) {
    throw new HttpError(429, "AI video generation limit reached for now — try again in a few minutes.", "rate_limited");
  }
  if (!(await durableRateLimit(`${meterKeyFor(kind)}:${orgId}`, monthlyCap, MONTH_SECONDS))) {
    throw quotaError(labelFor(kind), monthlyCap, monthlyCap, ent.plan);
  }
  return orgId;
}

const FAL_QUEUE_BASE = "https://queue.fal.run";
const FAL_KEY = Deno.env.get("FAL_KEY");

const MODEL_DRONE = "fal-ai/topaz/upscale/video";
const MODEL_DECLUTTER = "bria/video/erase/prompt";
const MODEL_AERIAL_T2V = "fal-ai/veo3.1/fast";
const MODEL_I2V = "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video";

// Drone-glide tiers → output target. Topaz bills per output pixel-frame, so the
// factor is derived from the SOURCE resolution (never > the target, never 8K).
const DRONE_TIERS: Record<string, { longEdge: number; fps: number }> = {
  "1080p60": { longEdge: 1920, fps: 60 },
  "4k30": { longEdge: 3840, fps: 30 },
  "4k60": { longEdge: 3840, fps: 60 },
};

// Topaz drone-glide cost per OUTPUT second, by tier (F-E-15). Authoritative
// numbers live in _shared/ledger.ts APP_AI_UNIT_CENTS (mirrors costs.py + admin).
const DRONE_TIER_CENTS: Record<string, number> = {
  "1080p60": APP_AI_UNIT_CENTS.topaz_1080p60_per_s,
  "4k30": APP_AI_UNIT_CENTS.topaz_4k30_per_s,
  "4k60": APP_AI_UNIT_CENTS.topaz_4k60_per_s,
};

// Bria hard limit: "duration must be less than 5s" (input schema). We disable
// auto_trim (never silently cut the user's clip) and pre-flight the duration.
const BRIA_MAX_SECONDS = 5;

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

// Anti-hallucination scaffolding: i2v models love to "help" by inventing decor,
// people, or a different room. Pin the clip to the exact photographed scene and
// allow only grounded camera motion.
function reelPrompt(space: SpaceType): string {
  return (
    `Photorealistic live continuation of this exact photographed ${SCENE_NOUN[space]} scene. The architecture, ` +
    "furniture, fixtures, decor, materials, lighting, and exposure stay identical to the source photo. " +
    "Camera: one slow, subtle, grounded push-in with gentle natural parallax — no cuts, no " +
    "transitions, and no panning that reveals unseen areas. Do not add, remove, or move any " +
    "objects; no people, no animals, no text or watermarks; no scene changes, style shifts, " +
    "warping, or flicker. " + GUARDRAILS
  );
}

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

const AERIAL_MOTIONS = ["rise_reveal", "pull_back", "orbit", "push_in"] as const;
type AerialMotion = typeof AERIAL_MOTIONS[number];
const AERIAL_TIMES = ["golden_hour", "midday", "twilight", "overcast"] as const;
type AerialTime = typeof AERIAL_TIMES[number];

const MOTION_TEXT: Record<AerialMotion, string> = {
  rise_reveal:
    "the camera starts low, just above the entrance, and rises smoothly and steadily, revealing the roofline, the grounds and the surroundings",
  pull_back:
    "the camera starts close on the facade and pulls back and upward in one continuous move, widening to show the whole property in its setting",
  orbit:
    "the camera performs one slow, smooth partial orbit around the building at a constant height, keeping it centered in frame",
  push_in:
    "the camera starts on a wide establishing view and pushes in slowly and steadily toward the entrance",
};

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
  } else {
    parts.push(
      `Cinematic aerial drone establishing shot of a single, believable ${subject}. ` +
        "One consistent building for the entire shot — the same structure, roofline, lot and street throughout.",
    );
  }
  parts.push(`Camera: ${MOTION_TEXT[args.motion]}.`);
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
  /** Compliance (W2-B3). Defaults to the source asset's listing. */
  listing_id?: string;
  label?: string;
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

      const orgId = await guardGenerate(user.id, req, "drone"); // validated — charge, then submit
      const input: Record<string, unknown> = {
        video_url: asset.url,
        model: "Proteus", // natural detail; interpolation gives the glide
        upscale_factor: upscale,
        H264_output: true,
      };
      if (interpolate) input.target_fps = fps;
      const sub = await falSubmit(MODEL_DRONE, input);

      // COST LEDGER (F-E-15): Topaz bills per OUTPUT second, and the output runs
      // the same wall-clock as the source, so units = the source duration. One
      // org-scoped row, job_id = NULL, best effort. Written only after fal ACCEPTED
      // the submit — the spend is committed at that point (E-network.md §1), and a
      // retried Idempotency-Key was already 409'd above, so one render → one row.
      // The drone route does not require duration_s; without it Topaz cannot be
      // priced per-second, so we log a warning and record no row rather than a
      // misleading $0 one (a residual gap — see HANDOFF).
      if (asset.duration_s && asset.duration_s > 0) {
        await recordAppAiCost(adminClient(), {
          orgId,
          provider: "fal",
          feature: "drone_render",
          model: MODEL_DRONE,
          units: asset.duration_s,
          unitCents: DRONE_TIER_CENTS[tier],
          meta: { tier, request_id: sub.request_id, upscale_factor: upscale, target_fps: fps, interpolated: interpolate },
        });
      } else {
        console.warn(
          `ai-video drone: asset ${body.asset_id} has no probed duration; ` +
            `Topaz ${tier} spend not recorded to cost_ledger (F-E-15 residual gap)`,
        );
      }
      return json({
        ...sub,
        kind: "drone",
        model_id: MODEL_DRONE,
        tier,
        target_fps: fps,
        upscale_factor: upscale,
        interpolated: interpolate,
        source: { width: asset.width, height: asset.height, fps: asset.fps, duration_s: asset.duration_s },
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
      // longer replace the guardrails (see header).
      const userErase = cleanPrompt(body.prompt);
      if (userErase) assertFairHousing(userErase, "This erase instruction");
      const erasePrompt = userErase
        ? guardedUserPrompt(userErase, space, "Erase objects from")
        : `${DECLUTTER_PROMPT[space]}. ${GUARDRAILS}`;

      await guardGenerate(user.id, req, "declutter"); // validated — charge, then submit
      const sub = await falSubmit(MODEL_DECLUTTER, {
        video_url: asset.url,
        prompt: erasePrompt,
        auto_trim: false, // never silently cut the video — process the full clip
        preserve_audio: true,
        output_container_and_codec: "mp4_h264",
      });
      // COST LEDGER (F-E-15): Bria video erase has NO committed unit price in the
      // repo (functions/admin/index.ts lists it as unit_cost_cents: null) and it
      // rides the reel allowance, so no cost_ledger row is written here on
      // purpose. Give it a real per-clip price in APP_AI_UNIT_CENTS + the admin
      // inventory first, then log it like the others (see HANDOFF).
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
      if (style) assertFairHousing(style, "This look-and-feel hint");
      if (region) assertFairHousing(region, "This setting");

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
      const prompt = buildAerialPrompt({ grounded, space, motion, time, region, style });

      const orgId = await guardGenerate(user.id, req, "aerial"); // validated — charge, then submit
      let sub: { request_id: string; status_url: string; response_url: string };
      let modelId: string;
      if (grounded) {
        modelId = MODEL_I2V;
        sub = await falSubmit(MODEL_I2V, {
          prompt,
          image_url: imageUrl,
          resolution: "1080p",
          duration: String(seconds), // Seedance takes duration as a string
          aspect_ratio: aspect,
          camera_fixed: false,
        });
      } else {
        modelId = MODEL_AERIAL_T2V;
        sub = await falSubmit(MODEL_AERIAL_T2V, {
          prompt,
          duration: `${seconds}s`,
          resolution: "1080p",
          aspect_ratio: aspect,
          generate_audio: false, // silent b-roll; the app scores it (and it's ~33% cheaper)
        });
      }

      // COST LEDGER (F-E-15): a GROUNDED aerial is Seedance i2v (billed per output
      // second); an UNGROUNDED one is Veo 3.1 Fast (a flat per-clip price — the
      // repo has no per-second Veo rate). One org-scoped row, job_id = NULL, best
      // effort, only after fal ACCEPTED the submit (spend committed; see §1).
      await recordAppAiCost(adminClient(), {
        orgId,
        provider: "fal",
        feature: "aerial",
        model: modelId,
        units: grounded ? seconds : 1,
        unitCents: grounded ? APP_AI_UNIT_CENTS.seedance_per_s : APP_AI_UNIT_CENTS.veo_aerial_clip,
        meta: { grounded, seconds, aspect, request_id: sub.request_id },
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
          motion,
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
      // the anti-hallucination + fair-housing guardrails (see header).
      const userMotion = cleanPrompt(body.prompt);
      if (userMotion) assertFairHousing(userMotion, "This clip prompt");
      const reelText = userMotion
        ? guardedUserPrompt(userMotion, space, "Animate")
        : reelPrompt(space);

      const orgId = await guardGenerate(user.id, req, "reel"); // validated — charge, then submit
      const sub = await falSubmit(MODEL_I2V, {
        prompt: reelText,
        image_url: imageUrl,
        resolution: "1080p",
        duration: String(secs), // Seedance takes duration as a string
      });

      // COST LEDGER (F-E-15): Seedance i2v bills per output second. One org-scoped
      // row, job_id = NULL, best effort, only after fal ACCEPTED the submit.
      await recordAppAiCost(adminClient(), {
        orgId,
        provider: "fal",
        feature: "reel",
        model: MODEL_I2V,
        units: secs,
        unitCents: APP_AI_UNIT_CENTS.seedance_per_s,
        meta: { seconds: secs, space_type: space, request_id: sub.request_id },
      });

      const prov = await recordProvenance(req, {
        listingId: body.listing_id ?? reelListingId,
        kind: "reel",
        label: body.label ?? null,
        modelId: MODEL_I2V,
        edit: "reel",
        promptSummary: userMotion ?? null,
      });
      return json({
        ...sub,
        kind: "reel",
        model_id: MODEL_I2V,
        seconds: secs,
        space_type: space,
        disclosure: prov.disclosure,
        provenance: { id: prov.id, recorded: prov.recorded, ...(prov.reason ? { reason: prov.reason } : {}) },
      }, 202);
    }

    // ---- GET /ai-video/status ----
    if (req.method === "GET" && seg.length === 1 && seg[0] === "status") {
      const params = new URL(req.url).searchParams;
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
        return json({ status: "completed", video_url: videoUrl });
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
