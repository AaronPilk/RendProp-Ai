import type { StudioPhoto } from "../../data/contracts";
import { imageFromURL, prepareImage, type SourceImage } from "./media";
import type { Edit } from "./model";

/** The image being edited and the untouched source are different assets.
 * No existing server field certifies the history of legacy native edit chains. */
export type PhotoSource = SourceImage & {
  original: SourceImage | null;
  originalVerified: boolean;
  disclosures: string[];
  edits: string[];
  stageBase?: PhotoSource;
};
export type PhotoDelivery = {
  file: File;
  original: File | null;
  originalPreview: string | null;
  originalVerified: boolean;
  disclosures: string[];
  edits: string[];
  provenanceId: string | null;
};
export function importedPhoto(source: SourceImage): PhotoSource {
  return { ...source, original: source, originalVerified: true, disclosures: [], edits: [] };
}
export async function propertyPhoto(photo: StudioPhoto, signal: AbortSignal): Promise<PhotoSource> {
  const altered = photo.isAltered || photo.isStaged;
  const [current, original] = await Promise.all([
    imageFromURL(photo.url, "working-photo.jpg", signal),
    altered && photo.originalUrl && photo.originalUrl !== photo.url
      ? imageFromURL(photo.originalUrl, "paired-source.jpg", signal).catch(() => { signal.throwIfAborted(); return null; })
      : Promise.resolve(null),
  ]);
  signal.throwIfAborted();
  return { ...current, original: altered ? original : current, originalVerified: !altered || !!original && photo.originalVerified === true,
    disclosures: altered && photo.caption ? [photo.caption] : [], edits: altered ? ["Earlier AI edits"] : [] };
}
/** Main editing always starts from the actual paired original, never the saved result. */
export async function propertyOriginalPhoto(photo: StudioPhoto, signal: AbortSignal): Promise<PhotoSource> {
  const altered = photo.isAltered || photo.isStaged;
  const url = altered ? photo.originalUrl : photo.url;
  if (!url) throw new Error("This saved result has no available original. Import the original to make a new edit.");
  const original = await imageFromURL(url, "original-photo.jpg", signal);
  signal.throwIfAborted();
  return { ...importedPhoto(original), originalVerified: !altered || photo.originalVerified === true };
}
export type PhotoLibraryTab = "original" | "declutter" | "stage" | "saved";
export function photosInTab(photos: readonly StudioPhoto[], tab: PhotoLibraryTab): StudioPhoto[] {
  if (tab === "original") return photos.filter(photo => !(photo.isAltered || photo.isStaged) || !!photo.originalUrl);
  if (tab === "saved") return photos.filter(photo => (photo.isAltered || photo.isStaged) && photo.editKind !== "declutter" && photo.editKind !== "stage");
  return photos.filter(photo => (photo.isAltered || photo.isStaged) && photo.editKind === tab);
}
export function inputForEdit(source: PhotoSource, edit: Edit): PhotoSource {
  return edit === "stage" && source.stageBase ? source.stageBase : source;
}
const labels: Record<Edit, string> = {
  declutter: "Digitally decluttered", stage: "Virtually staged", sky: "Sky replaced",
  twilight: "Digital twilight", lawn: "Landscaping altered", custom: "Custom AI edit",
};
export function photoDelivery(source: PhotoSource, file: File, edit: Edit, disclosure: string, provenanceId: string | null): PhotoDelivery {
  const input = inputForEdit(source, edit);
  return { file, original: source.original?.file ?? null, originalPreview: source.original?.preview ?? null,
    originalVerified: source.originalVerified, disclosures: [...new Set(input.disclosures.filter(value => value !== disclosure)), disclosure],
    edits: [...new Set([...input.edits, labels[edit]])], provenanceId };
}
export async function continuePhoto(source: PhotoSource, result: PhotoDelivery, edit: Edit, signal: AbortSignal): Promise<PhotoSource> {
  const current = await prepareImage(result.file, signal);
  signal.throwIfAborted();
  return { ...current, original: source.original, originalAssetId: source.originalAssetId,
    originalVerified: result.originalVerified, disclosures: [...result.disclosures], edits: [...result.edits],
    ...(source.stageBase ? { stageBase: source.stageBase } : edit === "stage" ? { stageBase: source } : {}) };
}
