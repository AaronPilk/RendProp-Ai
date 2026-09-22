import { HttpError } from "../_shared/http.ts";
import type { StudioContext } from "./context.ts";
type Row = Record<string, any>;
/** Call only with a result read from the private server-owned result table.
 * The existing set_provenance_media RPC resolves photos only. A completed
 * generated video instead attaches these verified server-derived references. */
export async function attachGeneratedVideoProof(
  context: StudioContext,
  result: Row,
  metadata: Row,
  assetId: string,
  key: string,
): Promise<void> {
  if (!result.provenance_id) return;
  if (result.user_id !== context.userId || result.org_id !== context.orgId) {
    throw new HttpError(
      403,
      "This generated result does not belong to the current account.",
    );
  }
  const [outputRead, proofRead, sourceRead] = await Promise.all([
    context.admin.from("capture_assets").select(
      "id,listing_id,uploaded,kind,bucket,storage_key",
    )
      .eq("id", assetId).eq("listing_id", result.listing_id).maybeSingle(),
    context.admin.from("media_provenance").select(
      "id,org_id,listing_id,original_key,altered_key",
    )
      .eq("id", result.provenance_id).eq("org_id", context.orgId).eq(
        "listing_id",
        result.listing_id,
      ).maybeSingle(),
    metadata.source_asset_id
      ? context.admin.from("capture_assets").select(
        "id,listing_id,uploaded,kind,bucket,storage_key",
      )
        .eq("id", metadata.source_asset_id).eq("listing_id", result.listing_id)
        .maybeSingle()
      : Promise.resolve({ data: null, error: null }),
  ]);
  if (outputRead.error || proofRead.error || sourceRead.error) {
    throw new HttpError(
      503,
      "The stored video and original could not be checked.",
    );
  }
  const output = outputRead.data,
    proof = proofRead.data,
    source = sourceRead.data,
    prefix = `renders/${context.orgId}/${result.listing_id}/`;
  if (
    !output || output.id !== assetId ||
    output.listing_id !== result.listing_id || output.uploaded !== true ||
    output.kind !== "video" || output.bucket !== "renders" ||
    output.storage_key !== key || !key.startsWith(prefix) || key.includes("..")
  ) {
    throw new HttpError(
      409,
      "The generated video upload has not been confirmed for this property.",
    );
  }
  if (
    !proof || proof.id !== result.provenance_id ||
    proof.org_id !== context.orgId || proof.listing_id !== result.listing_id ||
    proof.altered_key && proof.altered_key !== key
  ) {
    throw new HttpError(
      409,
      "The generated video's disclosure no longer matches this result.",
    );
  }
  if (
    metadata.source_asset_id &&
    (!source || source.id !== metadata.source_asset_id ||
      source.listing_id !== result.listing_id || source.uploaded !== true ||
      source.bucket !== "renders" ||
      !String(source.storage_key).startsWith(prefix) ||
      String(source.storage_key).includes(".."))
  ) {
    throw new HttpError(
      409,
      "The original source of this generated video is no longer available.",
    );
  }
  if (
    ["reel", "aerial"].includes(metadata.video_kind) &&
    (!source || source.kind !== "photo")
  ) {
    throw new HttpError(
      409,
      "This property animation needs its original saved photograph.",
    );
  }
  const originalKey = source?.storage_key ?? proof.original_key ?? null;
  if (proof.original_key && proof.original_key !== originalKey) {
    throw new HttpError(
      409,
      "The saved original no longer matches this generated result.",
    );
  }
  let update = context.admin.from("media_provenance").update({
    original_key: originalKey,
    altered_key: key,
  })
    .eq("id", proof.id).eq("org_id", context.orgId).eq(
      "listing_id",
      result.listing_id,
    );
  update = proof.altered_key == null
    ? update.is("altered_key", null)
    : update.eq("altered_key", proof.altered_key);
  update = proof.original_key == null
    ? update.is("original_key", null)
    : update.eq("original_key", proof.original_key);
  const saved = await update.select("id").maybeSingle();
  if (saved.error) {
    throw new HttpError(
      503,
      "The video is stored. Check status again to finish linking its disclosure.",
    );
  }
  if (!saved.data) {
    throw new HttpError(
      409,
      "The disclosure changed while this video was being saved. Check status again.",
    );
  }
}
