import { assert, HttpError, json, pathSegments, readJsonLimited } from "../_shared/http.ts";
import { publicR2Url } from "../_shared/r2.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Row = Record<string, unknown>;
export interface ListingActionContext {
  userId: string;
  orgId: string;
  // Request-owned Supabase clients. No service-client mutations are needed here.
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
    const { data, error } = await context.db.rpc("studio_gallery_update", {
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
  const { data: photo, error: photoError } = await context.db.from("photos")
    .select("id,listing_id,original_key,enhanced_key,is_staged,caption,sort,is_main")
    .eq("id", body.photo_id).eq("listing_id", listingId).maybeSingle();
  if (photoError) throw new HttpError(503, "This gallery photo could not be checked.");
  assert(photo, 404, "Gallery photo not found.");
  const key = photo.enhanced_key || photo.original_key;
  assert(typeof key === "string" && key.startsWith(`renders/${context.orgId}/${listingId}/`) && !key.includes(".."), 400, "Choose a published gallery photo.");
  const { data: proof, error: proofError } = await context.db.from("media_provenance")
    .select("disclosure").eq("org_id", context.orgId).eq("listing_id", listingId).eq("altered_key", key).limit(1).maybeSingle();
  if (proofError) throw new HttpError(503, "The photo disclosure could not be checked.");
  const disclosure = typeof proof?.disclosure === "string" && proof.disclosure.trim() ? proof.disclosure.trim().slice(0, 1000) : photo.is_staged ? "Virtually staged / AI-altered photo" : null;
  const caption = galleryCaption(body.caption, disclosure);
  if (photo.caption === caption) return json({ ok: true, photo }, 200, { "cache-control": "no-store" });
  assert(photo.caption === body.expected_caption, 409, "This caption changed on another device. Your text is kept; refresh the photo before saving again.");
  let update = context.db.from("photos").update({ caption }).eq("id", photo.id).eq("listing_id", listingId).eq("is_staged", photo.is_staged);
  for (const column of ["caption", "original_key", "enhanced_key"]) update = photo[column] === null ? update.is(column, null) : update.eq(column, photo[column]);
  const { data, error } = await update.select("id,listing_id,caption,is_staged,sort,is_main").maybeSingle();
  if (error) throw new HttpError(503, "Photo caption could not be saved.");
  assert(data, 409, "This photo changed on another device. Your text is kept; refresh the photo before saving again.");
  return json({ ok: true, photo: data }, 200, { "cache-control": "no-store" });
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
  const { data: member, error: memberError } = await context.db.from("memberships").select("role")
    .eq("org_id", context.orgId).eq("user_id", context.userId).maybeSingle();
  if (memberError) throw new HttpError(503, "Workspace permissions could not be checked.");
  assert(member && ["owner", "admin", "agent"].includes(member.role), 403, "Your role does not permit editing property media.");
  if (req.method === "PATCH") return await editGallery(body, listingId, context);
  assert(typeof assetId === "string" && UUID.test(assetId), 400, "Choose an uploaded photo.");
  const { data: asset, error: assetError } = await context.db.from("capture_assets")
    .select("id,listing_id,kind,bucket,uploaded,storage_key,content_type")
    .eq("id", assetId).eq("listing_id", listingId).maybeSingle();
  if (assetError) throw new HttpError(503, "Uploaded photo could not be checked.");
  assert(asset, 404, "Uploaded photo not found.");
  const key = canonicalPhotoKey(asset, context.orgId, listingId);
  if (segments[0] === "floorplan") {
    assert(asset.bucket === "renders" && ["image/jpeg", "image/png", "image/webp"].includes(asset.content_type),
      400, "Upload the floor plan as JPG, PNG, or WebP.");
    const url = (context.publicURL ?? publicR2Url)(key);
    assert(url && new URL(url).protocol === "https:", 503, "Published media is temporarily unavailable.");
    const { data: listing, error: listingError } = await context.db.from("listings").select("id,details")
      .eq("id", listingId).eq("org_id", context.orgId).is("deleted_at", null).maybeSingle();
    if (listingError) throw new HttpError(503, "Property could not be checked.");
    assert(listing, 404, "Property not found.");
    const old = listing.details;
    const details = { ...(old && typeof old === "object" && !Array.isArray(old) ? old : {}), floorplan_url: url, floorplan_asset_id: asset.id };
    assert(JSON.stringify(details).length <= 16000, 400, "This property has too much detail to attach a floor plan.");
    // Compare the document read above so a simultaneous phone save cannot be silently overwritten.
    let update = context.db.from("listings").update({ details }).eq("id", listingId).eq("org_id", context.orgId).is("deleted_at", null);
    update = old === null ? update.is("details", null) : update.eq("details", JSON.stringify(old));
    const { data, error } = await update.select("id,details").maybeSingle();
    if (error) throw new HttpError(503, "Floor plan could not be saved.");
    assert(data, 409, "This property changed on another device. Refresh and attach the floor plan again.");
    return json({ ok: true, listing_id: listingId, asset_id: asset.id, floorplan_url: url }, 200, { "cache-control": "no-store" });
  }
  const caption = typeof body.caption === "string" ? body.caption.trim().slice(0, 500) : "";
  assert(asset.bucket === "renders", 400, "Upload this photo to the gallery before publishing it.");
  let provenance: Row | null = null;
  let query = context.db.from("media_provenance").select("id,org_id,listing_id,original_key,altered_key,kind,disclosure")
    .eq("org_id", context.orgId).eq("listing_id", listingId).eq("altered_key", key);
  if (body.provenance_id !== undefined) {
    assert(typeof body.provenance_id === "string" && UUID.test(body.provenance_id), 400, "Invalid photo disclosure.");
    query = query.eq("id", body.provenance_id);
  }
  const { data: found, error: provenanceError } = await query.limit(1).maybeSingle();
  if (provenanceError) throw new HttpError(503, "Photo disclosure could not be checked.");
  provenance = found;
  if (body.provenance_id) assert(provenance, 400, "Attach this photo to its disclosure before adding it to the gallery.");
  const row = photoRow(asset, context.orgId, listingId, caption, provenance);
  // The verified capture asset UUID is the idempotency key. Reopening/retrying cannot add duplicate gallery rows.
  const { data: prior, error: priorError } = await context.db.from("photos").select("id,listing_id,original_key,enhanced_key,is_staged,caption,sort")
    .eq("id", asset.id).maybeSingle();
  if (priorError) throw new HttpError(503, "Gallery could not be checked.");
  if (prior) {
    assert(prior.listing_id === listingId, 409, "This photo is already associated with another property.");
    // A replay must never downgrade an already-disclosed photo to an original.
    assert(prior.original_key === row.original_key && prior.enhanced_key === row.enhanced_key && prior.is_staged === row.is_staged, 409, "The saved photo changed. Refresh the gallery.");
    return json({ ok: true, photo: prior }, 200, { "cache-control": "no-store" });
  }
  const { data, error } = await context.db.from("photos").insert(row).select("id,listing_id,caption,is_staged,sort").single();
  if (error) throw new HttpError(409, "The photo could not be added. Refresh the gallery before retrying.");
  return json({ ok: true, photo: data }, 201, { "cache-control": "no-store" });
}
