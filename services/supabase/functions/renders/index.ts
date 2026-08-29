// renders — create/track render jobs and publish tours (owner).
//
// Audit P0-3 hardening (this version): creation and publishing run through
// SECURITY DEFINER RPCs (migration 0006) that do the whole thing atomically:
//   create_render_job — membership + plan entitlement (monthly cap) + max 3
//     jobs in flight + Idempotency-Key replay, under a per-org advisory lock.
//   publish_render    — server-derived video key (the job's verified
//     role=render upload; callers can no longer supply video_key/stream_uid/
//     poster_key), chapters + job/listing status flips in one transaction,
//     idempotent per job (unique renders.job_id).
// Direct Data-API writes on render_jobs/renders are revoked in migration 0007.
//
//   POST /renders                 { listing_id, asset_id, tier, enhancements }  (+ Idempotency-Key header)
//   GET  /renders/:id             -> { status, current_step, progress, cost_cents, tour? }
//   POST /renders/:id/publish     { duration_s?, speed_factor?, staged?, chapters? } -> render
//   POST /renders/publish-app     { listing_id, asset_id, duration_s?, chapters?, … } -> render

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { getUser, userClient } from "../_shared/supabase.ts";
import { publicR2Url, streamHlsUrl } from "../_shared/r2.ts";

const TIERS = ["smooth", "premium4k", "cinematic"];
const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");
const shareUrl = (slug: string) => `${TOUR_BASE}/f/${slug}`;

/** Map RPnnn-prefixed RPC exceptions to proper HTTP statuses. */
function throwRpc(message: string | undefined): never {
  const msg = message ?? "request failed";
  const m = /RP(\d{3}):\s*(.*)/.exec(msg);
  if (m) throw new HttpError(Number(m[1]), m[2] || msg);
  throw new HttpError(400, msg);
}

/** Bounded, sanitized chapters payload for the publish RPC. */
function chapterRows(raw: unknown): Array<Record<string, unknown>> {
  if (!Array.isArray(raw)) return [];
  return (raw as Array<Record<string, unknown>>).slice(0, 60).map((c, i) => ({
    label: String(c.label ?? c.name ?? "").slice(0, 80),
    t_ms: Math.max(0, Math.round(Number(c.t_ms ?? c.tMs ?? 0))),
    sort: Number.isFinite(Number(c.sort)) ? Number(c.sort) : i,
  })).filter((r) => (r.label as string).length > 0);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    await getUser(req); // require auth; the RPCs re-check membership themselves
    const db = userClient(req);
    const seg = pathSegments(req, "renders");
    const idem = req.headers.get("idempotency-key");

    // ---- POST /renders ----
    if (req.method === "POST" && seg.length === 0) {
      const body = await readJson<Record<string, unknown>>(req);
      assert(body.listing_id, 400, "listing_id is required");
      assert(body.asset_id, 400, "asset_id is required");
      const tier = (body.tier as string) ?? "smooth";
      assert(TIERS.includes(tier), 400, `tier must be one of ${TIERS.join(", ")}`);

      const { data, error } = await db.rpc("create_render_job", {
        p_listing: body.listing_id,
        p_asset: body.asset_id,
        p_tier: tier,
        p_enhancements: (body.enhancements as Record<string, unknown>) ?? {},
        p_idem: idem ?? (body.idempotency_key as string | undefined) ?? null,
      });
      if (error) throwRpc(error.message);
      return json(data, 201);
    }

    // ---- POST /renders/:id/publish ----
    // video_key / stream_uid / poster_key / staged-override from the body are
    // deliberately IGNORED — the RPC derives them from server state.
    if (req.method === "POST" && seg.length === 2 && seg[1] === "publish") {
      const jobId = seg[0];
      const body = await readJson<Record<string, unknown>>(req);

      const { data: render, error } = await db.rpc("publish_render", {
        p_job: jobId,
        p_duration: (body.duration_s as number) ?? null,
        p_speed: (body.speed_factor as number) ?? 2.0,
        p_staged: typeof body.staged === "boolean" ? body.staged : null,
        p_chapters: chapterRows(body.chapters),
      });
      if (error) throwRpc(error.message);
      return json({ ...render, share_url: shareUrl(render.slug as string) }, 201);
    }

    // ---- POST /renders/publish-app ----
    // The app publishes its OWN on-device render (uploaded via /uploads
    // role=render). Two atomic, individually idempotent RPCs: create (replayed
    // by Idempotency-Key) then publish (replayed by unique job_id).
    if (req.method === "POST" && seg.length === 1 && seg[0] === "publish-app") {
      const body = await readJson<Record<string, unknown>>(req);
      assert(body.listing_id, 400, "listing_id is required");
      assert(body.asset_id, 400, "asset_id is required");
      const tier = (body.tier as string) ?? "smooth";

      const { data: job, error: jErr } = await db.rpc("create_render_job", {
        p_listing: body.listing_id,
        p_asset: body.asset_id,
        p_tier: TIERS.includes(tier) ? tier : "smooth",
        p_enhancements: (body.enhancements as Record<string, unknown>) ?? {},
        p_idem: idem ?? (body.idempotency_key as string | undefined) ?? null,
      });
      if (jErr) throwRpc(jErr.message);

      const { data: render, error: pErr } = await db.rpc("publish_render", {
        p_job: job.id,
        p_duration: (body.duration_s as number) ?? null,
        p_speed: (body.speed_factor as number) ?? 2.0,
        p_staged: typeof body.staged === "boolean" ? body.staged : null,
        p_chapters: chapterRows(body.chapters),
      });
      if (pErr) throwRpc(pErr.message);
      return json({ ...render, share_url: shareUrl(render.slug as string) }, 201);
    }

    // ---- GET /renders/:id ----
    if (req.method === "GET" && seg.length === 1) {
      const jobId = seg[0];
      const { data: job, error } = await db
        .from("render_jobs")
        .select("id, status, current_step, progress, cost_cents, error")
        .eq("id", jobId)
        .maybeSingle();
      if (error) throw new HttpError(400, `Status lookup failed: ${error.message}`);
      if (!job) throw new HttpError(404, "Render job not found");

      const { data: render } = await db
        .from("renders")
        .select("slug, duration_s, video_key, stream_uid, poster_key, staged, published_at")
        .eq("job_id", jobId)
        .not("published_at", "is", null)
        .maybeSingle();

      // Prefer the all-intra R2 mp4 (byte-range, frame-accurate scrub); HLS is
      // the adaptive fallback only. See tours/index.ts for the full rationale.
      let tour: Record<string, unknown> | null = null;
      if (render) {
        const scrubUrl = publicR2Url(render.video_key as string);
        const hlsUrl = streamHlsUrl(render.stream_uid as string);
        tour = {
          slug: render.slug,
          share_url: shareUrl(render.slug as string),
          video_url: scrubUrl ?? hlsUrl,
          scrub_url: scrubUrl,
          hls_url: hlsUrl,
          poster: publicR2Url(render.poster_key as string),
          staged: render.staged,
          duration_s: render.duration_s,
          published_at: render.published_at,
        };
      }

      return json({
        status: job.status,
        current_step: job.current_step,
        progress: job.progress,
        cost_cents: job.cost_cents,
        error: job.error ?? null,
        tour,
      });
    }

    throw new HttpError(405, `Method ${req.method} not allowed on this path`);
  } catch (err) {
    return respondError(err);
  }
});
