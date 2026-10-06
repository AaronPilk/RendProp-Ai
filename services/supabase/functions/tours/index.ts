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
import { assertMediaVisible, mediaVisibility, type MediaSourceRefs } from "../_shared/media-source-access.ts";
import { bucketForKey } from "../studio/handler.ts";
import { propertyGalleryKey, publicMainPhoto } from "../_shared/property-cover.ts";
import { publicProvenanceDisclosure } from "../_shared/provenance.ts";
import { publicR2Url, publishedR2Url, publishedStreamUrl, PUBLIC_MEDIA_PROXY } from "../_shared/r2.ts";
import { assertHostingAvailable } from "../_shared/hosting-retention.ts";
import { admittedFloorplan, admittedBusinessLogo, deliveryEnvelope, businessLogoDelivery, publishedListingDetails } from "./delivery.ts";
import { buildPersonalListingCard } from "../_shared/agentcard.ts";
import { resolveContactPhoto } from "../listings/client-contact.ts";
import { buildCta } from "./cta.ts";
import { bindSpatialChapters, type SpatialChapter } from "../spatial/chapters.ts";

const TOUR_BASE = (Deno.env.get("TOUR_PUBLIC_BASE_URL") ?? "https://rendprop.com").replace(/\/+$/, "");

// deno-lint-ignore no-explicit-any
async function listingAgentIdentity(admin: any, listing: string): Promise<Record<string,unknown>> {
  const {data,error}=await admin.rpc("public_listing_agent_identity",{p_listing:listing});
  if (error || !data || typeof data!=="object" || Array.isArray(data) ||
      typeof data.legacy_owned_single_member!=="boolean" ||
      !(data.personal_card===null || (typeof data.personal_card==="object" && !Array.isArray(data.personal_card))) ||
      !(data.profile_name===null || typeof data.profile_name==="string")) {
    if (error?.message?.startsWith("RP404:")) throw new HttpError(404,"Tour not found or not published");
    throw new HttpError(503,"The listing agent could not be verified. Please refresh.");
  }
  return data;
}

/** Branded link — agent card, CTA, lead form. The agent's own channels. */
const brandedUrl = (slug: string) => `${TOUR_BASE}/f/${slug}`;
/** Unbranded link — the property and nothing else. Safe for the MLS field. */
const unbrandedUrl = (slug: string) => `${TOUR_BASE}/u/${slug}`;

// How many disclosure lines a single tour will ever print. A listing is capped
// at 500 provenance rows by the RPC; the page shows the most recent 40.
const MAX_ALTERED_MEDIA = 40;

/** Measurement drafts sync with the owner's listing, independently of public
 * plan export. Keep their versioned metadata out of every public tour payload;
 * public property facts and owner-selected floor-plan media remain unchanged. */
function publicListingDetails(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>).filter(([key]) =>
      !key.toLowerCase().replaceAll("_", "").startsWith("floormeasurements")
    ),
  );
}

/** The model family in plain words — the public page never names a vendor model. */
function modelFamily(kind: string): string {
  return kind === "aerial" || kind === "reel" || kind === "video_reflection_removal"
    ? "AI video"
    : kind === "other" ? "Edited media" : "AI image edit";
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
async function alteredMediaFor(admin: any, orgId: string, listingId: string, refs: { keys: string[]; assets: string[] }, selectedKeys: ReadonlySet<string> | null, slug: string): Promise<AlteredMedium[]> {
  const { data, error } = await admin
    .from("media_provenance")
    .select("kind, edit, label, disclosure, original_key, altered_key, created_at")
    .eq("listing_id", listingId)
    .order("created_at", { ascending: false })
    // The private log is capped at 500. Filter before the public 40-item cap
    // so recent retired edits cannot crowd out a currently selected version.
    .limit(selectedKeys===null?MAX_ALTERED_MEDIA:500);
  // A disclosure lookup must never take the tour down: log and serve the tour
  // without the block rather than 500 the whole page.
  if (error) {
    console.error("altered_media lookup failed:", error.message);
    return [];
  }
  const current=(data??[]).filter((r:Record<string,unknown>)=>selectedKeys===null ||
    ["aerial","reel","video_reflection_removal"].includes(String(r.kind)) ||
    (typeof r.altered_key==="string" && selectedKeys.has(r.altered_key))).slice(0,MAX_ALTERED_MEDIA);
  const scopedKeys = current.flatMap((r: Record<string, unknown>) => [r.original_key, r.altered_key]).filter((key: unknown): key is string => bucketForKey(key, { orgId, listingId }) !== null);
  const visible = await mediaVisibility(admin, listingId, { keys: scopedKeys });
  return current.filter((r: Record<string, unknown>) => [r.original_key, r.altered_key].every(key => !key || (typeof key === "string" && visible.keys[key] === true))).map((r: Record<string, unknown>) => {
    for (const key of [r.original_key, r.altered_key]) if (typeof key === "string") refs.keys.push(key);
    return ({
    label: (r.label as string | null) ?? null,
    kind: r.kind as string,
    disclosure: publicProvenanceDisclosure(r.kind as string,(r.edit as string|null)??null,r.disclosure as string),
    model: modelFamily(r.kind as string),
    original_url: publishedR2Url(slug,r.original_key as string | null),
    altered_url: publishedR2Url(slug,r.altered_key as string | null),
    created_at: (r.created_at as string | null) ?? null,
  }); });
}

/** How many gallery photos a tour page will carry. A listing with more than
 * this many is not a gallery, it is a contact sheet. */
const MAX_GALLERY = 40;

/**
 * The listing's own photos, for the gallery on the tour page.
 *
 * Selected off the key prefix `/uploads` mints for `role:"gallery"`, because
 * `capture_assets` has no role column and the poster / original / gallery
 * distinction is server-derived from the key everywhere else too. `uploaded`
 * is the completion flag: a ticket writes its row BEFORE the bytes land, so
 * without it a cancelled upload would publish a 404 into the gallery.
 *
 * PROPERTY INFORMATION, NOT BRANDING — so this rides to the unbranded `/u/`
 * twin as well, on exactly the reasoning `floorplan_url` already carries. A
 * photo of the kitchen says nothing about which brokerage listed it.
 *
 * Never fatal: a gallery lookup must not take the tour down.
 */
// deno-lint-ignore no-explicit-any
async function galleryFor(admin: any, orgId: string, listingId: string, refs: { keys: string[]; assets: string[] }, selection: string[] | null, slug: string): Promise<Array<{ url: string }>> {
  if(selection?.length===0)return [];
  let query = admin
    .from("capture_assets")
    .select("id, storage_key, created_at")
    .eq("listing_id", listingId)
    .eq("kind", "photo")
    .eq("bucket", "renders")
    .eq("uploaded", true)
    .like("storage_key", "%/gallery-%");
  if(selection!==null)query=query.in("id",selection);
  const { data, error } = await query.order("created_at", { ascending: true }).order("id",{ascending:true}).limit(MAX_GALLERY);
  if (error) {
    console.error("gallery lookup failed:", error.message);
    return [];
  }
  const eligible = (data ?? []).filter((r: Record<string, unknown>) => propertyGalleryKey(r.storage_key, { orgId, listingId }) &&
    (selection===null || selection.includes(r.id as string)));
  if(selection!==null)eligible.sort((a: {id:string},b: {id:string})=>selection.indexOf(a.id)-selection.indexOf(b.id));
  const visible = await mediaVisibility(admin, listingId, { assets: eligible.map((r: { id: string }) => r.id), keys: eligible.map((r: { storage_key: string }) => r.storage_key) });
  const out: Array<{ url: string }> = [];
  for (const r of eligible) {
    if (visible.assets[r.id] !== true || visible.keys[r.storage_key] !== true) continue;
    const url = publishedR2Url(slug,(r as Record<string, unknown>).storage_key as string | null);
    if (url) { out.push({ url }); refs.assets.push(r.id); refs.keys.push(r.storage_key); }
  }
  return out;
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
  "Furniture and decor may be digitally added, removed, or restyled with AI. " +
  "Compare with the original to check fixed features, layout and access.";

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
          publicProvenanceDisclosure("virtual_stage",null,""),
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
    if(seg[0]==="business-logo"&&seg.length===2&&/^[a-f0-9-]{36}$/.test(seg[1]))return json(await businessLogoDelivery(adminClient(),seg[1],new URL(req.url).searchParams.get("key")),200,{"Cache-Control":"no-store"});
    if (seg.length > 2 || seg.length === 2 && seg[1] !== "delivery") throw new HttpError(404,"Tour not found");
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
      .select("id, org_id, agent_id, space_type, address, tagline, details, beds, baths, sqft, price_cents, zillow_url, main_photo_key, gallery_asset_ids, lat, lng, status, sold_at, deleted_at")
      .eq("id", render.listing_id)
      .maybeSingle();
    if (lErr) throw new HttpError(500, `Listing lookup failed: ${lErr.message}`);
    if (!listing || listing.deleted_at) throw new HttpError(404, "Tour not found or not published");
    await assertHostingAvailable(admin, listing.org_id);

    const visibleRefs: MediaSourceRefs & { keys: string[]; assets: string[] } = { renders: [render.id], assets: [], keys: [] };
    await assertMediaVisible(admin, listing.id, visibleRefs);

    // 3a. Every AI-altered asset for this listing — the public disclosure list.
    const selectedPhotos=listing.gallery_asset_ids??null;
    const gallery = await galleryFor(admin, listing.org_id, listing.id as string, visibleRefs,selectedPhotos,slug);
    const cover_url = await publicMainPhoto(admin,{orgId:listing.org_id,listingId:listing.id},
      listing.main_photo_key,key=>publishedR2Url(slug,key),visibleRefs,selectedPhotos);
    const altered_media = await alteredMediaFor(admin, listing.org_id, listing.id as string, visibleRefs,
      selectedPhotos===null?null:new Set(visibleRefs.keys),slug);

    // 3. Chapters (tap-to-jump dots) live on the capture asset behind the job.
    let chapters: SpatialChapter[] = [];
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

    // A scan added after a video was published lights up its existing chapter.
    // This is a private-table read with an explicit approved subset; it never
    // returns original keys, pending reviews, or ambiguous room-label guesses.
    if (chapters.length) {
      const { data: scenes, error: spatialError } = await admin.from("spatial_jobs")
        .select("id,status,approved,excluded,published_at,artifact_revision,review_revision,output_state,redactions,scene_manifest")
        .eq("listing_id", listing.id).eq("org_id", listing.org_id).eq("status", "ready")
        .eq("approved", true).eq("excluded", false).not("published_at", "is", null).limit(100);
      // Before 0040 is rolled out, the existing flythrough must remain usable.
      // Any read error suppresses only optional 3D anchors, never opens access.
      if (!spatialError && scenes) chapters = bindSpatialChapters(chapters, scenes);
    }

    // 4. Explicit client delivery stays first. Otherwise resolve only the
    // listing's current member's reviewed personal identity under DB locks.
    const { data: clientRow, error: clientError }=await admin.from("listing_client_contacts")
      .select("listing_id,org_id,enabled,public_card,hide_rendprop_branding,photo_asset_id,revision").eq("listing_id",listing.id).eq("org_id",listing.org_id).maybeSingle();
    if(clientError)throw new HttpError(503,"The listing contact could not be verified. Please retry.");
    const clientMode=clientRow?.enabled===true;
    const client=clientMode?await resolveContactPhoto(admin,clientRow,visibleRefs,key=>publishedR2Url(slug,key)):null;
    const identity = clientMode ? null : await listingAgentIdentity(admin,listing.id);
    const portrait=identity?.legacy_portrait as {asset_id?:unknown;storage_key?:unknown;url?:unknown}|null;
    const portraitURL=portrait && typeof portrait.asset_id==="string" && typeof portrait.storage_key==="string" && typeof portrait.url==="string" &&
      portrait.url===publicR2Url(portrait.storage_key) ? publishedR2Url(slug,portrait.storage_key) ?? undefined : undefined;
    if (portraitURL) {visibleRefs.assets.push(portrait!.asset_id as string);visibleRefs.keys.push(portrait!.storage_key as string);}
    const agent_card = clientMode ? {...(client?.public_card??{}),handle:null} : buildPersonalListingCard(identity!,portraitURL);

    // Scrub fidelity: the scroll-scrub player seeks frame-accurately, which only
    // works on the all-intra mp4 served over HTTP byte-range. Cloudflare Stream
    // (HLS) re-encodes away the all-intra GOP and snaps seeks to keyframes, so it
    // degrades scrubbing to keyframe-stepping. Therefore the R2 mp4 is the PRIMARY
    // scrub source; HLS is exposed separately as an adaptive fallback (long/4K).
    const scrub_url = publishedR2Url(slug,render.video_key as string);
    const hls_url = publishedStreamUrl(slug,render.stream_uid as string);
    const video_url = scrub_url ?? hls_url;

    const planURL = PUBLIC_MEDIA_PROXY ? await admittedFloorplan(admin,{orgId:listing.org_id,listingId:listing.id},floorplanUrl(listing.details),slug,visibleRefs) : floorplanUrl(listing.details);
    const logo = PUBLIC_MEDIA_PROXY ? await admittedBusinessLogo(admin,listing.org_id,agent_card.business_logo_url,slug) : null;
    if (PUBLIC_MEDIA_PROXY) {
      delete agent_card.business_logo_url;
      if (logo) agent_card.business_logo_url=logo.url;
    }
    for(const key of [render.video_key,render.poster_key])if(typeof key==="string")visibleRefs.keys.push(key);
    const staged = Boolean(render.staged);
    const sold_at = (listing.sold_at as string | null) ?? null;
    const status = (listing.status as string) ?? "ready";

    // These service-role reads bypass RLS; recheck every exposed lineage after
    // assembling the response, so revocation during optional reads cannot leak.
    await assertMediaVisible(admin, listing.id, visibleRefs);
    const {data:currentPhotos,error:currentPhotosError}=await admin.from("listings")
      .select("main_photo_key,gallery_asset_ids,deleted_at").eq("id",listing.id).maybeSingle();
    if(currentPhotosError || !currentPhotos || currentPhotos.deleted_at ||
       (currentPhotos.main_photo_key??null)!==(listing.main_photo_key??null) ||
       JSON.stringify(currentPhotos.gallery_asset_ids??null)!==JSON.stringify(selectedPhotos))
      throw new HttpError(503,"The published photos changed. Please refresh.");
    const {data: currentClient,error: currentClientError}=await admin.from("listing_client_contacts")
      .select("revision,enabled").eq("listing_id",listing.id).eq("org_id",listing.org_id).maybeSingle();
    if(currentClientError || (currentClient?.revision??null)!==(clientRow?.revision??null) || (currentClient?.enabled??false)!==clientMode)
      throw new HttpError(503,"The listing contact changed. Please refresh.");
    if (!clientMode && JSON.stringify(await listingAgentIdentity(admin,listing.id))!==JSON.stringify(identity))
      throw new HttpError(503,"The listing agent changed. Please refresh.");
    // Byte requests need publication freshness too, not merely lineage approval.
    if (seg[1] === "delivery") {
      const {data:currentRender,error:currentRenderError}=await admin.from("renders").select("id,listing_id,slug,video_key,poster_key,stream_uid,published_at").eq("id",render.id).not("published_at","is",null).maybeSingle();
      if(currentRenderError)throw new HttpError(503,"Published media could not be verified.");
      if(!currentRender || currentRender.listing_id!==listing.id || currentRender.slug!==slug || !currentRender.published_at || (["video_key","poster_key","stream_uid"] as const).some(k=>currentRender[k]!==render[k]))throw new HttpError(404,"This media is no longer published.");
      await assertMediaVisible(admin,listing.id,visibleRefs);
      if(logo && JSON.stringify(await admittedBusinessLogo(admin,listing.org_id,identity?.org_business && (identity.org_business as Record<string,unknown>).business_logo_url,slug))!==JSON.stringify(logo))throw new HttpError(404,"The logo is no longer published.");
      await assertHostingAvailable(admin, listing.org_id);
      return json(deliveryEnvelope(slug,{orgId:listing.org_id,listingId:listing.id},visibleRefs.keys,render.stream_uid,logo?.key),200,{"Cache-Control":"no-store"});
    }
    const publicDetails = publicListingDetails(listing.details);
    await assertHostingAvailable(admin, listing.org_id);
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
        details: PUBLIC_MEDIA_PROXY ? publishedListingDetails(publicDetails,slug,visibleRefs.keys) : publicDetails,
        beds: listing.beds,
        baths: listing.baths,
        sqft: listing.sqft,
        price_cents: listing.price_cents,
        price: formatUSD(listing.price_cents as number | null),
        // Historical rows can predate the coarse-coordinate write policy.
        // Public maps must never re-expose their precise device coordinates.
        lat: typeof listing.lat === "number" && Number.isFinite(listing.lat) && Math.abs(listing.lat) <= 90
          ? Math.round(listing.lat * 1000) / 1000 : null,
        lng: typeof listing.lng === "number" && Number.isFinite(listing.lng) && Math.abs(listing.lng) <= 180
          ? Math.round(listing.lng * 1000) / 1000 : null,
        status,
        sold_at,
      },
      video_url,
      scrub_url,   // all-intra mp4 (byte-range) — use this for frame-accurate scrubbing
      hls_url,     // Cloudflare Stream HLS — adaptive fallback for very long / 4K tours
      poster: publishedR2Url(slug,render.poster_key as string),
      cover_url,
      duration_s: render.duration_s,
      speed_factor: render.speed_factor,
      published_at: render.published_at,
      chapters,
      agent_card,
      client_mode:clientMode,
      hide_rendprop_branding:clientMode && clientRow?.hide_rendprop_branding===true,
      cta: buildCta(listing),
      // Floor plan, promoted out of details so the host can render it above the
      // gallery on BOTH pages (it is property information, not branding).
      floorplan_url: planURL,
      // The listing's photos. Same reasoning as floorplan_url: property
      // information, so it goes to the unbranded twin too.
      gallery,
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
