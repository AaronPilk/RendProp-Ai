import { requireContentWrite } from "../_shared/library-access.ts";
import { assert, HttpError, json, pathSegments, readJsonLimited } from "../_shared/http.ts";
import { publicR2Url } from "../_shared/r2.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Row = Record<string, unknown>;
export interface ListingActionContext {
  userId: string;
  orgId: string;
  // Request-owned clients. Dedicated floor-plan attachment needs the service
  // client after actor and asset checks; ordinary details remain client-fenced.
  // deno-lint-ignore no-explicit-any
  db: any;
  // deno-lint-ignore no-explicit-any
  admin?: any;
  authorizeListing(listingId: string): Promise<void>;
  publicURL?: (key: string) => string | null;
}
export function canonicalPhotoKey(asset: Row, orgId: string, listingId: string): string {
  assert(asset.listing_id === listingId && asset.kind === "photo" && asset.uploaded === true,
    400, "Choose a completely uploaded photo from this property.");
  assert(asset.bucket === "uploads" || asset.bucket === "renders", 400, "Photo storage is unavailable.");
  const key = asset.storage_key;
  assert(typeof key === "string" && key.startsWith(`${asset.bucket}/${orgId}/${listingId}/`) &&
    key.length < 1024 && !key.includes("..") && !/[?#\\]/.test(key), 400, "Photo does not belong to this property.");
  assert(!key.includes("/contact-"), 400, "Client headshots cannot be added to property media.");
  return key;
}
export function photoRow(asset: Row, orgId: string, listingId: string, caption: string, provenance?: Row | null): Row {
  const key = canonicalPhotoKey(asset, orgId, listingId);
  if (provenance) {
    assert(provenance.listing_id === listingId && provenance.org_id === orgId && provenance.altered_key === key,
      400, "The disclosure does not belong to this photo.");
    assert(typeof provenance.original_key === "string" && provenance.original_key.startsWith(`renders/${orgId}/${listingId}/`) && !provenance.original_key.includes(".."),
      400, "Upload the untouched original before adding this altered photo to the gallery.");
    assert(typeof provenance.disclosure === "string" && provenance.disclosure.length > 0, 400, "This photo is missing its disclosure.");
  }
  return {
    id: asset.id, listing_id: listingId,
    original_key: provenance ? provenance.original_key : key,
    enhanced_key: provenance ? key : null,
    is_staged: !!provenance,
    caption: provenance ? `${caption ? `${caption} · ` : ""}${String(provenance.disclosure).slice(0, 1000)}` : caption || null,
    sort: 0,
  };
}

/** Editing a label never removes a required public disclosure. */
export function galleryCaption(input: unknown, disclosure: string | null): string | null {
  assert(typeof input === "string" && input.length <= 2000, 400, "Use a photo caption of 500 characters or fewer.");
  let label = input.trim();
  if (disclosure && label.endsWith(disclosure)) label = label.slice(0, -disclosure.length).trim().replace(/·\s*$/, "").trim();
  assert(label.length <= 500, 400, "Use a photo caption of 500 characters or fewer, excluding its required disclosure.");
  return disclosure ? `${label ? `${label} · ` : ""}${disclosure}` : label || null;
}

function photoRPCError(error: { message?: unknown } | null | undefined): void {
  if (!error) return;
  const match = /^RP(400|403|404|409): (.{1,240})$/.exec(String(error.message));
  throw new HttpError(match ? Number(match[1]) : 503, match ? match[2] : "Gallery changes could not be saved. Refresh before retrying.");
}

async function editGallery(body: Row, listingId: string, context: ListingActionContext): Promise<Response> {
  const action = body.action;
  assert(action === "caption" || action === "cover" || action === "reorder", 400, "Choose a gallery action.");
  if (action === "reorder" || action === "cover") {
    if (action === "cover") {
      assert(typeof body.photo_id === "string" && UUID.test(body.photo_id), 400, "Choose a gallery photo.");
      assert(body.expected_main_photo_key === null || typeof body.expected_main_photo_key === "string" && body.expected_main_photo_key.length <= 1024, 400, "Refresh the property cover before changing it.");
    } else {
      for (const ids of [body.expected_order, body.photo_ids]) assert(Array.isArray(ids) && ids.length > 0 && ids.length <= 500 && ids.every(id => typeof id === "string" && UUID.test(id)) && new Set(ids).size === ids.length, 400, "Choose each gallery photo once, up to 500 photos.");
    }
    assert(context.admin, 503, "Gallery saving is temporarily unavailable.");
    const { data, error } = await context.admin.rpc("studio_gallery_update_v2", {
      p_actor: context.userId,
      p_org_id: context.orgId, p_listing_id: listingId, p_action: action,
      p_photo_id: action === "cover" ? body.photo_id : null,
      p_expected: action === "cover" ? body.expected_main_photo_key : body.expected_order,
      p_value: action === "reorder" ? body.photo_ids : null,
    });
    if (error) {
      const match = /^RP(400|403|404|409): (.{1,240})$/.exec(String(error.message));
      throw new HttpError(match ? Number(match[1]) : 503, match ? match[2] : "Gallery changes could not be saved. Refresh before retrying.");
    }
    assert(data?.ok === true, 503, "The saved gallery could not be confirmed. Refresh before retrying.");
    return json(data, 200, { "cache-control": "no-store" });
  }
  assert(typeof body.photo_id === "string" && UUID.test(body.photo_id), 400, "Choose a gallery photo.");
  assert(body.expected_caption === null || typeof body.expected_caption === "string" && body.expected_caption.length <= 4000, 400, "Refresh this caption before editing it.");
  assert(typeof body.caption === "string" && body.caption.length <= 2000, 400, "Use a photo caption of 500 characters or fewer.");
  assert(context.admin, 503, "Gallery saving is temporarily unavailable.");
  const { data, error } = await context.admin.rpc("studio_photo_caption", {
    p_actor: context.userId, p_org: context.orgId, p_listing: listingId,
    p_photo: body.photo_id, p_expected: body.expected_caption, p_caption: body.caption,
  });
  photoRPCError(error);
  assert(data?.ok === true && data.photo?.id === body.photo_id && data.photo?.listing_id === listingId,
    503, "The saved caption could not be confirmed. Refresh before retrying.");
  return json(data, 200, { "cache-control": "no-store" });
}

/** Adds existing verified media to the native listing. The browser never chooses storage keys or disclosure state. */
export async function handleListingActions(req: Request, context: ListingActionContext): Promise<Response | null> {
  const segments = pathSegments(req, "studio");
  if (segments.length !== 1 || !["photos", "floorplan"].includes(segments[0])) return null;
  assert(req.method === "POST" || req.method === "PATCH" && segments[0] === "photos", 405, "Use POST to attach media or PATCH to edit a gallery.");
  const body = await readJsonLimited<Row>(req, 65536);
  const listingId = body.listing_id, assetId = body.asset_id;
  assert(typeof listingId === "string" && UUID.test(listingId), 400, "Choose a property.");
  await context.authorizeListing(listingId);
  await requireContentWrite(context.admin, context.userId, context.orgId, listingId);
  if (req.method === "PATCH") return await editGallery(body, listingId, context);
  assert(typeof assetId === "string" && UUID.test(assetId), 400, "Choose an uploaded photo.");
  const { data: asset, error: assetError } = await context.db.from("capture_assets")
    .select("id,listing_id,kind,bucket,uploaded,storage_key,content_type")
    .eq("id", assetId).eq("listing_id", listingId).maybeSingle();
  if (assetError) throw new HttpError(503, "Uploaded photo could not be checked.");
  assert(asset, 404, "Uploaded photo not found.");
  const key = canonicalPhotoKey(asset, context.orgId, listingId);
  assert(!/\/contact-[^/]+$/.test(key),400,"Client headshots cannot be attached as property photos or floor plans.");
  if (segments[0] === "floorplan") {
    assert(asset.bucket === "renders" && ["image/jpeg", "image/png", "image/webp"].includes(asset.content_type),
      400, "Upload the floor plan as JPG, PNG, or WebP.");
    const url = (context.publicURL ?? publicR2Url)(key);
    assert(url && new URL(url).protocol === "https:", 503, "Published media is temporarily unavailable.");
    assert(context.admin, 503, "Floor plan saving is temporarily unavailable.");
    const { data: listing, error: listingError } = await context.db.from("listings").select("id,details")
      .eq("id", listingId).eq("org_id", context.orgId).is("deleted_at", null).maybeSingle();
    if (listingError) throw new HttpError(503, "Property could not be checked.");
    assert(listing, 404, "Property not found.");
    const old = listing.details;
    const details = { ...(old && typeof old === "object" && !Array.isArray(old) ? old : {}), floorplan_url: url, floorplan_asset_id: asset.id };
    assert(JSON.stringify(details).length <= 16000, 400, "This property has too much detail to attach a floor plan.");
    // Recheck current actor/asset authority and compare the exact details in
    // one transaction. The RPC merges only the two attachment keys.
    const { data, error } = await context.admin.rpc("studio_attach_floorplan", {
      p_actor: context.userId, p_org: context.orgId, p_listing: listingId,
      p_asset: asset.id, p_expected: old, p_url: url,
    });
    if (error) {
      if (error.code === "42501") throw new HttpError(403, "Your account no longer permits attaching a floor plan.");
      if (error.code === "P0002") throw new HttpError(404, "Property not found in this workspace.");
      if (error.code === "PT409" || error.code === "40001") throw new HttpError(409, "This property changed on another device. Refresh and attach the floor plan again.");
      if (error.code === "22023") throw new HttpError(400, "Choose an uploaded floor plan from this property.");
      throw new HttpError(503, "Floor plan could not be saved.");
    }
    assert(data?.id === listingId, 503, "The saved floor plan could not be confirmed. Please retry.");
    return json({ ok: true, listing_id: listingId, asset_id: asset.id, floorplan_url: url }, 200, { "cache-control": "no-store" });
  }
  const caption = typeof body.caption === "string" ? body.caption.trim().slice(0, 500) : "";
  assert(asset.bucket === "renders", 400, "Upload this photo to the gallery before publishing it.");
  if (body.provenance_id !== undefined) assert(typeof body.provenance_id === "string" && UUID.test(body.provenance_id), 400, "Invalid photo disclosure.");
  assert(context.admin, 503, "Gallery saving is temporarily unavailable.");
  // The database derives the immutable photo keys and disclosure, and checks
  // current actor authority under locks. Browser metadata cannot set flags.
  const { data, error } = await context.admin.rpc("studio_attach_photo", {
    p_actor: context.userId, p_org: context.orgId, p_listing: listingId,
    p_asset: asset.id, p_caption: caption, p_provenance: body.provenance_id ?? null,
  });
  photoRPCError(error);
  assert(data?.ok === true && typeof data.created === "boolean" && data.photo?.id === asset.id && data.photo?.listing_id === listingId,
    503, "The saved photo could not be confirmed. Refresh before retrying.");
  return json({ ok: true, photo: data.photo }, data.created ? 201 : 200, { "cache-control": "no-store" });
}
