// beacon — PUBLIC view metering from the tour player.
//
//   POST /beacon/:slug   { watch_ms, scroll_depth, streamed_minutes, view_start? }
//   POST /beacon         { slug, watch_ms, scroll_depth, streamed_minutes, view_start? }
//
// Upserts today's `metering` row for the render (unique per render_id + day).
// streamed_minutes is the billable delivery unit (see AI-COST-MODEL). Uses the
// service-role client; no public RLS policy exists on `metering` by design.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, clientIp, json, pathSegments, rateLimit, readJson, respondError } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

interface BeaconBody {
  slug?: string;
  watch_ms?: number;
  scroll_depth?: number; // 0..1
  streamed_minutes?: number;
  view_start?: boolean; // true on the first beacon of a session → counts a view
}

const num = (v: unknown) => (Number.isFinite(Number(v)) ? Number(v) : 0);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    if (req.method !== "POST") throw new HttpError(405, "Only POST is supported");

    // Best-effort rate limit — beacons are frequent, so this is generous.
    // TODO: durable limiter + Turnstile before launch (see leads).
    if (!rateLimit(`beacon:${clientIp(req)}`, 120, 60_000)) {
      throw new HttpError(429, "Too many requests");
    }

    const body = await readJson<BeaconBody>(req);
    const seg = pathSegments(req, "beacon");
    const slug = seg[0] ?? body.slug;
    assert(slug, 400, "slug is required (path or body)");

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
      watch_ms: num(existing?.watch_ms) + Math.max(0, Math.round(num(body.watch_ms))),
      streamed_minutes: Number(
        (num(existing?.streamed_minutes) + Math.max(0, num(body.streamed_minutes))).toFixed(2),
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
