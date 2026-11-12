import { assert } from "../_shared/http.ts";
import { isInternalAerialMedia } from "../_shared/property-media-purpose.ts";

/** RLS-visible row identity is required before this purpose check. The database
 * repeats the refusal at publication; browser presentation is never authority. */
export function assertOrdinaryRecordedMedia(row: { listing_id: string; storage_key: string }, scope: { orgId: string; listingId: string }): void {
  assert(row.listing_id === scope.listingId, 404, "Video upload not found.");
  assert(!isInternalAerialMedia(row.storage_key, scope), 409,
    "Aerial opening files must use their saved opening review and typed video composition.");
}
