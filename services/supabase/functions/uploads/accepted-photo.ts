import { assert } from "../_shared/http.ts";
import { listingLibraryScope } from "../_shared/library-access.ts";
import { PHOTO_OUTPUT_MAX_BYTES } from "../_shared/photo-output-policy.ts";
import { ensureAcceptedPhotoPublication, type PublicationClient, type PublicationIO } from "../_shared/photo-publication.ts";

type Row = Record<string, any>;
type Client = PublicationClient & { from(table: string): any };
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const SHA = /^[a-f0-9]{64}$/;

/** Complete the existing publication receipt for one exact accepted gallery
 * alias. Transport is already durable; a refused/uncertain preparation is
 * retried through this same completion, never by replacing the uploaded file.
 * This does not select the photo, change its cover, or rewrite edit history. */
export async function prepareAcceptedGalleryUpload(
  admin: Client, actor: string, asset: Row, requestSignal?: AbortSignal,
  io?: PublicationIO,
): Promise<void> {
  if (asset.kind !== "photo" || asset.bucket !== "renders" || asset.uploaded !== true ||
      asset.transport_version !== 2 || typeof asset.storage_key !== "string" ||
      !asset.storage_key.split("/").at(-1)?.startsWith("gallery-") ||
      typeof asset.sha256 !== "string" || !SHA.test(asset.sha256) ||
      !Number.isSafeInteger(asset.bytes) || asset.bytes < 1 || asset.bytes > PHOTO_OUTPUT_MAX_BYTES ||
      !["image/jpeg", "image/png", "image/webp"].includes(asset.content_type)) return;

  const signal = AbortSignal.any([...(requestSignal ? [requestSignal] : []), AbortSignal.timeout(90_000)]);
  // A metadata match is only a bounded work prefilter, never publication proof.
  // Do not filter by verdict/owner: a known but withdrawn or foreign result must
  // reach the canonical refusal, rather than be relabelled an ordinary photo.
  // Match the existing photo_edit_evidence_output_identity expression index.
  const candidates = await admin.from("photo_edit_evidence").select("id")
    .eq("output->>sha256", asset.sha256).eq("output->>bytes", String(asset.bytes))
    .eq("output->>mime", asset.content_type)
    .limit(1).abortSignal(signal);
  assert(!candidates.error && Array.isArray(candidates.data) && candidates.data.length <= 1,
    503, "The saved photo checks could not be confirmed. Retry this same upload.");
  if (candidates.data.length === 0) return;
  assert(UUID.test(actor) && UUID.test(asset.id) && UUID.test(asset.listing_id) && asset.upload_aborted === false,
    409, "The saved photo upload changed. Retry this same upload.");

  const scoped: PublicationClient = { rpc: (name, args) => {
    const query: any = admin.rpc(name, args);
    return typeof query.abortSignal === "function" ? query.abortSignal(signal) : query;
  } };
  const scope = await listingLibraryScope(scoped, actor, asset.listing_id, true);
  const reservation = await admin.from("upload_reservations")
    .select("asset_id,actor_id,org_id,listing_id,state,spec")
    .eq("asset_id", asset.id).eq("actor_id", actor).maybeSingle().abortSignal(signal);
  assert(!reservation.error, 503, "The saved photo upload receipt could not be confirmed. Retry this same upload.");
  const r = reservation.data;
  assert(r && r.asset_id === asset.id && r.actor_id === actor && r.org_id === scope.org_id &&
    r.listing_id === asset.listing_id && r.state === "completed" && r.spec?.key_role === "gallery" &&
    r.spec.listing_id === asset.listing_id && r.spec.kind === "photo" && r.spec.bucket === "renders" &&
    r.spec.bytes === asset.bytes,
    409, "The saved photo no longer matches its completed upload.");
  // This existing path verifies the real target and retained input/output
  // bodies, current ownership/library, accepted evidence, and source-copy ETag.
  // Reserve/finish are idempotent; the media visibility guard is not bypassed.
  const prepared = await ensureAcceptedPhotoPublication(scoped,
    { orgId: scope.org_id, libraryOrgId: scope.library_org_id, listingId: asset.listing_id },
    actor, asset.id, { expected: { sha256: asset.sha256, bytes: asset.bytes }, signal }, io);
  assert(prepared && prepared.outputAssetID === asset.id && prepared.listingID === asset.listing_id,
    409, "The saved edit could not be prepared. Its uploaded photo and listing selection are kept.");
}
