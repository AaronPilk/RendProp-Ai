// renders — create/track render jobs and publish tours (owner).
//
// Audit P0-3 hardening: creation and publishing run through SECURITY DEFINER
// RPCs (migrations 0006/0008/0011) that do the whole thing atomically:
//   create_render_job — membership + role + plan entitlement (monthly cap, via
//     effective_plan()) + max 3 WORKER jobs in flight + Idempotency-Key replay,
//     under a per-org advisory lock. `p_source:'app'` jobs are FREE (pricing:
//     "publishing is always free") and never counted or claimed by the worker.
//   publish_render    — server-derived video key (the job's verified
//     role=render upload) and server-verified poster (a renders-bucket photo
//     asset of the same listing), chapters + job/listing status flips in one
//     transaction, idempotent per job (unique renders.job_id).
//   fail_render_job   — publish-app marks its own job failed when publish_render
//     throws, so a failed publish never counts as "in flight" (F-supabase-05).
//   set_render_chapters — room tags edited after publish (PATCH …/chapters).
// Direct Data-API writes on render_jobs/renders are revoked in migration 0007.
//
//   POST  /renders                 { listing_id, asset_id, tier, enhancements }  (+ Idempotency-Key header)
//   GET   /renders/:job_id         -> { status, current_step, progress, cost_cents, error, tour? }
//   POST  /renders/:job_id/publish { duration_s?, speed_factor?, chapters?, poster_asset_id? } -> render
//   POST  /renders/publish-app     { listing_id, asset_id, duration_s?, speed_factor?, tier?, enhancements?,
//                                    chapters?, poster_asset_id? } -> { ...render, id, job_id, share_url, unbranded_url }
//   PATCH /renders/:render_id/chapters { chapters:[{label,t_ms,sort}] } -> { ok, count, chapters }

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, pathSegments, readJson, respondError, throwRpc } from "../_shared/http.ts";
import { assertNotDeleting, getUser, userClient } from "../_shared/supabase.ts";
import { publicR2Url, streamHlsUrl } from "../_shared/r2.ts";

const TIERS = ["smooth", "premium4k", "cinematic"];
const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");
// BRANDED link — agent card, CTA, lead form. The agent's own channels.
const shareUrl = (slug: string) => `${TOUR_BASE}/f/${slug}`;
// UNBRANDED link — the property and nothing else. This is the one that goes in
// an MLS virtual-tour field; unbranded rules ban agent branding, contact forms
// and external links, and it is the unbranded field that syndicates to the
// portals. Returned on every publish so the app never has to build it (W2-B2).
const unbrandedUrl = (slug: string) => `${TOUR_BASE}/u/${slug}`;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Bounded, sanitized chapters payload for the RPCs (which clamp again). `sort`
 * is a smallint in the DB — an unclamped value used to fail the whole publish
 * (audit F-supabase-35).
 */
function chapterRows(raw: unknown): Array<Record<string, unknown>> {
  if (!Array.isArray(raw)) return [];
  return (raw as Array<Record<string, unknown>>).slice(0, 60).map((c, i) => ({
    label: String(c?.label ?? c?.name ?? "").trim().slice(0, 80),
    t_ms: Math.min(86_400_000, Math.max(0, Math.round(Number(c?.t_ms ?? c?.tMs ?? 0)) || 0)),
    sort: Number.isFinite(Number(c?.sort)) ? Math.min(999, Math.max(0, Math.round(Number(c.sort)))) : i,
  })).filter((r) => (r.label as string).length > 0);
}

/** Optional uuid body field, or null. */
function optionalUuid(v: unknown, name: string): string | null {
  if (v === undefined || v === null || v === "") return null;
  assert(typeof v === "string" && UUID_RE.test(v), 400, `${name} must be a UUID`);
  return v as string;
}

function optionalNumber(v: unknown, name: string): number | null {
  if (v === undefined || v === null) return null;
  const n = Number(v);
  assert(Number.isFinite(n), 400, `${name} must be a number`);
  return n;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const user = await getUser(req); // require auth; the RPCs re-check membership + role themselves
    const db = userClient(req);
    const seg = pathSegments(req, "renders");
    const idem = req.headers.get("idempotency-key");

    // ---- POST /renders (worker path) ----
    if (req.method === "POST" && seg.length === 0) {
      const body = await readJson<Record<string, unknown>>(req);
      assert(body.listing_id, 400, "listing_id is required");
      assert(body.asset_id, 400, "asset_id is required");
      const tier = (body.tier as string) ?? "smooth";
      assert(TIERS.includes(tier), 400, `tier must be one of ${TIERS.join(", ")}`);
      await assertNotDeleting(user.id); // no new paid work once deletion starts

      const { data, error } = await db.rpc("create_render_job", {
        p_listing: body.listing_id,
        p_asset: body.asset_id,
        p_tier: tier,
        p_enhancements: (body.enhancements as Record<string, unknown>) ?? {},
        p_idem: idem ?? (body.idempotency_key as string | undefined) ?? null,
        p_source: "worker",
      });
      if (error) throwRpc(error.message);
      return json(data, 201);
    }

    // ---- POST /renders/:job_id/publish ----
    // video_key / stream_uid / staged-override from the body are deliberately
    // IGNORED — the RPC derives them from server state. The poster is accepted
    // only as an ASSET ID the RPC verifies (same listing, renders bucket, photo).
    if (req.method === "POST" && seg.length === 2 && seg[1] === "publish") {
      const jobId = seg[0];
      const body = await readJson<Record<string, unknown>>(req);

      const { data: render, error } = await db.rpc("publish_render", {
        p_job: jobId,
        p_duration: optionalNumber(body.duration_s, "duration_s"),
        p_speed: optionalNumber(body.speed_factor, "speed_factor") ?? 2.0,
        // `staged` is deliberately NOT forwarded: virtual-staging disclosure is
        // derived server-side from the job's enhancements (migration 0008).
        p_chapters: chapterRows(body.chapters),
        p_poster_asset: optionalUuid(body.poster_asset_id, "poster_asset_id"),
      });
      if (error) throwRpc(error.message);
      return json({
        ...render,
        share_url: shareUrl(render.slug as string),
        unbranded_url: unbrandedUrl(render.slug as string),
      }, 201);
    }

    // ---- POST /renders/publish-app ----
    // The app publishes its OWN on-device render (uploaded via /uploads
    // role=render). Two atomic, individually idempotent RPCs: create (replayed
    // by Idempotency-Key, source 'app' → free) then publish (replayed by unique
    // job_id). If publish throws, the job is marked failed right here so it
    // never lingers as `created` (which used to lock the workspace after three
    // failures — audit F-supabase-05).
    if (req.method === "POST" && seg.length === 1 && seg[0] === "publish-app") {
      const body = await readJson<Record<string, unknown>>(req);
      assert(body.listing_id, 400, "listing_id is required");
      assert(body.asset_id, 400, "asset_id is required");
      const tier = (body.tier as string) ?? "smooth";
      const posterAsset = optionalUuid(body.poster_asset_id, "poster_asset_id");
      const duration = optionalNumber(body.duration_s, "duration_s");
      const speed = optionalNumber(body.speed_factor, "speed_factor") ?? 2.0;
      await assertNotDeleting(user.id);

      const { data: job, error: jErr } = await db.rpc("create_render_job", {
        p_listing: body.listing_id,
        p_asset: body.asset_id,
        p_tier: TIERS.includes(tier) ? tier : "smooth",
        p_enhancements: (body.enhancements as Record<string, unknown>) ?? {},
        p_idem: idem ?? (body.idempotency_key as string | undefined) ?? null,
        p_source: "app",
      });
      if (jErr) throwRpc(jErr.message);

      const { data: render, error: pErr } = await db.rpc("publish_render", {
        p_job: job.id,
        p_duration: duration,
        p_speed: speed,
        // `staged` is deliberately NOT forwarded (see above).
        p_chapters: chapterRows(body.chapters),
        p_poster_asset: posterAsset,
      });
      if (pErr) {
        // Best effort: the RPC refuses to fail a job that already has a render
        // (a concurrent publish won), so this can never hide a live tour.
        const { error: fErr } = await db.rpc("fail_render_job", {
          p_job: job.id,
          p_error: String(pErr.message ?? "publish failed").slice(0, 500),
        });
        if (fErr) console.error("fail_render_job after publish failure:", fErr.message);
        throwRpc(pErr.message);
      }
      return json({
        ...render,
        id: render.id,
        job_id: job.id,
        share_url: shareUrl(render.slug as string),
        unbranded_url: unbrandedUrl(render.slug as string),
        poster: publicR2Url(render.poster_key as string | null),
      }, 201);
    }

    // ---- PATCH /renders/:render_id/chapters ----
    // Room tags edited after publish (audit F-A-10). Replaces the capture
    // chapters of the render's asset — the public tour reads them live.
    if (req.method === "PATCH" && seg.length === 2 && seg[1] === "chapters") {
      const renderId = seg[0];
      assert(UUID_RE.test(renderId), 400, "render id must be a UUID");
      const body = await readJson<Record<string, unknown>>(req);
      assert(Array.isArray(body.chapters), 400, "chapters must be an array of {label, t_ms, sort}");
      const rows = chapterRows(body.chapters);

      const { data: count, error } = await db.rpc("set_render_chapters", {
        p_render: renderId,
        p_chapters: rows,
      });
      if (error) throwRpc(error.message);

      // Read back what the tour will serve (RLS-scoped).
      const { data: render } = await db.from("renders").select("job_id").eq("id", renderId).maybeSingle();
      let chapters: Array<Record<string, unknown>> = [];
      if (render?.job_id) {
        const { data: job } = await db.from("render_jobs").select("capture_asset_id").eq("id", render.job_id).maybeSingle();
        if (job?.capture_asset_id) {
          const { data: rowsBack } = await db
            .from("capture_chapters")
            .select("label, t_ms, sort")
            .eq("asset_id", job.capture_asset_id)
            .order("sort", { ascending: true })
            .order("t_ms", { ascending: true });
          chapters = (rowsBack ?? []) as Array<Record<string, unknown>>;
        }
      }
      return json({ ok: true, count: Number(count ?? rows.length), chapters });
    }

    // ---- GET /renders/:job_id ----
    if (req.method === "GET" && seg.length === 1) {
      const jobId = seg[0];
      const { data: job, error } = await db
        .from("render_jobs")
        .select("id, listing_id, status, current_step, progress, cost_cents, error, source, tier")
        .eq("id", jobId)
        .maybeSingle();
      if (error) throw new HttpError(400, `Status lookup failed: ${error.message}`);
      if (!job) throw new HttpError(404, "Render job not found");

      const { data: render } = await db
        .from("renders")
        .select("id, slug, duration_s, video_key, stream_uid, poster_key, staged, published_at")
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
          render_id: render.id,
          slug: render.slug,
          share_url: shareUrl(render.slug as string),
          unbranded_url: unbrandedUrl(render.slug as string),
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
        id: job.id,
        listing_id: job.listing_id,
        status: job.status,
        source: job.source,
        tier: job.tier,
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
