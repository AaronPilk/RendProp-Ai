// renders — create/track render jobs and publish tours (owner).
//
//   POST /renders                 { listing_id, asset_id, tier, enhancements } -> render_job
//   GET  /renders/:id             -> { status, current_step, progress, cost_cents, tour? }
//   POST /renders/:id/publish     { duration_s?, video_key?, stream_uid?, poster_key?, speed_factor?, staged? }
//                                   -> render (with a unique url-safe slug)
//
// The render worker (Modal/CF Container) normally drives status + calls publish
// when a job reaches `ready`; exposing it here lets the app/worker do it over HTTP.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, nanoid, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { getUser, userClient } from "../_shared/supabase.ts";
import { publicR2Url, streamHlsUrl } from "../_shared/r2.ts";

const TIERS = ["smooth", "premium4k", "cinematic"];
const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.app").replace(/\/+$/, "");
const shareUrl = (slug: string) => `${TOUR_BASE}/f/${slug}`;

/** A render is "virtually staged" if any enhancement altered furniture/decor. */
function isStaged(enh: Record<string, unknown> | null | undefined): boolean {
  if (!enh) return false;
  if (enh.declutter === true) return true;
  const style = String(enh.style ?? "").trim().toLowerCase();
  return style !== "" && !["as_is", "as-is", "asis", "none"].includes(style);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    await getUser(req); // require auth; RLS enforces org ownership
    const db = userClient(req);
    const seg = pathSegments(req, "renders");

    // ---- POST /renders ----
    if (req.method === "POST" && seg.length === 0) {
      const body = await readJson<Record<string, unknown>>(req);
      const listingId = body.listing_id as string;
      const assetId = body.asset_id as string;
      const tier = (body.tier as string) ?? "smooth";
      const enhancements = (body.enhancements as Record<string, unknown>) ?? {};
      assert(listingId, 400, "listing_id is required");
      assert(assetId, 400, "asset_id is required");
      assert(TIERS.includes(tier), 400, `tier must be one of ${TIERS.join(", ")}`);

      // Verify the asset belongs to the listing (and both are visible via RLS).
      const { data: asset, error: aErr } = await db
        .from("capture_assets")
        .select("id, listing_id")
        .eq("id", assetId)
        .eq("listing_id", listingId)
        .maybeSingle();
      if (aErr) throw new HttpError(400, `Asset lookup failed: ${aErr.message}`);
      if (!asset) throw new HttpError(404, "Asset not found for this listing");

      const { data, error } = await db
        .from("render_jobs")
        .insert({
          listing_id: listingId,
          capture_asset_id: assetId,
          tier,
          enhancements,
          status: "created",
          progress: 0,
        })
        .select()
        .single();
      if (error) throw new HttpError(400, `Render create failed: ${error.message}`);
      return json(data, 201);
    }

    // ---- POST /renders/:id/publish ----
    if (req.method === "POST" && seg.length === 2 && seg[1] === "publish") {
      const jobId = seg[0];
      const body = await readJson<Record<string, unknown>>(req);

      const { data: job, error: jErr } = await db
        .from("render_jobs")
        .select("id, listing_id, capture_asset_id, enhancements")
        .eq("id", jobId)
        .maybeSingle();
      if (jErr) throw new HttpError(400, `Job lookup failed: ${jErr.message}`);
      if (!job) throw new HttpError(404, "Render job not found");

      // duration_s is NOT NULL on renders — take body, else the capture asset's.
      let durationS = body.duration_s as number | undefined;
      if (durationS == null && job.capture_asset_id) {
        const { data: asset } = await db
          .from("capture_assets")
          .select("duration_s")
          .eq("id", job.capture_asset_id)
          .maybeSingle();
        if (asset?.duration_s != null) durationS = Number(asset.duration_s);
      }
      assert(durationS != null, 400, "duration_s is required (not found on the capture asset)");

      const staged = typeof body.staged === "boolean" ? body.staged : isStaged(job.enhancements);
      const base = {
        job_id: job.id,
        listing_id: job.listing_id,
        duration_s: durationS,
        speed_factor: (body.speed_factor as number) ?? 2.0,
        video_key: (body.video_key as string) ?? null,
        stream_uid: (body.stream_uid as string) ?? null,
        poster_key: (body.poster_key as string) ?? null,
        staged,
        published_at: new Date().toISOString(),
      };

      // Insert with a fresh slug; retry on the (rare) unique collision.
      let render: Record<string, unknown> | null = null;
      for (let attempt = 0; attempt < 5; attempt++) {
        const slug = nanoid(10);
        const { data, error } = await db
          .from("renders")
          .insert({ ...base, slug })
          .select()
          .single();
        if (!error) {
          render = data;
          break;
        }
        // 23505 = unique_violation -> new slug and retry; anything else is fatal.
        if (error.code !== "23505") throw new HttpError(400, `Publish failed: ${error.message}`);
      }
      if (!render) throw new HttpError(500, "Could not allocate a unique slug");

      // Best-effort: flip the job + listing to ready (don't fail publish if these do).
      await db.from("render_jobs")
        .update({ status: "ready", progress: 1, finished_at: new Date().toISOString() })
        .eq("id", job.id);
      await db.from("listings").update({ status: "ready" }).eq("id", job.listing_id);

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

      const tour = render
        ? {
            slug: render.slug,
            share_url: shareUrl(render.slug as string),
            video_url: streamHlsUrl(render.stream_uid as string) ??
              publicR2Url(render.video_key as string),
            poster: publicR2Url(render.poster_key as string),
            staged: render.staged,
            duration_s: render.duration_s,
            published_at: render.published_at,
          }
        : null;

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
