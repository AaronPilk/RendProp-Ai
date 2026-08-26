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
import { getUser, userClient } from "../_shared/supabase.ts";
import { publicR2Url } from "../_shared/r2.ts";

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

const DEFAULT_REEL_PROMPT =
  "slow cinematic camera push-in, subtle parallax, keep the scene exactly as photographed";

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
    await getUser(req); // auth required on every route (also guards the FAL key)
    const db = userClient(req); // RLS: the caller only sees their own org's assets
    const seg = pathSegments(req, "ai-video");

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

      const address = (body.address ?? "").trim();
      const prompt = cleanPrompt(body.prompt) ??
        ("Cinematic aerial drone establishing shot, slowly descending and gliding toward a " +
          "beautiful residential property" +
          (address ? `, a home like the one at ${address}` : "") +
          ". Golden-hour light, smooth stabilized gimbal motion, gentle parallax over rooftops " +
          "and trees, photorealistic, rich natural detail, no people, no text.");

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
        const mime = body.mime ?? "image/jpeg";
        imageUrl = `data:${mime};base64,${body.image_b64}`;
      }

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

      // FAILED / ERROR / anything unexpected.
      return json({ status: "failed", error: await failureError(st, responseUrl) });
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
