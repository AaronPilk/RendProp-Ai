// beacon — PUBLIC view metering from the tour player.
//
//   POST /beacon/:slug   { watch_ms, scroll_depth, streamed_minutes, view_start? }
//   POST /beacon         { slug, watch_ms, scroll_depth, streamed_minutes, view_start? }
//
// Counts land in today's `metering` row via the bump_metering() RPC (migration
// 0006): an atomic UPSERT with += increments and server-side clamps, replacing
// the old read-modify-write (audit: lost updates under concurrency, and these
// public numbers must never feed billing — they are engagement telemetry).
// Uses the service-role client; no public RLS policy exists on `metering`.

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
// are generous ceilings; anything above is a spam/inflation attempt. The RPC
// clamps again server-side.
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
    // but the player still beacons. Acknowledge instead of 404ing every viewer.
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

    const { error: mErr } = await admin.rpc("bump_metering", {
      p_render: render.id,
      p_org: listing?.org_id ?? null,
      p_views: body.view_start ? 1 : 0,
      p_watch_ms: Math.round(clampN(body.watch_ms, MAX_WATCH_MS_PER_CALL)),
      p_streamed: Number(clampN(body.streamed_minutes, MAX_STREAMED_MIN_PER_CALL).toFixed(2)),
      p_scroll: Math.min(1, Math.max(0, num(body.scroll_depth))),
    });
    if (mErr) throw new HttpError(500, `Metering update failed: ${mErr.message}`);

    return json({ ok: true });
  } catch (err) {
    return respondError(err);
  }
});
