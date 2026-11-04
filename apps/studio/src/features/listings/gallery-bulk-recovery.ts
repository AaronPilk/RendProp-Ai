import { StudioError } from "../../data/config";
import type { StudioServices } from "../../data/services";
import type { GalleryScope } from "./gallery-selection";
import { prepareGalleryCopy } from "./gallery-copy";

export const MAX_SAVED_SOURCE_BATCH = 50;

export type SavedPhotoSource = { id: string; caption: string };
export type SavedSourceProgress = { checked: number; total: number; prepared: number; unavailable: number };
export type SavedSourceResult = SavedSourceProgress & { unavailablePhotos: { id: string; caption: string; reason: string }[] };

/** Source candidates only. A filename or a renders-bucket flag never proves originality. */
export function savedSourceCandidates(
  photos: readonly { id: string; caption?: string | null }[],
  assets: readonly { id: string; kind: string; bucket: string; uploaded: boolean; storage_key: string }[],
  orgID: string,
  listingID: string,
): SavedPhotoSource[] {
  const root = `renders/${orgID}/${listingID}/`;
  const byID = new Map(assets.map(asset => [asset.id, asset]));
  return photos.flatMap(photo => {
    const asset = byID.get(photo.id);
    if (!asset || asset.kind !== "photo" || asset.bucket !== "renders" || !asset.uploaded ||
        !asset.storage_key.startsWith(root) || asset.storage_key.startsWith(`${root}gallery-`) ||
        asset.storage_key.includes("/contact-") || asset.storage_key.includes("/prepared-video/")) return [];
    return [{ id: photo.id, caption: photo.caption ?? "" }];
  }).filter((photo, index, all) => all.findIndex(other => other.id === photo.id) === index);
}

/** Server proof decides eligibility for each source; this never selects a listing photo or cover. */
export async function prepareSavedSourceBatch(
  services: StudioServices,
  scope: GalleryScope,
  sources: readonly SavedPhotoSource[],
  signal: AbortSignal,
  onProgress: (progress: SavedSourceProgress) => void,
  prepare: typeof prepareGalleryCopy = prepareGalleryCopy,
): Promise<SavedSourceResult> {
  const unique = [...new Map(sources.map(source => [source.id, source])).values()].slice(0, MAX_SAVED_SOURCE_BATCH);
  const progress: SavedSourceProgress = { checked: 0, total: unique.length, prepared: 0, unavailable: 0 };
  const unavailablePhotos: SavedSourceResult["unavailablePhotos"] = [];
  onProgress({ ...progress });
  for (const source of unique) {
    signal.throwIfAborted();
    let sourcePrepared = false;
    try {
      const result = await prepare(services, scope, source.id, source.caption, signal, {
        onSourcePrepared: () => { sourcePrepared = true; },
      });
      signal.throwIfAborted();
      if (!result.complete || result.photo?.listing_id !== scope.listing) throw new Error("The prepared photo could not be confirmed. Resume this photo before continuing.");
      progress.prepared++;
    } catch (error) {
      signal.throwIfAborted();
      // Only a definite refusal from the first source-proof request may be
      // skipped. A 409 during upload or finish needs the same photo resumed.
      if (sourcePrepared || !(error instanceof StudioError) || error.status !== 409) throw error;
      progress.unavailable++;
      unavailablePhotos.push({ id: source.id, caption: source.caption, reason: error.message });
    }
    progress.checked++;
    onProgress({ ...progress });
  }
  return { ...progress, unavailablePhotos };
}
