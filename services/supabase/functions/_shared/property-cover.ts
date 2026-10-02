import { assert, HttpError, throwRpc } from "./http.ts";
import { mediaVisibility } from "./media-source-access.ts";
import { bucketForKey } from "../studio/handler.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Scope = { orgId: string; listingId: string };
type GalleryPhoto = { id: string; listing_id: string; kind: string; bucket: string; uploaded: boolean; storage_key: string };

/** Gallery uploads are property photos. Originals, client headshots, posters,
 * arbitrary URLs and another property's storage objects cannot be a cover. */
export function propertyGalleryKey(key: unknown, scope: Scope): key is string {
  if (bucketForKey(key, scope) !== "renders") return false;
  const prefix = `renders/${scope.orgId}/${scope.listingId}/gallery-`;
  return typeof key === "string" && key.startsWith(prefix) &&
    key.length <= 500 && key.slice(prefix.length).length > 0 &&
    !key.slice(prefix.length).includes("/");
}

export function gallerySelection(value: unknown): string[] | null {
  if (value === null) return null;
  assert(Array.isArray(value) && value.length <= 40 &&
    value.every(id => typeof id === "string" && UUID.test(id)),400,
    "Choose up to 40 uploaded gallery photos.");
  const ids=value.map(id=>id.toLowerCase());
  assert(new Set(ids).size===ids.length,400,"Choose each gallery photo once.");
  return ids;
}

// deno-lint-ignore no-explicit-any
async function eligiblePhoto(admin: any, scope: Scope, selector: { id?: string; key?: string }): Promise<GalleryPhoto | null> {
  let query = admin.from("capture_assets")
    .select("id,listing_id,kind,bucket,storage_key,uploaded")
    .eq("listing_id", scope.listingId);
  query = selector.id ? query.eq("id", selector.id) : query.eq("storage_key", selector.key);
  const { data: photo, error } = await query.maybeSingle();
  if (error) throw new HttpError(503, "The main photo could not be verified. Please retry.");
  if (!photo || !UUID.test(photo.id ?? "") || photo.listing_id !== scope.listingId ||
    (selector.id && photo.id !== selector.id) || (selector.key && photo.storage_key !== selector.key) ||
    photo.kind !== "photo" || photo.bucket !== "renders" || photo.uploaded !== true ||
    !propertyGalleryKey(photo.storage_key, scope)) return null;
  const visible = await mediaVisibility(admin, scope.listingId, { assets: [photo.id], keys: [photo.storage_key] });
  return visible.assets[photo.id] === true && visible.keys[photo.storage_key] === true ? photo : null;
}

/** Explicit selection is ordered and bounded; no deleted version is inferred
 * from an old upload. Null retains the legacy automatic gallery behavior. */
// deno-lint-ignore no-explicit-any
export async function publishedPhotoPatch(admin: any, scope: Scope, body: Record<string, unknown>, existing: { gallery_asset_ids?: string[] | null; main_photo_key?: string | null }): Promise<{ gallery_asset_ids?: string[] | null; main_photo_key?: string | null }> {
  const hasGallery=Object.hasOwn(body,"gallery_asset_ids");
  const selection=hasGallery?gallerySelection(body.gallery_asset_ids):existing.gallery_asset_ids??null;
  if(hasGallery && selection) {
    const photos=await Promise.all(selection.map(id=>eligiblePhoto(admin,scope,{id})));
    assert(photos.every(Boolean),400,"Choose available uploaded gallery photos belonging to this listing.");
  }
  const cover=await mainPhotoPatch(admin,scope,body);
  const coverKey=cover.main_photo_key===undefined?existing.main_photo_key:cover.main_photo_key;
  if(selection!==null && coverKey) {
    const photo=await eligiblePhoto(admin,scope,{key:coverKey});
    if(!photo || !selection.includes(photo.id.toLowerCase())) {
      assert(cover.main_photo_key===undefined,400,"The main photo must be included in the published gallery.");
      // A gallery replacement may retire the old cover with the old version.
      if(hasGallery)cover.main_photo_key=null;
    }
  }
  return {...(hasGallery?{gallery_asset_ids:selection}:{}),...cover};
}

/** The database merges against its locked latest selection. A client snapshot
 * must never overwrite photos another phone or Studio added meanwhile. */
// deno-lint-ignore no-explicit-any
export async function appendPublishedPhotos(admin: any, scope: Scope, userId: string, body: Record<string, unknown>) {
  assert(!Object.hasOwn(body,"gallery_asset_ids"),400,"Add gallery photos or replace the selection, not both.");
  const additions=gallerySelection(body.gallery_add_asset_ids);
  assert(additions!==null,400,"Choose the uploaded gallery photos to add.");
  const cover=await mainPhotoPatch(admin,scope,body);
  const {data,error}=await admin.rpc("append_listing_gallery",{
    p_user:userId,p_org:scope.orgId,p_listing:scope.listingId,p_add:additions,
    p_set_main:Object.hasOwn(cover,"main_photo_key"),p_main_photo_key:cover.main_photo_key??null,
  });
  if(error) {
    if(error.message && /RP\d{3}:/.test(error.message))throwRpc(error.message);
    throw new HttpError(503,"The published gallery could not be saved. Please retry.");
  }
  if(!data || data.id!==scope.listingId || data.org_id!==scope.orgId || !Array.isArray(data.gallery_asset_ids))
    throw new HttpError(503,"The published gallery could not be verified. Please refresh.");
  return data;
}

/** Omission preserves the cover; explicit null clears it. The asset ID is a
 * virtual request field, resolved to the existing main_photo_key column. */
// deno-lint-ignore no-explicit-any
export async function mainPhotoPatch(admin: any, scope: Scope, body: Record<string, unknown>): Promise<{ main_photo_key?: string | null }> {
  const byId = Object.hasOwn(body, "main_photo_asset_id"), byKey = Object.hasOwn(body, "main_photo_key");
  assert(!(byId && byKey), 400, "Choose the main photo by asset ID or storage key, not both.");
  if (!byId && !byKey) return {};
  const value = byId ? body.main_photo_asset_id : body.main_photo_key;
  if (value === null) return { main_photo_key: null };
  assert(typeof value === "string" && (byId ? UUID.test(value) : propertyGalleryKey(value, scope)), 400,
    "Choose an uploaded gallery photo belonging to this listing.");
  const photo = await eligiblePhoto(admin, scope, byId ? { id: value.toLowerCase() } : { key: value });
  assert(photo, 400, "Choose an available uploaded gallery photo belonging to this listing.");
  return { main_photo_key: photo.storage_key };
}

/** Legacy invalid or revoked cover references are omitted. Visibility outages
 * fail closed, and successful references join the tour's final privacy check. */
// deno-lint-ignore no-explicit-any
export async function publicMainPhoto(admin: any, scope: Scope, key: unknown,
  publicUrl: (key: string) => string | null, refs: { assets: string[]; keys: string[] }, selection: readonly string[] | null = null): Promise<string | null> {
  if(selection?.length===0)return null;
  if (!propertyGalleryKey(key, scope)) return null;
  const photo = await eligiblePhoto(admin, scope, { key });
  if (!photo || (selection!==null && !selection.includes(photo.id))) return null;
  const url = publicUrl(photo.storage_key);
  if (url) { refs.assets.push(photo.id); refs.keys.push(photo.storage_key); }
  return url;
}
