// tours — PUBLIC read of a published tour by slug (for the Cloudflare tour host).
//
//   GET /tours/:slug -> { listing (public subset), video_url, poster, chapters,
//                         agent_card, cta, staged, staged_disclosure, status, sold_at,
//                         share_url, unbranded_url, floorplan_url, altered_media[], ... }
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
//   • `estate-demo` / `demo` resolve to the hardcoded sample tour (see below),
//     matching the special case leads/ and beacon/ already carry.
//
// Compliance wave 2 (2026-09-04, W2-B2):
//   • `unbranded_url` — the MLS-safe /u/<slug> twin of `share_url`. Unbranded
//     virtual-tour rules ban agent branding, contact forms and external links,
//     and the unbranded field is what syndicates to Zillow/Realtor.com, so both
//     links are returned and the app never has to build one.
//   • `altered_media[]` — every AI-altered/AI-generated asset for this render's
//     listing, newest first, capped at 40. PUBLIC BY DESIGN: disclosure is the
//     legal obligation (CA AB 723 from 1 Jan 2026; NorthstarMLS from 10 Jul
//     2026 also wants an unaltered "Before" per altered room, which is what
//     `original_url` is). The payload is DELIBERATELY NARROW — label, kind,
//     disclosure, plain-words model family, and the two media URLs. The
//     internal columns (`prompt_summary`, `model_id`) are NEVER exposed here;
//     they belong to the org's own audit export (GET /me/compliance).
//   • `floorplan_url` — promoted out of `listing.details` so the tour host can
//     render the floor plan above the gallery (buyers rate floor plans 57%
//     "very useful" vs virtual tours 38%, NAR 2025).

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, json, pathSegments, respondError } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { publicR2Url, streamHlsUrl } from "../_shared/r2.ts";
import { buildAgentCard } from "../_shared/agentcard.ts";
import { buildCta } from "./cta.ts";

const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");

/** Branded link — agent card, CTA, lead form. The agent's own channels. */
const brandedUrl = (slug: string) => `${TOUR_BASE}/f/${slug}`;
/** Unbranded link — the property and nothing else. Safe for the MLS field. */
const unbrandedUrl = (slug: string) => `${TOUR_BASE}/u/${slug}`;

// How many disclosure lines a single tour will ever print. A listing is capped
// at 500 provenance rows by the RPC; the page shows the most recent 40.
const MAX_ALTERED_MEDIA = 40;

/** The model family in plain words — the public page never names a vendor model. */
function modelFamily(kind: string): string {
  return kind === "aerial" || kind === "reel" ? "AI video" : "AI image edit";
}

interface AlteredMedium {
  label: string | null;
  kind: string;
  disclosure: string;
  model: string;
  original_url: string | null;
  altered_url: string | null;
  created_at: string | null;
}

/**
 * The disclosure list for a listing. Public read is fine — it IS the
 * disclosure — but only the public subset leaves this function.
 */
// deno-lint-ignore no-explicit-any
async function alteredMediaFor(admin: any, listingId: string): Promise<AlteredMedium[]> {
  const { data, error } = await admin
    .from("media_provenance")
    .select("kind, label, disclosure, original_key, altered_key, created_at")
    .eq("listing_id", listingId)
    .order("created_at", { ascending: false })
    .limit(MAX_ALTERED_MEDIA);
  // A disclosure lookup must never take the tour down: log and serve the tour
  // without the block rather than 500 the whole page.
  if (error) {
    console.error("altered_media lookup failed:", error.message);
    return [];
  }
  return (data ?? []).map((r: Record<string, unknown>) => ({
    label: (r.label as string | null) ?? null,
    kind: r.kind as string,
    disclosure: r.disclosure as string,
    model: modelFamily(r.kind as string),
    original_url: publicR2Url(r.original_key as string | null),
    altered_url: publicR2Url(r.altered_key as string | null),
    created_at: (r.created_at as string | null) ?? null,
  }));
}

/**
 * The floor-plan image, wherever the listing keeps it. `details` is free-form
 * JSON written by the app, so accept the shapes the tour host already reads:
 * details.floorplan_url | details.floor_plan_url | details.floorplan.image_url |
 * details.floorplan.image (and the floor_plan spelling of either).
 */
function floorplanUrl(details: unknown): string | null {
  const d = (details ?? {}) as Record<string, unknown>;
  const direct = d.floorplan_url ?? d.floor_plan_url;
  if (typeof direct === "string" && /^https?:\/\//i.test(direct)) return direct;
  const fp = (d.floorplan ?? d.floor_plan) as Record<string, unknown> | undefined;
  if (fp && typeof fp === "object") {
    const nested = fp.image_url ?? fp.image ?? fp.url;
    if (typeof nested === "string" && /^https?:\/\//i.test(nested)) return nested;
  }
  return null;
}

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

// ── The public demo tour ──────────────────────────────────────────────────────
//
// rendprop.com/f/estate-demo has NO render row in the database: the tour host
// renders it from its own hardcoded Tour (services/edge/tour-host/src/demo.ts),
// which stays the canonical source for the full microsite content. But the iOS
// app and the marketing site both link to this slug, and resolving it here used
// to 404 — so this endpoint answers with the same tour shape instead.
//
// Read-only and side-effect free by construction: it returns before the service
// client is ever created, so there is no DB read, no metering, and no beacon.
// leads/ and beacon/ special-case the same two slugs.
//
// Media is served by the tour host's own /assets (absolute here, since callers
// of this API are not same-origin with the Worker).
const DEMO_SLUGS = new Set(["estate-demo", "demo"]);

function demoTour(): Record<string, unknown> {
  const asset = (p: string) => `${TOUR_BASE}${p}`;
  return {
    slug: "estate-demo",
    share_url: brandedUrl("estate-demo"),
    unbranded_url: unbrandedUrl("estate-demo"),
    space_type: "real_estate",
    demo: true, // callers can tell this is the sample, not a real listing
    status: "ready",
    sold_at: null,
    sold: false,
    archived: false,
    listing: {
      address: "1180 Crestline Ridge",
      tagline: "A glass-and-oak modern estate that opens to the canyon.",
      details: {
        year_built: "2023",
        acres: "0.7",
        garage: "4-car",
        frontage: "180'",
        story:
          "Set on a private ridge above the canyon, 1180 Crestline was designed around a single idea: erase the wall between the house and the view. Floor-to-ceiling glass slides fully away, so the great room, the pool deck, and the horizon become one continuous space.",
        gallery: [
          { url: asset("/assets/demo-g1.webp"), label: "Twilight arrival" },
          { url: asset("/assets/demo-g2.webp"), label: "Chef's kitchen" },
          { url: asset("/assets/demo-g3.webp"), label: "Great room" },
          { url: asset("/assets/demo-g4.webp"), label: "Primary bath" },
          { url: asset("/assets/demo-g5.webp"), label: "Sunken lounge" },
          { url: asset("/assets/demo-g6.webp"), label: "The estate" },
        ],
      },
      beds: 5,
      baths: 6,
      sqft: 6200,
      price_cents: 425000000,
      price: formatUSD(425000000),
      lat: null,
      lng: null,
      status: "ready",
      sold_at: null,
    },
    video_url: asset("/assets/demo-tour.mp4"),
    scrub_url: asset("/assets/demo-tour.mp4"),
    hls_url: null,
    poster: asset("/assets/demo-poster.webp"),
    duration_s: 137,
    speed_factor: 1,
    published_at: null,
    chapters: [
      { label: "Arrival", t_ms: 0, sort: 0 },
      { label: "Chef's kitchen", t_ms: 14000, sort: 1 },
      { label: "Primary suite", t_ms: 55000, sort: 2 },
      { label: "Spa bath", t_ms: 66000, sort: 3 },
      { label: "Great room", t_ms: 82000, sort: 4 },
      { label: "The grounds", t_ms: 105000, sort: 5 },
    ],
    agent_card: {
      name: "Alexandra Reyes",
      handle: "meridian",
      brokerage: "Meridian Estates",
      phone: "(305) 555-0142",
      website: "https://pilk.ai/",
      avatar_url: asset("/assets/agent-headshot.webp"),
      instagram: "pilk.ai",
      accent: "#7c3aed",
    },
    cta: {
      label: "Book a showing",
      mode: "lead_form",
      url: null,
      secondary: [],
      lead_fields: ["preferred_date"],
    },
    staged: true,
    staged_disclosure: STAGED_DISCLOSURE,
    disclosure_chip: "✦ Virtually staged",
    floorplan_url: null, // the demo ships floor-plan LEVELS in details, no image
    // The sample tour demonstrates the disclosure block end to end: a
    // before/after pair (NorthstarMLS), a plain photo edit, and the aerial with
    // HousingWire's exact simulated-movement wording. Sentences match
    // public.provenance_disclosure() in migration 0012 verbatim.
    altered_media: [
      {
        label: "Great room — virtually staged",
        kind: "virtual_stage",
        disclosure:
          "This photo was virtually staged with AI: furniture and decor were digitally added or restyled. The architecture, dimensions, and views are unchanged.",
        model: "AI image edit",
        original_url: asset("/assets/example-staging-before.webp"),
        altered_url: asset("/assets/example-staging-after.webp"),
        created_at: null,
      },
      {
        label: "Twilight arrival — sky and lighting",
        kind: "photo_edit",
        disclosure:
          "This photo was digitally altered with AI: the sky and lighting were changed to simulate dusk. The property itself is unchanged.",
        model: "AI image edit",
        original_url: asset("/assets/example-twilight-before.webp"),
        altered_url: asset("/assets/example-twilight-after.webp"),
        created_at: null,
      },
      {
        label: "Aerial intro — AI generated",
        kind: "aerial",
        disclosure:
          "Drone-style movement is simulated. No drone footage was captured. This establishing shot was generated by AI.",
        model: "AI video",
        original_url: null,
        altered_url: null,
        created_at: null,
      },
    ],
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    if (req.method !== "GET") throw new HttpError(405, "Only GET is supported");
    const seg = pathSegments(req, "tours");
    const slug = seg[0];
    if (!slug) throw new HttpError(400, "slug is required: GET /tours/:slug");

    // The hardcoded sample tour — answered before any DB access (see above).
    if (DEMO_SLUGS.has(slug)) return json(demoTour());

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

    // 3a. Every AI-altered asset for this listing — the public disclosure list.
    const altered_media = await alteredMediaFor(admin, listing.id as string);

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
      share_url: brandedUrl(render.slug as string),
      // MLS-safe twin. Never put the branded link in an MLS unbranded field.
      unbranded_url: unbrandedUrl(render.slug as string),
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
      // Floor plan, promoted out of details so the host can render it above the
      // gallery on BOTH pages (it is property information, not branding).
      floorplan_url: floorplanUrl(listing.details),
      staged,
      staged_disclosure: staged ? STAGED_DISCLOSURE : null,
      // The staged chip is unchanged; a tour with AI media but no staging now
      // gets an honest chip of its own instead of nothing. altered_media below
      // is the full per-asset disclosure list the tour host renders.
      disclosure_chip: staged
        ? "✦ Virtually staged"
        : altered_media.length > 0
        ? "✦ AI-altered media"
        : null,
      altered_media,
    });
  } catch (err) {
    return respondError(err);
  }
});
