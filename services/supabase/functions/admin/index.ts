// admin — the owner/admin spend console (read-only, server-enforced role).
//
// The owner needs to see, from inside the app, every AI/API call the product
// makes and what it costs. That is a CROSS-ORG read, which every tenant RLS
// policy correctly refuses — so it needs a role, and the role has to be one a
// hostile client cannot claim.
//
//   GET /admin/spend?window=today|7d|30d
//        -> { window, from, to, generated_at, total_cents, ledger_rows, truncated,
//             by_provider[], by_feature[], by_org[], coverage }
//   GET /admin/providers
//        -> { generated_at, provider_count, configured_count, providers[], last_probe }
//   GET /admin/providers/probe
//        -> { checked_at, probe_count, ok_count, fail_count, not_probeable_count,
//             results[{ key, configured, ok, latency_ms, error_class, how,
//                       message, detail, env_names, doc }], last_probe_recorded }
//   GET /admin/usage
//        -> { generated_at, month, month_start, org_count, blocked_count, truncated, orgs[] }
//   GET /admin/funnel?window=7d|30d|90d      (admin/funnel.ts — first-party app_events)
//        -> { window, steps[], crashes, errors, active_devices, sessions, by_day[],
//             purchases_verified, purchases_verified_sandbox,
//             purchase_completed_attributed }
//   GET /admin/subscriptions
//        -> { generated_at, active_total, grace_total, mrr_cents, mrr_note,
//             by_plan[], by_status[], environments[], sandbox_active, not_renewing,
//             expiring_within_7d, unlinked_subscriptions, pending_notifications,
//             last_notification_at, last_notification_type, truncated }
//   GET /admin/health
//        -> { generated_at, checked_provider_apis:false, note, window_days, providers[], job_failures }
//   GET /admin/routing
//        -> { generated_at, enabled, flag, spend_window_days, policies[], routes[] }
//  POST /admin/routing/flag        { enabled }   -- the AI router master switch
//  POST /admin/routing/step/{id}   { enabled }   -- one chain step on/off
//
// The two POSTs are the ONLY writes this function has. They are gated by the
// same requireAdmin() as everything else, they touch nothing but `app_config`
// and `ai_routes.enabled`, and both record WHO flipped WHAT into app_config —
// see the routing section at the bottom of this file.
//
// The exact response shapes are frozen in docs/ADMIN-CONSOLE-CONTRACT.md — the
// iOS screen decodes them with Codable, so every key is always present,
// optionals are explicit nulls and arrays are never omitted.
//
// ── THE TWO RULES THIS FILE EXISTS TO KEEP ───────────────────────────────────
//
// 1. ADMIN IS SERVER-ENFORCED. Nothing here trusts the client. There is no
//    header, body field or query parameter that grants admin: requireAdmin()
//    validates the bearer JWT with Supabase Auth and then reads
//    `profiles.is_admin` for THAT user id with the service-role client. The
//    lookup fails CLOSED. Independently of this function, migration 0017 makes
//    the same statement in Postgres: the admin-only RLS policies are predicated
//    on is_admin(), and `is_admin` is not in the tenant UPDATE grant, so a valid
//    non-admin JWT gets nothing extra even on a direct PostgREST call.
//
// 2. A CREDENTIAL VALUE NEVER LEAVES THIS PROCESS. /admin/providers and
//    /admin/health report whether a secret is configured, never anything about
//    it: no value, no prefix, no suffix, no length, no hash. `envConfigured()`
//    is the ONLY thing in this file that touches a credential env var, it
//    returns a boolean, and nothing logs what it read.
//
//    /admin/providers/probe (admin/probe.ts) is the ONE route that puts a key
//    on the wire, and it puts it in an Authorization header addressed to the
//    vendor who issued it and nowhere else. Rule 2 still holds for the
//    RESPONSE: every upstream string is redacted and truncated by probe.ts's
//    sanitize() before it reaches this file, no probe result carries a body,
//    and nothing here logs one. That route is separately rate limited at
//    6/hour/admin — see handleProbe below — because it is the only route that
//    fans out to eleven third parties.
//
// Privacy: org-level aggregates only. An org is identified by id + name, never
// by its members. No e-mail, phone, name or id of any other user appears in any
// response — and provider error strings are withheld too (an upstream message
// is arbitrary text that could carry a signed URL), so only `error->>'step'`
// and `error->>'type'` are surfaced.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, json, pathSegments, readJson, respondError, round4 } from "../_shared/http.ts";
import { adminClient, getUser } from "../_shared/supabase.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { probeAll } from "./probe.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { handleFunnel } from "./funnel.ts";

// A console refresh is a handful of aggregate queries; 60/min per admin is
// generous for a human and still bounds an accidental poll loop.
const ADMIN_MAX_PER_WINDOW = 60;
const ADMIN_WINDOW_SECONDS = 60;

// The key probe is the only route that makes outbound calls — eleven vendors at
// once. It gets its OWN durable limit ON TOP of the general one, because 60/min
// of THAT would be 660 third-party requests a minute from one impatient tap.
// Six an hour is more than a human needs (the answer does not change minute to
// minute) and is low enough that no vendor could ever see us as abusive.
const PROBE_MAX_PER_WINDOW = 6;
const PROBE_WINDOW_SECONDS = 3600;

// PostgREST caps a single response (Supabase's default db-max-rows is 1000), so
// every list read pages explicitly. Past the cap the response says `truncated`
// rather than quietly under-reporting a total.
const PAGE = 1000;
const MAX_PAGES = 50; // 50k rows
const MAX_ORGS = 200;
const HEALTH_WINDOW_DAYS = 7;
const MONTH_SECONDS = 30 * 86400;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const seg = pathSegments(req, "admin");
    const route = seg[0] ?? "";

    // Authenticate and authorise FIRST — before the method check and before the
    // route is even looked at — so an unauthenticated or non-admin caller learns
    // nothing about this function's surface, not even which routes exist.
    const admin = await requireAdmin(req);

    // The console stays read-only EXCEPT the two routing switches, which are
    // the only writes this function has. Every other route keeps the original
    // 405 verbatim.
    const isRoutingWrite = req.method === "POST" && route === "routing";
    if (req.method !== "GET" && !isRoutingWrite) {
      throw new HttpError(405, "The admin console is read-only — only GET is supported");
    }

    if (!(await durableRateLimit(`admin:${admin.userId}`, ADMIN_MAX_PER_WINDOW, ADMIN_WINDOW_SECONDS))) {
      throw new HttpError(429, "Too many admin requests — try again in a moment.", "rate_limited");
    }

    switch (route) {
      case "spend":
        return await handleSpend(req);
      case "providers":
        // GET /admin/providers/probe is the live key test; any other (or no)
        // second segment keeps answering the static inventory exactly as before.
        return seg[1] === "probe"
          ? await handleProbe(admin)
          : await handleProviders();
      case "usage":
        return await handleUsage();
      case "subscriptions":
        return await handleSubscriptions();
      case "health":
        return await handleHealth();
      case "funnel":
        return await handleFunnel(req);
      case "routing":
        return isRoutingWrite
          ? await handleRoutingWrite(req, admin, seg)
          : await handleRouting(admin);
      default:
        throw new HttpError(
          404,
          "Unknown route — GET /admin/spend, /admin/providers, /admin/providers/probe, " +
            "/admin/usage, /admin/health, /admin/funnel, /admin/subscriptions " +
            "or /admin/routing (POST /admin/routing/flag, /admin/routing/step/{id})",
        );
    }
  } catch (err) {
    return respondError(err);
  }
});

// ── The role gate ────────────────────────────────────────────────────────────

interface AdminCaller {
  userId: string;
}

/**
 * 401 without a valid JWT, 403 unless `profiles.is_admin` is true for that
 * user. Read with the SERVICE-ROLE client so the answer cannot depend on the
 * caller's own RLS context, and keyed on the id Supabase Auth returned for the
 * token — never on anything in the request body, headers or query string.
 *
 * Fails CLOSED: a lookup error is a 403, not an open door.
 */
async function requireAdmin(req: Request): Promise<AdminCaller> {
  const user = await getUser(req); // 401 on a missing/invalid/expired token

  const { data, error } = await adminClient()
    .from("profiles")
    .select("is_admin")
    .eq("id", user.id)
    .maybeSingle();

  if (error) {
    console.error("admin check failed:", error.message);
    throw new HttpError(403, "Admin access could not be verified — try again.", "forbidden", {
      reason: "admin_check_failed",
    });
  }
  if (data?.is_admin !== true) {
    throw new HttpError(403, "Admin access is required for this console.", "forbidden", {
      reason: "not_admin",
    });
  }
  return { userId: user.id };
}

// ── Credentials: NAMES and a boolean, nothing else ───────────────────────────

/**
 * True when `name` holds a non-empty value in this function's environment.
 *
 * This is the ONLY place a credential env var is read, and the value never
 * leaves this function: it is not returned, not logged, not measured, not
 * hashed. A boolean is the maximum any response may carry.
 */
function envConfigured(name: string): boolean {
  const raw = Deno.env.get(name);
  return typeof raw === "string" && raw.trim().length > 0;
}

// ── The provider inventory (code-derived, priced from the repo) ──────────────

interface ModelSpec {
  sku: string;
  label: string;
  unit: string;
  /** null when the repo has no committed price for this SKU. */
  unit_cost_cents: number | null;
  trigger: string;
  /** The file (and constant) the number came from. */
  source: string;
}

interface ProviderSpec {
  key: string;
  name: string;
  kind: "ai" | "infra" | "integration";
  billable: boolean;
  /** The env var NAME holding the credential. Never its value. */
  credential_env: string;
  /** Every env var NAME this provider needs. Names only. */
  env_names: string[];
  /** cost_ledger.provider value these calls carry, or null when nothing logs. */
  ledger_provider: string | null;
  /**
   * True when this provider's ABSENCE is expected — an unset credential is a
   * deliberate off-switch, not a fault (Cloudflare Stream, the KIE fallback).
   * Lets the console show "optional, off" instead of a red "not configured".
   * ADDED field: the shipped iOS build decodes leniently and ignores it.
   */
  optional?: boolean;
  /**
   * One line of owner-facing copy for an expected "not configured" state, so a
   * red row does not read as "broken". ADDED field (ignored by the shipped build).
   */
  whatToDo?: string;
  models: ModelSpec[];
}

const COSTS_PY = "services/pipeline/providers/costs.py";
const COST_MODEL_MD = "docs/AI-COST-MODEL.md";

const PROVIDERS: ProviderSpec[] = [
  {
    key: "gemini",
    name: "Google Gemini",
    kind: "ai",
    billable: true,
    credential_env: "GEMINI_API_KEY",
    env_names: ["GEMINI_API_KEY"],
    ledger_provider: "gemini",
    models: [
      {
        sku: "gemini-2.5-flash-image",
        label: "Nano Banana image edit (declutter / restage / twilight / sky / lawn / custom)",
        unit: "image",
        unit_cost_cents: 3.9,
        trigger: "Photo Studio: POST /ai-photo; worker restage in services/pipeline",
        source: `${COSTS_PY} — UNIT_COSTS_CENTS.photo_edit_gemini / restage_gemini (3.9)`,
      },
      {
        sku: "gemini-3.6-flash",
        label: "Text/vision helper (suggest, improve_prompt) — generates no image",
        unit: "call",
        unit_cost_cents: null,
        trigger: "POST /ai-photo with edit:\"suggest\" or edit:\"improve_prompt\"",
        source:
          "No committed price: the helper modes are deliberately unmetered (ai-photo/index.ts — they never touch the monthly allowance)",
      },
    ],
  },
  {
    key: "fal",
    name: "fal.ai",
    kind: "ai",
    billable: true,
    credential_env: "FAL_KEY",
    env_names: ["FAL_KEY"],
    ledger_provider: "fal",
    models: [
      {
        sku: "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video",
        label: "Seedance 1.0 Pro Fast — image-to-video",
        unit: "second of generated clip",
        unit_cost_cents: 4.8,
        trigger: "POST /ai-video/reel-clip; the worker's hero clip",
        source: `${COSTS_PY} — UNIT_COSTS_CENTS.hero_seedance_per_s (4.8 ≈ $0.24 / 5s)`,
      },
      {
        sku: "fal-ai/veo3.1/fast",
        label: "Veo 3.1 Fast — text-to-video establishing aerial (ungrounded)",
        unit: "8s 1080p clip",
        unit_cost_cents: 80.0,
        trigger: "POST /ai-video/aerial without a source photo",
        source:
          `${COST_MODEL_MD} §1 and services/supabase/migrations/0010 header — "AI aerial (Veo 3.1 Fast, 8s 1080p) $0.80"`,
      },
      {
        sku: "fal-ai/topaz/upscale/video (1080p60)",
        label: "Topaz Video AI — drone-glide render, 1080p60",
        unit: "second of output",
        unit_cost_cents: 4.0,
        trigger: "POST /ai-video/drone with tier \"1080p60\"",
        source: `${COSTS_PY} — UNIT_COSTS_CENTS.drone_render_1080p60_per_s (4.0)`,
      },
      {
        sku: "fal-ai/topaz/upscale/video (4k30)",
        label: "Topaz Video AI — drone-glide render, 4K30",
        unit: "second of output",
        unit_cost_cents: 8.0,
        trigger: "POST /ai-video/drone with tier \"4k30\"",
        source: `${COSTS_PY} — UNIT_COSTS_CENTS.drone_render_4k30_per_s (8.0)`,
      },
      {
        sku: "fal-ai/topaz/upscale/video (4k60)",
        label: "Topaz Video AI — drone-glide render, 4K60 (the single most expensive tap)",
        unit: "second of output",
        unit_cost_cents: 16.0,
        trigger: "POST /ai-video/drone with tier \"4k60\"",
        source: `${COSTS_PY} — UNIT_COSTS_CENTS.drone_render_4k60_per_s (16.0)`,
      },
      {
        sku: "fal-ai/flux — Fill/Kontext masked inpaint",
        label: "Flux Fill / Kontext — masked declutter inpaint",
        unit: "image",
        unit_cost_cents: 4.0,
        trigger: "Worker pipeline declutter (services/pipeline/providers/fal_client.py)",
        source: `${COSTS_PY} — UNIT_COSTS_CENTS.declutter_flux_fill (4.0)`,
      },
      {
        sku: "fal-ai/flux — Kontext [pro]",
        label: "Flux Kontext [pro] — restage fallback when Gemini is unavailable",
        unit: "image",
        unit_cost_cents: 4.0,
        trigger: "Worker pipeline restage, fal route",
        source: `${COSTS_PY} — UNIT_COSTS_CENTS.restage_fal_kontext (4.0)`,
      },
      {
        sku: "bria/video/erase/prompt",
        label: "Bria video eraser — prompt object removal (source must be < 5s)",
        unit: "clip",
        unit_cost_cents: null,
        trigger: "POST /ai-video/declutter",
        source:
          "No committed price in the repo; it is metered against the reel allowance (ai-video/index.ts capFor())",
      },
    ],
  },
  {
    key: "anthropic",
    name: "Anthropic (QC drift judge)",
    kind: "ai",
    billable: true,
    credential_env: "ANTHROPIC_API_KEY",
    env_names: ["ANTHROPIC_API_KEY"],
    ledger_provider: "anthropic",
    models: [
      {
        sku: "claude-haiku-4-5",
        label: "QC drift judge (default). Real cost is re-derived from response.usage",
        unit: "4-image QC call",
        unit_cost_cents: 0.9,
        trigger: "Worker pipeline QC after each enhanced room (services/pipeline/enhance.py)",
        source: `${COSTS_PY} — UNIT_COSTS_CENTS.qc_haiku_call (0.9); per-token rates in ANTHROPIC_RATES_CENTS_PER_1K`,
      },
      {
        sku: "claude-sonnet-5",
        label: "QC escalation when Haiku's confidence is low",
        unit: "4-image QC call",
        unit_cost_cents: 1.7,
        trigger: "Worker pipeline QC escalation (router policy; never Opus)",
        source: `${COSTS_PY} — UNIT_COSTS_CENTS.qc_sonnet_call (1.7)`,
      },
    ],
  },
  {
    key: "kie",
    name: "KIE.ai (one-key multi-model fallback)",
    kind: "ai",
    billable: true,
    optional: true,
    credential_env: "KIE_API_KEY",
    env_names: ["KIE_API_KEY"],
    ledger_provider: "kie",
    whatToDo:
      "Optional — the at-scale / one-key restage fallback. Absent by default; set KIE_API_KEY only to route restage through KIE. \"Not configured\" here is expected, not a fault.",
    models: [
      {
        sku: "KIE restage route",
        label: "Restage via KIE — the at-scale / one-key fallback route",
        unit: "image",
        unit_cost_cents: 9.0,
        trigger: "Worker pipeline restage when the route config selects kie",
        source: `${COSTS_PY} — UNIT_COSTS_CENTS.restage_kie (9.0)`,
      },
    ],
  },
  {
    key: "elevenlabs",
    name: "ElevenLabs (reel voiceover)",
    kind: "ai",
    billable: true,
    credential_env: "ELEVENLABS_API_KEY",
    env_names: ["ELEVENLABS_API_KEY"],
    ledger_provider: "elevenlabs",
    whatToDo:
      "Set ELEVENLABS_API_KEY in Edge Function secrets. Without it the reel voiceover's AI voices are unavailable (recording your own voice still works — that is on-device).",
    models: [
      {
        sku: "eleven_multilingual_v2 /with-timestamps",
        label: "AI voiceover with per-word timing for captions (ai-voice)",
        unit: "1k characters",
        unit_cost_cents: 15,
        trigger: "Reel Studio → Voice → AI voice (POST /ai-voice/tts)",
        source: "docs/VOICEOVER-CONTRACT.md; ElevenLabs Creator tier ≈ $0.15 / 1k chars",
      },
    ],
  },
  {
    key: "openai",
    name: "OpenAI (router: image edits, plain TTS, Whisper fallback, luna judge)",
    kind: "ai",
    billable: true,
    credential_env: "OPENAI_API_KEY",
    env_names: ["OPENAI_API_KEY"],
    ledger_provider: "openai",
    whatToDo:
      "Set OPENAI_API_KEY. Used only by AI-router steps (flag off = nothing runs here): gpt-image-2 mask edits, tts-1, whisper-1 captions fallback, gpt-5.6-luna room labels / fair-housing second opinion.",
    models: [
      {
        sku: "gpt-image-2 (edit)",
        label: "Mask-guided photo edit — router step for photo.declutter / photo.stage",
        unit: "image",
        unit_cost_cents: 4.1,
        trigger: "AI router (ai_routes) when the flag is on",
        source: "docs/AI-ROUTER-CONTRACT.md §3 (researched 2026-09-04)",
      },
      {
        sku: "whisper-1",
        label: "Word-timestamped captions when on-device speech is unavailable",
        unit: "minute",
        unit_cost_cents: 0.6,
        trigger: "stt.captions router fallback",
        source: "docs/AI-ROUTER-CONTRACT.md §3",
      },
    ],
  },
  {
    key: "higgsfield",
    name: "Higgsfield (aerial motion presets — experimental)",
    kind: "ai",
    billable: true,
    optional: true,
    credential_env: "HIGGSFIELD_API_KEY_ID",
    env_names: ["HIGGSFIELD_API_KEY_ID", "HIGGSFIELD_API_KEY_SECRET"],
    ledger_provider: "higgsfield",
    whatToDo:
      "Optional — routes stay disabled until enterprise no-training terms are in place. Needs BOTH HIGGSFIELD_API_KEY_ID and HIGGSFIELD_API_KEY_SECRET. \"Not configured\" is expected today.",
    models: [
      {
        sku: "dop/turbo",
        label: "Camera-motion preset aerial (5s / 720p) — A/B only",
        unit: "second",
        unit_cost_cents: 8.3,
        trigger: "video.aerial experimental step (disabled)",
        source: "docs/AI-ROUTER-CONTRACT.md §3",
      },
    ],
  },
  {
    key: "worldlabs",
    name: "World Labs Marble (3D worlds — spike)",
    kind: "ai",
    billable: true,
    optional: true,
    credential_env: "WORLDLABS_API_KEY",
    env_names: ["WORLDLABS_API_KEY"],
    ledger_provider: "worldlabs",
    whatToDo:
      "Optional — the 3D-world spike only runs from the Mac helper today (_bridge/marble/wl.sh); no edge function calls Marble yet. Set WORLDLABS_API_KEY when 3d.world goes live.",
    models: [
      {
        sku: "marble-1.1",
        label: "One navigable 3D world from a walkthrough / panorama",
        unit: "world",
        unit_cost_cents: 120,
        trigger: "3d.world (not wired into the app yet)",
        source: "docs/AI-ROUTER-CONTRACT.md §3; World Labs credits 2026-09-04",
      },
    ],
  },
  // Cloudflare is TWO independent products with independent credentials, so it is
  // two console rows. Folding them into one provider ANDed R2's keys with the
  // Stream token via providerConfigured's `.every()`, which reddened a perfectly
  // healthy R2 (uploads + renders both succeed) only because Stream — which app
  // tours do NOT use — has no token set. Both still carry ledger_provider
  // "cloudflare" (the ledger does not split R2 from Stream); the PROVIDER_LABELS
  // override below keeps aggregated Cloudflare spend labelled as one thing.
  {
    key: "cloudflare_r2",
    name: "Cloudflare R2 (object storage)",
    kind: "infra",
    billable: true,
    credential_env: "R2_ACCESS_KEY_ID",
    env_names: ["CLOUDFLARE_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"],
    ledger_provider: "cloudflare",
    models: [
      {
        sku: "r2_storage",
        label: "R2 object storage (uploads + renders). Egress is $0.",
        unit: "GB-month",
        unit_cost_cents: 1.5,
        trigger: "Every capture upload and published render — how app tours are stored AND served",
        source: `${COST_MODEL_MD} §3 ($0.015 per GB-month; egress $0.00)`,
      },
    ],
  },
  {
    key: "cloudflare_stream",
    name: "Cloudflare Stream (video delivery — optional)",
    kind: "infra",
    billable: true,
    optional: true,
    credential_env: "CLOUDFLARE_STREAM_TOKEN",
    env_names: ["CLOUDFLARE_STREAM_TOKEN", "CLOUDFLARE_STREAM_CUSTOMER_CODE"],
    ledger_provider: "cloudflare",
    whatToDo:
      "Optional — app tours serve video from Cloudflare R2, so Stream needs no key and a \"not configured\" row here is expected, not a fault. Set CLOUDFLARE_STREAM_TOKEN + CLOUDFLARE_STREAM_CUSTOMER_CODE only to enable HLS-delivered tours.",
    models: [
      {
        sku: "stream_store",
        label: "Cloudflare Stream storage (HLS-delivered tours only)",
        unit: "stored minute per month",
        unit_cost_cents: 0.5,
        trigger: "Logged once per Stream-hosted published render; skipped entirely when Stream is off (app tours use R2)",
        source:
          `services/worker/infra_costs.py + services/worker/settings.py — stream_store_cents_per_min (0.5); ${COST_MODEL_MD} §3 ($0.005/min)`,
      },
      {
        sku: "stream_deliver",
        label: "Cloudflare Stream delivery — the only cost that scales with VIEWS",
        unit: "watched minute",
        unit_cost_cents: 0.1,
        trigger: "Every view of a Stream-delivered tour (metered per view via the beacon → metering table)",
        source: `${COST_MODEL_MD} §3 ($0.001 per watched minute)`,
      },
    ],
  },
  {
    key: "render_compute",
    name: "Render worker compute",
    kind: "infra",
    billable: true,
    // No vendor credential exists for this line — it is our OWN compute, priced by
    // a configurable per-minute ESTIMATE (a default in settings.py, optionally
    // overridden by RENDER_COMPUTE_CENTS_PER_MIN). credential_env is therefore a
    // plain-words description, NOT an env var name: with env_names empty the
    // health route must not claim "RENDER_COMPUTE_CENTS_PER_MIN is set" for a
    // value it never checked. It reports status "no_key_required" instead.
    credential_env: "A per-minute compute rate (no API key required)",
    env_names: [],
    ledger_provider: "modal",
    models: [
      {
        sku: "ffmpeg-h264-allintra",
        label: "Server-side encode compute — no vendor key; a CONFIGURABLE ESTIMATE, not a vendor bill",
        unit: "output minute",
        unit_cost_cents: 0.5,
        trigger: "Worker render of a 4K / AI / Stream-hosted tour (the base render is free on device)",
        source:
          "services/worker/settings.py — render_compute_cents_per_min (0.5), overridable with RENDER_COMPUTE_CENTS_PER_MIN",
      },
    ],
  },
  {
    key: "ghl",
    name: "GoHighLevel CRM",
    kind: "integration",
    billable: false,
    credential_env: "GHL_API_KEY",
    env_names: ["GHL_API_KEY", "GHL_LOCATION_ID"],
    ledger_provider: null,
    models: [
      {
        sku: "contacts/upsert",
        label: "Lead sync to the CRM (no per-call charge — covered by the CRM subscription)",
        unit: "lead",
        unit_cost_cents: 0,
        trigger: "A tour visitor submits the lead form (POST /leads); DELETE /me lead purge",
        source: "services/supabase/functions/leads/index.ts — no metered cost",
      },
    ],
  },
  {
    key: "turnstile",
    name: "Cloudflare Turnstile",
    kind: "integration",
    billable: false,
    credential_env: "TURNSTILE_SECRET_KEY",
    env_names: ["TURNSTILE_SECRET_KEY"],
    ledger_provider: null,
    models: [
      {
        sku: "siteverify",
        label: "Bot check on the public lead form (free)",
        unit: "verification",
        unit_cost_cents: 0,
        trigger: "POST /leads from a public tour page",
        source: "services/supabase/functions/leads/index.ts — free tier",
      },
    ],
  },
  {
    key: "apple",
    name: "Sign in with Apple",
    kind: "integration",
    billable: false,
    credential_env: "APPLE_PRIVATE_KEY_P8",
    env_names: ["APPLE_TEAM_ID", "APPLE_CLIENT_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY_P8"],
    ledger_provider: null,
    models: [
      {
        sku: "auth/token + auth/revoke",
        label: "Token exchange and revocation on account deletion (TN3194) — free",
        unit: "call",
        unit_cost_cents: 0,
        trigger: "POST /me/apple-code at sign-in; DELETE /me at account deletion",
        source: "services/supabase/functions/_shared/apple.ts — free",
      },
    ],
  },
];

/** Human labels for the ledger's `feature` vocabulary. Unknown keys pass through. */
const FEATURE_LABELS: Record<string, string> = {
  declutter: "Declutter",
  restage: "Virtual restage",
  hero: "AI hero clip",
  qc: "QC drift judge",
  render: "Server render compute",
  // In-app AI (POST /ai-photo, /ai-video) — the F-E-15 writers, distinct from the
  // worker's declutter/restage/hero lines above (app spend has job_id IS NULL).
  photo_edit: "AI photo edit",
  reel: "AI reel clip",
  aerial: "AI aerial",
  drone_render: "Drone-glide render (Topaz)",
  stream_store: "Stream storage",
  stream_deliver: "Stream delivery",
};

const PROVIDER_LABELS: Record<string, string> = Object.fromEntries(
  PROVIDERS.map((p) => [p.ledger_provider ?? p.key, p.name]),
);
// cloudflare_r2 and cloudflare_stream both log under ledger_provider "cloudflare"
// (the ledger does not distinguish R2 from Stream). Object.fromEntries would keep
// only whichever split row was built last, so spend aggregated under that key
// gets an explicit combined label instead of one half's name.
PROVIDER_LABELS["cloudflare"] = "Cloudflare (R2 + Stream)";

// ── Small helpers ────────────────────────────────────────────────────────────

function nowIso(): string {
  return new Date().toISOString();
}

/**
 * True when every credential this provider REQUIRES is present. A provider that
 * needs no secret (env_names empty — e.g. our own render compute) is operational
 * by definition and reads true, but `requires_credential` in the response and
 * the "no_key_required" health status keep that case honest: nothing was
 * checked, so no response asserts a specific env var "is set".
 */
function providerConfigured(p: ProviderSpec): boolean {
  return p.env_names.length === 0 ? true : p.env_names.every(envConfigured);
}

/**
 * Health status slug for a provider row. Extends the original
 * ok/idle/unmetered/unconfigured set with two honest values the old set could
 * not express. Both are new slug VALUES, not new fields — the shipped iOS build
 * renders an unknown status through its neutral default branch, so nothing
 * breaks on the phone already in the field:
 *   • "no_key_required" — needs no secret (env_names empty). "configured" was
 *     never a claim about a verified credential, so it must not imply one.
 *   • "optional_off"    — an OPTIONAL provider whose credential is deliberately
 *     unset (Stream, KIE). "Not configured" here is expected, not a fault.
 */
function healthStatus(p: ProviderSpec, configured: boolean, hasRows: boolean): string {
  if (p.env_names.length === 0) return "no_key_required";
  if (!configured) return p.optional ? "optional_off" : "unconfigured";
  if (p.ledger_provider === null) return "unmetered";
  return hasRows ? "ok" : "idle";
}

/**
 * Read every row a filtered query matches, a page at a time.
 * Ordered by `id` (stable) so pages cannot skip or duplicate rows across the
 * boundary the way an ordering on a tied timestamp can.
 */
async function pageAll<T>(
  build: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>,
  what: string,
): Promise<{ rows: T[]; truncated: boolean }> {
  const rows: T[] = [];
  for (let p = 0; p < MAX_PAGES; p++) {
    const { data, error } = await build(p * PAGE, p * PAGE + PAGE - 1);
    if (error) throw new HttpError(500, `${what} read failed: ${error.message}`);
    const batch = data ?? [];
    rows.push(...batch);
    if (batch.length < PAGE) return { rows, truncated: false };
  }
  return { rows, truncated: true };
}

interface LedgerRow {
  id: string;
  org_id: string | null;
  provider: string | null;
  feature: string | null;
  model: string | null;
  total_cents: number | string | null;
  created_at: string;
}

function readLedgerSince(db: SupabaseClient, sinceIso: string) {
  return pageAll<LedgerRow>(
    (from, to) =>
      db
        .from("cost_ledger")
        .select("id, org_id, provider, feature, model, total_cents, created_at")
        .gte("created_at", sinceIso)
        .order("id", { ascending: true })
        .range(from, to),
    "Cost ledger",
  );
}

interface Bucket {
  total: number;
  rows: number;
}

function bump(map: Map<string, Bucket>, key: string, cents: number): void {
  const b = map.get(key) ?? { total: 0, rows: 0 };
  b.total += cents;
  b.rows += 1;
  map.set(key, b);
}

function share(part: number, whole: number): number {
  return whole > 0 ? round4(part / whole) : 0;
}

/**
 * The effective plan — mirrors public.effective_plan() (migration 0010): an
 * expired trial reads `free`, exactly as it does in every charge path. Kept in
 * TypeScript here because the console reads hundreds of orgs at once and a
 * per-org RPC round trip is not worth it; nothing is charged off this value.
 */
function effectivePlan(plan: string | null, trialEndsAt: string | null): string {
  const raw = plan ?? "trial";
  if (raw !== "trial") return raw;
  if (!trialEndsAt) return "trial";
  const ends = Date.parse(trialEndsAt);
  return Number.isFinite(ends) && ends < Date.now() ? "free" : "trial";
}

// ── GET /admin/spend ─────────────────────────────────────────────────────────

const WINDOWS = ["today", "7d", "30d"] as const;
type SpendWindow = typeof WINDOWS[number];

function windowStart(w: SpendWindow): Date {
  const now = new Date();
  if (w === "today") {
    return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  }
  const days = w === "7d" ? 7 : 30;
  return new Date(now.getTime() - days * 86_400_000);
}

async function handleSpend(req: Request): Promise<Response> {
  const raw = (new URL(req.url).searchParams.get("window") ?? "today").trim();
  if (!(WINDOWS as readonly string[]).includes(raw)) {
    throw new HttpError(400, `window must be one of ${WINDOWS.join(", ")}`);
  }
  const win = raw as SpendWindow;
  const from = windowStart(win);
  const fromIso = from.toISOString();
  const db = adminClient();

  const [{ rows, truncated }, coverage] = await Promise.all([
    readLedgerSince(db, fromIso),
    buildCoverage(db),
  ]);

  const byProvider = new Map<string, Bucket>();
  const byFeature = new Map<string, Bucket>();
  const byOrg = new Map<string, Bucket>();
  let total = 0;

  for (const r of rows) {
    const cents = Number(r.total_cents ?? 0);
    if (!Number.isFinite(cents)) continue;
    total += cents;
    bump(byProvider, r.provider ?? "unknown", cents);
    bump(byFeature, r.feature ?? "unknown", cents);
    bump(byOrg, r.org_id ?? "", cents); // "" == unattributed (org_id is nullable)
  }
  total = round4(total);

  // Org names for the ids we actually saw. Org-level only: id + name + plan,
  // never a member.
  const orgIds = [...byOrg.keys()].filter((k) => k !== "");
  const orgMeta = new Map<string, { name: string; plan: string | null }>();
  for (let i = 0; i < orgIds.length; i += 200) {
    const chunk = orgIds.slice(i, i + 200);
    const { data, error } = await db.from("orgs").select("id, name, plan").in("id", chunk);
    if (error) throw new HttpError(500, `Org lookup failed: ${error.message}`);
    for (const o of data ?? []) {
      orgMeta.set(o.id as string, { name: (o.name as string) ?? "", plan: (o.plan as string) ?? null });
    }
  }

  const sortDesc = <T extends { total_cents: number }>(a: T[]): T[] =>
    a.sort((x, y) => y.total_cents - x.total_cents);

  return json({
    window: win,
    from: fromIso,
    to: nowIso(),
    generated_at: nowIso(),
    total_cents: total,
    ledger_rows: rows.length,
    truncated,
    by_provider: sortDesc(
      [...byProvider.entries()].map(([key, b]) => ({
        key,
        label: PROVIDER_LABELS[key] ?? key,
        total_cents: round4(b.total),
        rows: b.rows,
        share: share(b.total, total),
      })),
    ),
    by_feature: sortDesc(
      [...byFeature.entries()].map(([key, b]) => ({
        key,
        label: FEATURE_LABELS[key] ?? key,
        total_cents: round4(b.total),
        rows: b.rows,
        share: share(b.total, total),
      })),
    ),
    by_org: sortDesc(
      [...byOrg.entries()].map(([id, b]) => ({
        org_id: id === "" ? null : id,
        org_name: id === "" ? "(unattributed)" : (orgMeta.get(id)?.name ?? "(deleted workspace)"),
        plan: id === "" ? null : (orgMeta.get(id)?.plan ?? null),
        total_cents: round4(b.total),
        rows: b.rows,
        share: share(b.total, total),
      })),
    ),
    coverage,
  });
}

// ── coverage: what the ledger number does and does NOT include ───────────────
//
// This is the honest part of /admin/spend. `total_cents` is the LEDGER's number,
// not the invoice. Two named sources are missing today (docs/handoff/E-network.md
// §2, finding F-E-15): ai-photo and ai-video make billable Gemini and fal calls
// and never write a cost_ledger row, so every in-app AI generation is invisible
// here AND to the per-org monthly COGS ceiling inside log_job_cost(). Stream
// DELIVERY — the one cost that scales with views — is metered per view in
// `metering` and likewise never priced into the ledger.
//
// `represented` is probed against the data, not asserted in prose, so coverage
// heals itself the moment those writers land:
//   • app AI has no render job, so an org-scoped ledger row with job_id IS NULL
//     can only have come from an app-AI ledger write (E-network.md §2 says
//     logCost() cannot be used as-is precisely because it requires a job_id).
//   • stream delivery would arrive as feature = 'stream_deliver'.

interface CoverageSource {
  key: string;
  label: string;
  represented: boolean;
  detail: string;
  reference: string;
}

async function buildCoverage(db: SupabaseClient): Promise<Record<string, unknown>> {
  const [appRes, deliverRes] = await Promise.all([
    db.from("cost_ledger").select("id", { count: "exact", head: true }).is("job_id", null),
    db.from("cost_ledger").select("id", { count: "exact", head: true }).eq("feature", "stream_deliver"),
  ]);
  // A failed probe must not silently claim coverage: assume the gap is open.
  const appAiLogged = !appRes.error && (appRes.count ?? 0) > 0;
  const deliveryLogged = !deliverRes.error && (deliverRes.count ?? 0) > 0;

  const sources: CoverageSource[] = [
    {
      key: "worker_pipeline",
      label: "Worker render pipeline — declutter, restage, hero clip, QC",
      represented: true,
      detail:
        "services/pipeline writes one cost_ledger row per metered provider call through log_job_cost(), which also enforces the per-job cap and the per-org monthly COGS ceiling.",
      reference: "services/pipeline/cost_ledger.py",
    },
    {
      key: "worker_infra",
      label: "Worker infrastructure — server encode compute and Stream storage",
      represented: true,
      detail:
        "services/worker/infra_costs.py logs feature=render and feature=stream_store. The render number is a configurable per-minute ESTIMATE, not a vendor bill.",
      reference: "services/worker/infra_costs.py",
    },
    {
      key: "app_ai_photo",
      label: "In-app AI photo edits (POST /ai-photo)",
      represented: appAiLogged,
      detail: appAiLogged
        ? "Org-scoped ledger rows with no render job are present, so app AI photo spend is now being recorded."
        : "The ai-photo edge function never writes a cost_ledger row, so every Photo Studio edit is missing from the total above and from the per-org monthly COGS ceiling. Real provider spend is HIGHER than this number. Size the gap from GET /admin/usage photo_edits_used x 3.9c.",
      reference: "docs/handoff/E-network.md §2 (finding F-E-15)",
    },
    {
      key: "app_ai_video",
      label: "In-app AI video — reel clips, aerials, Topaz drone renders (POST /ai-video)",
      represented: appAiLogged,
      detail: appAiLogged
        ? "Org-scoped ledger rows with no render job are present, so app AI video spend is now being recorded."
        : "The ai-video edge function never writes a cost_ledger row. These are the expensive taps (aerial $0.80, Topaz up to $14.40) and none of them appear above. Size the gap from GET /admin/usage reels/aerials/drone counters x the unit prices in GET /admin/providers.",
      reference: "docs/handoff/E-network.md §2 (finding F-E-15)",
    },
    {
      key: "stream_delivery",
      label: "Cloudflare Stream delivery — the cost that scales with views",
      represented: deliveryLogged,
      detail: deliveryLogged
        ? "feature=stream_deliver rows are present, so watched-minute delivery is priced into the ledger."
        : "Views are metered in the `metering` table (watched minutes per render per day) but never priced into cost_ledger, so delivery spend does not appear above.",
      reference: "docs/AI-COST-MODEL.md §3 ($0.001 per watched minute)",
    },
  ];

  const missing = sources.filter((s) => !s.represented);
  return {
    complete: missing.length === 0,
    headline: missing.length === 0
      ? "Every known spend source writes to the ledger — this total is complete."
      : `Incomplete: ${missing.length} spend source(s) never reach the ledger, so real provider spend is HIGHER than the total shown.`,
    represented_count: sources.length - missing.length,
    missing_count: missing.length,
    sources,
  };
}

// ── GET /admin/providers ─────────────────────────────────────────────────────

/** The `admin_last_probe` block, as the console renders it. */
interface LastProbe {
  at: string | null;
  ok_count: number | null;
  fail_count: number | null;
}

/**
 * When the keys were last actually TESTED, and how it went. Read defensively:
 * this row does not exist until somebody presses the button, and a console that
 * has never been probed must show "never tested", not an error.
 *
 * The stored value also carries `by` (the admin's user id) so a probe is never
 * anonymous — the same audit convention as the routing switches. It is NOT
 * returned: this file's rule is that no user id but the caller's own appears in
 * any payload.
 */
async function readLastProbe(db: SupabaseClient): Promise<LastProbe | null> {
  const { data, error } = await db
    .from("app_config")
    .select("value")
    .eq("key", "admin_last_probe")
    .maybeSingle();
  if (error || !data) return null;
  const v = (data.value ?? {}) as Record<string, unknown>;
  if (typeof v.at !== "string") return null;
  return {
    at: v.at,
    ok_count: typeof v.ok_count === "number" ? v.ok_count : null,
    fail_count: typeof v.fail_count === "number" ? v.fail_count : null,
  };
}

async function handleProviders(): Promise<Response> {
  // ADDED field. A best-effort read: the inventory is the point of this route
  // and must still answer if app_config is unreadable.
  const lastProbe = await readLastProbe(adminClient()).catch(() => null);

  const providers = PROVIDERS.map((p) => ({
    key: p.key,
    name: p.name,
    kind: p.kind,
    billable: p.billable,
    credential_env: p.credential_env, // the NAME. never the value.
    env_names: p.env_names,
    configured: providerConfigured(p),
    ledger_provider: p.ledger_provider,
    // ADDED fields (safe: the shipped iOS build decodes leniently and ignores
    // unknown keys). They let the console tell "optional, deliberately off" and
    // "no credential needed" apart from "required, but missing" instead of
    // reddening a working provider.
    optional: p.optional ?? false,
    requires_credential: p.env_names.length > 0,
    what_to_do: p.whatToDo ?? null,
    models: p.models,
  }));

  return json({
    generated_at: nowIso(),
    provider_count: providers.length,
    configured_count: providers.filter((p) => p.configured).length,
    providers,
    // ADDED field (the shipped iOS build ignores unknown keys). null until the
    // owner has pressed "Test all keys" at least once. `configured` above is
    // still only "the env var is set" — this is the last time any of them was
    // proved to WORK, which is a different and much more useful fact.
    last_probe: lastProbe,
  });
}

// ── GET /admin/providers/probe — the live key test ───────────────────────────
//
// The one route in this function that calls anybody. It exists because
// `configured: true` has never meant "working": a rotated key, a truncated
// paste and a key from the wrong account all look identical to envConfigured(),
// and several of these keys had never been exercised from deployed code at all.
//
// Every probe is a $0, idempotent, read-only call — a list/credits/status
// endpoint, never a generation. The endpoint table, the doc URL for each, and
// the observed bad-key status code all live in admin/probe.ts.
//
// Three guards, in order:
//   1. requireAdmin() — already run by the dispatcher, before the method check.
//   2. The general 60/min admin limit — already charged by the dispatcher.
//   3. This route's OWN 6/hour limit, below. One tap is eleven outbound
//      requests; nothing else here is.
//
// Nothing about a credential is returned or logged. probe.ts redacts and
// truncates every upstream string before it gets here, and this function adds
// no logging of its own beyond the count.

async function handleProbe(caller: AdminCaller): Promise<Response> {
  if (
    !(await durableRateLimit(
      `admin-probe:${caller.userId}`,
      PROBE_MAX_PER_WINDOW,
      PROBE_WINDOW_SECONDS,
    ))
  ) {
    throw new HttpError(
      429,
      "You've tested the keys a few times already. You can test again in about an hour.",
      "rate_limited",
    );
  }

  const report = await probeAll();
  const at = report.checked_at;

  // Remember the result so /admin/providers can say "Last tested 12 min ago:
  // 9 ok, 1 failed" without re-running eleven vendor calls. `by` records WHO,
  // matching the routing switches; it is stored, never returned.
  const { error } = await adminClient()
    .from("app_config")
    .upsert({
      key: "admin_last_probe",
      value: {
        at,
        ok_count: report.ok_count,
        fail_count: report.fail_count,
        not_probeable_count: report.not_probeable_count,
        by: caller.userId,
      },
      updated_at: at,
    }, { onConflict: "key" });
  if (error) console.error("admin: last-probe write failed:", error.message);

  // Counts only. Not which vendor, not what it said.
  console.log(
    `admin: key probe by ${caller.userId} — ${report.ok_count} ok, ` +
      `${report.fail_count} failed, ${report.not_probeable_count} not testable`,
  );

  return json({ ...report, last_probe_recorded: !error });
}

// ── GET /admin/usage ─────────────────────────────────────────────────────────

// The monthly meter key prefixes the AI routes charge (ai-photo / ai-video).
// Scoping the rate_limits read to these four prefixes is deliberate: the same
// table holds `leads:<ip>` and `beacon:<ip>` rows, and a visitor IP is personal
// data that has no business in an admin response.
const METERS: Array<{ feature: string; prefix: string; capField: keyof Entitlement }> = [
  { feature: "photo_edits", prefix: "aiphotomo", capField: "photo_edits_per_month" },
  { feature: "reels", prefix: "reelmo", capField: "reels_per_month" },
  { feature: "aerials", prefix: "aerialmo", capField: "aerials_per_month" },
  { feature: "drone", prefix: "dronemo", capField: "topaz_per_month" },
];

interface Entitlement {
  plan: string;
  renders_per_month: number;
  photo_edits_per_month: number;
  reels_per_month: number;
  aerials_per_month: number;
  topaz_per_month: number;
  seats: number;
  cogs_ceiling_cents: number;
  price_cents: number;
}

/**
 * The org-keyed monthly meters, one prefix at a time.
 *
 * Four narrow `like` reads rather than one hand-built `or=(...)` string: the
 * prefix filter is the ONLY thing keeping the IP-keyed `leads:<ip>` and
 * `beacon:<ip>` rows in this table out of an admin response, and it is not worth
 * resting that on the quoting rules of a filter expression built by hand.
 */
async function readMeters(db: SupabaseClient): Promise<{ rows: MeterRow[]; truncated: boolean }> {
  const rows: MeterRow[] = [];
  let truncated = false;
  for (const m of METERS) {
    const page = await pageAll<MeterRow>(
      (from, to) =>
        db.from("rate_limits").select("key, count, window_start, window_seconds")
          .like("key", `${m.prefix}:%`)
          .order("key", { ascending: true }).range(from, to),
      "Usage counters",
    );
    rows.push(...page.rows);
    truncated = truncated || page.truncated;
  }
  return { rows, truncated };
}

interface MeterRow {
  key: string;
  count: number;
  window_start: string;
  window_seconds: number;
}

const IN_FLIGHT_STATUSES = ["created", "queued", "claimed", "processing"];

/** render_jobs has no org_id: the org comes from the joined listing. */
type JoinedOrg = { org_id: string } | Array<{ org_id: string }> | null;

async function handleUsage(): Promise<Response> {
  const db = adminClient();
  const now = new Date();
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const monthStartIso = monthStart.toISOString();

  const [orgsRes, entRes, meterRes, ledger, monthJobs, liveJobs] = await Promise.all([
    pageAll<{ id: string; name: string; plan: string | null; trial_ends_at: string | null }>(
      (from, to) =>
        db.from("orgs").select("id, name, plan, trial_ends_at").is("deleted_at", null)
          .order("id", { ascending: true }).range(from, to),
      "Orgs",
    ),
    db.from("plan_entitlements").select("*"),
    readMeters(db),
    readLedgerSince(db, monthStartIso),
    pageAll<{ id: string; listings: JoinedOrg }>(
      (from, to) =>
        db.from("render_jobs").select("id, listings!inner(org_id)")
          .eq("source", "worker").gte("created_at", monthStartIso)
          .order("id", { ascending: true }).range(from, to),
      "Render jobs",
    ),
    pageAll<
      { id: string; status: string; lease_expires_at: string | null; listings: JoinedOrg }
    >(
      (from, to) =>
        db.from("render_jobs").select("id, status, lease_expires_at, listings!inner(org_id)")
          .eq("source", "worker").in("status", IN_FLIGHT_STATUSES)
          .order("id", { ascending: true }).range(from, to),
      "In-flight render jobs",
    ),
  ]);

  if (entRes.error) throw new HttpError(500, `Entitlement lookup failed: ${entRes.error.message}`);
  const entitlements = new Map<string, Entitlement>(
    ((entRes.data ?? []) as Entitlement[]).map((e) => [e.plan, e]),
  );

  const spendByOrg = new Map<string, number>();
  for (const r of ledger.rows) {
    if (!r.org_id) continue;
    const cents = Number(r.total_cents ?? 0);
    if (Number.isFinite(cents)) spendByOrg.set(r.org_id, (spendByOrg.get(r.org_id) ?? 0) + cents);
  }

  // PostgREST types an embedded resource as an array even for a to-one join,
  // and supabase-js reflects that; normalise both shapes.
  const orgOf = (row: { listings: JoinedOrg }): string | null => {
    const l = row.listings;
    if (!l) return null;
    return (Array.isArray(l) ? l[0]?.org_id : l.org_id) ?? null;
  };

  const rendersByOrg = new Map<string, number>();
  for (const j of monthJobs.rows) {
    const o = orgOf(j);
    if (o) rendersByOrg.set(o, (rendersByOrg.get(o) ?? 0) + 1);
  }

  const nowMs = now.getTime();
  const inFlightByOrg = new Map<string, number>();
  const orphanByOrg = new Map<string, number>();
  for (const j of liveJobs.rows) {
    const o = orgOf(j);
    if (!o) continue;
    // 0015: an expired lease on a `processing` job is an ORPHAN, not in flight.
    const leaseMs = j.lease_expires_at ? Date.parse(j.lease_expires_at) : NaN;
    const orphaned = j.status === "processing" && Number.isFinite(leaseMs) && leaseMs <= nowMs;
    if (orphaned) orphanByOrg.set(o, (orphanByOrg.get(o) ?? 0) + 1);
    else inFlightByOrg.set(o, (inFlightByOrg.get(o) ?? 0) + 1);
  }

  // key -> live counter, with an expired 30-day window counting as 0 (the same
  // arithmetic GET /me does, so the two screens can never disagree).
  const meterByKey = new Map<string, number>();
  for (const row of meterRes.rows) {
    const startMs = Date.parse(row.window_start);
    const endMs = startMs + Number(row.window_seconds ?? MONTH_SECONDS) * 1000;
    if (!Number.isFinite(startMs) || endMs <= nowMs) continue;
    meterByKey.set(row.key, Math.max(0, Number(row.count ?? 0)));
  }

  const orgs = orgsRes.rows.map((o) => {
    const plan = effectivePlan(o.plan, o.trial_ends_at);
    const ent = entitlements.get(plan) ?? entitlements.get("trial");
    const caps: Record<string, number> = {
      renders: ent?.renders_per_month ?? 0,
      photo_edits: ent?.photo_edits_per_month ?? 0,
      reels: ent?.reels_per_month ?? 0,
      aerials: ent?.aerials_per_month ?? 0,
      drone: ent?.topaz_per_month ?? 0,
    };
    const used: Record<string, number> = { renders: rendersByOrg.get(o.id) ?? 0 };
    for (const m of METERS) {
      const raw = meterByKey.get(`${m.prefix}:${o.id}`) ?? 0;
      const cap = caps[m.feature] ?? 0;
      // bump_rate keeps counting past the cap; clamp what we display.
      used[m.feature] = cap > 0 ? Math.min(raw, cap) : raw;
    }

    const spend = round4(spendByOrg.get(o.id) ?? 0);
    const ceiling = ent?.cogs_ceiling_cents ?? 0;
    const inFlight = inFlightByOrg.get(o.id) ?? 0;
    const orphaned = orphanByOrg.get(o.id) ?? 0;

    const reasons: string[] = [];
    for (const feature of ["renders", "photo_edits", "reels", "aerials", "drone"]) {
      const cap = caps[feature] ?? 0;
      if (cap > 0 && (used[feature] ?? 0) >= cap) reasons.push(`${feature}_at_cap`);
    }
    if (ceiling > 0 && spend >= ceiling) reasons.push("spend_ceiling_reached");
    if (inFlight >= 3) reasons.push("jobs_in_flight_max");
    if (orphaned > 0) reasons.push("orphaned_jobs");

    return {
      org_id: o.id,
      org_name: o.name ?? "",
      plan,
      plan_raw: o.plan ?? "trial",
      trial_ends_at: o.trial_ends_at ?? null,
      spend_cents_month: spend,
      cogs_ceiling_cents: ceiling,
      spend_share_of_ceiling: share(spend, ceiling),
      renders_used: used.renders ?? 0,
      renders_cap: caps.renders ?? 0,
      photo_edits_used: used.photo_edits ?? 0,
      photo_edits_cap: caps.photo_edits ?? 0,
      reels_used: used.reels ?? 0,
      reels_cap: caps.reels ?? 0,
      aerials_used: used.aerials ?? 0,
      aerials_cap: caps.aerials ?? 0,
      drone_used: used.drone ?? 0,
      drone_cap: caps.drone ?? 0,
      jobs_in_flight: inFlight,
      jobs_orphaned: orphaned,
      blocked: reasons.length > 0,
      blocked_reasons: reasons,
    };
  });

  orgs.sort((a, b) =>
    b.spend_cents_month - a.spend_cents_month || a.org_name.localeCompare(b.org_name)
  );
  const capped = orgs.slice(0, MAX_ORGS);

  return json({
    generated_at: nowIso(),
    month: monthStartIso.slice(0, 7),
    month_start: monthStartIso,
    org_count: orgs.length,
    blocked_count: orgs.filter((o) => o.blocked).length,
    truncated: orgsRes.truncated || orgs.length > MAX_ORGS,
    orgs: capped,
  });
}

// ── GET /admin/health ────────────────────────────────────────────────────────
//
// Deliberately makes NO outbound provider call: this route must never spend a
// cent or exercise a key. Everything below comes from data we already hold.

async function handleHealth(): Promise<Response> {
  const db = adminClient();
  const sinceIso = new Date(Date.now() - HEALTH_WINDOW_DAYS * 86_400_000).toISOString();

  const metered = PROVIDERS.filter((p) => p.ledger_provider !== null);

  const [{ rows: windowRows }, lastRows, failures] = await Promise.all([
    readLedgerSince(db, sinceIso),
    Promise.all(
      metered.map((p) =>
        db.from("cost_ledger")
          .select("created_at, feature, model")
          .eq("provider", p.ledger_provider as string)
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle()
      ),
    ),
    pageAll<{ error: Record<string, unknown> | null; finished_at: string | null; status: string }>(
      (from, to) =>
        db.from("render_jobs").select("error, finished_at, status")
          .eq("status", "failed").gte("finished_at", sinceIso)
          .order("finished_at", { ascending: false }).range(from, to),
      "Render job failures",
    ),
  ]);

  const inWindow = new Map<string, Bucket>();
  for (const r of windowRows) {
    const cents = Number(r.total_cents ?? 0);
    bump(inWindow, r.provider ?? "unknown", Number.isFinite(cents) ? cents : 0);
  }

  const providers = metered.map((p, i) => {
    const configured = providerConfigured(p);
    const last = lastRows[i];
    const lastRow = last.error ? null : last.data;
    // An unconfigured provider cannot have run, so it shows no success or spend —
    // even when it shares a ledger_provider key with a sibling that DID (Stream
    // shares "cloudflare" with R2). Only a configured provider is credited with
    // the window's rows for that key, so a deliberately-off Stream row does not
    // display R2/worker Cloudflare spend as if it were its own.
    const b = configured ? inWindow.get(p.ledger_provider as string) : undefined;
    const status = healthStatus(p, configured, !!b && b.rows > 0);
    return {
      key: p.key,
      name: p.name,
      credential_env: p.credential_env, // NAME only (plain words for a keyless line)
      configured,
      status,
      optional: p.optional ?? false,
      requires_credential: p.env_names.length > 0,
      ledger_provider: p.ledger_provider,
      last_success_at: configured ? ((lastRow?.created_at as string | undefined) ?? null) : null,
      last_success_detail: configured && lastRow
        ? `${lastRow.feature ?? "?"} / ${lastRow.model ?? "-"}`
        : null,
      rows_in_window: b?.rows ?? 0,
      spend_cents_in_window: round4(b?.total ?? 0),
    };
  });

  // Providers that never write ledger rows: say so instead of implying health.
  for (const p of PROVIDERS.filter((x) => x.ledger_provider === null)) {
    const configured = providerConfigured(p);
    providers.push({
      key: p.key,
      name: p.name,
      credential_env: p.credential_env,
      configured,
      status: healthStatus(p, configured, false),
      optional: p.optional ?? false,
      requires_credential: p.env_names.length > 0,
      ledger_provider: null,
      last_success_at: null,
      last_success_detail: null,
      rows_in_window: 0,
      spend_cents_in_window: 0,
    });
  }

  // Failures are per-JOB, not per-provider: render_jobs.error is
  // {message, step, type, ts} and records no provider. `message` is an
  // arbitrary upstream string that could carry a signed URL or key material, so
  // it is NOT surfaced — only the bounded `step` and `type`.
  const byStep = new Map<string, number>();
  let lastAt: string | null = null;
  let lastStep: string | null = null;
  let lastType: string | null = null;
  for (const f of failures.rows) {
    const step = String((f.error?.step as string | undefined) ?? "unknown").slice(0, 40);
    byStep.set(step, (byStep.get(step) ?? 0) + 1);
    if (lastAt === null) {
      lastAt = f.finished_at ?? null;
      lastStep = step;
      lastType = String((f.error?.type as string | undefined) ?? "unknown").slice(0, 60);
    }
  }

  const { count: orphanCount } = await db
    .from("render_jobs")
    .select("id", { count: "exact", head: true })
    .eq("source", "worker")
    .eq("status", "processing")
    .lt("lease_expires_at", nowIso());

  return json({
    generated_at: nowIso(),
    checked_provider_apis: false,
    note:
      "No provider API is called by this route — no spend, no latency, no key exercised. " +
      "Success is inferred from cost_ledger rows (a row is only written after a metered call returned); " +
      "failures are render-job failures, which are NOT attributed to a provider. " +
      "A provider needing no secret is reported \"no_key_required\", and an optional provider whose " +
      "credential is deliberately unset is \"optional_off\" — the route verifies no secret for either and " +
      "asserts none is set. An unconfigured provider shows no success or spend, since it cannot have run.",
    window_days: HEALTH_WINDOW_DAYS,
    providers,
    job_failures: {
      window_days: HEALTH_WINDOW_DAYS,
      failed_jobs: failures.rows.length,
      orphaned_jobs: orphanCount ?? 0,
      last_failure_at: lastAt,
      last_failure_step: lastStep,
      last_failure_type: lastType,
      by_step: [...byStep.entries()]
        .map(([key, count]) => ({ key, count }))
        .sort((a, b) => b.count - a.count),
    },
  });
}

// ── GET /admin/routing — the AI router, and the two switches that change it ──
//
// Routes live in a TABLE (migration 0018), so this console is where a human
// actually sees the brain: which chain each task resolves to, what each step
// costs, whether its circuit is open, and what it has spent in 30 days.
//
// Shape frozen in docs/ADMIN-CONSOLE-CONTRACT.md §Routing.
//
// PRIVACY, deliberately: `app_config.ai_router` stores `changed_by` (the admin's
// user id) because an audit trail with no actor is not an audit trail. The
// RESPONSE never returns that id — the console's own rule is that no user id
// but the caller's own may appear in any payload — so it reports
// `changed_by_is_you` instead. The id stays in the database for whoever reads
// it with the service role.

const ROUTING_SPEND_WINDOW_DAYS = 30;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface RouteRowAdmin {
  id: string;
  task: string;
  position: number;
  provider: string;
  model: string;
  unit: string;
  unit_cents: number | string | null;
  capabilities: string[] | null;
  max_latency_s: number | null;
  min_plan: string | null;
  same_model_as: string | null;
  privacy_tier: string | null;
  enabled: boolean | null;
  retire_after: string | null;
  note: string | null;
  updated_at: string | null;
}

interface HealthRowAdmin {
  provider: string;
  model: string;
  consecutive_failures: number | null;
  open_until: string | null;
  p95_latency_ms: number | null;
  last_ok_at: string | null;
  last_fail_at: string | null;
  last_error_class: string | null;
}

function stepKey(provider: string, model: string): string {
  return `${provider}|${model}`;
}

/** The `ai_router` row, defensively read: any shape but `{enabled:true}` is off. */
async function readRouterFlag(
  db: SupabaseClient,
): Promise<{ enabled: boolean; changed_by: string | null; changed_at: string | null }> {
  const { data, error } = await db
    .from("app_config")
    .select("value")
    .eq("key", "ai_router")
    .maybeSingle();
  if (error) throw new HttpError(500, `Router flag read failed: ${error.message}`);
  const v = (data?.value ?? {}) as Record<string, unknown>;
  return {
    enabled: v.enabled === true,
    changed_by: typeof v.changed_by === "string" ? v.changed_by : null,
    changed_at: typeof v.changed_at === "string" ? v.changed_at : null,
  };
}

async function handleRouting(caller: AdminCaller): Promise<Response> {
  const db = adminClient();
  const sinceIso = new Date(Date.now() - ROUTING_SPEND_WINDOW_DAYS * 86_400_000).toISOString();

  const [flag, policyRes, routes, healthRes, ledger] = await Promise.all([
    readRouterFlag(db),
    db.from("plan_routing_policy").select("plan, policy").order("plan", { ascending: true }),
    pageAll<RouteRowAdmin>(
      (from, to) =>
        db.from("ai_routes")
          // ONE string literal: supabase-js parses the column list at the TYPE
          // level, and a concatenated string degrades the row type to
          // GenericStringError[].
          .select(
            "id, task, position, provider, model, unit, unit_cents, capabilities, max_latency_s, min_plan, same_model_as, privacy_tier, enabled, retire_after, note, updated_at",
          )
          .order("id", { ascending: true })
          .range(from, to),
      "AI routes",
    ),
    db.from("provider_health").select(
      "provider, model, consecutive_failures, open_until, p95_latency_ms, last_ok_at, last_fail_at, last_error_class",
    ),
    readLedgerSince(db, sinceIso),
  ]);

  if (policyRes.error) {
    throw new HttpError(500, `Routing policy read failed: ${policyRes.error.message}`);
  }
  if (healthRes.error) {
    throw new HttpError(500, `Provider health read failed: ${healthRes.error.message}`);
  }

  // 30-day spend, keyed on the EXACT (provider, model) a ledger row carries.
  // A zero here means "no ledger row with this exact pair in the window", not
  // "never used" — the legacy fal rows log `fal-ai/…` prefixed model ids while
  // the router rows carry the bare slug, and they are deliberately different
  // rows in ai_routes.
  const spend = new Map<string, Bucket>();
  for (const r of ledger.rows) {
    const cents = Number(r.total_cents ?? 0);
    bump(spend, stepKey(r.provider ?? "", r.model ?? ""), Number.isFinite(cents) ? cents : 0);
  }

  const health = new Map<string, HealthRowAdmin>();
  for (const h of (healthRes.data ?? []) as HealthRowAdmin[]) {
    health.set(stepKey(h.provider, h.model), h);
  }

  const nowMs = Date.now();
  const byTask = new Map<string, RouteRowAdmin[]>();
  for (const r of routes.rows) {
    const list = byTask.get(r.task) ?? [];
    list.push(r);
    byTask.set(r.task, list);
  }

  const routeGroups = [...byTask.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([task, rows]) => {
      rows.sort((a, b) => a.position - b.position);
      const legacyRow = rows.find((r) => r.note === "legacy") ?? null;
      const steps = rows.map((r) => {
        const h = health.get(stepKey(r.provider, r.model)) ?? null;
        const openUntil = h?.open_until ?? null;
        const openMs = openUntil ? Date.parse(openUntil) : NaN;
        const b = spend.get(stepKey(r.provider, r.model));
        return {
          route_id: r.id,
          position: r.position,
          provider: r.provider,
          model: r.model,
          unit: r.unit,
          unit_cents: round4(Number(r.unit_cents ?? 0)),
          capabilities: Array.isArray(r.capabilities) ? r.capabilities : [],
          max_latency_s: Number(r.max_latency_s ?? 0),
          min_plan: r.min_plan ?? "free",
          same_model_as: r.same_model_as ?? null,
          privacy_tier: r.privacy_tier ?? null,
          enabled: r.enabled === true,
          retire_after: r.retire_after ?? null,
          is_legacy: r.note === "legacy",
          note: r.note ?? null,
          updated_at: r.updated_at ?? null,
          health: {
            open: Number.isFinite(openMs) && openMs > nowMs,
            open_until: openUntil,
            consecutive_failures: Number(h?.consecutive_failures ?? 0),
            p95_latency_ms: h?.p95_latency_ms ?? null,
            last_ok_at: h?.last_ok_at ?? null,
            last_fail_at: h?.last_fail_at ?? null,
            last_error_class: h?.last_error_class ?? null,
          },
          spend_30d_cents: round4(b?.total ?? 0),
          spend_30d_rows: b?.rows ?? 0,
        };
      });
      return {
        task,
        step_count: steps.length,
        // What a chain actually resolves to with the flag ON: enabled, not
        // retired, and not the legacy row.
        live_step_count: steps.filter((s) =>
          s.enabled && !s.is_legacy && (s.retire_after === null || s.retire_after >= todayUtc())
        ).length,
        legacy: legacyRow
          ? { route_id: legacyRow.id, provider: legacyRow.provider, model: legacyRow.model }
          : null,
        steps,
      };
    });

  return json({
    generated_at: nowIso(),
    enabled: flag.enabled,
    flag: {
      enabled: flag.enabled,
      changed_at: flag.changed_at,
      // Never the raw id — see the privacy note above.
      changed_by_is_you: flag.changed_by !== null && flag.changed_by === caller.userId,
      changed_by_recorded: flag.changed_by !== null,
    },
    spend_window_days: ROUTING_SPEND_WINDOW_DAYS,
    spend_truncated: ledger.truncated,
    routes_truncated: routes.truncated,
    note:
      "While the brain is OFF, every feature uses the one provider it shipped with — nothing changes. " +
      "The 30-day spend next to each step counts only bills from that exact provider and model, " +
      "so $0 can simply mean it hasn't been billed under that name yet, not that it's unused.",
    policies: (policyRes.data ?? []).map((r) => ({
      plan: String((r as { plan?: unknown }).plan ?? ""),
      policy: String((r as { policy?: unknown }).policy ?? ""),
    })),
    routes: routeGroups,
  });
}

function todayUtc(): string {
  return new Date().toISOString().slice(0, 10);
}

// ── POST /admin/routing/flag · POST /admin/routing/step/{id} ─────────────────
//
// The only two writes in this function. Both are already past requireAdmin()
// (which runs before the method check and fails closed) and past the per-admin
// rate limiter, and both write WHO did WHAT into app_config so a flip is never
// anonymous.
//
// Neither can widen anything: `flag` writes one boolean into one app_config
// row, and `step` writes one boolean into one ai_routes row. There is no route
// here that creates a step, changes a price, or edits a model id — a new route
// is still a migration, which is what keeps the chain reviewable.

async function handleRoutingWrite(
  req: Request,
  caller: AdminCaller,
  seg: string[],
): Promise<Response> {
  const what = seg[1] ?? "";
  const db = adminClient();

  const body = await readJson<{ enabled?: unknown }>(req);
  if (typeof body.enabled !== "boolean") {
    throw new HttpError(400, "Body must be {\"enabled\": true|false}");
  }
  const enabled = body.enabled;
  const at = nowIso();

  if (what === "flag") {
    const value = { enabled, changed_by: caller.userId, changed_at: at };
    const { error } = await db
      .from("app_config")
      .upsert({ key: "ai_router", value, updated_at: at }, { onConflict: "key" });
    if (error) throw new HttpError(500, `Router flag write failed: ${error.message}`);
    // Deliberately loud: this is the switch that moves live traffic.
    console.log(`admin: ai_router flag set to ${enabled} by ${caller.userId}`);
    return json({
      ok: true,
      enabled,
      changed_at: at,
      note: enabled
        ? "The router is ON. Each task now resolves to its table-driven chain."
        : "The router is OFF. Every task resolves to its legacy step — behaviour is exactly what shipped.",
    });
  }

  if (what === "step") {
    const id = String(seg[2] ?? "").trim();
    if (!UUID_RE.test(id)) {
      throw new HttpError(400, "POST /admin/routing/step/{route_id} needs a uuid route id");
    }

    const { data: row, error: readErr } = await db
      .from("ai_routes")
      .select("id, task, position, provider, model, note, enabled")
      .eq("id", id)
      .maybeSingle();
    if (readErr) throw new HttpError(500, `Route read failed: ${readErr.message}`);
    if (!row) throw new HttpError(404, "No such route step");

    // The legacy row is what the flag-off path returns. Enabling it would put it
    // into a flag-ON chain as well and silently change routing; disabling it
    // would delete the flag-off answer for that task. It is not a switch.
    if (row.note === "legacy") {
      throw new HttpError(
        409,
        "That is the task's legacy step (the flag-off answer) and is not switchable. " +
          "Turn the router itself off with POST /admin/routing/flag instead.",
        "conflict",
      );
    }

    const { error: upErr } = await db
      .from("ai_routes")
      .update({ enabled, updated_at: at })
      .eq("id", id);
    if (upErr) throw new HttpError(500, `Route step write failed: ${upErr.message}`);

    // Who flipped what. app_config is admin-only, so this audit line is not
    // tenant-visible; it is deliberately a separate key from the master flag so
    // a step toggle can never overwrite the flag's own audit trail.
    const audit = {
      route_id: row.id,
      task: row.task,
      position: row.position,
      provider: row.provider,
      model: row.model,
      enabled,
      changed_by: caller.userId,
      changed_at: at,
    };
    const { error: auditErr } = await db
      .from("app_config")
      .upsert({ key: "ai_router_last_step_change", value: audit, updated_at: at }, {
        onConflict: "key",
      });
    if (auditErr) console.error("admin: routing step audit write failed:", auditErr.message);

    console.log(
      `admin: ai_routes ${row.task}#${row.position} (${row.provider}/${row.model}) ` +
        `enabled=${enabled} by ${caller.userId}`,
    );

    return json({
      ok: true,
      route_id: row.id,
      task: row.task,
      position: row.position,
      provider: row.provider,
      model: row.model,
      enabled,
      changed_at: at,
      audit_recorded: !auditErr,
    });
  }

  throw new HttpError(
    404,
    "Unknown routing write — POST /admin/routing/flag or /admin/routing/step/{route_id}",
  );
}

// ── GET /admin/subscriptions ─────────────────────────────────────────────────
//
// What the App Store is actually paying us — read from OUR tables. No Apple API
// call, no key, no network: `apple_subscriptions` is written only by
// apply_apple_entitlement() from a JWS this server verified (migration 0019),
// so this is a straight read of state that is already trusted.
//
// MRR is an ESTIMATE and the response says so. plan_entitlements.price_cents is
// the MONTHLY list price; an annual subscriber pays ten months' worth once a
// year, which is 10/12 of that per month. Treating an annual sub as a monthly
// one would overstate it by 20%, so the product id decides the divisor. Apple's
// 15-30% commission is NOT deducted — this is gross subscription revenue.
//
// Only `active` counts toward MRR. `grace` means Apple's charge FAILED and is
// being retried; the customer still has the plan, so it is reported next to the
// number rather than folded into it.
//
// Privacy: org-level aggregates only, exactly like every other route here. No
// org name, no member, no transaction id, no product-level customer detail.

/** An annual subscription is ten months' list price, spread over twelve. */
const ANNUAL_MRR_FACTOR = 10 / 12;
const EXPIRING_SOON_DAYS = 7;

interface SubscriptionRow {
  org_id: string | null;
  plan: string | null;
  product_id: string | null;
  status: string | null;
  environment: string | null;
  expires_at: string | null;
  auto_renew: boolean | null;
}

async function handleSubscriptions(): Promise<Response> {
  const db = adminClient();
  const now = new Date();

  const [subs, entRes, lastNoteRes, pendingRes] = await Promise.all([
    pageAll<SubscriptionRow>(
      (from, to) =>
        db.from("apple_subscriptions")
          .select("org_id, plan, product_id, status, environment, expires_at, auto_renew")
          .order("original_transaction_id", { ascending: true }).range(from, to),
      "Subscriptions",
    ),
    db.from("plan_entitlements").select("plan, price_cents"),
    db.from("apple_notifications")
      .select("notification_type, subtype, received_at")
      .order("received_at", { ascending: false }).limit(1),
    db.from("apple_notifications")
      .select("notification_uuid", { count: "exact", head: true }).eq("pending", true),
  ]);

  if (entRes.error) throw new HttpError(500, `Entitlement lookup failed: ${entRes.error.message}`);
  const priceOf = new Map<string, number>(
    ((entRes.data ?? []) as Array<{ plan: string; price_cents: number }>)
      .map((e) => [e.plan, Number(e.price_cents ?? 0)]),
  );

  const byPlan = new Map<string, { active: number; grace: number; mrr_cents: number }>();
  const byStatus = new Map<string, number>();
  const byEnvironment = new Map<string, number>();

  let activeTotal = 0;
  let graceTotal = 0;
  let mrrCents = 0;
  let notRenewing = 0;
  let expiringSoon = 0;
  let unlinked = 0;
  let sandboxActive = 0;

  const soonMs = now.getTime() + EXPIRING_SOON_DAYS * 86_400_000;

  for (const s of subs.rows) {
    const status = s.status ?? "unknown";
    byStatus.set(status, (byStatus.get(status) ?? 0) + 1);
    if (!s.org_id) unlinked++;
    if (status !== "active" && status !== "grace") continue;

    // A Sandbox subscription is App Review, TestFlight or one of our own
    // testers. It is real enough to grant a plan (that is the point of the
    // sandbox) but it is NOT money, and folding it into active_total and MRR
    // turns the one screen the owner reads for revenue into a count of how many
    // people are testing. Counted separately, next to the number.
    const env = s.environment ?? "unknown";
    const isSandbox = env === "Sandbox";

    const plan = s.plan ?? "unknown";
    const bucket = byPlan.get(plan) ?? { active: 0, grace: 0, mrr_cents: 0 };

    if (status === "active") {
      byEnvironment.set(env, (byEnvironment.get(env) ?? 0) + 1);
      if (isSandbox) {
        sandboxActive++;
        byPlan.set(plan, bucket);
        continue;
      }
      activeTotal++;
      bucket.active++;
      const monthly = priceOf.get(plan) ?? 0;
      const factor = (s.product_id ?? "").endsWith(".annual") ? ANNUAL_MRR_FACTOR : 1;
      const line = monthly * factor;
      bucket.mrr_cents += line;
      mrrCents += line;
    } else if (isSandbox) {
      sandboxActive++;
      byPlan.set(plan, bucket);
      continue;
    } else {
      graceTotal++;
      bucket.grace++;
    }
    byPlan.set(plan, bucket);

    if (s.auto_renew === false) notRenewing++;
    const expMs = s.expires_at ? Date.parse(s.expires_at) : NaN;
    if (Number.isFinite(expMs) && expMs <= soonMs) expiringSoon++;
  }

  const last = ((lastNoteRes.data ?? []) as Array<
    { notification_type: string | null; subtype: string | null; received_at: string }
  >)[0] ?? null;

  return json({
    generated_at: now.toISOString(),
    active_total: activeTotal,
    grace_total: graceTotal,
    mrr_cents: Math.round(mrrCents),
    mrr_note:
      "Gross estimate from plan_entitlements.price_cents. Annual plans count as " +
      "10/12 of the monthly list price. Active PRODUCTION subscriptions only — " +
      "Sandbox (App Review and TestFlight) is reported as sandbox_active and " +
      "counts toward nothing. Apple's commission is not deducted.",
    by_plan: [...byPlan.entries()]
      .map(([plan, b]) => ({
        plan,
        active: b.active,
        grace: b.grace,
        price_cents: priceOf.get(plan) ?? 0,
        mrr_cents: Math.round(b.mrr_cents),
      }))
      .sort((a, b) => b.mrr_cents - a.mrr_cents || a.plan.localeCompare(b.plan)),
    by_status: [...byStatus.entries()]
      .map(([status, count]) => ({ status, count }))
      .sort((a, b) => b.count - a.count || a.status.localeCompare(b.status)),
    environments: [...byEnvironment.entries()]
      .map(([environment, active]) => ({ environment, active }))
      .sort((a, b) => b.active - a.active || a.environment.localeCompare(b.environment)),
    // Active or in grace, but bought in the Sandbox: testers, not revenue.
    sandbox_active: sandboxActive,
    not_renewing: notRenewing,
    expiring_within_7d: expiringSoon,
    // A subscription Apple told us about that no signed-in device has claimed.
    unlinked_subscriptions: unlinked,
    // Notifications waiting for POST /me/entitlement to link a workspace.
    pending_notifications: pendingRes.count ?? 0,
    last_notification_at: last?.received_at ?? null,
    last_notification_type: last
      ? (last.subtype ? `${last.notification_type}/${last.subtype}` : last.notification_type)
      : null,
    truncated: subs.truncated,
  });
}
