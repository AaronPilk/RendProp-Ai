// ai-chapters — AUTO ROOM CHAPTERS from the walkthrough video (owner-authenticated).
//
//   POST /ai-chapters { listing_id, asset_id, max_chapters?: 12, language?: "en" }
//     → { chapters[], summary, model, cost_cents_estimate, video_seconds,
//         time_base, warnings[], disclosure, provenance }
//
// The single biggest unbuilt win in the product: the agent never tags rooms by
// hand again. Gemini watches the walkthrough at 1 fps / MEDIA_RESOLUTION_LOW and
// says where each room starts; the app PRE-FILLS the room tagger with editable
// suggestions. ~1¢ for a 90-second house.
//
// Full contract (JSON, Swift types, the time base, what the app must do):
//   docs/AI-CHAPTERS-CONTRACT.md
//
// ── THREE THINGS THIS FUNCTION DELIBERATELY DOES NOT DO ──────────────────────
//
//  1. IT NEVER WRITES `capture_chapters`. Suggestions are suggestions. The app
//     shows them, the agent confirms or edits them, and THEN the existing
//     PATCH /renders/:render_id/chapters writes them. A model that silently
//     re-labels a published tour is a product that agents stop trusting.
//
//  2. IT NEVER RESCALES A TIMESTAMP. `start_s` is seconds into the asset that
//     was submitted, full stop (`time_base: "asset_seconds"`). Rendprop has two
//     timelines for one walk — capture time (`RoomTag.tMs`, the tagger) and
//     rendered time (`capture_chapters.t_ms`, retimed by `speedFactor`) — and
//     NOTHING on the capture_assets row records which one a given file is in.
//     `speedFactor` lives only in the app's RenderedTour. A server that guessed
//     would be silently wrong for every hand-imported render, so the caller
//     converts. The contract tells iOS to send the ORIGINAL CAPTURE asset, which
//     is the tagger's own timeline and needs no conversion at all.
//
//  3. IT NEVER FAILS THE CALL OVER A BAD DESCRIPTION. Every returned
//     `description` is run through assertMarketingCopy(); one that trips the
//     fair-housing rules is DROPPED and its chapter is kept. The offending text
//     was written by a model, not by the agent — there is nothing for them to
//     fix, and losing the room label teaches them nothing.
//
// ── WHY THE VIDEO GOES THROUGH THE FILES API ─────────────────────────────────
//
// `file_data.file_uri` accepts Files API URIs and YouTube URLs; an arbitrary
// public HTTPS URL is not documented as supported. So the R2 object is STREAMED
// (never buffered) into the Files API, used once, and DELETED immediately —
// this is customer media, and Google's 48 h auto-expiry is a backstop, not a
// plan. See ai-chapters/gemini.ts for the verified request shapes.
//
// ── AUTH / QUOTA / LEDGER / PROVENANCE ───────────────────────────────────────
//
// Mirrors ai-video exactly: owner JWT, role gate (`marketing` is read-only),
// entitlementForCharge (a degraded plan lookup is a 503, never a 402),
// Idempotency-Key dedupe, a burst limiter and a monthly meter — charged AFTER
// the body and the asset validate and immediately BEFORE the billable call, and
// REFUNDED when Gemini fails (F-E-16). The meter is its own counter
// (`chaptersmo:<org>`) against the EXISTING `renders_per_month` cap: chapters
// are part of publishing a tour, not a new thing to sell, and adding a plan
// column for a 1¢ feature would be a migration in someone else's file.
//
// Needs the GEMINI_API_KEY function secret plus the shared R2 env
// (CLOUDFLARE_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY).

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { adminClient, getUser, orgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";
import { durableRateLimit, refundRateLimit } from "../_shared/ratelimit.ts";
import { entitlementForCharge, quotaError } from "../_shared/entitlements.ts";
import { recordProvenance } from "../_shared/provenance.ts";
import { recordAppAiCost } from "../_shared/ledger.ts";
import { R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS } from "../_shared/r2.ts";
import * as routerModule from "../_shared/router.ts";
import { AwsClient } from "https://esm.sh/aws4fetch@1.0.20";

import { deleteFile, generateChapters, requireGemini, uploadVideoFromUrl, waitForActive } from "./gemini.ts";
import { allowedLabels, chaptersPrompt, spaceTypeOf, systemInstruction } from "./prompt.ts";
import { postprocessChapters } from "./postprocess.ts";

// ── Tunables ─────────────────────────────────────────────────────────────────

const BURST_MAX_PER_WINDOW = 10;
const BURST_WINDOW_SECONDS = 300; // 10 analyses / 5 min / org
const MONTH_SECONDS = 30 * 86400;

/** How long the R2 GET stays signed. Google fetches it once, immediately. */
const SOURCE_URL_TTL_SECONDS = 900;

/** Ceilings. The Files API takes 2 GB; an edge function has a wall clock. */
const MAX_VIDEO_SECONDS = 20 * 60;
const MAX_VIDEO_BYTES = 300 * 1_000_000;

/** Frames per second the model samples. 1 fps is the documented default. */
const SAMPLE_FPS = 1;

/** Max chapters, and the ceiling on what a caller may ask for. */
const DEFAULT_MAX_CHAPTERS = 12;
const HARD_MAX_CHAPTERS = 24;

/** Legacy model for `video.chapters` — what runs when the router flag is off. */
const LEGACY_MODEL = "gemini-3.6-flash";

/**
 * Cents per SECOND of analysed video, from docs/AI-ROUTER-CONTRACT.md §3
 * (`video.chapters`: gemini low-res 1 fps ≈ 1.4¢ per 2 min). 90 s ⇒ 1.05¢.
 *
 * It lives here and not in APP_AI_UNIT_CENTS because _shared/ledger.ts belongs
 * to another agent this wave. It BELONGS in APP_AI_UNIT_CENTS as
 * `gemini_chapters_per_s` the moment that file is open for edits — the same
 * scoping duplicate ai-voice made with presignGet, not a second way of doing
 * things. Move it in lockstep with services/pipeline/providers/costs.py and the
 * admin provider inventory.
 */
const CHAPTERS_UNIT_CENTS_PER_S = 0.0117;

/** Wall-clock budget for the whole Gemini leg (upload + ACTIVE + generate). */
const GEMINI_DEADLINE_MS = 110_000;

/** How many steps of the router's chain to try. The Files upload is done ONCE
 *  and reused, so a second attempt costs only another generateContent. */
const MAX_CHAIN_ATTEMPTS = 2;

// ── R2 signed GET ────────────────────────────────────────────────────────────
//
// _shared/r2.ts presigns PUT but has no GET, and it is frozen (it trims every
// credential for a reason: one trailing newline in the access key took the whole
// storage layer down on 2026-09-04). ai-voice/index.ts carries the same local
// signer with the same aws4fetch version and the same trimming discipline; this
// is the second copy, and both belong in _shared/r2.ts as `presignGet` the
// moment that file is open for edits again.
//
// Unlike ai-video's public-URL resolver this works for the PRIVATE uploads
// bucket too, which is the whole point: the ORIGINAL CAPTURE — the asset whose
// timeline the room tagger is written in — lives there.

const trimmedEnv = (name: string): string | undefined => {
  const raw = Deno.env.get(name);
  if (raw === undefined) return undefined;
  const clean = raw.trim();
  return clean === "" ? undefined : clean;
};

const R2_ACCOUNT_ID = trimmedEnv("CLOUDFLARE_ACCOUNT_ID");
const R2_ACCESS_KEY_ID = trimmedEnv("R2_ACCESS_KEY_ID");
const R2_SECRET_ACCESS_KEY = trimmedEnv("R2_SECRET_ACCESS_KEY");

let _r2: AwsClient | null = null;
function r2Client(): AwsClient {
  if (_r2) return _r2;
  if (!R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY) {
    throw new HttpError(500, "Missing R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY");
  }
  _r2 = new AwsClient({
    accessKeyId: R2_ACCESS_KEY_ID,
    secretAccessKey: R2_SECRET_ACCESS_KEY,
    service: "s3",
    region: "auto",
  });
  return _r2;
}

/** Encode each path segment but keep the "/" separators (safe for S3 SigV4). */
function encodeKey(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

function r2Endpoint(): string {
  if (!R2_ACCOUNT_ID) throw new HttpError(500, "Missing env var: CLOUDFLARE_ACCOUNT_ID");
  return `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
}

/** Presign an R2 GET URL. Mirror of r2.ts `presignPut` (see note above). */
async function presignGet(bucket: string, key: string, expiresIn: number): Promise<string> {
  const url = new URL(`${r2Endpoint()}/${bucket}/${encodeKey(key)}`);
  url.searchParams.set("X-Amz-Expires", String(expiresIn));
  const signed = await r2Client().sign(url.toString(), { method: "GET", aws: { signQuery: true } });
  return signed.url;
}

// ── Router ───────────────────────────────────────────────────────────────────
//
// STATIC import on purpose. This was a runtime `import()` while the router was
// still being written by another agent; the Supabase CLI bundler cannot trace a
// non-literal specifier, and the first deploy shipped WITHOUT `_shared/router.ts`
// — which would have silently pinned this function to the legacy model forever.
// A static import is bundled, `deno check`ed, and fails loudly at deploy time
// if the module is missing, which is the failure mode we want.
//
// Absent route or `ai_router.enabled = false` ⇒ the legacy hardcoded step
// (`gemini-3.6-flash`) — byte-identical behaviour.

interface RouteStepLike {
  route_id?: string;
  provider?: string;
  model?: string;
  /** "second" | "call" | … — decides what the ledger's `units` MEANS. */
  unit?: string;
  unit_cents?: number;
}

interface RouterModule {
  resolveRoute?: (task: string, ctx: Record<string, unknown>) => Promise<RouteStepLike[]>;
  reportOutcome?: (step: RouteStepLike, r: Record<string, unknown>) => Promise<void>;
}

function loadRouter(): Promise<RouterModule | null> {
  // The real module is typed more strictly than RouterModule (RouteContext vs a
  // bag of unknowns); the widening is deliberate and one-directional.
  return Promise.resolve(routerModule as unknown as RouterModule);
}

interface ChosenRoute {
  provider: string;
  model: string;
  /** What ONE `unitCents` buys: a second of video, or the whole call. */
  unit: "second" | "call";
  unitCents: number;
  routeId: string | null;
  source: "router" | "legacy";
  step: RouteStepLike | null;
}

const LEGACY_ROUTE: ChosenRoute = {
  provider: "gemini",
  model: LEGACY_MODEL,
  unit: "second",
  unitCents: CHAPTERS_UNIT_CENTS_PER_S,
  routeId: null,
  source: "legacy",
  step: null,
};

/**
 * The ordered chain to try for `video.chapters`.
 *
 * The capability tokens MUST match migration 0018's seed exactly
 * (`video_understanding`, `timestamps` — underscores). `ctx.needs` is a hard AND,
 * so one hyphen would filter every step out and silently pin the feature to the
 * legacy model forever. Both are genuinely required: a step that watches video
 * but cannot give timestamps is useless for chapters.
 *
 * The chain is used AS RETURNED — never re-filtered (HANDOFF-DB.md §2).
 *
 * An empty chain (no rows, or everything filtered) falls back to the legacy step
 * rather than 503ing. For a route that already exists this would be wrong, but
 * `video.chapters` has no prior behaviour to preserve except this constant, and
 * hard-failing the flagship feature because a seed row is missing is the worse
 * error. The plan boundary is still enforced — by the quota gate above, which
 * runs whatever the router says.
 */
async function chooseChain(plan: string): Promise<{ router: RouterModule | null; chain: ChosenRoute[] }> {
  const router = await loadRouter();
  if (!router?.resolveRoute) return { router, chain: [LEGACY_ROUTE] };
  try {
    const steps = await router.resolveRoute("video.chapters", {
      plan,
      needs: ["video_understanding", "timestamps"],
      carries_customer_media: true,
    });
    const chain = (Array.isArray(steps) ? steps : [])
      .filter((s) => typeof s?.model === "string" && s.model.length > 0)
      .slice(0, MAX_CHAIN_ATTEMPTS)
      .map((step): ChosenRoute => {
        const cents = Number(step.unit_cents);
        // 0018 prices video.chapters PER CALL (1.4¢ per tour), not per second.
        // Honouring the row's own unit is the difference between a 1¢ ledger row
        // and a 126¢ one.
        const unit = step.unit === "second" ? "second" : "call";
        return {
          provider: step.provider ?? "gemini",
          model: step.model as string,
          unit,
          // A row that forgot its price must not make the feature look free.
          unitCents: Number.isFinite(cents) && cents > 0
            ? cents
            : (unit === "second" ? CHAPTERS_UNIT_CENTS_PER_S : CHAPTERS_UNIT_CENTS_PER_S * 90),
          routeId: step.route_id ?? null,
          source: "router",
          step,
        };
      });
    return { router, chain: chain.length > 0 ? chain : [LEGACY_ROUTE] };
  } catch (e) {
    console.error("ai-chapters: resolveRoute failed, using the legacy step:", e instanceof Error ? e.message : String(e));
    return { router, chain: [LEGACY_ROUTE] };
  }
}

/** Ledger units for one analysis, in the unit the CHOSEN route is priced in. */
function ledgerUnits(route: ChosenRoute, videoSeconds: number): number {
  return route.unit === "second" ? videoSeconds : 1;
}

/** Best effort — a router that cannot record an outcome must not fail a result. */
async function reportOutcome(
  router: RouterModule | null,
  route: ChosenRoute,
  ok: boolean,
  latencyMs: number,
  errorClass?: string,
): Promise<void> {
  if (!router?.reportOutcome || !route.step) return;
  try {
    await router.reportOutcome(route.step, {
      ok,
      latency_ms: Math.max(0, Math.round(latencyMs)),
      ...(errorClass ? { error_class: errorClass } : {}),
    });
  } catch (e) {
    console.error("ai-chapters: reportOutcome failed:", e instanceof Error ? e.message : String(e));
  }
}

// ── Quota ────────────────────────────────────────────────────────────────────

interface Charge {
  orgId: string;
  plan: string;
  monthlyKey: string;
  burstKey: string;
}

/**
 * Role gate + quotas for ONE analysis. Called only after the body AND the asset
 * have validated — charging up front is how `{}` bodies used to burn an org's
 * allowance with no provider call ever made (audit round 4).
 */
async function guardChapters(userId: string, req: Request, orgId: string): Promise<Charge> {
  const admin = adminClient();
  const { data: mem, error: mErr } = await admin
    .from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle();
  if (mErr) throw new HttpError(500, `Role lookup failed: ${mErr.message}`);
  if (!mem?.role || mem.role === "marketing") {
    throw new HttpError(403, "Your role does not permit AI room suggestions");
  }

  // A degraded plan lookup is a 503 here, never a 402 (audit F-E-02).
  const ent = await entitlementForCharge(orgId);
  const monthlyCap = ent.renders_per_month; // the CAP is shared with renders; the counter is not
  if (monthlyCap <= 0) throw quotaError("AI room suggestions", 0, 0, ent.plan);

  const idem = req.headers.get("idempotency-key")?.trim();
  if (idem && idem.length <= 128) {
    if (!(await durableRateLimit(`aichidem:${orgId}:${idem}`, 1, 120))) {
      throw new HttpError(409, "Duplicate submission — these room suggestions were already requested.", "conflict");
    }
  }

  const burstKey = `aichapters:${orgId}`;
  if (!(await durableRateLimit(burstKey, BURST_MAX_PER_WINDOW, BURST_WINDOW_SECONDS))) {
    throw new HttpError(429, "AI room-suggestion limit reached for now — try again in a few minutes.", "rate_limited");
  }
  const monthlyKey = `chaptersmo:${orgId}`;
  if (!(await durableRateLimit(monthlyKey, monthlyCap, MONTH_SECONDS))) {
    throw quotaError("AI room suggestions", monthlyCap, monthlyCap, ent.plan);
  }
  return { orgId, plan: ent.plan, monthlyKey, burstKey };
}

/** Hand back everything a FAILED analysis charged. Never throws. */
async function refundCharge(charge: Charge): Promise<void> {
  await refundRateLimit(charge.monthlyKey, MONTH_SECONDS, 1);
  await refundRateLimit(charge.burstKey, BURST_WINDOW_SECONDS, 1);
}

// ── Asset resolution ─────────────────────────────────────────────────────────

interface ResolvedAsset {
  id: string;
  listingId: string;
  orgId: string;
  bucket: string;
  storageKey: string;
  contentType: string;
  durationS: number;
  spaceType: string | null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function requiredUuid(v: unknown, name: string): string {
  assert(typeof v === "string" && UUID_RE.test(v.trim()), 400, `${name} must be a UUID`);
  return (v as string).trim();
}

/**
 * Load the capture_assets row as the CALLER (RLS applies), then re-verify every
 * boundary the caller could otherwise cross: the asset must belong to the named
 * listing, that listing's org must match X-Org-Id when one is sent, and the
 * upload must be finished. A two-org user must not spend org A's allowance on
 * org B's asset (F-supabase-35).
 */
// deno-lint-ignore no-explicit-any
async function resolveVideoAsset(db: any, assetId: string, listingId: string, req: Request): Promise<ResolvedAsset> {
  const { data, error } = await db
    .from("capture_assets")
    .select("id, listing_id, kind, bucket, storage_key, content_type, uploaded, duration_s, bytes, listings!inner(org_id, space_type, deleted_at)")
    .eq("id", assetId)
    .maybeSingle();
  if (error) throw new HttpError(400, `Asset lookup failed: ${error.message}`);
  if (!data) throw new HttpError(404, "Asset not found");

  const listing = (Array.isArray(data.listings) ? data.listings[0] : data.listings) as
    | { org_id: string; space_type: string | null; deleted_at: string | null }
    | undefined;
  if (!listing || listing.deleted_at) throw new HttpError(404, "Asset not found");

  if (String(data.listing_id) !== listingId) {
    throw new HttpError(400, "asset_id does not belong to listing_id");
  }
  const preferred = preferredOrg(req);
  if (preferred && preferred !== listing.org_id) {
    throw new HttpError(403, "This asset belongs to a different workspace than X-Org-Id");
  }
  assert(data.kind === "video", 400, "Room suggestions need a video asset");
  assert(data.uploaded === true, 409, "Asset upload is not complete");

  const key = typeof data.storage_key === "string" ? data.storage_key : "";
  assert(key.length > 0, 409, "This asset has no storage key yet");

  // Without a probed duration nothing downstream can be clamped, priced, or
  // pre-flighted against the ceiling — so require it rather than guess it.
  const duration = Number(data.duration_s);
  if (!Number.isFinite(duration) || duration <= 0) {
    throw new HttpError(
      409,
      "This asset has no probed duration — re-upload the walkthrough with duration_s so it can be analysed.",
      "conflict",
    );
  }
  if (duration > MAX_VIDEO_SECONDS) {
    throw new HttpError(
      413,
      `This walkthrough is ${Math.round(duration / 60)} minutes. Room suggestions accept up to ` +
        `${MAX_VIDEO_SECONDS / 60} minutes — split it, or run suggestions on the rendered tour.`,
    );
  }
  const bytes = Number(data.bytes);
  if (Number.isFinite(bytes) && bytes > MAX_VIDEO_BYTES) {
    throw new HttpError(
      413,
      `This walkthrough is ${(bytes / 1_000_000).toFixed(0)} MB. Room suggestions accept up to ` +
        `${Math.floor(MAX_VIDEO_BYTES / 1_000_000)} MB — run them on the rendered tour instead.`,
    );
  }

  const bucketRaw = String(data.bucket ?? "uploads");
  const bucket = bucketRaw === "renders" ? R2_BUCKET_RENDERS : R2_BUCKET_UPLOADS;
  const declared = typeof data.content_type === "string" ? data.content_type.trim() : "";

  return {
    id: String(data.id),
    listingId,
    orgId: listing.org_id,
    bucket,
    storageKey: key,
    // Gemini's supported video types; anything else is declared as mp4, which is
    // what every app-produced walkthrough actually is.
    contentType: /^video\/(mp4|mpeg|mov|quicktime|avi|webm|wmv|x-flv|3gpp)$/i.test(declared)
      ? (declared.toLowerCase() === "video/quicktime" ? "video/mov" : declared.toLowerCase())
      : "video/mp4",
    durationS: duration,
    spaceType: listing.space_type ?? null,
  };
}

// ── Handler ──────────────────────────────────────────────────────────────────

interface ChaptersBody {
  listing_id?: string;
  asset_id?: string;
  max_chapters?: number;
  language?: string;
  label?: string;
}

/** Bounded language tag — it only ever reaches the prompt as "write in X". */
function cleanLanguage(raw: unknown): string {
  const s = String(raw ?? "en").trim().slice(0, 16);
  return /^[A-Za-z]{2,8}(-[A-Za-z0-9]{2,8})*$/.test(s) ? s : "en";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const seg = pathSegments(req, "ai-chapters");
    if (req.method !== "POST" || seg.length !== 0) {
      throw new HttpError(404, "Not found: POST /ai-chapters", "not_found");
    }

    requireGemini(); // 503 before any quota is charged if the key is missing
    const user = await getUser(req); // auth required (also guards the Gemini key)
    const db = userClient(req); // RLS: the caller only sees their own org's assets

    const body = await readJson<ChaptersBody>(req);
    const listingId = requiredUuid(body.listing_id, "listing_id");
    const assetId = requiredUuid(body.asset_id, "asset_id");
    const askedFor = Math.round(Number(body.max_chapters ?? DEFAULT_MAX_CHAPTERS));
    const maxChapters = Number.isFinite(askedFor) && askedFor > 0
      ? Math.min(HARD_MAX_CHAPTERS, askedFor)
      : DEFAULT_MAX_CHAPTERS;
    const language = cleanLanguage(body.language);

    const asset = await resolveVideoAsset(db, assetId, listingId, req);

    // The org the quota is charged to is the ASSET's org, cross-checked against
    // X-Org-Id above — never orgForUser()'s default, which for a two-org user
    // could be the wrong workspace entirely.
    const defaultOrg = await orgForUser(user.id, preferredOrg(req));
    if (defaultOrg !== asset.orgId && !preferredOrg(req)) {
      throw new HttpError(
        403,
        "This asset belongs to another workspace — send X-Org-Id for the workspace that owns it.",
      );
    }
    const charge = await guardChapters(user.id, req, asset.orgId); // validated — charge, then spend

    const space = spaceTypeOf(asset.spaceType);
    const labels = allowedLabels(space);
    const { router, chain } = await chooseChain(charge.plan);

    const sourceUrl = await presignGet(asset.bucket, asset.storageKey, SOURCE_URL_TTL_SECONDS);
    const prompt = chaptersPrompt({
      space,
      labels,
      videoSeconds: asset.durationS,
      maxChapters,
      language,
    });
    const system = systemInstruction();

    const startedAt = Date.now();
    let uploadedName: string | null = null;
    let route: ChosenRoute = chain[0];
    let raw: { text: string; promptTokens: number | null; outputTokens: number | null; finishReason: string | null };
    try {
      // The upload is the expensive, slow half and it is model-independent, so
      // it happens ONCE outside the chain loop — a fallback step costs only
      // another generateContent against the file already sitting in ACTIVE.
      const uploaded = await uploadVideoFromUrl({
        sourceUrl,
        mimeType: asset.contentType,
        // No address, no agent, no listing name — a display name is metadata on
        // someone else's server.
        displayName: `walkthrough-${asset.id.slice(0, 8)}`,
        maxBytes: MAX_VIDEO_BYTES,
      });
      uploadedName = uploaded.name;
      await waitForActive(uploaded.name, startedAt + GEMINI_DEADLINE_MS);

      // Walk the router's chain in order. Every attempt is reported so the
      // circuit breaker sees the truth; only an UPSTREAM failure is worth
      // another model, and only while there is wall clock left to spend.
      let lastError: unknown = null;
      let result: typeof raw | null = null;
      for (let i = 0; i < chain.length; i++) {
        const candidate = chain[i];
        const attemptAt = Date.now();
        try {
          result = await generateChapters({
            model: candidate.model,
            fileUri: uploaded.uri,
            mimeType: uploaded.mimeType,
            systemInstruction: system,
            prompt,
            fps: SAMPLE_FPS,
          });
          route = candidate;
          await reportOutcome(router, candidate, true, Date.now() - attemptAt);
          break;
        } catch (e) {
          lastError = e;
          const cls = errorClassOf(e);
          await reportOutcome(router, candidate, false, Date.now() - attemptAt, cls);
          const retryable = cls === "upstream" || cls === "rate_limit";
          const timeLeft = Date.now() < startedAt + GEMINI_DEADLINE_MS;
          if (!retryable || i === chain.length - 1 || !timeLeft) throw e;
          console.log(`ai-chapters: ${candidate.model} failed (${cls}); trying ${chain[i + 1].model}`);
        }
      }
      if (!result) throw lastError ?? new HttpError(502, "The video model returned nothing.", "upstream");
      raw = result;
    } catch (e) {
      // Nothing was produced, so nothing is owed. Hand the allowance back before
      // the error surfaces (F-E-16).
      await refundCharge(charge);
      throw e;
    } finally {
      // Customer media does not sit on a third party's disk for 48 hours.
      if (uploadedName) await deleteFile(uploadedName);
    }

    // ── Parse + post-process ────────────────────────────────────────────────
    // A response that isn't JSON is a model failure, not a server failure: the
    // agent gets an empty suggestion set and a warning, and still has a working
    // tagger. It is NOT refunded — Gemini ran and billed.
    let parsed: Record<string, unknown> = {};
    try {
      parsed = JSON.parse(raw.text || "{}") as Record<string, unknown>;
    } catch {
      console.error(`ai-chapters: model returned non-JSON (finish=${raw.finishReason ?? "?"})`);
    }

    const { chapters, warnings } = postprocessChapters(parsed.chapters, {
      videoSeconds: asset.durationS,
      maxChapters,
      allowedLabels: labels,
    });
    if (raw.finishReason && raw.finishReason !== "STOP" && raw.finishReason !== "FINISH_REASON_STOP") {
      warnings.push("The model stopped early, so the last rooms may be missing.");
    }
    const summary = typeof parsed.summary === "string" && parsed.summary.trim()
      ? parsed.summary.trim().slice(0, 600)
      : null;

    // ── Ledger (F-E-15) ─────────────────────────────────────────────────────
    // Units = SECONDS OF VIDEO analysed, which is what the token bill tracks
    // (1 fps × 70 tokens/frame at MEDIA_RESOLUTION_LOW). Written only on the
    // confirmed-success path; a retried Idempotency-Key was 409'd above, so one
    // analysis writes exactly one row. Best effort, never fatal.
    const cost = await recordAppAiCost(adminClient(), {
      orgId: charge.orgId,
      provider: route.provider,
      feature: "chapters",
      model: route.model,
      // Priced in the CHOSEN route's own unit: the legacy step is per second of
      // video, and migration 0018's rows are per CALL. Using one for the other
      // is the difference between a 1¢ ledger row and a 126¢ one.
      units: ledgerUnits(route, asset.durationS),
      unitCents: route.unitCents,
      meta: {
        asset_id: asset.id,
        space_type: space,
        chapters: chapters.length,
        route_id: route.routeId,
        route_source: route.source,
        route_unit: route.unit,
        video_seconds: Math.round(asset.durationS * 100) / 100,
        prompt_tokens: raw.promptTokens,
        output_tokens: raw.outputTokens,
        fps: SAMPLE_FPS,
        media_resolution: "MEDIA_RESOLUTION_LOW",
      },
    });

    // ── Provenance (W2-B3) ──────────────────────────────────────────────────
    // Nothing was generated INTO the media, but an AI did read the agent's
    // footage and produce the labels a buyer will see, so it belongs in the
    // broker's audit log. kind "other" / edit "chapters". Best effort.
    const prov = await recordProvenance(req, {
      listingId,
      kind: "other",
      label: "AI-suggested room labels",
      modelId: route.model,
      edit: "chapters",
      promptSummary: `${chapters.length} room suggestions from a ${Math.round(asset.durationS)}s walkthrough`,
      originalAssetId: asset.id,
    });

    return json({
      chapters,
      summary,
      model: route.model,
      provider: route.provider,
      route: { task: "video.chapters", route_id: route.routeId, source: route.source },
      cost_cents_estimate: cost.total_cents,
      video_seconds: Math.round(asset.durationS * 100) / 100,
      // Seconds into THE ASSET THAT WAS SUBMITTED. Never rescaled server-side —
      // see the header and docs/AI-CHAPTERS-CONTRACT.md §3.
      time_base: "asset_seconds",
      asset_id: asset.id,
      warnings,
      disclosure: prov.disclosure,
      provenance: { id: prov.id, recorded: prov.recorded, ...(prov.reason ? { reason: prov.reason } : {}) },
    });
  } catch (err) {
    return respondError(err);
  }
});

/** Map a thrown error onto the router's error_class vocabulary. */
function errorClassOf(e: unknown): string {
  if (e instanceof HttpError) {
    if (e.status === 429) return "rate_limit";
    if (e.status === 504) return "timeout";
    if (e.status === 400 || e.status === 409 || e.status === 413) return "validation";
    if (e.status >= 500) return "upstream";
  }
  return "other";
}
