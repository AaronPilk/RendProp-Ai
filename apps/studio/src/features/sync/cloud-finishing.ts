import type { StudioServices } from "../../data";
import type { AudioSourceRef, EditClip } from "../../editor/model";
import { decodeSavedMedia, downloadSavedMedia, loadCloudOriginal, saveCloudOriginal } from "../projects/cloud-media";

export async function savePropertyMusic(services: StudioServices, orgId: string, listingId: string, file: File, source: AudioSourceRef, signal: AbortSignal) {
  if (file.size !== source.size || source.size > 16 * 1024 * 1024 || !/^[a-f0-9]{64}$/.test(source.sha256)) throw new Error("Reselect the original music before saving it.");
  await saveCloudOriginal(services, orgId, file, source.sha256, signal);
  const result = await services.api("/functions/v1/studio/property-music", { orgId, method: "POST", signal, body: { listing_id: listingId, sha256: source.sha256, licensed: true } }) as { attached?: unknown; sha256?: unknown };
  if (result.attached !== true || result.sha256 !== source.sha256) throw new Error("Music uploaded, but its property attachment is unconfirmed. Retry Save music.");
}

export async function restorePropertyMusic(services: StudioServices, orgId: string, listingId: string, source: AudioSourceRef, signal: AbortSignal): Promise<File> {
  // A private file can exist without the explicit property attachment. Prefer
  // the binding endpoint so restoring cannot falsely mark an unshared file saved.
  const raw = await services.api(`/functions/v1/studio/property-music?listing_id=${listingId}&sha256=${source.sha256}`, { orgId, signal });
  const media = decodeSavedMedia(raw, source.sha256);
  if (!media || media.bytes !== source.size) throw new Error("Saved music does not match this edit. Reselect the original and save it again.");
  return downloadSavedMedia(media, signal);
}

export async function requestSourceAnalysis(services: StudioServices, orgId: string, clip: EditClip, source: { assetId: string; listingId: string } | undefined, signal: AbortSignal): Promise<unknown> {
  if (clip.source.kind !== "video") throw new Error("Choose a video recording with speech.");
  if (!source) throw new Error("Save this original with your property before transcribing it.");
  if (clip.source.size > 24_000_000 || clip.source.duration > 300) throw new Error("Speech analysis currently needs an MP4 copy under 24 MB and five minutes. You can also import timed subtitles.");
  const capability = await services.api("/functions/v1/studio/media-analysis", { orgId, signal }) as { available?: unknown };
  if (capability.available !== true) throw new Error("Automatic speech captions are not enabled yet. Import an SRT or WebVTT transcript to add reviewed captions now.");
  return services.api("/functions/v1/studio/media-analysis", { orgId, method: "POST", signal, timeoutMs: 150_000, idempotencyKey: crypto.randomUUID(), body: { listing_id: source.listingId, source_id: source.assetId, source_kind: "asset" } });
}

/** A local cache/private original remains useful after an attachment failed,
 * but never marks the property review as ready until its binding is confirmed. */
export { loadCloudOriginal };
