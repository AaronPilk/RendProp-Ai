import { HttpError } from "../_shared/http.ts";
import { assertHostingAvailable } from "../_shared/hosting-retention.ts";
import { assertMediaVisible, type MediaSourceRefs } from "../_shared/media-source-access.ts";

const RENDER_FIELDS = "id, job_id, listing_id, slug, duration_s, speed_factor, video_key, stream_uid, poster_key, staged, published_at, presentation_kind";
const LISTING_FIELDS = "id, org_id, agent_id, space_type, address, tagline, details, beds, baths, sqft, price_cents, zillow_url, main_photo_key, gallery_asset_ids, lat, lng, status, sold_at, deleted_at";
const LOCATION_FIELDS = "id, org_id, space_type, lat, lng, deleted_at";

/** One authoritative entry proof for full public tours and their narrow
 * location projection. No cached publication, hosting or presenter approval. */
// deno-lint-ignore no-explicit-any
export async function publishedTourContext(admin: any, slug: string, locationOnly = false) {
  const { data: render, error: rErr } = await admin.from("renders")
    .select(locationOnly ? "id, listing_id, slug, published_at" : RENDER_FIELDS)
    .eq("slug", slug).not("published_at", "is", null).maybeSingle();
  if (rErr) throw new HttpError(500, `Render lookup failed: ${rErr.message}`);
  if (!render) throw new HttpError(404, "Tour not found or not published");
  const { data: listing, error: lErr } = await admin.from("listings")
    .select(locationOnly ? LOCATION_FIELDS : LISTING_FIELDS).eq("id", render.listing_id).maybeSingle();
  if (lErr) throw new HttpError(500, `Listing lookup failed: ${lErr.message}`);
  if (!listing || listing.deleted_at) throw new HttpError(404, "Tour not found or not published");
  const visibleRefs: MediaSourceRefs & { keys: string[]; assets: string[] } = { renders: [render.id], assets: [], keys: [] };
  await Promise.all([assertHostingAvailable(admin, listing.org_id), assertMediaVisible(admin, listing.id, visibleRefs)]);
  return { render, listing, visibleRefs };
}

/** Return only a coarsened published location, with final fresh fences. This
 * intentionally does not read/sign gallery media, contacts or agent identity. */
// deno-lint-ignore no-explicit-any
export async function publishedLocation(admin: any, context: Awaited<ReturnType<typeof publishedTourContext>>) {
  const { render, listing, visibleRefs } = context;
  if (listing.space_type !== "real_estate" || typeof render.published_at !== "string" ||
      !Number.isFinite(Date.parse(render.published_at)) || Date.parse(render.published_at) > Date.now())
    throw new HttpError(404, "Tour location not found or not published");
  const [freshRender, freshListing] = await Promise.all([
    admin.from("renders").select("id,listing_id,slug,published_at").eq("id", render.id).not("published_at", "is", null).maybeSingle(),
    admin.from("listings").select(LOCATION_FIELDS).eq("id", listing.id).maybeSingle(),
  ]);
  if (freshRender.error || freshListing.error) throw new HttpError(503, "Published location could not be verified. Please refresh.");
  const current = freshListing.data;
  if (!freshRender.data || freshRender.data.id !== render.id || freshRender.data.listing_id !== listing.id ||
      freshRender.data.slug !== render.slug || freshRender.data.published_at !== render.published_at ||
      !current || current.deleted_at || current.id !== listing.id || current.org_id !== listing.org_id ||
      current.space_type !== listing.space_type) throw new HttpError(404, "Tour location is no longer published.");
  if (current.lat !== listing.lat || current.lng !== listing.lng) throw new HttpError(503, "The published location changed. Please refresh.");
  await Promise.all([assertMediaVisible(admin, listing.id, visibleRefs), assertHostingAvailable(admin, listing.org_id)]);
  const coarse = (value: unknown, limit: number) => typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= limit ? Math.round(value * 1000) / 1000 : null;
  return { slug: render.slug, space_type: "real_estate", published_at: render.published_at,
    listing: { lat: coarse(listing.lat, 90), lng: coarse(listing.lng, 180) } };
}
