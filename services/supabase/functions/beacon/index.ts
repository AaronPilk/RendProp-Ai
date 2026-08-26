// beacon — PUBLIC view metering from the tour player.
//
//   POST /beacon/:slug   { watch_ms, scroll_depth, streamed_minutes, view_start? }
//   POST /beacon         { slug, watch_ms, scroll_depth, streamed_minutes, view_start? }
//
// Upserts today's `metering` row for the render (unique per render_id + day).
// streamed_minutes is the billable delivery unit (see AI-COST-MODEL). Uses the
// service-role client; no public RLS policy exists on `metering` by design.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, clientIp, json, pathSegments, readJson, respondError } from "../_shared/http.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { adminClient } from "../_shared/supabase.ts";

interface BeaconBody {
  slug?: string;
  watch_ms?: number;
  scroll_depth?: number; // 0..1
  streamed_minutes?: number;
  view_start?: boolean; // true on the first beacon of a session → counts a view
}

const num = (v: unknown) => (Number.isFinite(Number(v)) ? Number(v) : 0);

// Per-call clamps (audit P1-2): beacon is public, so a single POST must never
// move the counters more than a real session plausibly could. The player
// batches ~20s intervals, so 5 min of watch and 60 streamed minutes per call
// are generous ceilings; anything above is a spam/inflation attempt.
const MAX_WATCH_MS_PER_CALL = 5 * 60 * 1000;
const MAX_STREAMED_MIN_PER_CALL = 60;
const clampN = (v: unknown, max: number) => Math.min(max, Math.max(0, num(v)));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    if (req.method !== "POST") throw new HttpError(405, "Only POST is supported");

    // Durable per-IP limit — beacons are frequent, so this is generous.
    if (!(await durableRateLimit(`beacon:${clientIp(req)}`, 120, 60))) {
      throw new HttpError(429, "Too many requests");
    }

    const body = await readJson<BeaconBody>(req);
    const seg = pathSegments(req, "beacon");
    const slug = seg[0] ?? body.slug;
    assert(slug, 400, "slug is required (path or body)");

    // The public demo tour has no DB render row — its metrics aren't recorded,
    // but the player still beacons. Acknowledge instead of 404ing every viewer
    // (2026-08-26 rig test found constant failing beacons on /f/estate-demo).
    if (slug === "estate-demo" || slug === "demo") return json({ ok: true, demo: true });

    const admin = adminClient();

    const { data: render, error: rErr } = await admin
      .from("renders")
      .select("id, listing_id")
      .eq("slug", slug)
      .not("published_at", "is", null)
      .maybeSingle();
    if (rErr) throw new HttpError(500, `Render lookup failed: ${rErr.message}`);
    if (!render) throw new HttpError(404, "Tour not found");

    const { data: listing } = await admin
      .from("listings")
      .select("org_id")
      .eq("id", render.listing_id)
      .maybeSingle();

    const day = new Date().toISOString().slice(0, 10); // YYYY-MM-DD (UTC)

    // Read-modify-write the daily counter. NOTE: not atomic under high
    // concurrency — acceptable for view metering. TODO: move to an RPC that
    // does an atomic UPSERT ... ON CONFLICT DO UPDATE with += increments.
    const { data: existing } = await admin
      .from("metering")
      .select("id, views, watch_ms, streamed_minutes, max_scroll_depth")
      .eq("render_id", render.id)
      .eq("day", day)
      .maybeSingle();

    const row: Record<string, unknown> = {
      render_id: render.id,
      org_id: listing?.org_id ?? null,
      day,
      views: num(existing?.views) + (body.view_start ? 1 : 0),
      watch_ms: num(existing?.watch_ms) + Math.round(clampN(body.watch_ms, MAX_WATCH_MS_PER_CALL)),
      streamed_minutes: Number(
        (num(existing?.streamed_minutes) + clampN(body.streamed_minutes, MAX_STREAMED_MIN_PER_CALL)).toFixed(2),
      ),
      max_scroll_depth: Math.min(
        1,
        Math.max(num(existing?.max_scroll_depth), Math.max(0, num(body.scroll_depth))),
      ),
    };
    if (existing?.id) row.id = existing.id;

    const { error: upErr } = await admin.from("metering").upsert(row, { onConflict: "render_id,day" });
    if (upErr) throw new HttpError(500, `Metering upsert failed: ${upErr.message}`);

    return json({ ok: true });
  } catch (err) {
    return respondError(err);
  }
});
