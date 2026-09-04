// tours — PUBLIC read of a published tour by slug (for the Cloudflare tour host).
//
//   GET /tours/:slug -> { listing (public subset), video_url, poster, chapters,
//                         agent_card, cta, staged, staged_disclosure, status, sold_at, ... }
//
// Uses the service-role client (RLS bypass) but ONLY ever returns a published,
// non-sensitive subset. Org internals (plan, ids, cost, emails-as-names) are
// never leaked.
//
// Fix wave 1 (2026-09-03):
//   • 404 when the listing is soft-deleted (the 0011 trigger also unpublishes,
//     but a tour must never outlive its listing — audit F-supabase-07).
//   • `status` + `sold_at` are returned so the player can show SOLD / Archived
//     (decision A17).
//   • The agent card name is brand_kit.name, else the listing agent's profile
//     name — NEVER the org name, which used to be the sign-in email (decision
//     A14, audit F-supabase-06 / F-E-10). Anything that looks like an email is
//     dropped rather than published.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, json, pathSegments, respondError } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { publicR2Url, streamHlsUrl } from "../_shared/r2.ts";
import { buildAgentCard } from "../_shared/agentcard.ts";
import { buildCta } from "./cta.ts";

const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");

const STAGED_DISCLOSURE =
  "Some imagery in this tour has been virtually staged or digitally decluttered. " +
  "Furniture and decor may be digitally added, removed, or restyled; the architecture, " +
  "layout, dimensions, and views are unchanged.";

function formatUSD(cents: number | null | undefined): string | null {
  if (cents == null) return null;
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0,
  }).format(Number(cents) / 100);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    if (req.method !== "GET") throw new HttpError(405, "Only GET is supported");
    const seg = pathSegments(req, "tours");
    const slug = seg[0];
    if (!slug) throw new HttpError(400, "slug is required: GET /tours/:slug");

    const admin = adminClient();

    // 1. Published render for this slug.
    const { data: render, error: rErr } = await admin
      .from("renders")
      .select("id, job_id, listing_id, slug, duration_s, speed_factor, video_key, stream_uid, poster_key, staged, published_at")
      .eq("slug", slug)
      .not("published_at", "is", null)
      .maybeSingle();
    if (rErr) throw new HttpError(500, `Render lookup failed: ${rErr.message}`);
    if (!render) throw new HttpError(404, "Tour not found or not published");

    // 2. Listing (public subset) + its org. A deleted listing has no public tour.
    const { data: listing, error: lErr } = await admin
      .from("listings")
      .select("id, org_id, agent_id, space_type, address, tagline, details, beds, baths, sqft, price_cents, zillow_url, lat, lng, status, sold_at, deleted_at")
      .eq("id", render.listing_id)
      .maybeSingle();
    if (lErr) throw new HttpError(500, `Listing lookup failed: ${lErr.message}`);
    if (!listing || listing.deleted_at) throw new HttpError(404, "Tour not found or not published");

    const [{ data: org }, { data: agentProfile }] = await Promise.all([
      admin.from("orgs").select("handle, space_type, brand_kit").eq("id", listing.org_id).maybeSingle(),
      listing.agent_id
        ? admin.from("profiles").select("name").eq("id", listing.agent_id).maybeSingle()
        : Promise.resolve({ data: null }),
    ]);

    // 3. Chapters (tap-to-jump dots) live on the capture asset behind the job.
    let chapters: Array<{ label: string; t_ms: number; sort: number }> = [];
    const { data: job } = await admin
      .from("render_jobs")
      .select("capture_asset_id")
      .eq("id", render.job_id)
      .maybeSingle();
    if (job?.capture_asset_id) {
      const { data: chapterRows } = await admin
        .from("capture_chapters")
        .select("label, t_ms, sort")
        .eq("asset_id", job.capture_asset_id)
        .order("sort", { ascending: true })
        .order("t_ms", { ascending: true });
      chapters = (chapterRows ?? []).map((c) => ({
        label: c.label as string,
        t_ms: c.t_ms as number,
        sort: c.sort as number,
      }));
    }

    // 4. Assemble the safe agent card from the org's brand kit (allow-listed
    //    fields; name never falls back to the org name — see _shared/agentcard.ts).
    const agent_card = buildAgentCard(org?.brand_kit, {
      profileName: agentProfile?.name,
      orgHandle: org?.handle ?? null,
    });

    // Scrub fidelity: the scroll-scrub player seeks frame-accurately, which only
    // works on the all-intra mp4 served over HTTP byte-range. Cloudflare Stream
    // (HLS) re-encodes away the all-intra GOP and snaps seeks to keyframes, so it
    // degrades scrubbing to keyframe-stepping. Therefore the R2 mp4 is the PRIMARY
    // scrub source; HLS is exposed separately as an adaptive fallback (long/4K).
    const scrub_url = publicR2Url(render.video_key as string);
    const hls_url = streamHlsUrl(render.stream_uid as string);
    const video_url = scrub_url ?? hls_url;

    const staged = Boolean(render.staged);
    const sold_at = (listing.sold_at as string | null) ?? null;
    const status = (listing.status as string) ?? "ready";

    return json({
      slug: render.slug,
      share_url: `${TOUR_BASE}/f/${render.slug}`,
      space_type: listing.space_type,
      status,
      sold_at,
      sold: sold_at !== null,
      archived: status === "archived",
      listing: {
        address: listing.address,
        tagline: listing.tagline,
        details: listing.details ?? {},
        beds: listing.beds,
        baths: listing.baths,
        sqft: listing.sqft,
        price_cents: listing.price_cents,
        price: formatUSD(listing.price_cents as number | null),
        lat: listing.lat,
        lng: listing.lng,
        status,
        sold_at,
      },
      video_url,
      scrub_url,   // all-intra mp4 (byte-range) — use this for frame-accurate scrubbing
      hls_url,     // Cloudflare Stream HLS — adaptive fallback for very long / 4K tours
      poster: publicR2Url(render.poster_key as string),
      duration_s: render.duration_s,
      speed_factor: render.speed_factor,
      published_at: render.published_at,
      chapters,
      agent_card,
      cta: buildCta(listing),
      staged,
      staged_disclosure: staged ? STAGED_DISCLOSURE : null,
      disclosure_chip: staged ? "✦ Virtually staged" : null,
    });
  } catch (err) {
    return respondError(err);
  }
});
