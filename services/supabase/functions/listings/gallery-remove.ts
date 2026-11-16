import { assert, HttpError, throwRpc } from "../_shared/http.ts";
import { gallerySelection } from "../_shared/property-cover.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Authority = { rpc(name: string, args: Record<string, unknown>): PromiseLike<{data: any; error: any}> };

/** A partial/cloud library may remove only its explicitly known assets. The
 * database compares the full fresh snapshot under its listing lock; this call
 * never replaces unknown remote photos or revokes any stored media. */
export async function removePublishedPhotos(admin: Authority, scope: {orgId: string; listingId: string}, actor: string,
  body: Record<string, unknown>, idempotencyKey: string | null): Promise<Record<string, unknown>> {
  const keys = ["gallery_remove_asset_ids", "gallery_remove_operation_id", "expected_gallery_asset_ids", "expected_main_photo_key"];
  assert(Object.keys(body).length === keys.length && keys.every(k => Object.hasOwn(body, k)), 400,
    "Send the saved photo-removal operation and its current gallery snapshot only.");
  assert(typeof body.gallery_remove_operation_id === "string" && UUID.test(body.gallery_remove_operation_id), 400, "Keep a valid saved photo-removal operation.");
  const operation = body.gallery_remove_operation_id.toLowerCase();
  assert(idempotencyKey?.toLowerCase() === `gallery-remove:${operation}`, 409, "Retry the same saved photo-removal operation.");
  const remove = gallerySelection(body.gallery_remove_asset_ids);
  assert(remove !== null && remove.length > 0, 400, "Choose the exact uploaded photos to remove.");
  const expected = gallerySelection(body.expected_gallery_asset_ids);
  const cover = body.expected_main_photo_key;
  assert(cover === null || typeof cover === "string" && cover.length <= 500, 400, "Keep the current saved cover snapshot.");
  const {data, error} = await admin.rpc("remove_listing_gallery", {
    p_user: actor, p_org: scope.orgId, p_listing: scope.listingId, p_operation: operation,
    p_remove: remove, p_expected: expected, p_expected_main: cover,
  });
  if (error) {
    if (error.code === "PT409") throw new HttpError(409, "The listing photos changed elsewhere. Refresh the gallery before removing this photo.", "gallery_selection_changed");
    if (typeof error.message === "string" && /RP\d{3}:/.test(error.message)) throwRpc(error.message);
    throw new HttpError(503, "The photo removal couldn't be confirmed. Keep this saved operation and retry.");
  }
  const ack = data?.gallery_remove;
  assert(data && data.id === scope.listingId && data.org_id === scope.orgId && Array.isArray(data.gallery_asset_ids) &&
    ack?.operation_id === operation && ack.actor_id === actor && typeof ack.replayed === "boolean" &&
    JSON.stringify(ack.requested_asset_ids) === JSON.stringify(remove) && Array.isArray(ack.removed_asset_ids) &&
    ack.removed_asset_ids.every((id: unknown) => typeof id === "string" && remove.includes(id)) &&
    new Set(ack.removed_asset_ids).size === ack.removed_asset_ids.length, 503,
    "The saved photo-removal receipt could not be verified. Keep the same operation and retry.");
  return data;
}

/** Hash/byte identities for matching an imported local file, never guessed from
 * a photos-table UUID, filename or a different property's source. */
export async function publishedGallerySnapshot(admin: Authority, scope: {orgId: string; listingId: string}, actor: string): Promise<Record<string, unknown>> {
  const {data, error} = await admin.rpc("listing_gallery_snapshot", {p_user: actor, p_org: scope.orgId, p_listing: scope.listingId});
  if (error) {
    if (typeof error.message === "string" && /RP\d{3}:/.test(error.message)) throwRpc(error.message);
    throw new HttpError(503, "The listing photo selection couldn't be refreshed. Please retry.");
  }
  assert(data && data.id === scope.listingId && data.org_id === scope.orgId && Array.isArray(data.gallery_assets) && data.gallery_assets.length <= 100 &&
    (data.gallery_asset_ids === null || Array.isArray(data.gallery_asset_ids)) &&
    data.gallery_assets.every((a: any) => a && UUID.test(a.asset_id) && /^[a-f0-9]{64}$/.test(a.sha256) && Number.isSafeInteger(a.bytes) && a.bytes > 0),
    503, "The listing's saved photo identities couldn't be verified.");
  return data;
}
