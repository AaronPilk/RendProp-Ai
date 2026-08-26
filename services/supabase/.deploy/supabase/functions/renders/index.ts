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
const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");
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

    // ---- POST /renders/publish-app ----
    // The app publishes its OWN on-device render (already uploaded to the renders
    // bucket via /uploads role=render). No Python worker needed: create a ready
    // job + a published render row pointing at the uploaded mp4, store chapters
    // (room tags → tap-to-jump dots), and mint the public slug.
    if (req.method === "POST" && seg.length === 1 && seg[0] === "publish-app") {
      const body = await readJson<Record<string, unknown>>(req);
      const listingId = body.listing_id as string;
      const assetId = body.asset_id as string;
      assert(listingId, 400, "listing_id is required");
      assert(assetId, 400, "asset_id is required");

      // The uploaded render mp4 must belong to this listing and be completed.
      const { data: asset, error: aErr } = await db
        .from("capture_assets")
        .select("id, listing_id, storage_key, bucket, uploaded, duration_s")
        .eq("id", assetId)
        .eq("listing_id", listingId)
        .maybeSingle();
      if (aErr) throw new HttpError(400, `Asset lookup failed: ${aErr.message}`);
      if (!asset) throw new HttpError(404, "Render asset not found for this listing");
      assert(asset.bucket === "renders", 400, "asset_id must be a role=render upload");
      assert(asset.uploaded === true, 409, "Render asset upload is not complete");

      let durationS = body.duration_s as number | undefined;
      if (durationS == null && asset.duration_s != null) durationS = Number(asset.duration_s);
      assert(durationS != null, 400, "duration_s is required");

      const enhancements = (body.enhancements as Record<string, unknown>) ?? {};
      const tier = (body.tier as string) ?? "smooth";
      const staged = typeof body.staged === "boolean" ? body.staged : isStaged(enhancements);

      // A ready job keeps the schema invariant (renders.job_id NOT NULL) and links
      // chapters (render_jobs.capture_asset_id → capture_chapters.asset_id). status
      // 'ready' is NOT in the worker's claim set, so the worker never touches it.
      const { data: job, error: jErr } = await db
        .from("render_jobs")
        .insert({
          listing_id: listingId,
          capture_asset_id: assetId,
          tier: TIERS.includes(tier) ? tier : "smooth",
          enhancements,
          status: "ready",
          progress: 1,
          finished_at: new Date().toISOString(),
        })
        .select("id")
        .single();
      if (jErr) throw new HttpError(400, `Job create failed: ${jErr.message}`);

      // Chapters (room/area tags) → tap-to-jump dots on the public tour.
      const rawChapters = Array.isArray(body.chapters)
        ? body.chapters as Array<Record<string, unknown>>
        : [];
      if (rawChapters.length > 0) {
        const rows = rawChapters
          .map((c, i) => ({
            asset_id: assetId,
            label: String(c.label ?? c.name ?? "").slice(0, 80),
            t_ms: Math.max(0, Math.round(Number(c.t_ms ?? c.tMs ?? 0))),
            sort: Number.isFinite(Number(c.sort)) ? Number(c.sort) : i,
          }))
          .filter((r) => r.label.length > 0);
        if (rows.length > 0) await db.from("capture_chapters").insert(rows);
      }

      const base = {
        job_id: job.id,
        listing_id: listingId,
        duration_s: durationS,
        speed_factor: (body.speed_factor as number) ?? 2.0,
        video_key: asset.storage_key as string,
        poster_key: (body.poster_key as string) ?? null,
        staged,
        published_at: new Date().toISOString(),
      };

      let render: Record<string, unknown> | null = null;
      for (let attempt = 0; attempt < 5; attempt++) {
        const slug = nanoid(10);
        const { data, error } = await db.from("renders").insert({ ...base, slug }).select().single();
        if (!error) { render = data; break; }
        if (error.code !== "23505") throw new HttpError(400, `Publish failed: ${error.message}`);
      }
      if (!render) throw new HttpError(500, "Could not allocate a unique slug");

      await db.from("listings").update({ status: "ready" }).eq("id", listingId);
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

      // Prefer the all-intra R2 mp4 (byte-range, frame-accurate scrub); HLS is the
      // adaptive fallback only. See tours/index.ts for the full rationale.
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
