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
//   POST /ai-video/declutter  { asset_id, prompt? }
//       Bria video eraser (prompt-based object removal). Source must be < 5 s.
//   POST /ai-video/aerial     { prompt?, address?, seconds?=8, aspect?: "16:9"|"9:16" }
//       Veo 3.1 Fast text-to-video establishing shot. SYNTHETIC footage —
//       response carries { synthetic: true } so the app can disclose.
//   POST /ai-video/reel-clip  { asset_id? | image_b64? (+mime?), prompt?, seconds?=5 }
//       Seedance i2v: animate a listing photo into a motion clip.
//   GET  /ai-video/status?status_url=...&response_url=...
//       → { status: "processing", queue_position?, logs_tail? }
//       → { status: "completed", video_url }
//       → { status: "failed", error }
//
// Every submit response: { request_id, status_url, response_url, kind, model_id, ... }.
//
// Model ids verified against fal (2026-08-25):
//   fal-ai/topaz/upscale/video                       (proven in services/pipeline)
//   bria/video/erase/prompt                          https://fal.ai/models/bria/video/erase/prompt/api
//   fal-ai/veo3.1/fast                               https://fal.ai/models/fal-ai/veo3.1/fast
//   fal-ai/bytedance/seedance/v1/pro/fast/image-to-video  (proven in services/pipeline)
//
// Needs the FAL_KEY function secret + the shared R2 env (R2_PUBLIC_BASE_URL).

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { adminClient, getUser, orgForUser, preferredOrg, userClient } from "../_shared/supabase.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { publicR2Url } from "../_shared/r2.ts";

// Denial-of-wallet guards (audit P1-3): every generate route hits a paid GPU
// queue, so cap submissions per burst window AND per rolling month per org,
// and soft-dedupe retried submits via the Idempotency-Key header.
const GEN_MAX_PER_WINDOW = 12;
const GEN_WINDOW_SECONDS = 300; // 12 video jobs / 5 min / org
const MONTH_SECONDS = 30 * 86400;

// Plan-scaled monthly ceilings, proportional to the published render tiers
// (2/5/15). AI video clips — aerials, reels, declutter, drone upscales — are
// separate from tour renders and cost real GPU time, so they get their own
// bounded allowance rather than the old flat 400. Free early access = Solo.
const GEN_MONTHLY_BY_PLAN: Record<string, number> = {
  free: 10,
  solo: 10,
  pro: 30,
  team: 90,
};

// Bound inline base64 so a caller can't push unbounded memory pressure through
// readJson (audit round 4). ~12 MB of base64 ≈ 9 MB binary.
const MAX_IMAGE_B64_CHARS = 12_000_000;

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
async function guardGenerate(userId: string, req: Request): Promise<void> {
  const orgId = await orgForUser(userId, preferredOrg(req));
  const admin = adminClient();

  const { data: mem, error: mErr } = await admin
    .from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle();
  if (mErr) throw new HttpError(500, `Role lookup failed: ${mErr.message}`);
  if (!mem?.role || mem.role === "marketing") {
    throw new HttpError(403, "Your role does not permit AI video generation");
  }

  const { data: org } = await admin.from("orgs").select("plan").eq("id", orgId).maybeSingle();
  const monthlyCap = GEN_MONTHLY_BY_PLAN[String(org?.plan ?? "free")] ?? GEN_MONTHLY_BY_PLAN.free;
  // Idempotency soft-dedupe: when the client sends an Idempotency-Key, a
  // duplicate submit inside 2 minutes is rejected instead of double-billed.
  const idem = req.headers.get("idempotency-key")?.trim();
  if (idem && idem.length <= 128) {
    if (!(await durableRateLimit(`aividem:${orgId}:${idem}`, 1, 120))) {
      throw new HttpError(409, "Duplicate submission — this job was already started.");
    }
  }
  if (!(await durableRateLimit(`aivideo:${orgId}`, GEN_MAX_PER_WINDOW, GEN_WINDOW_SECONDS))) {
    throw new HttpError(429, "AI video generation limit reached for now — try again in a few minutes.");
  }
  if (!(await durableRateLimit(`aivideomo:${orgId}`, monthlyCap, MONTH_SECONDS))) {
    throw new HttpError(429, "This workspace has reached its monthly AI video limit for its plan — contact support to raise it.");
  }
}

const FAL_QUEUE_BASE = "https://queue.fal.run";
const FAL_KEY = Deno.env.get("FAL_KEY");

const MODEL_DRONE = "fal-ai/topaz/upscale/video";
const MODEL_DECLUTTER = "bria/video/erase/prompt";
const MODEL_AERIAL = "fal-ai/veo3.1/fast";
const MODEL_REEL = "fal-ai/bytedance/seedance/v1/pro/fast/image-to-video";

const DRONE_TIERS = ["1080p60", "4k30", "4k60"];

// Bria hard limit: "duration must be less than 5s" (input schema). We disable
// auto_trim (never silently cut the user's clip) and pre-flight the duration.
const BRIA_MAX_SECONDS = 5;

const DEFAULT_DECLUTTER_PROMPT =
  "remove clutter, shoes, bags, boxes, cords, laundry, dishes, and personal items " +
  "from the floor and surfaces; keep the room, furniture, and architecture unchanged";

// Anti-hallucination scaffolding: i2v models love to "help" by inventing decor,
// people, or a different room. Pin the clip to the exact photographed scene and
// allow only grounded camera motion.
const DEFAULT_REEL_PROMPT =
  "Photorealistic live continuation of this exact photographed scene. The architecture, " +
  "furniture, decor, materials, lighting, and exposure stay identical to the source photo. " +
  "Camera: one slow, subtle, grounded push-in with gentle natural parallax — no cuts, no " +
  "transitions, and no panning that reveals unseen areas. Do not add, remove, or move any " +
  "objects; no people, no animals, no text or watermarks; no scene changes, style shifts, " +
  "warping, or flicker.";

interface DroneBody {
  asset_id?: string;
  tier?: string;
  target_fps?: number;
}
interface DeclutterBody {
  asset_id?: string;
  prompt?: string;
}
interface AerialBody {
  prompt?: string;
  address?: string;
  /** Optional look-and-feel hint ("modern glass house with a pool, golden
   *  hour") woven into the guarded default prompt. ≤ 200 chars. */
  style?: string;
  seconds?: number;
  aspect?: string;
}
interface ReelBody {
  asset_id?: string;
  image_b64?: string;
  mime?: string;
  prompt?: string;
  seconds?: number;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const user = await getUser(req); // auth required on every route (also guards the FAL key)
    const db = userClient(req); // RLS: the caller only sees their own org's assets
    const seg = pathSegments(req, "ai-video");

    // NOTE: quota is NOT charged here any more. Each generate route validates
    // its body (and resolves its asset) FIRST, then calls guardGenerate()
    // immediately before the billable fal submit — see audit round 4.

    // ---- POST /ai-video/drone ----
    if (req.method === "POST" && seg.length === 1 && seg[0] === "drone") {
      const body = await readJson<DroneBody>(req);
      assert(body.asset_id, 400, "asset_id is required");
      const tier = body.tier ?? "4k30";
      assert(DRONE_TIERS.includes(tier), 400, `tier must be one of ${DRONE_TIERS.join(", ")}`);
      let fps = Math.round(Number(body.target_fps ?? 60));
      if (!Number.isFinite(fps)) throw new HttpError(400, "target_fps must be a number");
      fps = Math.min(120, Math.max(24, fps));

      const asset = await resolvePublicAsset(db, body.asset_id);
      await guardGenerate(user.id, req); // validated — charge, then submit
      const sub = await falSubmit(MODEL_DRONE, {
        video_url: asset.url,
        model: "Proteus", // natural detail; interpolation gives the glide
        upscale_factor: tier === "1080p60" ? 1 : 2,
        target_fps: fps,
        H264_output: true,
      });
      return json({ ...sub, kind: "drone", model_id: MODEL_DRONE, tier, target_fps: fps }, 202);
    }

    // ---- POST /ai-video/declutter ----
    if (req.method === "POST" && seg.length === 1 && seg[0] === "declutter") {
      const body = await readJson<DeclutterBody>(req);
      assert(body.asset_id, 400, "asset_id is required");

      const asset = await resolvePublicAsset(db, body.asset_id);
      if (asset.duration_s != null && asset.duration_s >= BRIA_MAX_SECONDS) {
        throw new HttpError(
          400,
          `Bria's video eraser only accepts clips under ${BRIA_MAX_SECONDS}s and auto-trim is ` +
            `disabled so your full clip is processed — this asset is ${asset.duration_s}s. ` +
            `Trim the clip to under ${BRIA_MAX_SECONDS}s and try again.`,
        );
      }

      await guardGenerate(user.id, req); // validated — charge, then submit
      const sub = await falSubmit(MODEL_DECLUTTER, {
        video_url: asset.url,
        prompt: cleanPrompt(body.prompt) ?? DEFAULT_DECLUTTER_PROMPT,
        auto_trim: false, // never silently cut the video — process the full clip
        preserve_audio: true,
        output_container_and_codec: "mp4_h264",
      });
      return json({ ...sub, kind: "declutter", model_id: MODEL_DECLUTTER }, 202);
    }

    // ---- POST /ai-video/aerial ----
    if (req.method === "POST" && seg.length === 1 && seg[0] === "aerial") {
      const body = await readJson<AerialBody>(req);
      const aspect = body.aspect ?? "16:9";
      assert(aspect === "16:9" || aspect === "9:16", 400, `aspect must be "16:9" or "9:16"`);
      // Veo 3.1 Fast durations are the enum 4s|6s|8s — snap up to the nearest.
      const wanted = Number(body.seconds ?? 8);
      const duration = wanted <= 4 ? "4s" : wanted <= 6 ? "6s" : "8s";

      // NOTE (2026-08-26 fix): the street address is deliberately NOT put in the
      // prompt anymore. Veo's safety filter can reject prompts that name real
      // residential addresses (reads as location/PII), which failed jobs within
      // seconds — and the address added nothing visually since the model has
      // never seen the property. `address` is still accepted for back-compat
      // but ignored. An optional `style` hint personalizes the look instead.
      const style = (body.style ?? "").trim().slice(0, 200)
        .replace(/[\r\n]+/g, " ");
      // Anti-hallucination scaffolding: t2v aerials drift into morphing houses
      // and toy-town scale — pin one consistent property with stable geometry.
      const prompt = cleanPrompt(body.prompt) ??
        ("Cinematic aerial drone establishing shot, slowly descending and gliding toward a " +
          (style ? `beautiful residential property — ${style} — ` : "beautiful residential property") +
          ". One single consistent property for the entire shot — the same house, roofline, " +
          "lot, and street throughout, with stable, coherent geometry and no morphing or " +
          "warping structures. Realistic suburban scale and proportions. Golden-hour light, " +
          "smooth stabilized gimbal motion, gentle parallax over rooftops and trees, " +
          "photorealistic, rich natural detail. No people, no text, no watermarks, no logos.");

      await guardGenerate(user.id, req); // validated — charge, then submit
      const sub = await falSubmit(MODEL_AERIAL, {
        prompt,
        duration,
        resolution: "1080p",
        aspect_ratio: aspect,
        generate_audio: false, // silent b-roll; the app scores it (and it's ~33% cheaper)
      });
      return json(
        {
          ...sub,
          kind: "aerial",
          synthetic: true, // AI-generated footage — the app must disclose this
          model_id: MODEL_AERIAL,
          seconds: Number(duration.replace("s", "")),
          aspect,
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
      if (body.asset_id) {
        const asset = await resolvePublicAsset(db, body.asset_id);
        imageUrl = asset.url;
      } else {
        assert(body.image_b64, 400, "asset_id or image_b64 is required");
        assert(typeof body.image_b64 === "string", 400, "image_b64 must be a string");
        assert(body.image_b64.length <= MAX_IMAGE_B64_CHARS, 413,
               "image is too large — resize it before sending");
        const mime = body.mime ?? "image/jpeg";
        imageUrl = `data:${mime};base64,${body.image_b64}`;
      }

      await guardGenerate(user.id, req); // validated — charge, then submit
      const sub = await falSubmit(MODEL_REEL, {
        prompt: cleanPrompt(body.prompt) ?? DEFAULT_REEL_PROMPT,
        image_url: imageUrl,
        resolution: "1080p",
        duration: String(secs), // Seedance takes duration as a string
      });
      return json({ ...sub, kind: "reel", model_id: MODEL_REEL, seconds: secs }, 202);
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
        throw new HttpError(502, `fal status ${stRes.status}: ${JSON.stringify(st).slice(0, 300)}`);
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
          throw new HttpError(502, `fal result ${rRes.status}: ${JSON.stringify(result).slice(0, 300)}`);
        }
        const videoUrl = extractVideoUrl(result);
        if (!videoUrl) {
          throw new HttpError(502, `fal result had no video url: ${JSON.stringify(result).slice(0, 300)}`);
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
  if (!FAL_KEY) throw new HttpError(500, "FAL_KEY function secret is not set");
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
    throw new HttpError(502, `fal submit failed (${modelId}, HTTP ${res.status}): ${JSON.stringify(data).slice(0, 400)}`);
  }
  const { request_id, status_url, response_url } = data as Record<string, unknown>;
  if (!request_id || !status_url || !response_url) {
    throw new HttpError(502, `Unexpected fal submit response (${modelId}): ${JSON.stringify(data).slice(0, 400)}`);
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

/**
 * Load a capture_assets row (RLS applies via the user client) and require a
 * fal-fetchable PUBLIC URL: uploaded + bucket "renders" + configured public base.
 */
// deno-lint-ignore no-explicit-any
async function resolvePublicAsset(
  db: any,
  assetId: string,
): Promise<{ id: string; kind: string; url: string; duration_s: number | null }> {
  const { data, error } = await db
    .from("capture_assets")
    .select("id, listing_id, kind, bucket, storage_key, uploaded, duration_s")
    .eq("id", assetId)
    .maybeSingle();
  if (error) throw new HttpError(400, `Asset lookup failed: ${error.message}`);
  if (!data) throw new HttpError(404, "Asset not found");
  assert(data.uploaded === true, 409, "Asset upload is not complete");

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
      400,
      "R2_PUBLIC_BASE_URL is not configured on the server, so no public URL can be built " +
        "for this asset. Set the R2_PUBLIC_BASE_URL function secret to the renders bucket's public base.",
    );
  }
  return {
    id: data.id as string,
    kind: data.kind as string,
    url,
    duration_s: data.duration_s == null ? null : Number(data.duration_s),
  };
}

/** Trimmed non-empty prompt, or undefined. */
function cleanPrompt(p: string | undefined): string | undefined {
  const t = (p ?? "").trim();
  return t.length > 0 ? t : undefined;
}
